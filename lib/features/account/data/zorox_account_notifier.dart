import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/addons/data/addon_repository.dart';
import '../../../core/cloudstream/cloudstream_models.dart';
import '../../../core/cloudstream/cloudstream_repository.dart';
import '../../../core/extensions/models/extension_plugin.dart';
import '../../../core/logger/app_logger.dart';
import '../../../core/nuvio/data/nuvio_repository.dart';
import '../../../core/storage/library_repository.dart';
import '../../../core/storage/secure_token_storage.dart';
import '../../../core/storage/storage_service.dart';
import '../../extensions/providers/extensions_controller.dart';
import '../../library/presentation/history_provider.dart';
import '../../../core/theme/accent_color.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/theme/theme_variant.dart';
import '../../home/presentation/home_row_prefs_provider.dart';
import '../../library/presentation/library_provider.dart';
import '../../profiles/data/zeus_profile.dart';
import '../../profiles/data/zeus_profiles_notifier.dart';
import '../../search/domain/search_plugin_filter.dart';
import '../../settings/presentation/general_settings_provider.dart';
import '../../settings/presentation/player_settings_provider.dart';
import 'zorox_backup.dart';
import 'zorox_settings_sync.dart';
import 'zorox_sync_client.dart';

/// The ZoroX account: login + cloud sync, and Export/Import backup.
///
/// Plain Riverpod ([NotifierProvider]) — no codegen, so no `build_runner`.
///
/// What is stored where:
///   - Session token + email: platform keychain/keystore
///     ([SecureTokenStorage], never Hive, never plain text).
///   - The password is NEVER stored anywhere on the device.
///   - Sync server URL + last-synced time: the settings box
///     ([StorageService.setString]).
///   - The backup itself: history box + library box + the two plugin
///     systems' own stores; this feature only reads them and restores into
///     them through their public APIs.
class ZoroxAccountState {
  const ZoroxAccountState({
    this.email,
    this.loggedIn = false,
    this.busy = false,
    this.error,
    this.lastSyncedAt,
    this.cloudConfigured = true,
    this.workerUrl = kZoroxSyncWorkerUrl,
    this.usingDefaultServer = true,
    this.sessionExpired = false,
    this.autoSyncEnabled = true,
  });

  /// "Sync automatically" (v9): on by default. When on and logged in, the
  /// app syncs by itself on open and on return to the foreground.
  final bool autoSyncEnabled;

  final String? email;
  final bool loggedIn;
  final bool busy;

  /// The last failure, in the user's words; cleared on the next attempt.
  final String? error;
  final DateTime? lastSyncedAt;

  /// True when a sync server URL is set (cloud sync is possible).
  final bool cloudConfigured;

  /// The server in use: the saved one, else the built-in default.
  final String workerUrl;

  /// True when no server of the user's own is saved (v8).
  final bool usingDefaultServer;

  /// True after the server refused the saved session (401) — also from a
  /// background auto-upload. The card says "log in again" until a login.
  final bool sessionExpired;

  ZoroxAccountState copyWith({
    String? email,
    bool? loggedIn,
    bool? busy,
    String? error,
    bool clearError = false,
    DateTime? lastSyncedAt,
    bool? cloudConfigured,
    String? workerUrl,
    bool? usingDefaultServer,
    bool? sessionExpired,
    bool? autoSyncEnabled,
  }) => ZoroxAccountState(
    autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
    email: email ?? this.email,
    loggedIn: loggedIn ?? this.loggedIn,
    busy: busy ?? this.busy,
    error: clearError ? null : (error ?? this.error),
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    cloudConfigured: cloudConfigured ?? this.cloudConfigured,
    workerUrl: workerUrl ?? this.workerUrl,
    usingDefaultServer: usingDefaultServer ?? this.usingDefaultServer,
    sessionExpired: sessionExpired ?? this.sessionExpired,
  );
}

final zoroxAccountProvider =
    NotifierProvider<ZoroxAccountNotifier, ZoroxAccountState>(
      ZoroxAccountNotifier.new,
    );

/// What the card and the dialog say after the server refused the session.
const String kSessionExpiredMessage = 'Session expired. Log in again.';

class ZoroxAccountNotifier extends Notifier<ZoroxAccountState> {
  static const String _kTokenKey = 'zorox_account_token';
  static const String _kEmailKey = 'zorox_account_email';
  static const String _kWorkerUrlKey = 'zorox_sync_worker_url';
  static const String _kLastSyncedKey = 'zorox_last_synced_at';

  /// "Sync automatically" (v9). Stored only when switched off; this
  /// device's own choice, never part of a backup.
  static const String _kAutoSyncOffKey = 'zorox_auto_sync_off';

  /// When a synced setting last changed on this device (v9), Unix ms.
  /// What decides whether the cloud's settings or this device's are the
  /// newer ones in an automatic sync. Never part of a backup's settings.
  static const String _kSettingsChangedAtKey = 'zorox_settings_changed_at';

  /// The automatic sync's throttle (v9): at most once per 10 minutes.
  final AutoSyncGate _autoSyncGate = AutoSyncGate();
  bool _autoSyncRunning = false;

  /// True while a restore is writing into the stores (v9). The change
  /// listeners below see those writes; they must not read them as the
  /// user changing something (no upload scheduled, no "settings changed
  /// here" stamp) — a restore never triggers a sync of its own.
  bool _restoring = false;
  StreamSubscription<String>? _settingsWatch;

  /// How long after a change the auto-upload waits, so ten history saves in
  /// a row become one upload instead of ten.
  static const Duration _autoSyncDebounce = Duration(seconds: 10);

  final _client = ZoroxSyncClient();
  Timer? _autoSyncTimer;
  bool _restored = false;

  /// Re-entrancy guards for the file pickers. A double-tap on Import (or
  /// Export) fired `pickFile` twice, and file_picker throws
  /// `PlatformException(multiple_request)` for a second pick while one is
  /// already open — the import then died before the backup was even read.
  /// While one is in progress, further taps are ignored (they return null,
  /// which the UI already treats as "user cancelled").
  bool _importInProgress = false;
  bool _exportInProgress = false;

