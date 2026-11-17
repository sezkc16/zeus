import 'package:local_auth/local_auth.dart';

import 'app_lock_controller.dart';

/// [AppLockAuthenticator] over the `local_auth` plugin: Face ID / Touch ID
/// with the device passcode as the fallback (`biometricOnly: false`).
class LocalAuthAuthenticator
    implements AppLockAuthenticator, AppLockBiometrics {
  LocalAuthAuthenticator([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<AppLockAuthResult> authenticate(String reason) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
        // The prompt survives a trip to the background instead of failing.
        persistAcrossBackgrounding: true,
      );
      return ok ? AppLockAuthResult.success : AppLockAuthResult.failed;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.uiUnavailable => AppLockAuthResult.unavailable,
        _ => AppLockAuthResult.failed,
      };
    } catch (_) {
      // No plugin on this platform (a desktop build, a test): nothing to
      // authenticate with.
      return AppLockAuthResult.unavailable;
    }
  }

  /// True when the system reports at least one biometric this app can use.
  /// On Android that is whatever `BiometricManager` exposes to apps (the
  /// plugin asks for weak or strong class): a face unlock the phone maker
  /// keeps to the lock screen only is not in this list.
  @override
  Future<bool> hasEnrolledBiometrics() async {
    try {
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<AppLockAuthResult> authenticateBiometric(String reason) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        // No device passcode here: the other way in is the app's own.
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
      return ok ? AppLockAuthResult.success : AppLockAuthResult.failed;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.noBiometricsEnrolled ||
        LocalAuthExceptionCode.noBiometricHardware ||
        LocalAuthExceptionCode.uiUnavailable => AppLockAuthResult.unavailable,
        _ => AppLockAuthResult.failed,
      };
    } catch (_) {
      return AppLockAuthResult.unavailable;
    }
  }
}
