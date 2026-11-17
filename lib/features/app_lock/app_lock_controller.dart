import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;

import 'app_lock_passcode.dart';

/// How an attempt to authenticate ended.
enum AppLockAuthResult {
  /// The person proved it is them (Face ID, Touch ID or the device passcode).
  success,

  /// They did not: cancelled, failed, or the system dismissed the prompt.
  failed,

  /// The device has nothing to authenticate with (no biometrics and no
  /// passcode set), or the prompt cannot be shown at all.
  unavailable,
}

/// What asks the device who is holding it. The real one wraps `local_auth`;
/// tests use a fake.
abstract class AppLockAuthenticator {
  /// Whether the device can authenticate at all (biometrics or passcode).
  Future<bool> isAvailable();

  /// Shows the system prompt with [reason]. Never throws.
  Future<AppLockAuthResult> authenticate(String reason);
}

/// Unlocking with the device's biometrics only (Face ID, Touch ID, an
/// Android fingerprint or face), with no device-passcode fallback: the
/// alternative on the lock screen is the app's own passcode.
abstract class AppLockBiometrics {
  /// Whether a biometric is enrolled and usable by apps on this device.
  Future<bool> hasEnrolledBiometrics();

  /// Shows the biometric prompt with [reason]. Never throws.
  Future<AppLockAuthResult> authenticateBiometric(String reason);
}

/// How a typed passcode was judged.
enum AppLockPasscodeCheck {
  /// It is the passcode.
  ok,

  /// It is not; the try was counted.
  wrong,

  /// Too many wrong tries: nothing is accepted until the wait is over.
  blocked,

  /// The saved passcode could not be read (a restored phone, cleared
  /// keychain). The lock falls back to the device's own authentication.
  missing,
}

/// What became of a request to switch the lock on or off.
enum AppLockChange { done, unavailable, notVerified }

/// The app lock's state machine.
///
///  * Cold start: locked when the lock is enabled.
///  * Unlocks only on a successful authentication; a failure stays locked.
///  * Locks again when the app comes back after more than [relockAfter] in
///    the background.
///  * Covers the content (without locking) whenever the app is inactive,
///    hidden or paused, so the app switcher shows no content.
///  * Never locks or covers while the player is active (video playing, or
///    Picture-in-Picture): [isPlayerActive] answers that. A lock that came
///    due while the player was up waits until the player closes.
class AppLockController extends ChangeNotifier {
  AppLockController({
    required AppLockAuthenticator authenticator,
    required bool enabled,
    required Future<void> Function(bool enabled) persist,
    AppLockStorage? storage,
    AppLockBiometrics? biometrics,
    DateTime Function() now = DateTime.now,
    this.relockAfter = const Duration(seconds: 60),
  }) : _authenticator = authenticator,
       _persist = persist,
       _storage = storage ?? InMemoryAppLockStorage(),
       _biometrics = biometrics,
       _now = now,
       _enabled = enabled,
       _locked = enabled;

  final AppLockAuthenticator _authenticator;
  final Future<void> Function(bool enabled) _persist;
  final AppLockStorage _storage;
  final AppLockBiometrics? _biometrics;
  final DateTime Function() _now;

  /// Longest the app may sit in the background without locking again.
  final Duration relockAfter;

  /// Whether the player is on top right now. Set by the gate (which knows
  /// the router); false until then - a cold start has no player.
  bool Function() isPlayerActive = () => false;

  bool _enabled;
  bool _locked;
  bool _covered = false;
  bool _authenticating = false;
  bool _lastAttemptFailed = false;
  bool _lockWhenPlayerCloses = false;
  DateTime? _backgroundedAt;
  int _lockGeneration = 0;
  bool _disposed = false;

  /// Whether the lock is switched on.
  bool get enabled => _enabled;

  /// Whether the app's own passcode is set. When the lock is on without one
  /// (switched on before custom passcodes existed), it keeps working the old
  /// way - the device's biometrics or device passcode - until one is set.
  bool get usesPasscode => _storage.hasPasscode;

  /// Whether Face ID / fingerprint may unlock instead of the passcode.
  bool get biometricEnabled => _storage.hasPasscode && _storage.biometricEnabled;

  /// Wrong passcode tries in a row.
  int get failedAttempts => _storage.failedAttempts;