  @override
  ZoroxAccountState build() {
    ref.onDispose(() {
      _autoSyncTimer?.cancel();
      unawaited(_settingsWatch?.cancel());
    });
    if (!_restored) {
      _restored = true;
      unawaited(_restoreSession());
    }
    // Auto-upload (debounced) when anything the backup covers changes while
    // logged in: a watch-history save, a ZoroX plugin install/remove, or
    // a CloudStream repo/plugin change. requestAutoSync() no-ops when logged
    // out or unconfigured, and debounces 10s, so frequent saves collapse
    // into one upload. The listeners are set up once here — the provider is
    // keep-alive once built — so they fire for the whole session, including
    // changes made from the player, which never opens the Account screen.
    ref.listen(watchHistoryProvider, (_, _) => requestAutoSync());
    ref.listen(extensionsControllerProvider, (_, _) => requestAutoSync());
    ref.listen(cloudStreamRepositoryProvider, (_, _) => requestAutoSync());
    // v9: add-ons and synced settings too, on the same 10 s debounce.
    ref.listen(addonRepositoryProvider, (_, _) => requestAutoSync());
    ref.listen(nuvioRepositoryProvider, (_, _) => requestAutoSync());
    _watchSyncedSettings();
    return const ZoroxAccountState();
  }

  /// Watches the settings box for a change to an allow-listed key: stamps
  /// "settings changed here, now" and schedules the debounced upload.
  /// Writes made by a restore are ignored.
  void _watchSyncedSettings() {
    if (_settingsWatch != null) return;
    try {
      _settingsWatch = ref
          .read(storageServiceProvider)
          .watchSettingKeys()
          .listen((key) {
            if (_restoring || !kSyncedSettingKeys.contains(key)) return;
            unawaited(_stampSettingsChanged());
            requestAutoSync();
          }, onError: (Object _) {});
    } catch (e) {
      talker.warning('[ZoroX Account] settings watch not started: $e');
    }
  }

  Future<void> _stampSettingsChanged([int? at]) async {
    try {
      await ref
          .read(storageServiceProvider)
          .setString(
            _kSettingsChangedAtKey,
            '${at ?? DateTime.now().millisecondsSinceEpoch}',
          );
    } catch (_) {
      // A missing stamp only makes the cloud's settings win once.
    }
  }

  int _settingsChangedAt() {
    try {
      return int.tryParse(
            ref.read(storageServiceProvider).getString(_kSettingsChangedAtKey) ??
                '',
          ) ??
          0;
    } catch (_) {
      return 0;
    }
  }

  /// Switches "Sync automatically" (v9).
  Future<void> setAutoSyncEnabled(bool enabled) async {
    await ref
        .read(storageServiceProvider)
        .setString(_kAutoSyncOffKey, enabled ? null : '1');
    if (ref.mounted) state = state.copyWith(autoSyncEnabled: enabled);
  }

  // --- session ---------------------------------------------------------------

  Future<void> _restoreSession() async {
    try {
      final tokens = ref.read(secureTokenStorageProvider);
      final token = await tokens.read(_kTokenKey);
      final email = await tokens.read(_kEmailKey);
      final storage = ref.read(storageServiceProvider);
      final workerUrl = _workerUrl(storage);
      final lastSynced = _lastSynced(storage);
      if (!ref.mounted) return;
      state = state.copyWith(
        email: email,
        loggedIn: token != null && token.isNotEmpty && email != null,
        workerUrl: workerUrl,
        cloudConfigured: workerUrl.isNotEmpty,
        usingDefaultServer: _savedWorkerUrl(storage).isEmpty,
        lastSyncedAt: lastSynced,
        autoSyncEnabled: storage.getString(_kAutoSyncOffKey) == null,
      );
      // Cold start (v9): the session is known now — sync once, quietly.
      unawaited(autoSync());
      // Profiles: fetch the list so the gate knows whether to show the
      // picker or the first-profile setup. Never throws: a failure
      // leaves the cached list (offline). Logged out (Build 2), the
      // device's local-only profiles load instead.
      if (state.loggedIn) {
        unawaited(refreshZeusProfiles());
      } else {
        unawaited(
          ref
              .read(zeusProfilesProvider.notifier)
              .refreshLocalZeusProfiles(),
        );
      }
    } catch (e) {
      talker.warning('[ZoroX Account] restoring the session failed: $e');
    }
  }

  String _savedWorkerUrl(StorageService storage) =>
      storage.getString(_kWorkerUrlKey)?.trim() ?? '';

  String _workerUrl(StorageService storage) =>
      effectiveSyncServerUrl(storage.getString(_kWorkerUrlKey));

  DateTime? _lastSynced(StorageService storage) {
    final raw = storage.getString(_kLastSyncedKey);
    final millis = raw == null ? null : int.tryParse(raw);
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<String> _requireWorkerUrl() async {
    final url = _workerUrl(ref.read(storageServiceProvider));
    ZoroxSyncClient.checkBaseUrl(url);
    return url;
  }

  Future<String?> _token() =>
      ref.read(secureTokenStorageProvider).read(_kTokenKey);

  Future<void> _markSynced() async {
    final now = DateTime.now();
    await ref
        .read(storageServiceProvider)
        .setString(_kLastSyncedKey, '${now.millisecondsSinceEpoch}');
    if (ref.mounted) state = state.copyWith(lastSyncedAt: now);
  }

  // --- auth ------------------------------------------------------------------

  static final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  static String? validateCredentials(String email, String password) {
    if (!_emailPattern.hasMatch(email.trim())) {
      return 'Enter a valid email address.';
    }
    if (password.length < 8) {
      return 'Password must be at least 8 characters.';
    }
    return null;
  }

  /// Creates the account, then uploads the local backup so the account
  /// starts with everything already on this device.
  Future<bool> register({
    required String email,
    required String password,
  }) async {
    final problem = validateCredentials(email, password);
    if (problem != null) {
      state = state.copyWith(error: problem);
      return false;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final baseUrl = await _requireWorkerUrl();
      final token = await _client.register(
        baseUrl,
        email.trim().toLowerCase(),
        password,
      );
      await _saveSession(email.trim().toLowerCase(), token);
      // A fresh account has no cloud backup to download; upload local.
      await uploadBackup();
      // Profiles (Build 1): a fresh account has none — the gate shows
      // the first-profile setup, and the migration runs from there.
      await refreshZeusProfiles();
      return true;
    } on ZoroxSyncException catch (e) {
      if (ref.mounted) state = state.copyWith(busy: false, error: e.message);
      return false;
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(busy: false, error: '$e');
      }
      return false;
    } finally {
      if (ref.mounted && state.busy) state = state.copyWith(busy: false);
    }
  }

