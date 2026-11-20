import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/storage_service.dart';
import '../../account/data/zorox_sync_client.dart';
import '../../app_lock/app_lock_controller.dart';
import '../../app_lock/app_lock_passcode.dart';
import 'zeus_profile.dart';
import 'zeus_profiles_client.dart';

/// The profile calls' client, overridable in tests.
final zeusProfilesClientProvider = Provider<ZeusProfilesClient>(
  (ref) => ZeusProfilesClient(),
);

final zeusProfilesProvider =
    NotifierProvider<ZeusProfilesNotifier, ZeusProfilesState>(
      ZeusProfilesNotifier.new,
    );

/// What the picker and the gate know about profiles.
///
/// Plain Riverpod ([NotifierProvider]) — no codegen, so no `build_runner`,
/// like [ZoroxAccountNotifier].
class ZeusProfilesState {
  const ZeusProfilesState({
    this.profiles = const [],
    this.activeProfileId,
    this.fetched = false,
    this.loading = false,
    this.error,
    this.needsDefaultPin = false,
    this.legacyDataPendingMove = false,
    this.migrated = false,
    this.localMode = false,
  });

  /// The account's profiles, in server order. From the local cache until
  /// the first fetch replaces it, so the picker works offline.
  final List<ZeusProfile> profiles;

  /// The active profile on this device, or null while none is picked
  /// (the gate shows the picker) or the user is logged out.
  final String? activeProfileId;

  /// A network fetch completed at least once this run.
  final bool fetched;

  /// A fetch is in flight.
  final bool loading;

  /// The last failure, in the user's words; cleared on the next attempt.
  final String? error;

  /// Migration case 2: the server has no profiles yet, so the first
  /// profile still needs its PIN (required) before it can be created.
  final bool needsDefaultPin;

  /// Migration case 3: the account has profiles and this device still
  /// has legacy (pre-profile) history/My List. Build 2 asks which
  /// profile to move it into; until then it stays in the legacy boxes.
  final bool legacyDataPendingMove;

  /// The legacy data was migrated into the first profile once.
  final bool migrated;

  /// Build 2 (local-only mode): the list in [profiles] is the device's
  /// own list, not the account's. True when logged out (local profiles),
  /// false when the list came from the server. The gate and the PIN
  /// screen key off this: local profiles never ask for an account
  /// password, and "Forgot PIN?" is hidden for them.
  final bool localMode;

  ZeusProfile? get activeProfile {
    final id = activeProfileId;
    if (id == null) return null;
    for (final p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  ZeusProfilesState copyWith({
    List<ZeusProfile>? profiles,
    String? activeProfileId,
    bool clearActiveProfileId = false,
    bool? fetched,
    bool? loading,
    String? error,
    bool clearError = false,
    bool? needsDefaultPin,
    bool? legacyDataPendingMove,
    bool? migrated,
    bool? localMode,
  }) => ZeusProfilesState(
    profiles: profiles ?? this.profiles,
    activeProfileId: clearActiveProfileId
        ? null
        : (activeProfileId ?? this.activeProfileId),
    fetched: fetched ?? this.fetched,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    needsDefaultPin: needsDefaultPin ?? this.needsDefaultPin,
    legacyDataPendingMove: legacyDataPendingMove ?? this.legacyDataPendingMove,
    migrated: migrated ?? this.migrated,
    localMode: localMode ?? this.localMode,
  );
}

/// The profiles' state: the cached list, the active profile on this
/// device, PIN verification + lockout, and the migration flags.
///
/// The notifier never talks to the account notifier: the account side
/// (login / register / cold start) passes the session in
/// [refreshAfterAuth], and this notifier keeps the base URL + token in
/// memory for its later calls. That keeps the dependency one-way —
/// account → profiles — and the PIN record never leaves this feature
/// except inside a profile create/update call.
class ZeusProfilesNotifier extends Notifier<ZeusProfilesState> {
  String? _baseUrl;
  String? _token;
  bool _fetching = false;

  /// The local list was loaded this run (Build 2): [refreshLocalZeusProfiles]
  /// is a no-op afterwards, until a logout or a login resets it.
  bool _localLoaded = false;

  StorageService get _storage => ref.read(storageServiceProvider);
  ZeusProfilesClient get _client => ref.read(zeusProfilesClientProvider);

  @override
  ZeusProfilesState build() {
    // The cache is the offline source of truth until a fetch replaces
    // it; a device that never logged in reads nothing here.
    var cached = const <ZeusProfile>[];
    String? activeId;
    var migrated = false;
    try {
      final storage = ref.read(storageServiceProvider);
      final raw = storage.getString(ZeusProfileCacheKeys.list);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['profiles'] is List) {
          cached = [
            for (final e in decoded['profiles'] as List)
              if (e is Map)
                ZeusProfile.fromJson(Map<String, dynamic>.from(e)),
          ];
        }
      }
      activeId = storage.getString(ZeusProfileCacheKeys.activeId);
      migrated = storage.getString(ZeusProfileCacheKeys.migrated) != null;
    } catch (_) {
      // A damaged cache must never keep the app from starting; the next
      // fetch rebuilds it.
      cached = const [];
      activeId = null;
    }
    return ZeusProfilesState(
      profiles: cached,
      activeProfileId: activeId,
      migrated: migrated,
    );
  }

