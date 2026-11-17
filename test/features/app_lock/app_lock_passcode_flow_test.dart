// ignore_for_file: riverpod_lint/scoped_providers_should_specify_dependencies

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zorox/core/router/app_router.dart';
import 'package:zorox/features/app_lock/app_lock_controller.dart';
import 'package:zorox/features/app_lock/app_lock_gate.dart';
import 'package:zorox/features/app_lock/app_lock_passcode.dart';
import 'package:zorox/features/app_lock/app_lock_provider.dart';
import 'package:zorox/features/app_lock/app_lock_strings.dart';
import 'package:zorox/features/settings/presentation/app_lock_settings_screen.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// App lock (v1.0.1): set a passcode in Settings, then the lock screen's
/// number pad - a wrong passcode stays locked, the right one opens.

class _Auth implements AppLockAuthenticator, AppLockBiometrics {
  AppLockAuthResult next = AppLockAuthResult.success;
  AppLockAuthResult nextBiometric = AppLockAuthResult.success;
  bool enrolled = false;
  int devicePrompts = 0;
  int biometricPrompts = 0;

  @override
  Future<bool> isAvailable() async => true;

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
  late _Auth auth;
  late InMemoryAppLockStorage storage;
  late AppLockController controller;
  late GoRouter router;
  var now = DateTime(2026, 11, 17, 12);

