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

  /// Creates a profile (the picker's "+" tile, and the migration's first
  /// profile). The PIN record is made on this device at the profile
  /// round count; the PIN itself never leaves it.
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
    final baseUrl = _baseUrl;
    final token = _token;
    if (baseUrl == null || token == null) {
      state = state.copyWith(error: 'Log in again to add a profile.');
      return null;
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
  Future<void> switchZeusProfile(String profileId) async {
    if (state.profiles.every((p) => p.id != profileId)) return;
    await _storage.setActiveZeusProfile(profileId);
    await _storage.setString(ZeusProfileCacheKeys.activeId, profileId);
    if (ref.mounted) {
      state = state.copyWith(activeProfileId: profileId, clearError: true);
    }
  }

  /// Changes a profile's PIN, after the server verifies the account
  /// password ([accountPassword]). The new record is made on this device.
  /// Used by "Forgot PIN?" (Build 1) and by profile management (Build 2).
  Future<bool> updateZeusProfilePin({
    required String profileId,
    required String newPin,
    required String accountPassword,
  }) async {
    if (!isValidAppLockPasscode(newPin)) {
      state = state.copyWith(error: 'The PIN must be 4 digits.');
      return false;
    }
    final baseUrl = _baseUrl;
    final token = _token;
    if (baseUrl == null || token == null) {
      state = state.copyWith(error: 'Log in again to change the PIN.');
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
}
