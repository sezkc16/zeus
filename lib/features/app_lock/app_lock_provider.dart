import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/secure_token_storage.dart';
import '../../core/storage/settings_repository.dart';
import '../../core/storage/storage_service.dart';
import 'app_lock_controller.dart';
import 'app_lock_passcode.dart';
import 'local_auth_authenticator.dart';

/// What asks the device who is holding it. Overridden with a fake in tests.
final appLockAuthenticatorProvider = Provider<AppLockAuthenticator>(
  (ref) => LocalAuthAuthenticator(),
);

/// Where the lock keeps its passcode record and flags. Overridden in tests.
final appLockStorageProvider = Provider<AppLockStorage>(
  // Looked up when first used, not when the lock is built: a screen that
  // only shows the App lock row needs no storage of its own.
  (ref) => DeviceAppLockStorage(
    () => ref.read(storageServiceProvider),
    () => ref.read(secureTokenStorageProvider),
  ),
);

/// The app lock. The setting is read synchronously from the settings box
/// (already open when the app's ProviderScope is built), so a cold start
/// with the lock on is locked from the very first frame.
final appLockControllerProvider = Provider<AppLockController>((ref) {
  final repository = ref.watch(settingsRepositoryProvider);
  final authenticator = ref.watch(appLockAuthenticatorProvider);
  final controller = AppLockController(
    authenticator: authenticator,
    biometrics: authenticator is AppLockBiometrics
        ? authenticator as AppLockBiometrics
        : null,
    storage: ref.watch(appLockStorageProvider),
    enabled: _readEnabled(repository),
    persist: repository.setAppLockEnabled,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// A settings box that could not be read (storage failed to open; the app
/// shows its own error for that) counts as the lock being off: there is no
/// saved choice to honour, and locking someone out over it helps no one.
bool _readEnabled(SettingsRepository repository) {
  try {
    return repository.isAppLockEnabled();
  } catch (_) {
    return false;
  }
}

/// The real [AppLockStorage].
///
///  * The passcode record (a salted hash, never the digits) goes to the
///    platform's secure storage - Keychain on iOS, Keystore-backed storage
///    on Android - through the app's existing [SecureTokenStorage]. Where
///    that backend is broken it falls back to the app's settings box, as it
///    does for sign-in tokens.
///  * The small flags (a passcode is set, biometrics allowed, wrong tries,
///    wait-until time) live in the settings box so they can be read before
///    the first frame.
///
/// None of these keys is on the backup / account-sync allow-list
/// (`kSyncedSettingKeys`), so none of it ever leaves the device.
class DeviceAppLockStorage implements AppLockStorage {
  DeviceAppLockStorage(this._settingsOf, this._secureOf);

  final StorageService Function() _settingsOf;
  final SecureTokenStorage Function() _secureOf;

  StorageService get _settings => _settingsOf();
  SecureTokenStorage get _secure => _secureOf();

  static const String kPasscodeRecord = 'app_lock_passcode_record';
  static const String kHasPasscode = 'app_lock_has_passcode';
  static const String kBiometric = 'app_lock_biometric';
  static const String kFailedAttempts = 'app_lock_failed_attempts';
  static const String kBlockedUntil = 'app_lock_blocked_until';

  /// Every settings key the lock uses besides the on/off switch.
  static const List<String> allKeys = <String>[
    kPasscodeRecord,
    kHasPasscode,
    kBiometric,
    kFailedAttempts,
    kBlockedUntil,
  ];

  T? _read<T>(String key) {
    try {
      final value = _settings.getRawSetting(key);
      return value is T ? value : null;
    } catch (_) {
      return null;
    }
  }

  @override
  bool get hasPasscode => _read<bool>(kHasPasscode) ?? false;

  @override
  Future<void> setHasPasscode(bool value) =>
      _settings.setPlayerSetting(kHasPasscode, value ? true : null);

  @override
  bool get biometricEnabled => _read<bool>(kBiometric) ?? false;

  @override
  Future<void> setBiometricEnabled(bool value) =>
      _settings.setPlayerSetting(kBiometric, value ? true : null);

  @override
  int get failedAttempts => _read<int>(kFailedAttempts) ?? 0;

  @override
  int get blockedUntilMs => _read<int>(kBlockedUntil) ?? 0;

  @override
  Future<void> setAttempts({
    required int failedAttempts,
    required int blockedUntilMs,
  }) async {
    await _settings.setPlayerSetting(
      kFailedAttempts,
      failedAttempts > 0 ? failedAttempts : null,
    );
    await _settings.setPlayerSetting(
      kBlockedUntil,
      blockedUntilMs > 0 ? blockedUntilMs : null,
    );
  }

  @override
  Future<String?> readPasscodeRecord() => _secure.read(kPasscodeRecord);

  @override
  Future<void> writePasscodeRecord(String record) =>
      _secure.write(kPasscodeRecord, record);

  @override
  Future<void> deletePasscodeRecord() => _secure.delete(kPasscodeRecord);
}