  /// How much longer no passcode is accepted; zero when one may be tried.
  Duration get blockedFor {
    final until = _storage.blockedUntilMs;
    if (until <= 0) return Duration.zero;
    final left = until - _now().millisecondsSinceEpoch;
    if (left <= 0) return Duration.zero;
    // A clock moved back must not stretch the wait past the longest one.
    return Duration(
      milliseconds: left > kAppLockMaxWait.inMilliseconds
          ? kAppLockMaxWait.inMilliseconds
          : left,
    );
  }

  /// Whether the lock screen is up.
  bool get locked => _locked;

  /// Whether the content is covered because the app is not in front.
  bool get covered => _covered;

  /// Whether the system prompt is up.
  bool get authenticating => _authenticating;

  /// Whether the last unlock attempt on this lock screen did not succeed.
  bool get lastAttemptFailed => _lastAttemptFailed;

  /// Goes up each time the app locks, so the lock screen prompts once per
  /// lock and not again after a failed attempt.
  int get lockGeneration => _lockGeneration;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _lock() {
    if (_locked) return;
    _locked = true;
    _lastAttemptFailed = false;
    _lockGeneration++;
  }

  /// Feed every app lifecycle change in here.
  void onLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _covered = false;
        final since = _backgroundedAt;
        _backgroundedAt = null;
        if (_enabled &&
            !_locked &&
            since != null &&
            _now().difference(since) > relockAfter) {
          if (isPlayerActive()) {
            _lockWhenPlayerCloses = true;
          } else {
            _lock();
          }
        }
      case AppLifecycleState.inactive:
        // The system's own Face ID / passcode prompt makes the app
        // inactive; that is not the app leaving the front.
        if (_enabled && !_authenticating && !isPlayerActive()) _covered = true;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _backgroundedAt ??= _now();
        if (_enabled && !isPlayerActive()) _covered = true;
      case AppLifecycleState.detached:
        break;
    }
    _notify();
  }

  /// Call when the player route opens or closes.
  void onPlayerActivityChanged() {
    if (isPlayerActive()) {
      // The player came up: nothing covers a video.
      if (_covered) {
        _covered = false;
        _notify();
      }
      return;
    }
    if (_lockWhenPlayerCloses) {
      _lockWhenPlayerCloses = false;
      if (_enabled) {
        _lock();
        _notify();
      }
    }
  }

  /// Asks the person to unlock. Stays locked unless they succeed.
  Future<bool> unlock(String reason) async {
    if (!_locked) return true;
    if (_authenticating) return false;
    _authenticating = true;
    _notify();
    AppLockAuthResult result;
    try {
      result = await _authenticator.authenticate(reason);
    } catch (_) {
      result = AppLockAuthResult.failed;
    }
    _authenticating = false;
    if (result == AppLockAuthResult.success) {
      _locked = false;
      _lastAttemptFailed = false;
      // Time spent behind the lock screen is not time away.
      _backgroundedAt = null;
    } else {
      _lastAttemptFailed = true;
    }
    _notify();
    return !_locked;
  }

  /// Switches the lock on or off. On needs one successful authentication
  /// first; without it the lock stays off.
  Future<AppLockChange> setEnabled(bool on, {required String reason}) async {
    if (on == _enabled) return AppLockChange.done;
    if (!on) {
      _enabled = false;
      _locked = false;
      _covered = false;
      _lockWhenPlayerCloses = false;
      await _persist(false);
      await _clearPasscode();
      _notify();
      return AppLockChange.done;
    }
    if (_authenticating) return AppLockChange.notVerified;
    _authenticating = true;
    _notify();
    AppLockAuthResult result;
    try {
      result = await _authenticator.isAvailable()
          ? await _authenticator.authenticate(reason)
          : AppLockAuthResult.unavailable;
    } catch (_) {
      result = AppLockAuthResult.failed;
    }
    _authenticating = false;
    if (result != AppLockAuthResult.success) {
      _notify();
      return result == AppLockAuthResult.unavailable
          ? AppLockChange.unavailable
          : AppLockChange.notVerified;
    }
    _enabled = true;
    _backgroundedAt = null;
    await _persist(true);
    _notify();
    return AppLockChange.done;
  }

  Future<void> _clearPasscode() async {
    try {
      await _storage.deletePasscodeRecord();
    } catch (_) {}
    await _storage.setHasPasscode(false);
    await _storage.setBiometricEnabled(false);
    await _storage.setAttempts(failedAttempts: 0, blockedUntilMs: 0);
  }

  /// Judges a typed passcode and keeps the count of wrong tries: five are
  /// free, then each wrong one starts a wait (30 s, doubling to 5 min).
  /// The count is saved, so restarting the app does not reset it.
  Future<AppLockPasscodeCheck> checkPasscode(String code) async {
    if (blockedFor > Duration.zero) return AppLockPasscodeCheck.blocked;
    String? record;
    try {
      record = await _storage.readPasscodeRecord();
    } catch (_) {
      record = null;
    }
    if (!AppLockPasscodeHash.isWellFormed(record)) {
      // Nothing to check against: do not lock the person out for good.
      await _storage.setHasPasscode(false);
      await _storage.setAttempts(failedAttempts: 0, blockedUntilMs: 0);
      _notify();
      return AppLockPasscodeCheck.missing;
    }
    if (AppLockPasscodeHash.verify(code, record)) {
      await _storage.setAttempts(failedAttempts: 0, blockedUntilMs: 0);
      _notify();
      return AppLockPasscodeCheck.ok;
    }
    final attempts = _storage.failedAttempts + 1;
    final wait = appLockWaitAfter(attempts);
    await _storage.setAttempts(
      failedAttempts: attempts,
      blockedUntilMs: wait == Duration.zero
          ? 0
          : _now().add(wait).millisecondsSinceEpoch,
    );
    _notify();
    return AppLockPasscodeCheck.wrong;
  }

  void _unlocked() {
    _locked = false;
    _lastAttemptFailed = false;
    // Time spent behind the lock screen is not time away.
    _backgroundedAt = null;
  }

  /// The lock screen's number pad: unlocks when [code] is the passcode.
  Future<AppLockPasscodeCheck> submitPasscode(String code) async {
    final result = await checkPasscode(code);
    if (result == AppLockPasscodeCheck.ok) {
      _unlocked();
      _notify();
    }
    return result;
  }

  /// Whether a biometric is enrolled that this app may use.
  Future<bool> biometricsAvailable() async {
    try {
      return await _biometrics?.hasEnrolledBiometrics() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Runs the biometric-only prompt; true when it recognised the person.
  Future<bool> confirmWithBiometric(String reason) async {
    final biometrics = _biometrics;
    if (biometrics == null || _authenticating) return false;
    _authenticating = true;
    _notify();
    AppLockAuthResult result;
    try {
      result = await biometrics.authenticateBiometric(reason);
    } catch (_) {
      result = AppLockAuthResult.failed;
    }
    _authenticating = false;
    _notify();
    return result == AppLockAuthResult.success;
  }

  /// Face ID / fingerprint on the lock screen. Stays locked unless it
  /// succeeds; the passcode pad is always there as the other way in.
  Future<bool> unlockWithBiometric(String reason) async {
    if (!_locked) return true;
    if (!biometricEnabled) return false;
    if (await confirmWithBiometric(reason)) {
      await _storage.setAttempts(failedAttempts: 0, blockedUntilMs: 0);
      _unlocked();
      _notify();
    }
    return !_locked;
  }

  /// Asks the phone itself who is holding it (biometrics or the phone's
  /// own passcode / PIN): what "Forgot passcode?" rests on. False when it
  /// failed or the phone has nothing to ask with.
  Future<bool> confirmDeviceOwner(String reason) async {
    if (_authenticating) return false;
    _authenticating = true;
    _notify();
    AppLockAuthResult result;
    try {
      result = await _authenticator.isAvailable()
          ? await _authenticator.authenticate(reason)
          : AppLockAuthResult.unavailable;
    } catch (_) {
      result = AppLockAuthResult.failed;
    }
    _authenticating = false;
    _notify();
    return result == AppLockAuthResult.success;
  }

  /// Saves [code] as the passcode (only its salted hash is kept) and, when
  /// the lock was off, switches it on. Whoever calls this has already
  /// proved who they are, or is setting the lock up for the first time.
  /// With [unlock] the lock screen opens too (a passcode reset from it).
  Future<bool> setPasscode(String code, {bool unlock = false}) async {
    if (!isValidAppLockPasscode(code)) return false;
    try {
      await _storage.writePasscodeRecord(AppLockPasscodeHash.create(code));
    } catch (_) {
      return false;
    }
    await _storage.setHasPasscode(true);
    await _storage.setAttempts(failedAttempts: 0, blockedUntilMs: 0);
    if (!_enabled) {
      _enabled = true;
      _backgroundedAt = null;
      await _persist(true);
    }
    if (unlock) _unlocked();
    _notify();
    return true;
  }

  /// Switches unlocking with Face ID / fingerprint on or off.
  Future<void> setBiometricEnabled(bool on) async {
    await _storage.setBiometricEnabled(on);
    _notify();
  }
}