  /// Logs in, downloads the cloud backup and restores it (newest wins per
  /// item), then uploads the merged result so the server holds the union.
  Future<bool> login({required String email, required String password}) async {
    final problem = validateCredentials(email, password);
    if (problem != null) {
      state = state.copyWith(error: problem);
      return false;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final baseUrl = await _requireWorkerUrl();
      final token = await _client.login(
        baseUrl,
        email.trim().toLowerCase(),
        password,
      );
      await _saveSession(email.trim().toLowerCase(), token);
      // v9: on login the cloud copy's settings apply. And the upload only
      // follows a download that worked (or found no backup yet): a cloud
      // copy this app could not read is never overwritten.
      final outcome = await _downloadAndRestore(cloudSettingsWin: true);
      if (outcome != _DownloadOutcome.failed) await uploadBackup();
      // Profiles (Build 1): fetch the list (and work out the migration
      // case) now that the session is live.
      await refreshZeusProfiles();
      return true;
    } on ZoroxSyncException catch (e) {
      if (ref.mounted) state = state.copyWith(busy: false, error: e.message);
      return false;
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(busy: false, error: '$e');
      }
      return false;
    } finally {
      if (ref.mounted && state.busy) state = state.copyWith(busy: false);
    }
  }

  Future<void> _saveSession(String email, String token) async {
    final tokens = ref.read(secureTokenStorageProvider);
    await tokens.write(_kTokenKey, token);
    await tokens.write(_kEmailKey, email);
    if (ref.mounted) {
      state = state.copyWith(
        email: email,
        loggedIn: true,
        sessionExpired: false,
      );
    }
  }

  /// Logs out on the server (best effort) and deletes the local session.
  /// Backups and local data stay on the device.
  Future<void> logout() async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final token = await _token();
      final baseUrl = _workerUrl(ref.read(storageServiceProvider));
      if (token != null && baseUrl.isNotEmpty) {
        await _client.logout(baseUrl, token);
      }
    } finally {
      final tokens = ref.read(secureTokenStorageProvider);
      await tokens.delete(_kTokenKey);
      await tokens.delete(_kEmailKey);
    // Profiles (Build 2): back onto the device's local-only profiles.
    // The server cache is deleted (a next login must not flash the old
    // account's list) and the local list loads; the local profiles and
    // their data survive. The server list is untouched — the next login
    // re-fetches it.
    await ref.read(zeusProfilesProvider.notifier).switchToLocalProfiles();
      if (ref.mounted) {
        state = state.copyWith(
          email: null,
          loggedIn: false,
          busy: false,
          lastSyncedAt: null,
        );
      }
    }
  }

  // --- profiles (Build 1) --------------------------------------------------------

  /// Fetches the profile list after auth (login / register / cold start),
  /// so the gate knows whether to show the picker or the first-profile
  /// setup. Never throws: a failure leaves the cached list (offline).
  Future<void> refreshZeusProfiles() async {
    if (!state.loggedIn) return;
    try {
      final baseUrl = await _requireWorkerUrl();
      final token = await _token();
      if (token == null || token.isEmpty) return;
      await ref
          .read(zeusProfilesProvider.notifier)
          .refreshAfterAuth(baseUrl: baseUrl, token: token);
    } catch (_) {
      // Offline or unconfigured: the cached list stands.
    }
  }

  /// Migration case 2 (design §9): the account has no profiles yet, so
  /// the current Continue Watching / My List becomes the first profile.
  ///
  /// Creates the profile (the PIN record is made on this device),
  /// switches to it, copies the legacy history + library into its boxes,
  /// uploads the copy as that profile's backup (and once to the legacy
  /// key, so old clients are not left with a stale-empty backup), then
  /// clears the legacy boxes and marks the migration done.
  ///
  /// Returns the profile, or null when the profile itself could not be
  /// created. A failed upload does NOT fail the migration: the profile
  /// and its local copy exist, the legacy boxes are left alone, and the
  /// next sync round (or Build 2's move prompt) picks the data up — the
  /// server backup is the safety net, and nothing is lost either way.
  Future<ZeusProfile?> completeZeusProfileMigration({
    required String name,
    required String color,
    required String pin,
  }) async {
    if (!state.loggedIn) return null;
    final profilesNotifier = ref.read(zeusProfilesProvider.notifier);
    final profile = await profilesNotifier.createZeusProfile(
      name: name,
      color: color,
      pin: pin,
    );
    if (profile == null) {
      if (ref.mounted) {
        state = state.copyWith(
          error:
              ref.read(zeusProfilesProvider).error ??
              'Could not create the profile.',
        );
      }
      return null;
    }
    final storage = ref.read(storageServiceProvider);
    await profilesNotifier.switchZeusProfile(profile.id);
    await storage.copyLegacyHistoryAndLibraryToZeusProfile(profile.id);
    try {
      final baseUrl = await _requireWorkerUrl();
      final token = await _token();
      if (token == null || token.isEmpty) {
        throw const ZoroxSyncException(
          'Session expired. Log in again.',
          statusCode: 401,
        );
      }
      final backup = await collectBackup();
      await _client.upload(baseUrl, token, backup.toJson(), profileId: profile.id);
      await _client.upload(baseUrl, token, backup.toJson());
      await storage.clearLegacyHistoryAndLibrary();
      await profilesNotifier.markMigrated();
      await _markSynced();
    } catch (e) {
      // The profile and its local copy exist; the upload is retried by
      // the next sync round. The legacy boxes stay until it succeeds.
      talker.warning('[ZoroX Account] profile migration upload failed: $e');
      if (ref.mounted) {
        state = state.copyWith(
          error:
              'The profile was created, but its backup could not be uploaded yet. Your data is safe on this device.',
        );
      }
    }
    return profile;
  }

  /// Migration §9 case 3 (Build 2): merges the device's legacy history /
  /// My List into [profileId] (newest wins, the same rule as a backup
  /// restore), uploads that profile's backup so the cloud gets the
  /// merged data, then clears the legacy boxes and marks the migration
  /// done. The target must be the active profile — only its backup can
  /// be uploaded. Returns false (with [state.error]) when the upload
  /// fails; the legacy boxes stay, so the prompt asks again. Nothing is
  /// lost either way: a re-run merges idempotently.
  Future<bool> moveLegacyDataIntoZeusProfile(String profileId) async {
    if (!state.loggedIn) return false;
    final activeId = ref.read(zeusProfilesProvider).activeProfileId;
    if (activeId != profileId) {
      if (ref.mounted) {
        state = state.copyWith(
          error: 'Open that profile first, then move the data into it.',
        );
      }
      return false;
    }
    final storage = ref.read(storageServiceProvider);
    await storage.mergeLegacyHistoryAndLibraryIntoZeusProfile(profileId);
    final uploaded = await _uploadBackup(silent: true);
    if (!uploaded) {
      if (ref.mounted) {
        state = state.copyWith(
          error: 'Could not upload the merged backup. Try again.',
        );
      }
      return false;
    }
    await storage.clearLegacyHistoryAndLibrary();
    final profilesNotifier = ref.read(zeusProfilesProvider.notifier);
    await profilesNotifier.markMigrated();
    profilesNotifier.clearLegacyMovePending();
    return true;
  }

  /// §9 case 3's other way out (Build 2): discards the device's legacy
  /// data and marks the migration done, so the prompt never asks again.
  Future<void> deleteLegacyData() async {
    final storage = ref.read(storageServiceProvider);
    await storage.clearLegacyHistoryAndLibrary();
    final profilesNotifier = ref.read(zeusProfilesProvider.notifier);
    await profilesNotifier.markMigrated();
    profilesNotifier.clearLegacyMovePending();
  }

  // --- sync server URL --------------------------------------------------------

  /// Saves the user's own sync server (empty clears it and goes back to
  /// the built-in default). Only `https://` is accepted.
  Future<bool> setWorkerUrl(String rawUrl) async {
    final url = rawUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (url.isNotEmpty && !url.startsWith('https://')) {
      state = state.copyWith(
        error: 'The sync server URL must start with https://',
      );
      return false;
    }
    await ref
        .read(storageServiceProvider)
        .setString(_kWorkerUrlKey, url.isEmpty ? null : url);
    if (ref.mounted) {
      final effective = effectiveSyncServerUrl(url);
      state = state.copyWith(
        workerUrl: effective,
        cloudConfigured: effective.isNotEmpty,
        usingDefaultServer: url.isEmpty,
        clearError: true,
      );
    }
    return true;
  }

  // --- cloud sync ---------------------------------------------------------------

  /// Uploads the current local backup. Returns false (with [state.error])
  /// when not logged in, not configured, or the server refuses.
  Future<bool> uploadBackup() => _uploadBackup();

  Future<bool> _uploadBackup({bool silent = false}) async {
    if (!state.loggedIn) return false;
    if (!silent) state = state.copyWith(busy: true, clearError: true);
    try {
      final baseUrl = await _requireWorkerUrl();
      final token = await _token();
      if (token == null || token.isEmpty) {
        throw const ZoroxSyncException(
          'Session expired. Log in again.',
          statusCode: 401,
        );
      }
      final backup = await collectBackup();
      // Profiles (Build 2): regular uploads write the ACTIVE profile's
      // backup key, not the legacy key. No active profile (picker
      // pending, or no profiles yet) keeps the legacy upload, as before.
      await _client.upload(
        baseUrl,
        token,
        backup.toJson(),
        profileId: ref.read(zeusProfilesProvider).activeProfileId,
      );
      await _markSynced();
      return true;
    } on ZoroxSyncException catch (e) {
      if (e.sessionExpired) {
        await _expireSession();
      } else if (!silent && ref.mounted) {
        state = state.copyWith(error: e.message);
      }
      return false;
    } catch (e) {
      if (!silent && ref.mounted) state = state.copyWith(error: '$e');
      return false;
    } finally {
      if (!silent && ref.mounted && state.busy) {
        state = state.copyWith(busy: false);
      }
    }
  }

  /// The server refused the saved session (v8): drop it and say so on the
  /// card, so a background auto-upload that hits a 401 is not silent. The
  /// email stays, local data is untouched; logging in again clears this.
  Future<void> _expireSession() async {
    try {
      await ref.read(secureTokenStorageProvider).delete(_kTokenKey);
    } catch (e) {
      talker.warning('[ZoroX Account] dropping the expired session: $e');
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      loggedIn: false,
      sessionExpired: true,
      error: kSessionExpiredMessage,
    );
  }

  /// Downloads the cloud backup and restores it. Returns the restore
  /// report, or null when the account has never synced (nothing to
  /// restore) or the download failed ([state.error] says why).
  Future<ZoroxRestoreReport?> downloadAndRestore() async {
    ZoroxRestoreReport? report;
    await _downloadAndRestore(onReport: (r) => report = r);
    return report;
  }

  /// "Sync now" (v9): download, merge, upload — the same round the
  /// automatic sync makes, but with the busy state and errors shown.
  Future<bool> syncNow() async {
    if (!state.loggedIn) return false;
    final outcome = await _downloadAndRestore();
    if (outcome == _DownloadOutcome.failed) return false;
    return uploadBackup();
  }

  /// One silent sync round for the active profile (Build 2): run after
  /// a profile switch, so the new profile's cloud backup lands in its
  /// boxes before the user notices. No-op when logged out or when no
  /// profile is active — logged-out data stays local. The round is
  /// guarded by the same running flag as [autoSync], so a switch during
  /// a cold-start round does not run twice.
  Future<bool> syncActiveZeusProfile() async {
    if (!state.loggedIn) return false;
    if (_autoSyncRunning) return false;
    if (ref.read(zeusProfilesProvider).activeProfileId == null) {
      return false;
    }
    _autoSyncRunning = true;
    try {
      final outcome = await _downloadAndRestore(silent: true);
      if (outcome == _DownloadOutcome.failed) return true;
      await _uploadBackup(silent: true);
      return true;
    } catch (e) {
      talker.warning('[ZoroX Account] profile switch sync failed: $e');
      return true;
    } finally {
      _autoSyncRunning = false;
    }
  }

  /// The download + restore step shared by login, Sync now and the
  /// automatic sync.
  ///
  /// [cloudSettingsWin]: the cloud's settings replace this device's
  /// whatever their age (login). Otherwise they apply only when they are
  /// newer than this device's last settings change.
  ///
  /// [silent]: no busy state and no error text — for the automatic sync.
  /// A refused session (401) is never silent: it still flips the card to
  /// "Session expired".
  Future<_DownloadOutcome> _downloadAndRestore({
    bool cloudSettingsWin = false,
    bool silent = false,
    void Function(ZoroxRestoreReport report)? onReport,
  }) async {
    if (!state.loggedIn) return _DownloadOutcome.failed;
    if (!silent) state = state.copyWith(busy: true, clearError: true);
    try {
      final baseUrl = await _requireWorkerUrl();
      final token = await _token();
      if (token == null || token.isEmpty) {
        throw const ZoroxSyncException(
          'Session expired. Log in again.',
          statusCode: 401,
        );
      }
      final remote = await _client.download(
        baseUrl,
        token,
        // Profiles (Build 2): download the ACTIVE profile's backup, not
        // the legacy key. No active profile keeps the legacy download.
        profileId: ref.read(zeusProfilesProvider).activeProfileId,
      );
      if (remote == null) return _DownloadOutcome.nothingStored;
      final report = await restoreBackup(
        ZoroxBackup.fromJson(remote),
        settings: cloudSettingsWin
            ? SettingsRestore.always
            : SettingsRestore.ifNewer,
      );
      onReport?.call(report);
      await _markSynced();
      return _DownloadOutcome.restored;
    } on ZoroxSyncException catch (e) {
      if (e.sessionExpired) {
        await _expireSession();
      } else if (!silent && ref.mounted) {
        state = state.copyWith(error: e.message);
      }
      return _DownloadOutcome.failed;
    } catch (e) {
      if (!silent && ref.mounted) state = state.copyWith(error: '$e');
      return _DownloadOutcome.failed;
    } finally {
      if (!silent && ref.mounted && state.busy) {
        state = state.copyWith(busy: false);
      }
    }
  }

  /// The automatic sync (v9): on cold start and on return to the
  /// foreground. Quietly downloads, merges and uploads — no busy state, no
  /// error text; only a refused session shows (the v8 "Session expired").
  ///
  /// It does nothing when logged out, switched off, already running,
  /// while a manual sync is busy, while the player is on top
  /// ([playerOnTop]), or within 10 minutes of the last automatic sync.
  /// Returns whether a round actually ran.
  ///
  /// No loops: the restore inside it does not schedule an upload (see
  /// [_restoring]), the round ends with its own single upload, and an
  /// upload never causes a download — only the app opening or returning
  /// does, and that is throttled.
  Future<bool> autoSync({bool playerOnTop = false, DateTime? now}) async {
    final at = now ?? DateTime.now();
    if (_autoSyncRunning || !state.cloudConfigured) return false;
    if (!_autoSyncGate.mayRun(
      now: at,
      loggedIn: state.loggedIn,
      enabled: state.autoSyncEnabled,
      playerOnTop: playerOnTop,
      busy: state.busy,
    )) {
      return false;
    }
    // Profiles (Build 1): no sync round until a profile is active, when
    // the account has profiles. With no profiles (or none fetched yet)
    // the legacy sync runs as today — the migration copies from the
    // legacy boxes after it.
    final zeusProfiles = ref.read(zeusProfilesProvider);
    if (zeusProfiles.profiles.isNotEmpty &&
        zeusProfiles.activeProfileId == null) {
      return false;
    }
    _autoSyncGate.markRan(at);
    _autoSyncRunning = true;
    try {
      final outcome = await _downloadAndRestore(silent: true);
      if (outcome == _DownloadOutcome.failed) return true;
      if (!ref.mounted || !state.loggedIn) return true;
      // The round's own upload replaces any upload a change scheduled.
      _autoSyncTimer?.cancel();
      await _uploadBackup(silent: true);
      return true;
    } catch (e) {
      talker.warning('[ZoroX Account] automatic sync failed: $e');
      return true;
    } finally {
      _autoSyncRunning = false;
    }
  }

  /// The debounced auto-upload: call whenever history, plugins or library
  /// change while logged in. Ten saves in a row become one upload, ten
  /// seconds after the last one. A failure is logged, not shown — a
  /// background sync must never pop an error over what the user is doing;
  /// the next manual Sync now reports it.
  void requestAutoSync() {
    if (_restoring) return;
    if (!state.loggedIn || !state.cloudConfigured) return;
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer(_autoSyncDebounce, () async {
      if (!ref.mounted || !state.loggedIn) return;
      try {
        await _uploadBackup(silent: true);
      } catch (e) {
        talker.warning('[ZoroX Account] auto-upload failed: $e');
      }
    });
  }

  // --- backup: collect ---------------------------------------------------------

  /// Reads everything the backup covers. Plugin collection never fails the
  /// backup: a repository that will not load is skipped and the rest still
  /// goes in (the restore step reports what is missing).
  Future<ZoroxBackup> collectBackup() async {
    final storage = ref.read(storageServiceProvider);
    final history = storage.getAllHistoryEntries();
    final library = ref
        .read(libraryRepositoryProvider)
        .getLibraryItems()
        .map((item) => item.toJson())
        .toList();

    var zoroxRepos = <String>[];
    var zoroxPlugins = <Map<String, String>>[];
    try {
      final extensions = ref.read(extensionsControllerProvider.notifier);
      await extensions.ensureInitialized();
      final extensionsState = ref.read(extensionsControllerProvider);
      zoroxRepos = [for (final repo in extensionsState.repositories) repo.url];
      zoroxPlugins = [
        for (final plugin in extensionsState.installedPlugins)
          {
            'packageName': plugin.packageName,
            'repositoryUrl': plugin.repositoryUrl ?? '',
          },
      ];
    } catch (e) {
      talker.warning('[ZoroX Account] ZoroX plugins not backed up: $e');
    }

    var cloudstreamRepos = <String>[];
    var cloudstreamPlugins = <Map<String, String>>[];
    try {
      final cloudstream = ref.read(cloudStreamRepositoryProvider.notifier);
      await cloudstream.load();
      final cloudstreamState = ref.read(cloudStreamRepositoryProvider);
      cloudstreamRepos = [
        for (final repo in cloudstreamState.repositories) repo.url,
      ];
      cloudstreamPlugins = [
        for (final plugin in cloudstreamState.installed)
          {
            'internalName': plugin.info.internalName,
            'name': plugin.info.name,
            'url': plugin.info.url,
            'repositoryUrl': plugin.info.repositoryUrl,
          },
      ];
    } catch (e) {
      talker.warning('[ZoroX Account] CloudStream plugins not backed up: $e');
    }

    // v9: Stremio add-ons, as manifest URLs in the user's order. An
    // add-on whose URL carries a credential (a debrid or API key in its
    // configuration) is left out — a backup never carries a key.
    var stremioAddons = <Map<String, dynamic>>[];
    var addonsSkipped = 0;
    try {
      await ref.read(addonRepositoryProvider.notifier).whenLoaded();
      for (final addon in ref.read(addonRepositoryProvider).addons) {
        if (addonUrlCarriesSecret(addon.manifestUrl)) {
          addonsSkipped++;
          continue;
        }
        stremioAddons.add({
          'url': addon.manifestUrl,
          'enabled': addon.enabled,
        });
      }
    } catch (e) {
      stremioAddons = [];
      talker.warning('[ZoroX Account] add-ons not backed up: $e');
    }

    // v9: Nuvio repositories and which of their providers are on or off.
    // Provider settings and the Nuvio TMDB key are never read.
    var nuvioRepos = <Map<String, dynamic>>[];
    bool? nuvioEnabled;
    try {
      await ref.read(nuvioRepositoryProvider.notifier).whenLoaded();
      final nuvio = ref.read(nuvioRepositoryProvider);
      nuvioEnabled = nuvio.enabled;
      for (final repo in nuvio.repos) {
        if (addonUrlCarriesSecret(repo.manifestUrl)) {
          addonsSkipped++;
          continue;
        }
        nuvioRepos.add({
          'url': repo.manifestUrl,
          'disabled': repo.disabledScrapers.toList()..sort(),
          'enabledOverrides': repo.enabledOverrides.toList()..sort(),
        });
      }
    } catch (e) {
      nuvioRepos = [];
      talker.warning('[ZoroX Account] Nuvio repositories not backed up: $e');
    }

    // v9: the allow-listed settings, and when they last changed here.
    Map<String, dynamic>? settings;
    try {
      settings = collectSyncedSettings(storage.getRawSetting);
    } catch (e) {
      talker.warning('[ZoroX Account] settings not backed up: $e');
    }

    return ZoroxBackup(
      exportedAt: DateTime.now().millisecondsSinceEpoch,
      history: history,
      library: library,
      zoroxRepos: zoroxRepos,
      zoroxPlugins: zoroxPlugins,
      cloudstreamRepos: cloudstreamRepos,
      cloudstreamPlugins: cloudstreamPlugins,
      stremioAddons: stremioAddons,
      nuvioRepos: nuvioRepos,
      nuvioEnabled: nuvioEnabled,
      settings: settings,
      settingsUpdatedAt: _settingsChangedAt(),
      addonsSkippedForSecrets: addonsSkipped,
      // Profiles (Build 1): the active profile's id, or null for the
      // legacy (logged-out) backup. The history/library above already
      // come from the active pair, so the stamp and the contents agree.
      profileId: ref.read(zeusProfilesProvider).activeProfileId,
    );
  }

  // --- backup: restore ---------------------------------------------------------

  /// Merges [backup] into this device: newest timestamp wins per history
  /// entry, bookmarks are added when missing, repositories are re-added and
  /// their missing plugins re-installed. Never throws for one bad entry;
  /// failures are collected in the report.
  ///
  /// v9: add-ons and Nuvio repositories that are missing are re-added
  /// (what is already installed is left exactly as it is), and settings
  /// follow [settings] — a backup file and a login apply the backup's
  /// settings; a routine sync applies them only when they are newer than
  /// this device's last settings change.
  Future<ZoroxRestoreReport> restoreBackup(
    ZoroxBackup backup, {
    SettingsRestore settings = SettingsRestore.always,
  }) async {
    _restoring = true;
    try {
      return await _restoreBackup(backup, settings);
    } finally {
      // Box-watch events arrive a beat after the write; let them pass
      // before changes count as the user's again.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      _restoring = false;
    }
  }

  Future<ZoroxRestoreReport> _restoreBackup(
    ZoroxBackup backup,
    SettingsRestore settingsRule,
  ) async {
    final errors = <String>[];
    var historyRestored = 0;
    var historySkipped = 0;
    var libraryRestored = 0;
    var zoroxReposRestored = 0;
    var zoroxPluginsRestored = 0;
    var cloudstreamReposRestored = 0;
    var cloudstreamPluginsRestored = 0;

    // History: newest timestamp wins, per box key.
    final storage = ref.read(storageServiceProvider);
    final local = <String, int>{
      for (final raw in storage.getAllHistoryEntries())
        if (raw['key'] is String)
          raw['key'] as String:
              ((raw['entry'] as Map?)?['timestamp'] as int?) ?? 0,
    };
    final toPut = <Map<String, dynamic>>[];
    for (final raw in backup.history) {
      final key = raw['key'];
      final entry = raw['entry'];
      if (key is! String || entry is! Map) continue;
      final timestamp = (entry['timestamp'] as int?) ?? 0;
      if (!local.containsKey(key) || timestamp > (local[key] ?? 0)) {
        toPut.add(raw);
        historyRestored++;
      } else {
        historySkipped++;
      }
    }
    if (toPut.isNotEmpty) {
      await storage.restoreHistoryEntries(toPut);
    }

    // Library: add what is missing.
    final library = ref.read(libraryRepositoryProvider);
    for (final raw in backup.library) {
      final item = libraryItemFromBackup(raw);
      if (item == null) continue;
      try {
        final wasThere = library.isInLibrary(item.url);
        await library.addToLibrary(item);
        if (!wasThere) libraryRestored++;
      } catch (e) {
        errors.add('Could not restore bookmark "${item.title}": $e');
      }
    }

    // ZoroX repositories, then their plugins.
    try {
      final extensions = ref.read(extensionsControllerProvider.notifier);
      await extensions.ensureInitialized();
      var extensionsState = ref.read(extensionsControllerProvider);
      for (final url in backup.zoroxRepos) {
        if (extensionsState.repositories.any((repo) => repo.url == url)) {
          continue;
        }
        try {
          await extensions.addRepository(url);
          zoroxReposRestored++;
        } catch (e) {
          errors.add('Could not add repository $url: $e');
        }
        extensionsState = ref.read(extensionsControllerProvider);
      }
      for (final saved in backup.zoroxPlugins) {
        final packageName = saved['packageName'];
        if (packageName == null || packageName.isEmpty) continue;
        if (extensionsState.installedPlugins.any(
          (plugin) => plugin.packageName == packageName,
        )) {
          continue;
        }
        final found = _findZoroXPlugin(extensionsState, packageName);
        if (found == null) {
          errors.add(
            'Plugin $packageName is no longer listed by its repository, so it was not restored.',
          );
          continue;
        }
        try {
          await extensions.installPlugin(found);
          zoroxPluginsRestored++;
        } catch (e) {
          errors.add('Could not install ${found.name}: $e');
        }
        extensionsState = ref.read(extensionsControllerProvider);
      }
    } catch (e) {
      errors.add('Zeus plugins were not restored: $e');
    }

    // CloudStream repositories, then their plugins.
    try {
      final cloudstream = ref.read(cloudStreamRepositoryProvider.notifier);
      await cloudstream.load();
      var cloudstreamState = ref.read(cloudStreamRepositoryProvider);
      for (final url in backup.cloudstreamRepos) {
        if (cloudstreamState.repositories.any((repo) => repo.url == url)) {
          continue;
        }
        try {
          await cloudstream.addRepository(url);
          cloudstreamReposRestored++;
        } catch (e) {
          errors.add('Could not add repository $url: $e');
        }
        cloudstreamState = ref.read(cloudStreamRepositoryProvider);
      }
      if (!cloudstreamState.enabled) {
        if (backup.cloudstreamPlugins.isNotEmpty) {
          errors.add(
            'CloudStream is switched off, so its ${backup.cloudstreamPlugins.length} plugin(s) were not restored. Switch it on in Settings and import again.',
          );
        }
      } else {
        for (final saved in backup.cloudstreamPlugins) {
          final internalName = saved['internalName'];
          final repositoryUrl = saved['repositoryUrl'];
          if (internalName == null || repositoryUrl == null) continue;
          if (cloudstreamState.installed.any(
            (plugin) =>
                plugin.info.internalName == internalName &&
                plugin.info.repositoryUrl == repositoryUrl,
          )) {
            continue;
          }
          final found = _findCloudStreamPlugin(
            cloudstreamState,
            internalName,
            repositoryUrl,
          );
          if (found == null) {
            errors.add(
              'Plugin ${saved['name'] ?? internalName} is no longer listed by its repository, so it was not restored.',
            );
            continue;
          }
          try {
            await cloudstream.install(found);
            cloudstreamPluginsRestored++;
          } catch (e) {
            errors.add('Could not install ${found.name}: $e');
          }
          cloudstreamState = ref.read(cloudStreamRepositoryProvider);
        }
      }
    } catch (e) {
      errors.add('CloudStream plugins were not restored: $e');
    }

    // v9: Stremio add-ons. Only the missing ones are installed; an add-on
    // already here keeps its own on/off state and position.
    var addonsRestored = 0;
    try {
      final addons = ref.read(addonRepositoryProvider.notifier);
      await addons.whenLoaded();
      for (final saved in backup.stremioAddons) {
        final url = saved['url'];
        if (url is! String || url.isEmpty) continue;
        // A backup file is outside input: never install a URL that
        // carries a credential from one either.
        if (addonUrlCarriesSecret(url)) continue;
        if (addons.isInstalled(url)) continue;
        try {
          final added = await addons.install(url);
          if (saved['enabled'] == false) {
            await addons.setEnabled(added.manifestUrl, false);
          }
          addonsRestored++;
        } catch (e) {
          errors.add('Could not install add-on $url: $e');
        }
      }
    } catch (e) {
      errors.add('Add-ons were not restored: $e');
    }

    // v9: Nuvio repositories, same rule — add what is missing, with the
    // provider switches it was backed up with.
    var nuvioReposRestored = 0;
    try {
      final nuvio = ref.read(nuvioRepositoryProvider.notifier);
      await nuvio.whenLoaded();
      for (final saved in backup.nuvioRepos) {
        final url = saved['url'];
        if (url is! String || url.isEmpty) continue;
        if (addonUrlCarriesSecret(url)) continue;
        if (ref
            .read(nuvioRepositoryProvider)
            .repos
            .any((repo) => repo.manifestUrl == url)) {
          continue;
        }
        try {
          final repo = await nuvio.addRepository(url);
          for (final id in (saved['disabled'] as List?) ?? const []) {
            if (id is String) {
              await nuvio.setScraperEnabled(repo.manifestUrl, id, false);
            }
          }
          for (final id in (saved['enabledOverrides'] as List?) ?? const []) {
            if (id is String) {
              await nuvio.setScraperEnabled(repo.manifestUrl, id, true);
            }
          }
          nuvioReposRestored++;
        } catch (e) {
          errors.add('Could not add Nuvio repository $url: $e');
        }
      }
      if (nuvioReposRestored > 0 &&
          backup.nuvioEnabled == true &&
          !ref.read(nuvioRepositoryProvider).enabled) {
        await nuvio.setEnabled(true);
      }
    } catch (e) {
      errors.add('Nuvio repositories were not restored: $e');
    }

    // v9: settings — only when the backup carries any, and by the rule.
    var settingsChanged = 0;
    final incoming = backup.settings;
    final applySettings =
        incoming != null &&
        (settingsRule == SettingsRestore.always ||
            (settingsRule == SettingsRestore.ifNewer &&
                backup.settingsUpdatedAt > _settingsChangedAt()));
    if (applySettings) {
      try {
        settingsChanged = await applySyncedSettings(
          incoming,
          read: storage.getRawSetting,
          write: storage.setPlayerSetting,
        );
        // This device's settings are now the backup's: same age.
        await _stampSettingsChanged(backup.settingsUpdatedAt);
        if (settingsChanged > 0) _refreshSettingsProviders();
      } catch (e) {
        errors.add('Settings were not restored: $e');
      }
    }

    // Push the restored items into the Home / Library UI. Both providers
    // are keep-alive and cache their lists, and this restore writes straight
    // to the boxes/repository — without a refresh, Continue Watching and the
    // Library keep showing the pre-import (empty) list until the app
    // restarts. This was the "import restores plugins but not history"
    // bug: the entries WERE in the box, the Home just never re-read them.
    if (historyRestored > 0) {
      ref.read(watchHistoryProvider.notifier).refresh();
    }
    if (libraryRestored > 0) {
      ref.read(libraryProvider.notifier).refresh();
    }

    return ZoroxRestoreReport(
      historyRestored: historyRestored,
      historySkipped: historySkipped,
      historyInBackup: backup.history.length,
      libraryRestored: libraryRestored,
      zoroxReposRestored: zoroxReposRestored,
      zoroxPluginsRestored: zoroxPluginsRestored,
      cloudstreamReposRestored: cloudstreamReposRestored,
      cloudstreamPluginsRestored: cloudstreamPluginsRestored,
      addonsRestored: addonsRestored,
      nuvioReposRestored: nuvioReposRestored,
      settingsChanged: settingsChanged,
      errors: errors,
    );
  }

  /// Makes the running app re-read the settings a restore just wrote:
  /// each of these providers caches what it read at start.
  void _refreshSettingsProviders() {
    void refresh(void Function() invalidate) {
      try {
        invalidate();
      } catch (e) {
        talker.warning('[ZoroX Account] a settings refresh failed: $e');
      }
    }

    refresh(() => ref.invalidate(playerSettingsProvider));
    refresh(() => ref.invalidate(appThemeModeProvider));
    refresh(() => ref.invalidate(themeVariantProvider));
    refresh(() => ref.invalidate(accentColorProvider));
    refresh(() => ref.invalidate(generalSettingsProvider));
    refresh(() => ref.invalidate(homeRowPrefsProvider));
    refresh(() => ref.invalidate(searchDisabledSourcesProvider));
  }

  static ExtensionPlugin? _findZoroXPlugin(
    ExtensionsState extensionsState,
    String packageName,
  ) {
    for (final plugins in extensionsState.availablePlugins.values) {
      for (final plugin in plugins) {
        if (plugin.packageName == packageName) return plugin;
      }
    }
    return null;
  }

  static CsPluginInfo? _findCloudStreamPlugin(
    CloudStreamState cloudstreamState,
    String internalName,
    String repositoryUrl,
  ) {
    // The repository it came from first; any repository listing it second
    // (a repository can move, and the plugin is the same file).
    for (final repo in cloudstreamState.repositories) {
      if (repo.url != repositoryUrl) continue;
      for (final plugin in repo.plugins) {
        if (plugin.internalName == internalName) return plugin;
      }
    }
    for (final repo in cloudstreamState.repositories) {
      for (final plugin in repo.plugins) {
        if (plugin.internalName == internalName) return plugin;
      }
    }
    return null;
  }

  // --- export / import (no backend) --------------------------------------------

  /// Writes the backup to a file the user can keep. Returns the path and
  /// whether the share sheet was opened, or null when the user cancels. On
  /// iOS there is no save dialog, so the file goes to a temp file and the
  /// share sheet opens for "Save to Files".
  Future<({String path, bool openedShareSheet})?> exportBackupFile() async {
    if (_exportInProgress) return null;
    _exportInProgress = true;
    try {
      return await _exportBackupFile();
    } finally {
      _exportInProgress = false;
    }
  }

  Future<({String path, bool openedShareSheet})?> _exportBackupFile() async {
    final backup = await collectBackup();
    final bytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(backup.toJson()),
    );
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final fileName = 'zorox-backup-$stamp.json';
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Save Zeus backup',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );
      if (uri != null) {
        return (path: uri.toFilePath(), openedShareSheet: false);
      }
    } catch (e) {
      talker.warning('[ZoroX Account] save dialog failed: $e');
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    await OpenFile.open(file.path);
    return (path: file.path, openedShareSheet: true);
  }

  /// True while a backup import is running. The UI answers a second tap
  /// with "already running" instead of silence: the old `importBackupFile()`
  /// returned null for a tap that landed mid-import, which the UI read as
  /// "user cancelled". (The guard covers the pick; the UI's progress dialog
  /// covers the restore that follows it.)
  bool get importInProgress => _importInProgress;

  /// Picks a backup file and restores it. Returns the restore report, or
  /// null when the user cancels the picker. Throws [ZoroxSyncException]
  /// when the file is not a ZoroX backup.
  Future<ZoroxRestoreReport?> importBackupFile() async {
    final backup = await pickBackupFile();
    if (backup == null) return null;
    return await restoreBackup(backup);
  }

  /// Picks a backup file and parses it, without restoring it — so the UI can
  /// show progress while the (slow, network) restore runs. Returns null when
  /// the user cancels the picker. Throws [ZoroxSyncException] when the file
  /// is not a ZoroX backup, [PlatformException] when the picker itself fails.
  Future<ZoroxBackup?> pickBackupFile() async {
    if (_importInProgress) return null;
    _importInProgress = true;
    try {
      return await _pickBackupFile();
    } finally {
      _importInProgress = false;
    }
  }

  Future<ZoroxBackup?> _pickBackupFile() async {
    try {
      // file_picker throws PlatformException(multiple_request) when a pick
      // is started while another pick is still open (a stale pending
      // picker). The raw exception reads like a crash; tell the user to
      // tap Import again instead — the guard above is reset in `finally`,
      // so the next tap works. (Only the picker in this block can throw a
      // PlatformException, so the catch below is effectively pick-only.)
      final picked = await FilePicker.pickFile(
        dialogTitle: 'Import Zeus backup',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (picked == null) return null;
      // On iOS the picked file is a security-scoped URL, not a plain path:
      // XFile reads it either way.
      final bytes = picked.path != null
          ? await File(picked.path!).readAsBytes()
          : await picked.xFile.readAsBytes();
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const ZoroxSyncException('That file is not a Zeus backup.');
      }
      return ZoroxBackup.fromJson(Map<String, dynamic>.from(decoded));
    } on PlatformException catch (e) {
      if (e.code == 'multiple_request') {
        throw const ZoroxSyncException(
          'The file picker was already open — please tap Import again.',
        );
      }
      rethrow;
    }
  }
}


/// How a restore treats the backup's settings (v9).
enum SettingsRestore {
  /// The backup's settings replace this device's (a backup file, a login).
  always,

  /// Only when the backup's settings are newer than this device's last
  /// settings change (Sync now, the automatic sync).
  ifNewer,

  /// Settings are left alone.
  never,
}

enum _DownloadOutcome { restored, nothingStored, failed }
