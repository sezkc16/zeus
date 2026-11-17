import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/app_lock/app_lock_controller.dart';

/// App lock (v7): the lock state machine, with a fake authenticator and a
/// fake clock.

class _Auth implements AppLockAuthenticator {
  bool available = true;
  AppLockAuthResult next = AppLockAuthResult.success;
  int prompts = 0;
  Completer<AppLockAuthResult>? pending;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<AppLockAuthResult> authenticate(String reason) {
    prompts++;
    final p = pending;
    if (p != null) return p.future;
    return Future.value(next);
  }
}

void main() {
  late _Auth auth;
  late DateTime now;
  late List<bool> persisted;
  var playerActive = false;

  AppLockController make({required bool enabled}) {
    final c = AppLockController(
      authenticator: auth,
      enabled: enabled,
      persist: (v) async => persisted.add(v),
      now: () => now,
    )..isPlayerActive = () => playerActive;
    addTearDown(c.dispose);
    return c;
  }

  void background(AppLockController c, Duration away) {
    c.onLifecycle(AppLifecycleState.inactive);
    c.onLifecycle(AppLifecycleState.hidden);
    c.onLifecycle(AppLifecycleState.paused);
    now = now.add(away);
    c.onLifecycle(AppLifecycleState.hidden);
    c.onLifecycle(AppLifecycleState.inactive);
    c.onLifecycle(AppLifecycleState.resumed);
  }

  setUp(() {
    auth = _Auth();
    now = DateTime(2026, 11, 17, 12);
    persisted = [];
    playerActive = false;
  });

  test('cold start: locked when enabled, open when not', () {
    expect(make(enabled: true).locked, isTrue);
    final off = make(enabled: false);
    expect(off.locked, isFalse);
    expect(off.covered, isFalse);
  });

  test('unlocks on success', () async {
    final c = make(enabled: true);
    expect(await c.unlock('r'), isTrue);
    expect(c.locked, isFalse);
    expect(c.lastAttemptFailed, isFalse);
    expect(auth.prompts, 1);
  });

  test('stays locked on failure, and on an authenticator that throws', () async {
    final c = make(enabled: true);
    auth.next = AppLockAuthResult.failed;
    expect(await c.unlock('r'), isFalse);
    expect(c.locked, isTrue);
    expect(c.lastAttemptFailed, isTrue);

    auth.next = AppLockAuthResult.unavailable;
    expect(await c.unlock('r'), isFalse);
    expect(c.locked, isTrue);

    auth.pending = Completer<AppLockAuthResult>()..completeError(StateError('x'));
    expect(await c.unlock('r'), isFalse);
    expect(c.locked, isTrue);

    auth.pending = null;
    auth.next = AppLockAuthResult.success;
    expect(await c.unlock('r'), isTrue);
    expect(c.locked, isFalse);
  });

  test('only one prompt at a time', () async {
    final c = make(enabled: true);
    auth.pending = Completer<AppLockAuthResult>();
    final first = c.unlock('r');
    expect(c.authenticating, isTrue);
    expect(await c.unlock('r'), isFalse);
    expect(auth.prompts, 1);
    auth.pending!.complete(AppLockAuthResult.success);
    expect(await first, isTrue);
  });

  test('re-locks only after more than 60 s in the background', () async {
    final c = make(enabled: true);
    await c.unlock('r');
    final generation = c.lockGeneration;

    background(c, const Duration(seconds: 30));
    expect(c.locked, isFalse);
    expect(c.covered, isFalse);

    background(c, const Duration(seconds: 60));
    expect(c.locked, isFalse, reason: 'exactly 60 s is not more than 60 s');

    background(c, const Duration(seconds: 61));
    expect(c.locked, isTrue);
    expect(c.lockGeneration, generation + 1);
  });

  test('short trips do not add up', () async {
    final c = make(enabled: true);
    await c.unlock('r');
    background(c, const Duration(seconds: 40));
    now = now.add(const Duration(minutes: 5)); // in front, in use
    background(c, const Duration(seconds: 40));
    expect(c.locked, isFalse);
  });

  test('covers the content while not in front, uncovers on return', () async {
    final c = make(enabled: true);
    await c.unlock('r');
    c.onLifecycle(AppLifecycleState.inactive);
    expect(c.covered, isTrue, reason: 'the app switcher');
    expect(c.locked, isFalse);
    c.onLifecycle(AppLifecycleState.resumed);
    expect(c.covered, isFalse);
    expect(c.locked, isFalse, reason: 'inactive alone never locks');
  });

  test('disabled: never covers, never locks', () {
    final c = make(enabled: false);
    c.onLifecycle(AppLifecycleState.inactive);
    expect(c.covered, isFalse);
    background(c, const Duration(hours: 2));
    expect(c.locked, isFalse);
    expect(c.covered, isFalse);
  });

  test('the system prompt making the app inactive is not a cover', () async {
    final c = make(enabled: true);
    auth.pending = Completer<AppLockAuthResult>();
    final unlocking = c.unlock('r');
    c.onLifecycle(AppLifecycleState.inactive);
    expect(c.covered, isFalse);
    auth.pending!.complete(AppLockAuthResult.success);
    await unlocking;
    c.onLifecycle(AppLifecycleState.resumed);
    expect(c.locked, isFalse);
    expect(c.covered, isFalse);
  });

  test('no lock and no cover while the player is active', () async {
    final c = make(enabled: true);
    await c.unlock('r');
    playerActive = true;
    c.onPlayerActivityChanged();

    c.onLifecycle(AppLifecycleState.inactive);
    expect(c.covered, isFalse);
    c.onLifecycle(AppLifecycleState.paused);
    expect(c.covered, isFalse, reason: 'Picture-in-Picture keeps playing');
    now = now.add(const Duration(minutes: 10));
    c.onLifecycle(AppLifecycleState.resumed);
    expect(c.locked, isFalse);
    expect(c.covered, isFalse);

    // The lock that came due waits for the player to close.
    playerActive = false;
    c.onPlayerActivityChanged();
    expect(c.locked, isTrue);
  });

  test('a short trip with the player up leaves nothing pending', () async {
    final c = make(enabled: true);
    await c.unlock('r');
    playerActive = true;
    background(c, const Duration(seconds: 20));
    playerActive = false;
    c.onPlayerActivityChanged();
    expect(c.locked, isFalse);
  });

  test('opening the player lifts a cover', () async {
    final c = make(enabled: true);
    await c.unlock('r');
    c.onLifecycle(AppLifecycleState.inactive);
    expect(c.covered, isTrue);
    playerActive = true;
    c.onPlayerActivityChanged();
    expect(c.covered, isFalse);
  });

  group('enabling', () {
    test('requires one successful authentication', () async {
      final c = make(enabled: false);
      expect(await c.setEnabled(true, reason: 'r'), AppLockChange.done);
      expect(c.enabled, isTrue);
      expect(c.locked, isFalse, reason: 'they just proved it is them');
      expect(persisted, [true]);
      expect(auth.prompts, 1);
    });

    test('a failed authentication leaves it off', () async {
      final c = make(enabled: false);
      auth.next = AppLockAuthResult.failed;
      expect(await c.setEnabled(true, reason: 'r'), AppLockChange.notVerified);
      expect(c.enabled, isFalse);
      expect(c.authenticating, isFalse);
      expect(persisted, isEmpty);
    });

    test('a device with nothing to authenticate with leaves it off', () async {
      final c = make(enabled: false);
      auth.available = false;
      expect(await c.setEnabled(true, reason: 'r'), AppLockChange.unavailable);
      expect(c.enabled, isFalse);
      expect(auth.prompts, 0);
      expect(persisted, isEmpty);
    });

    test('switching off clears the lock and is saved', () async {
      final c = make(enabled: true);
      await c.unlock('r');
      expect(await c.setEnabled(false, reason: 'r'), AppLockChange.done);
      expect(c.enabled, isFalse);
      expect(persisted, [false]);
      background(c, const Duration(hours: 1));
      expect(c.locked, isFalse);
    });

    test('once on, it locks after a long trip away', () async {
      final c = make(enabled: false);
      await c.setEnabled(true, reason: 'r');
      background(c, const Duration(seconds: 90));
      expect(c.locked, isTrue);
    });
  });
}