  Future<void> pump(
    WidgetTester tester, {
    required bool enabled,
    Size size = const Size(393, 852),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    controller = AppLockController(
      authenticator: auth,
      biometrics: auth,
      storage: storage,
      enabled: enabled,
      persist: (_) async {},
      now: () => now,
    );
    addTearDown(controller.dispose);
    router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const AppLockSettingsScreen()),
        GoRoute(
          path: kPlayerRoutePath,
          builder: (_, _) => const Scaffold(body: Text('VIDEO')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appLockControllerProvider.overrideWithValue(controller)],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              AppLockGate(router: router, child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String digits) async {
    for (final d in digits.split('')) {
      await tester.tap(find.byKey(ValueKey('app-lock-key-$d')).last);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  String title(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('app-lock-pad-title')).last)
      .data!;
  String message(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('app-lock-pad-message')).last)
      .data!;

  const cover = ValueKey('app-lock-cover');
  // Widget tests run as Android: the same wording the widgets pick.
  final strings = AppLockStrings.current();

  setUp(() {
    auth = _Auth();
    storage = InMemoryAppLockStorage();
    now = DateTime(2026, 11, 17, 12);
  });

  testWidgets('set a passcode, lock, wrong stays locked, right unlocks', (
    tester,
  ) async {
    await pump(tester, enabled: false);
    expect(find.byKey(cover), findsNothing);

    // Turning the lock on asks for a new passcode, twice.
    await tester.tap(find.byKey(const ValueKey('app-lock-master-switch')));
    await tester.pumpAndSettle();
    expect(title(tester), strings.enterNew);
    await type(tester, '2468');
    expect(title(tester), strings.confirmNew);

    // A mismatch clears and starts over.
    await type(tester, '2469');
    expect(title(tester), strings.enterNew);
    expect(message(tester), strings.mismatch);
    expect(controller.enabled, isFalse);

    await type(tester, '2468');
    await type(tester, '2468');
    expect(controller.enabled, isTrue);
    expect(controller.usesPasscode, isTrue);
    expect(storage.record!.contains('2468'), isFalse);
    // Back on the App lock page, switched on, not locked.
    expect(
      tester
          .widget<Switch>(find.byKey(const ValueKey('app-lock-master-switch')))
          .value,
      isTrue,
    );
    expect(find.byKey(cover), findsNothing);
    // No biometric enrolled on this phone: no switch for it.
    expect(find.byKey(const ValueKey('app-lock-biometric')), findsNothing);

    // More than a minute away locks.
    controller.onLifecycle(AppLifecycleState.paused);
    now = now.add(const Duration(seconds: 61));
    controller.onLifecycle(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byKey(cover), findsOneWidget);
    expect(title(tester), strings.enterPasscode);
    // The lock screen never calls the device's own prompt.
    expect(auth.devicePrompts, 0);

    await type(tester, '1111');
    expect(find.byKey(cover), findsOneWidget);
    expect(message(tester), strings.wrong);
    expect(controller.failedAttempts, 1);

    await type(tester, '2468');
    expect(find.byKey(cover), findsNothing);
    expect(controller.locked, isFalse);
  });

  testWidgets('five wrong tries show a countdown and block the pad', (
    tester,
  ) async {
    storage = InMemoryAppLockStorage(
      hasPasscode: true,
      record: AppLockPasscodeHash.create('2468'),
    );
    await pump(tester, enabled: true);
    expect(find.byKey(cover), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      await type(tester, '0000');
    }
    expect(message(tester), contains('Try again in 30 s'));
    await type(tester, '2468');
    expect(find.byKey(cover), findsOneWidget);

    now = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await type(tester, '2468');
    expect(find.byKey(cover), findsNothing);
  });

  testWidgets('forgot passcode: the phone confirms, then a new passcode', (
    tester,
  ) async {
    storage = InMemoryAppLockStorage(
      hasPasscode: true,
      record: AppLockPasscodeHash.create('2468'),
    );
    await pump(tester, enabled: true);

    auth.next = AppLockAuthResult.failed;
    await tester.tap(find.byKey(const ValueKey('app-lock-forgot')));
    await tester.pumpAndSettle();
    expect(message(tester), strings.forgotFailed);
    expect(title(tester), strings.enterPasscode);

    auth.next = AppLockAuthResult.success;
    await tester.tap(find.byKey(const ValueKey('app-lock-forgot')));
    await tester.pumpAndSettle();
    expect(title(tester), strings.enterNew);
    await type(tester, '9753');
    await type(tester, '9753');
    expect(find.byKey(cover), findsNothing);
    expect(AppLockPasscodeHash.verify('9753', storage.record), isTrue);
  });

  testWidgets('biometric: prompted once when the lock appears, with a key to '
      'try again; the passcode still works', (tester) async {
    storage = InMemoryAppLockStorage(
      hasPasscode: true,
      biometricEnabled: true,
      record: AppLockPasscodeHash.create('2468'),
    );
    auth
      ..enrolled = true
      ..nextBiometric = AppLockAuthResult.failed;
    await pump(tester, enabled: true);
    expect(auth.biometricPrompts, 1);
    expect(find.byKey(cover), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('app-lock-key-biometric')));
    await tester.pumpAndSettle();
    expect(auth.biometricPrompts, 2);
    expect(find.byKey(cover), findsOneWidget);

    auth.nextBiometric = AppLockAuthResult.success;
    await tester.tap(find.byKey(const ValueKey('app-lock-key-biometric')));
    await tester.pumpAndSettle();
    expect(find.byKey(cover), findsNothing);
    expect(auth.devicePrompts, 0);
  });

  testWidgets('turning the lock off and changing the passcode ask for the '
      'current passcode', (tester) async {
    storage = InMemoryAppLockStorage(
      hasPasscode: true,
      record: AppLockPasscodeHash.create('2468'),
    );
    await pump(tester, enabled: true);
    await type(tester, '2468');
    expect(find.byKey(cover), findsNothing);

    // Change: current, then new twice.
    await tester.tap(find.byKey(const ValueKey('app-lock-passcode-row')));
    await tester.pumpAndSettle();
    expect(title(tester), strings.enterCurrent);
    await type(tester, '0000');
    expect(message(tester), strings.wrong);
    await type(tester, '2468');
    expect(title(tester), strings.enterNew);
    await type(tester, '1357');
    await type(tester, '1357');
    expect(AppLockPasscodeHash.verify('1357', storage.record), isTrue);

    // Off: a wrong passcode leaves it on.
    await tester.tap(find.byKey(const ValueKey('app-lock-master-switch')));
    await tester.pumpAndSettle();
    expect(title(tester), strings.enterCurrent);
    await type(tester, '2468');
    expect(controller.enabled, isTrue);
    await type(tester, '1357');
    expect(controller.enabled, isFalse);
    expect(storage.record, isNull);
  });

  testWidgets('migration: an old lock shows the prompt to set a passcode and '
      'still unlocks with the device', (tester) async {
    await pump(tester, enabled: true);
    // The old lock screen prompted the device by itself, as before, and
    // that opened the app.
    expect(auth.devicePrompts, 1);
    expect(find.byKey(cover), findsNothing);
    expect(
      find.byKey(const ValueKey('app-lock-legacy-prompt')),
      findsOneWidget,
    );

    // Setting a passcode asks the device first, then the new passcode.
    await tester.tap(find.byKey(const ValueKey('app-lock-passcode-row')));
    await tester.pumpAndSettle();
    expect(auth.devicePrompts, 2);
    await type(tester, '4321');
    await type(tester, '4321');
    expect(controller.usesPasscode, isTrue);
    expect(find.byKey(const ValueKey('app-lock-footnote')), findsOneWidget);
  });

  for (final size in const [Size(852, 393), Size(260, 280), Size(320, 568)]) {
    testWidgets('the lock screen fits $size without overflow', (tester) async {
      storage = InMemoryAppLockStorage(
        hasPasscode: true,
        record: AppLockPasscodeHash.create('2468'),
      );
      await pump(tester, enabled: true, size: size);
      expect(find.byKey(cover), findsOneWidget);
      expect(tester.takeException(), isNull);
      await type(tester, '2468');
      expect(find.byKey(cover), findsNothing);
    });
  }

  test('wording follows the platform', () {
    const ios = AppLockStrings(TargetPlatform.iOS);
    const android = AppLockStrings(TargetPlatform.android);
    expect(ios.biometricSwitch, 'Unlock with Face ID');
    expect(android.biometricSwitch, 'Unlock with face or fingerprint');
    expect(android.rowSubtitle.contains('Face ID'), isFalse);
    expect(android.legacyPrompt.contains('Face ID'), isFalse);
    expect(android.forgotFailed.contains('iPhone'), isFalse);
  });
}
