import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/settings_repository.dart';
import 'app_lock_controller.dart';
import 'local_auth_authenticator.dart';

/// What asks the device who is holding it. Overridden with a fake in tests.
final appLockAuthenticatorProvider = Provider<AppLockAuthenticator>(
  (ref) => LocalAuthAuthenticator(),
);

/// The app lock. The setting is read synchronously from the settings box
/// (already open when the app's ProviderScope is built), so a cold start
/// with the lock on is locked from the very first frame.
final appLockControllerProvider = Provider<AppLockController>((ref) {
  final repository = ref.watch(settingsRepositoryProvider);
  final controller = AppLockController(
    authenticator: ref.watch(appLockAuthenticatorProvider),
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