  /// Fetches the profile list after a login, a register, or a cold start
  /// with a restored session. Keeps the cached list on failure (offline).
  /// Also works out which migration case applies (design §9).
  Future<void> refreshAfterAuth({
    required String baseUrl,
    required String token,
  }) async {
    _baseUrl = baseUrl;
    _token = token;
    if (_fetching) return;
    _fetching = true;
    if (ref.mounted) state = state.copyWith(loading: true, clearError: true);
    try {
      final profiles = await _client.fetchZeusProfiles(baseUrl, token);
      // A profile deleted on another device must not stay active here.
      var activeId = state.activeProfileId;
      if (activeId != null &&
          profiles.every((p) => p.id != activeId)) {
        activeId = null;
        await _storage.setActiveZeusProfile(null);
        await _storage.setString(ZeusProfileCacheKeys.activeId, null);
      }
      await _writeCache(profiles);
      final legacyPending =
          profiles.isNotEmpty &&
          !state.migrated &&
          _storage.legacyHistoryOrLibraryNonEmpty;
      if (!ref.mounted) return;
      state = state.copyWith(
        profiles: profiles,
        activeProfileId: activeId,
        clearActiveProfileId: activeId == null,
        fetched: true,
        loading: false,
        needsDefaultPin: profiles.isEmpty,
        legacyDataPendingMove: legacyPending,
        localMode: false,
      );
    } on ZoroxSyncException catch (e) {
      if (ref.mounted) {
        state = state.copyWith(loading: false, error: e.message);
      }
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(loading: false, error: '$e');
      }
    } finally {
      _fetching = false;
    }
  }

  /// Loads the device's local-only profiles (Build 2): the list for
  /// logged-out users, kept in its own cache so it never mixes with the
  /// account's server list. Called on a logged-out cold start and on
  /// logout. Sets [ZeusProfilesState.localMode] so the gate, the PIN
  /// screen and the manage UI know no account password exists.
  ///
  /// An empty local list means the first local profile still needs its
  /// PIN (the gate shows the first-profile setup, which migrates the
  /// legacy data into it — no account needed).
  Future<void> refreshLocalZeusProfiles() async {
    if (state.localMode && _localLoaded) return;
    List<ZeusProfile> local = const [];
    String? activeId;
    var migrated = false;
    try {
      local = _readCachedList(ZeusProfileCacheKeys.localList);
      activeId = _storage.getString(ZeusProfileCacheKeys.localActiveId);
      migrated = _storage.getString(ZeusProfileCacheKeys.migrated) != null;
    } catch (_) {
      local = const [];
      activeId = null;
    }
    if (activeId != null && local.every((p) => p.id != activeId)) {
      activeId = null;
      await _storage.setActiveZeusProfile(null);
      await _storage.setString(ZeusProfileCacheKeys.localActiveId, null);
    }
    _localLoaded = true;
    if (!ref.mounted) return;
    state = state.copyWith(
      profiles: local,
      activeProfileId: activeId,
      clearActiveProfileId: activeId == null,
      fetched: true,
      loading: false,
      clearError: true,
      needsDefaultPin: local.isEmpty,
      legacyDataPendingMove: false,
      migrated: migrated,
      localMode: true,
    );
    // Point the history/library pair at the local active profile (or
    // the legacy boxes while none is picked yet).
    await _storage.setActiveZeusProfile(activeId);
  }

  /// Logs out of the account's profiles and back onto the device's
  /// local-only ones: the server cache is deleted (as [clearLocalState]
  /// did — a next login must not flash the old account's list), then the
  /// local list is loaded. The local profiles and their data survive.
  Future<void> switchToLocalProfiles() async {
    _localLoaded = false;
    await clearLocalState();
    await refreshLocalZeusProfiles();
  }

  /// Reads a cached profile list (server or local) from the settings box.
  List<ZeusProfile> _readCachedList(String key) {
    final raw = _storage.getString(key);
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is Map && decoded['profiles'] is List) {
      return [
        for (final e in decoded['profiles'] as List)
          if (e is Map) ZeusProfile.fromJson(Map<String, dynamic>.from(e)),
      ];
    }
    return const [];
  }

  /// Creates a profile (the picker's "+" tile, and the migration's first
  /// profile). The PIN record is made on this device at the profile
  /// round count; the PIN itself never leaves it.
  ///
  /// Logged out (no session): the profile is created on this device
  /// only, with a device-generated id, and stored in the local cache —
  /// no account, no server call.
  Future<ZeusProfile?> createZeusProfile({
    required String name,
    required String color,
    required String pin,
  }) async {
    final nameError = zeusProfileNameError(name);
    if (nameError != null) {
      state = state.copyWith(error: nameError);
      return null;
    }
    if (!kZeusProfileColors.containsKey(color)) {
      state = state.copyWith(error: 'Unknown profile colour.');
      return null;
    }
    if (!isValidAppLockPasscode(pin)) {
      state = state.copyWith(error: 'The PIN must be 4 digits.');
      return null;
    }
    if (state.profiles.length >= kZeusProfileMaxCount) {
      state = state.copyWith(
        error: 'You can have up to $kZeusProfileMaxCount profiles.',
      );
      return null;
    }
    final baseUrl = _baseUrl;
    final token = _token;
    if (baseUrl == null || token == null) {
      // Local-only (Build 2): no session, so no server. The id and the
      // PIN record are both made on this device.
      final now = DateTime.now();
      final profile = ZeusProfile(
        id: newZeusProfileId(),
        name: name.trim(),
        color: color,
        pinRecord: AppLockPasscodeHash.create(
          pin,
          rounds: kZeusProfilePinRounds,
        ),
        createdAt: now,
        updatedAt: now,
      );
      final profiles = [...state.profiles, profile];
      await _writeLocalCache(profiles);
      if (ref.mounted) {
        state = state.copyWith(
          profiles: profiles,
          loading: false,
          needsDefaultPin: false,
        );
      }
      return profile;
    }
    state = state.copyWith(loading: true, clearError: true);
    try {
      final profile = await _client.createZeusProfile(
        baseUrl,
        token,
        name: name.trim(),
        color: color,
        pinRecord: AppLockPasscodeHash.create(
          pin,
          rounds: kZeusProfilePinRounds,
        ),
      );
      final profiles = [...state.profiles, profile];
      await _writeCache(profiles);
      if (ref.mounted) {
        state = state.copyWith(
          profiles: profiles,
          loading: false,
          needsDefaultPin: false,
        );
      }
      return profile;
    } on ZoroxSyncException catch (e) {
      if (ref.mounted) {
        state = state.copyWith(loading: false, error: e.message);
      }
      return null;
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(loading: false, error: '$e');
      }
      return null;
    }
  }

  /// Renames / recolours a profile (Build 2 management). Logged in, the
  /// server is updated (token only — no password for a rename); logged
  /// out, the local cache is updated. Returns false with [state.error]
  /// when nothing changed or the server refused.
  Future<bool> updateZeusProfile({
    required String profileId,
    String? name,
    String? color,
  }) async {
    final trimmed = name?.trim();
    if (trimmed != null) {
      final nameError = zeusProfileNameError(trimmed);
      if (nameError != null) {
        state = state.copyWith(error: nameError);
        return false;
      }
    }
    if (color != null && !kZeusProfileColors.containsKey(color)) {
      state = state.copyWith(error: 'Unknown profile colour.');
      return false;
    }
    if (name == null && color == null) return true;
    final baseUrl = _baseUrl;
    final token = _token;
    if (baseUrl == null || token == null) {
      // Local-only: the cache is the list.
      if (!state.profiles.any((p) => p.id == profileId)) return false;
      final profiles = [
        for (final p in state.profiles)
          if (p.id == profileId)
            p.copyWith(
              name: trimmed,
              color: color,
              updatedAt: DateTime.now(),
            )
          else
            p,
      ];
      await _writeLocalCache(profiles);
      if (ref.mounted) state = state.copyWith(profiles: profiles);
      return true;
    }
    state = state.copyWith(loading: true, clearError: true);
    try {
      final updated = await _client.updateZeusProfile(
        baseUrl,
        token,
        profileId,
        name: trimmed,
        color: color,
      );
      final profiles = [
        for (final p in state.profiles)
          if (p.id == profileId) updated else p,
      ];
      await _writeCache(profiles);
      if (ref.mounted) state = state.copyWith(profiles: profiles, loading: false);
      return true;
    } on ZoroxSyncException catch (e) {
      if (ref.mounted) {
        state = state.copyWith(loading: false, error: e.message);
      }
      return false;
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(loading: false, error: '$e');
      }
      return false;
    }
  }

  /// Deletes a profile and its data (Build 2 management).
  ///
  /// Logged in, the server verifies the account password first (a kid
  /// who knows a profile PIN must not be able to delete it) and deletes
  /// the profile's backup too. Logged out, the profile's own PIN must
  /// already have been confirmed by the caller (there is no account
  /// password) and only the local copy is removed. Either way the
  /// profile's history/library boxes are deleted from disk, its PIN
  /// counters are cleared, and deleting the active profile switches to
  /// the first remaining one. The last profile can never be deleted.
  Future<bool> deleteZeusProfile({
    required String profileId,
    String? accountPassword,
  }) async {
    if (state.profiles.length <= 1) {
      state = state.copyWith(
        error: 'The last profile cannot be deleted.',
      );
      return false;
    }
    if (!state.profiles.any((p) => p.id == profileId)) return false;
    final baseUrl = _baseUrl;
    final token = _token;
    if (baseUrl != null && token != null) {
      if (accountPassword == null || accountPassword.isEmpty) {
        state = state.copyWith(
          error: 'Enter your Zeus account password to delete this profile.',
        );
        return false;
      }
      state = state.copyWith(loading: true, clearError: true);
      try {
        await _client.deleteZeusProfile(
          baseUrl,
          token,
          profileId,
          accountPassword,
        );
      } on ZoroxSyncException catch (e) {
        if (ref.mounted) {
          state = state.copyWith(loading: false, error: e.message);
        }
        return false;
      } catch (e) {
        if (ref.mounted) {
          state = state.copyWith(loading: false, error: '$e');
        }
        return false;
      }
    }
    final wasActive = state.activeProfileId == profileId;
    final profiles = [
      for (final p in state.profiles)
        if (p.id != profileId) p,
    ];
    if (state.localMode) {
      await _writeLocalCache(profiles);
    } else {
      await _writeCache(profiles);
    }
    await _setPinAttempts(profileId, 0, 0);
    await _storage.deleteZeusProfileBoxes(profileId);
    if (ref.mounted) {
      state = state.copyWith(profiles: profiles, loading: false);
    }
    if (wasActive && profiles.isNotEmpty) {
      await switchZeusProfile(profiles.first.id);
    }
    return true;
  }

  /// Migration for a logged-out device (Build 2): the current Continue
  /// Watching / My List becomes the first LOCAL profile. Same steps as
  /// the account migration, minus the server: create locally, switch to
  /// it, copy the legacy history + library into its boxes, clear the
  /// legacy boxes and mark the migration done. Returns the profile, or
  /// null when it could not be created.
  Future<ZeusProfile?> completeLocalProfileMigration({
    required String name,
    required String color,
    required String pin,
  }) async {
    final profile = await createZeusProfile(
      name: name,
      color: color,
      pin: pin,
    );
    if (profile == null) return null;
    final storage = ref.read(storageServiceProvider);
    await switchZeusProfile(profile.id);
    await storage.copyLegacyHistoryAndLibraryToZeusProfile(profile.id);
    await storage.clearLegacyHistoryAndLibrary();
    await markMigrated();
    return profile;
  }

  /// Checks [pin] against [profileId]'s record, locally, with the same
  /// lockout as the app lock: 5 free tries, then 30 s doubling to 5 min
  /// ([appLockWaitAfter]). The counters live in the settings box, per
  /// profile, so they are readable before any network.
  Future<AppLockPasscodeCheck> checkZeusProfilePin(
    String profileId,
    String pin,
  ) async {
    ZeusProfile? profile;
    for (final p in state.profiles) {
      if (p.id == profileId) profile = p;
    }
    if (profile == null || !profile.hasPinRecord) {
      return AppLockPasscodeCheck.missing;
    }
    if (blockedForZeusProfile(profileId) > Duration.zero) {
      return AppLockPasscodeCheck.blocked;
    }
    if (AppLockPasscodeHash.verify(pin, profile.pinRecord)) {
      await _setPinAttempts(profileId, 0, 0);
      return AppLockPasscodeCheck.ok;
    }
    final attempts = _pinAttempts(profileId) + 1;
    final wait = appLockWaitAfter(attempts);
    final blockedUntil = wait > Duration.zero
        ? DateTime.now().millisecondsSinceEpoch + wait.inMilliseconds
        : 0;
    await _setPinAttempts(profileId, attempts, blockedUntil);
    return AppLockPasscodeCheck.wrong;
  }

  /// How long no PIN is accepted for [profileId], or zero.
  Duration blockedForZeusProfile(String profileId) {
    final until = _pinBlockedUntil(profileId);
    if (until <= 0) return Duration.zero;
    final left = until - DateTime.now().millisecondsSinceEpoch;
    return left > 0 ? Duration(milliseconds: left) : Duration.zero;
  }

  int _pinAttempts(String profileId) {
    final raw = _storage.getString(
      ZeusProfileCacheKeys.attempts(profileId),
    );
    return int.tryParse(raw ?? '') ?? 0;
  }

  int _pinBlockedUntil(String profileId) {
    final raw = _storage.getString(
      ZeusProfileCacheKeys.blockedUntil(profileId),
    );
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<void> _setPinAttempts(
    String profileId,
    int attempts,
    int blockedUntilMs,
  ) async {
    // setString(key, null) deletes the key: a clean record reads as 0.
    await _storage.setString(
      ZeusProfileCacheKeys.attempts(profileId),
      attempts <= 0 ? null : '$attempts',
    );
    await _storage.setString(
      ZeusProfileCacheKeys.blockedUntil(profileId),
      blockedUntilMs <= 0 ? null : '$blockedUntilMs',
    );
  }

  /// Makes [profileId] the active profile on this device: its history
  /// and library boxes become the active pair, and the choice is kept
  /// locally (never synced — each device may sit on a different profile).
  /// The active id is stored under the local key in local mode and the
  /// server key otherwise, so the two lists never share one.
  Future<void> switchZeusProfile(String profileId) async {
    if (state.profiles.every((p) => p.id != profileId)) return;
    await _storage.setActiveZeusProfile(profileId);
    await _storage.setString(
      state.localMode
          ? ZeusProfileCacheKeys.localActiveId
          : ZeusProfileCacheKeys.activeId,
      profileId,
    );
    if (ref.mounted) {
      state = state.copyWith(activeProfileId: profileId, clearError: true);
    }
  }

  /// Changes a profile's PIN, after the server verifies the account
  /// password ([accountPassword]). The new record is made on this device.
  /// Used by "Forgot PIN?" (Build 1) and by profile management (Build 2).
  ///
  /// Logged out (local-only profile), there is no account password: the
  /// caller must already have confirmed the profile's current PIN (the
  /// manage screen shows the PIN pad first), and the record is updated
  /// in the local cache only.
  Future<bool> updateZeusProfilePin({
    required String profileId,
    required String newPin,
    String? accountPassword,
  }) async {
    if (!isValidAppLockPasscode(newPin)) {
      state = state.copyWith(error: 'The PIN must be 4 digits.');
      return false;
    }
    final baseUrl = _baseUrl;
    final token = _token;
    if (baseUrl == null || token == null) {
      if (!state.profiles.any((p) => p.id == profileId)) return false;
      final record = AppLockPasscodeHash.create(
        newPin,
        rounds: kZeusProfilePinRounds,
      );
      final profiles = [
        for (final p in state.profiles)
          if (p.id == profileId)
            p.copyWith(pinRecord: record, updatedAt: DateTime.now())
          else
            p,
      ];
      await _writeLocalCache(profiles);
      await _setPinAttempts(profileId, 0, 0);
      if (ref.mounted) state = state.copyWith(profiles: profiles);
      return true;
    }
    if (accountPassword == null || accountPassword.isEmpty) {
      state = state.copyWith(
        error: 'Enter your Zeus account password to change the PIN.',
      );
      return false;
    }
    state = state.copyWith(loading: true, clearError: true);
    try {
      final updated = await _client.updateZeusProfile(
        baseUrl,
        token,
        profileId,
        pinRecord: AppLockPasscodeHash.create(
          newPin,
          rounds: kZeusProfilePinRounds,
        ),
        accountPassword: accountPassword,
      );
      final profiles = [
        for (final p in state.profiles)
          if (p.id == profileId) updated else p,
      ];
      await _writeCache(profiles);
      await _setPinAttempts(profileId, 0, 0);
      if (ref.mounted) state = state.copyWith(profiles: profiles, loading: false);
      return true;
    } on ZoroxSyncException catch (e) {
      if (ref.mounted) {
        state = state.copyWith(loading: false, error: e.message);
      }
      return false;
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(loading: false, error: '$e');
      }
      return false;
    }
  }

  /// Records that the legacy data was migrated once (design §9 case 2).
  Future<void> markMigrated() async {
    await _storage.setString(ZeusProfileCacheKeys.migrated, '1');
    if (ref.mounted) {
      state = state.copyWith(migrated: true, needsDefaultPin: false);
    }
  }

  /// The legacy data was handled (moved or deleted, Build 2 §9 case 3):
  /// the prompt and the Settings rows go away without waiting for the
  /// next fetch.
  void clearLegacyMovePending() {
    if (ref.mounted) state = state.copyWith(legacyDataPendingMove: false);
  }

  /// Logs out locally: the cache, the active profile and the PIN
  /// counters go; the history/library pair goes back to the legacy
  /// boxes. The server list is untouched — the next login re-fetches it.
  Future<void> clearLocalState() async {
    final ids = [for (final p in state.profiles) p.id];
    await _storage.setString(ZeusProfileCacheKeys.list, null);
    await _storage.setString(ZeusProfileCacheKeys.activeId, null);
    await _storage.setString(ZeusProfileCacheKeys.migrated, null);
    for (final id in ids) {
      await _setPinAttempts(id, 0, 0);
    }
    await _storage.setActiveZeusProfile(null);
    _baseUrl = null;
    _token = null;
    if (ref.mounted) state = const ZeusProfilesState();
  }

  Future<void> _writeCache(List<ZeusProfile> profiles) async {
    await _storage.setString(
      ZeusProfileCacheKeys.list,
      jsonEncode({
        'profiles': [for (final p in profiles) p.toJson()],
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  /// The local-only list's cache (Build 2): same shape, its own key, so
  /// it never mixes with the server list.
  Future<void> _writeLocalCache(List<ZeusProfile> profiles) async {
    await _storage.setString(
      ZeusProfileCacheKeys.localList,
      jsonEncode({
        'profiles': [for (final p in profiles) p.toJson()],
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }
}
