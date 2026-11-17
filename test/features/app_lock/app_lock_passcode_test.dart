import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/account/data/zorox_settings_sync.dart';
import 'package:zorox/features/app_lock/app_lock_controller.dart';
import 'package:zorox/features/app_lock/app_lock_passcode.dart';
import 'package:zorox/features/app_lock/app_lock_provider.dart';

/// App lock (v1.0.1): the app's own passcode - how it is kept, how wrong
/// tries are counted, and what happens to a lock switched on before it.

class _Auth implements AppLockAuthenticator, AppLockBiometrics {
  bool available = true;
  AppLockAuthResult next = AppLockAuthResult.success;
  AppLockAuthResult nextBiometric = AppLockAuthResult.success;
  bool enrolled = true;
  int devicePrompts = 0;
  int biometricPrompts = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<AppLockAuthResult> authenticate(String reason) async {
    devicePrompts++;
    return next;
  }

  @override
  Future<bool> hasEnrolledBiometrics() async => enrolled;

  @override
  Future<AppLockAuthResult> authenticateBiometric(String reason) async {
    biometricPrompts++;
    return nextBiometric;
  }
}

void main() {
  group('the passcode record', () {
    test('never holds the digits, and checks only the right passcode', () {
      final record = AppLockPasscodeHash.create('4821');
      expect(record.contains('4821'), isFalse);
      expect(record.startsWith(r'v1$'), isTrue);
      expect(AppLockPasscodeHash.verify('4821', record), isTrue);
      expect(AppLockPasscodeHash.verify('4822', record), isFalse);
      expect(AppLockPasscodeHash.verify('', record), isFalse);
    });

    test('the same passcode gives a different record each time (salt)', () {
      final a = AppLockPasscodeHash.create('0000');
      final b = AppLockPasscodeHash.create('0000');
      expect(a, isNot(b));
      expect(AppLockPasscodeHash.verify('0000', a), isTrue);
      expect(AppLockPasscodeHash.verify('0000', b), isTrue);
    });

    test('a fixed salt gives a fixed record', () {
      final a = AppLockPasscodeHash.create('1234', random: Random(7));
      final b = AppLockPasscodeHash.create('1234', random: Random(7));
      expect(a, b);
    });

    test('a damaged or missing record matches nothing', () {
      expect(AppLockPasscodeHash.verify('1234', null), isFalse);
      expect(AppLockPasscodeHash.verify('1234', ''), isFalse);
      expect(AppLockPasscodeHash.verify('1234', r'v1$10$!!$!!'), isFalse);
      expect(AppLockPasscodeHash.verify('1234', r'v2$10$AAAA$AAAA'), isFalse);
      expect(AppLockPasscodeHash.isWellFormed('1234'), isFalse);
    });

    test('only four digits are a passcode', () {
      expect(isValidAppLockPasscode('0123'), isTrue);
      expect(isValidAppLockPasscode('123'), isFalse);
      expect(isValidAppLockPasscode('12345'), isFalse);
      expect(isValidAppLockPasscode('12a4'), isFalse);
    });
  });

  test('waits: five free tries, then 30 s doubling to 5 min', () {
    for (var i = 0; i < 5; i++) {
      expect(appLockWaitAfter(i), Duration.zero);
    }
    expect(appLockWaitAfter(5), const Duration(seconds: 30));
    expect(appLockWaitAfter(6), const Duration(seconds: 60));
    expect(appLockWaitAfter(7), const Duration(seconds: 120));
    expect(appLockWaitAfter(8), const Duration(seconds: 240));
    expect(appLockWaitAfter(9), const Duration(minutes: 5));
    expect(appLockWaitAfter(500), const Duration(minutes: 5));
  });

  test('nothing the lock stores is on the backup / sync allow-list', () {
    expect(kSyncedSettingKeys.contains('app_lock_enabled'), isFalse);
    for (final key in DeviceAppLockStorage.allKeys) {
      expect(kSyncedSettingKeys.contains(key), isFalse, reason: key);
    }
  });

  group('the controller', () {
    late _Auth auth;
    late DateTime now;
    late List<bool> persisted;
    late InMemoryAppLockStorage storage;

    AppLockController make({required bool enabled}) {
      final c = AppLockController(
        authenticator: auth,
        biometrics: auth,
        storage: storage,
        enabled: enabled,
        persist: (v) async => persisted.add(v),
        now: () => now,
      );
      addTearDown(c.dispose);
      return c;
    }

    setUp(() {
      auth = _Auth();
      now = DateTime(2026, 11, 17, 12);
      persisted = [];
      storage = InMemoryAppLockStorage();
    });

    test('setting a passcode switches the lock on and keeps only a hash',
        () async {
      final c = make(enabled: false);
      expect(await c.setPasscode('12'), isFalse);
      expect(c.enabled, isFalse);
      expect(await c.setPasscode('2468'), isTrue);
      expect(c.enabled, isTrue);
      expect(c.usesPasscode, isTrue);
      expect(c.locked, isFalse);
      expect(persisted, [true]);
      expect(storage.record, isNotNull);
      expect(storage.record!.contains('2468'), isFalse);
      // No system prompt was needed to set it up.
      expect(auth.devicePrompts, 0);
    });

    test('a cold start is locked; only the right passcode opens it',
        () async {
      storage = InMemoryAppLockStorage(
        hasPasscode: true,
        record: AppLockPasscodeHash.create('2468'),
      );
      final c = make(enabled: true);
      expect(c.locked, isTrue);
      expect(await c.submitPasscode('0000'), AppLockPasscodeCheck.wrong);
      expect(c.locked, isTrue);
      expect(c.failedAttempts, 1);
      expect(await c.submitPasscode('2468'), AppLockPasscodeCheck.ok);
      expect(c.locked, isFalse);
      expect(c.failedAttempts, 0);
      // The device passcode prompt is not part of unlocking any more.
      expect(auth.devicePrompts, 0);
    });

    test('five wrong tries start a wait that doubles and survives a restart',
        () async {
      storage = InMemoryAppLockStorage(
        hasPasscode: true,
        record: AppLockPasscodeHash.create('2468'),
      );
      var c = make(enabled: true);
      for (var i = 0; i < 4; i++) {
        expect(await c.submitPasscode('0000'), AppLockPasscodeCheck.wrong);
        expect(c.blockedFor, Duration.zero);
      }
      expect(await c.submitPasscode('0000'), AppLockPasscodeCheck.wrong);
      expect(c.blockedFor, const Duration(seconds: 30));
      // Even the right passcode waits.
      expect(await c.submitPasscode('2468'), AppLockPasscodeCheck.blocked);
      expect(c.locked, isTrue);

      // The app is closed and opened again: still waiting.
      c = make(enabled: true);
      expect(c.locked, isTrue);
      expect(c.failedAttempts, 5);
      now = now.add(const Duration(seconds: 20));
      expect(c.blockedFor, const Duration(seconds: 10));
      expect(await c.submitPasscode('2468'), AppLockPasscodeCheck.blocked);

      now = now.add(const Duration(seconds: 11));
      expect(c.blockedFor, Duration.zero);
      expect(await c.submitPasscode('0000'), AppLockPasscodeCheck.wrong);
      expect(c.blockedFor, const Duration(seconds: 60));

      now = now.add(const Duration(seconds: 61));
      expect(await c.submitPasscode('2468'), AppLockPasscodeCheck.ok);
      expect(c.locked, isFalse);
      expect(storage.failedAttempts, 0);
      expect(storage.blockedUntilMs, 0);
    });

    test('a clock set back cannot stretch the wait past five minutes',
        () async {
      storage = InMemoryAppLockStorage(
        hasPasscode: true,
        record: AppLockPasscodeHash.create('2468'),
        failedAttempts: 5,
        blockedUntilMs:
            now.add(const Duration(days: 3)).millisecondsSinceEpoch,
      );
      final c = make(enabled: true);
      expect(c.blockedFor, const Duration(minutes: 5));
    });

    test('biometrics unlock only when switched on, and never fall back to '
        'the device passcode', () async {
      storage = InMemoryAppLockStorage(
        hasPasscode: true,
        record: AppLockPasscodeHash.create('2468'),
      );
      final c = make(enabled: true);
      expect(await c.unlockWithBiometric('r'), isFalse);
      expect(auth.biometricPrompts, 0);

      await c.setBiometricEnabled(true);
      auth.nextBiometric = AppLockAuthResult.failed;
      expect(await c.unlockWithBiometric('r'), isFalse);
      expect(c.locked, isTrue);
      auth.nextBiometric = AppLockAuthResult.success;
      expect(await c.unlockWithBiometric('r'), isTrue);
      expect(c.locked, isFalse);
      expect(auth.biometricPrompts, 2);
      expect(auth.devicePrompts, 0);
    });

    test('migration: a lock switched on before passcodes keeps working with '
        'the device prompt until a passcode is set', () async {
      // v7 state: the switch is on, nothing else is stored.
      final c = make(enabled: true);
      expect(c.locked, isTrue);
      expect(c.usesPasscode, isFalse);
      expect(c.biometricEnabled, isFalse);

      expect(await c.unlock('Unlock Zeus'), isTrue);
      expect(auth.devicePrompts, 1);
      expect(c.enabled, isTrue);

      expect(await c.setPasscode('1357'), isTrue);
      expect(c.usesPasscode, isTrue);
      expect(c.enabled, isTrue);
      // It was on already: nothing new is persisted for the switch.
      expect(persisted, isEmpty);
    });

    test('a passcode that cannot be read falls back to the device prompt '
        'instead of locking the person out', () async {
      storage = InMemoryAppLockStorage(hasPasscode: true);
      final c = make(enabled: true);
      expect(c.locked, isTrue);
      expect(await c.submitPasscode('2468'), AppLockPasscodeCheck.missing);
      expect(c.locked, isTrue);
      expect(c.usesPasscode, isFalse);
      expect(await c.unlock('Unlock Zeus'), isTrue);
      expect(c.locked, isFalse);
    });

    test('forgot passcode: the phone confirms, a new passcode opens the app',
        () async {
      storage = InMemoryAppLockStorage(
        hasPasscode: true,
        record: AppLockPasscodeHash.create('2468'),
        failedAttempts: 6,
        blockedUntilMs:
            now.add(const Duration(seconds: 50)).millisecondsSinceEpoch,
      );
      final c = make(enabled: true);
      auth.next = AppLockAuthResult.failed;
      expect(await c.confirmDeviceOwner('r'), isFalse);
      auth.next = AppLockAuthResult.success;
      expect(await c.confirmDeviceOwner('r'), isTrue);
      expect(await c.setPasscode('9753', unlock: true), isTrue);
      expect(c.locked, isFalse);
      expect(c.blockedFor, Duration.zero);
      expect(AppLockPasscodeHash.verify('9753', storage.record), isTrue);
      expect(AppLockPasscodeHash.verify('2468', storage.record), isFalse);
    });

    test('the phone has nothing to confirm with: forgot cannot reset',
        () async {
      auth.available = false;
      final c = make(enabled: true);
      expect(await c.confirmDeviceOwner('r'), isFalse);
      expect(auth.devicePrompts, 0);
    });

    test('switching the lock off forgets the passcode', () async {
      final c = make(enabled: false);
      await c.setPasscode('2468');
      await c.setBiometricEnabled(true);
      await c.setEnabled(false, reason: 'r');
      expect(c.enabled, isFalse);
      expect(c.usesPasscode, isFalse);
      expect(storage.record, isNull);
      expect(storage.biometricEnabled, isFalse);
      expect(persisted, [true, false]);
    });
  });
}
