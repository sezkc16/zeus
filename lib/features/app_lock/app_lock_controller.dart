import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;

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
    DateTime Function() now = DateTime.now,
    this.relockAfter = const Duration(seconds: 60),
  }) : _authenticator = authenticator,
       _persist = persist,
       _now = now,
       _enabled = enabled,
       _locked = enabled;

  final AppLockAuthenticator _authenticator;
  final Future<void> Function(bool enabled) _persist;
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
}
