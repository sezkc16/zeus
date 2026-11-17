// ignore_for_file: riverpod_lint/scoped_providers_should_specify_dependencies

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zorox/core/router/app_router.dart';
import 'package:zorox/features/app_lock/app_lock_controller.dart';
import 'package:zorox/features/app_lock/app_lock_gate.dart';
import 'package:zorox/features/app_lock/app_lock_provider.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// App lock (v7): the gate over the app - lock screen on a cold start,
/// one automatic prompt, Unlock after a failure, the privacy cover, and
/// standing down over the player route.

class _Auth implements AppLockAuthenticator {
  AppLockAuthResult next = AppLockAuthResult.failed;
  int prompts = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<AppLockAuthResult> authenticate(String reason) async {
    prompts++;
    return next;
  }
}

void main() {
  late _Auth auth;
  late AppLockController controller;
  late GoRouter router;

  Future<void> pump(WidgetTester tester, {required bool enabled}) async {
    auth = _Auth();
    controller = AppLockController(
      authenticator: auth,
      enabled: enabled,
      persist: (_) async {},
    );
    addTearDown(controller.dispose);
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('SECRET CONTENT')),
        ),
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
    await tester.pump();
    await tester.pump();
  }

  const cover = ValueKey('app-lock-cover');
  const unlock = ValueKey('app-lock-unlock');

  testWidgets('off: no cover, no prompt', (tester) async {
    await pump(tester, enabled: false);
    expect(find.byKey(cover), findsNothing);
    expect(find.text('SECRET CONTENT'), findsOneWidget);
    expect(auth.prompts, 0);
  });

  testWidgets('cold start: locked, prompts once, a failure stays locked and '
      'Unlock tries again', (tester) async {
    await pump(tester, enabled: true);
    expect(find.byKey(cover), findsOneWidget);
    expect(find.text('Zeus'), findsOneWidget);
    expect(auth.prompts, 1, reason: 'one automatic prompt');
    expect(find.byKey(const ValueKey('app-lock-failed')), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(auth.prompts, 1, reason: 'no prompt loop after a failure');

    auth.next = AppLockAuthResult.success;
    await tester.tap(find.byKey(unlock));
    await tester.pump();
    await tester.pump();
    expect(auth.prompts, 2);
    expect(find.byKey(cover), findsNothing);
    expect(find.text('SECRET CONTENT'), findsOneWidget);
  });

  testWidgets('inactive covers without the Unlock button; resumed uncovers', (
    tester,
  ) async {
    await pump(tester, enabled: true);
    auth.next = AppLockAuthResult.success;
    await tester.tap(find.byKey(unlock));
    await tester.pump();
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.byKey(cover), findsOneWidget);
    expect(find.byKey(unlock), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byKey(cover), findsNothing);
  });

  testWidgets('player route on top: no cover while inactive', (tester) async {
    await pump(tester, enabled: true);
    auth.next = AppLockAuthResult.success;
    await tester.tap(find.byKey(unlock));
    await tester.pump();
    await tester.pump();

    unawaited(router.push<void>(kPlayerRoutePath));
    await tester.pumpAndSettle();
    expect(find.text('VIDEO'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.byKey(cover), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byKey(cover), findsNothing);
  });
}
