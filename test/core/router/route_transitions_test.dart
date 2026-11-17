import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zorox/core/router/route_transitions.dart';
import 'package:zorox/core/utils/motion.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('iOS: a pushed page is a CupertinoPage, so the edge swipe goes back', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final page = smoothPage(key: const ValueKey('p'), child: const SizedBox());
    expect(page, isA<CupertinoPage<void>>());
    debugDefaultTargetPlatformOverride = null;
  });

  test('iOS: the player keeps the custom page - no back swipe', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final page = smoothPage(
      key: const ValueKey('p'),
      child: const SizedBox(),
      swipeBack: false,
    );
    expect(page, isA<CustomTransitionPage<void>>());
    debugDefaultTargetPlatformOverride = null;
  });

  test('Android: the slide + fade page, at the shared duration', () {
    final page = smoothPage(key: const ValueKey('p'), child: const SizedBox());
    expect(page, isA<CustomTransitionPage<void>>());
    final custom = page as CustomTransitionPage<void>;
    expect(custom.transitionDuration, kMotionPage);
    expect(custom.reverseTransitionDuration, kMotionPage);
  });

  test('the shared timings are the 1.0.1 slower set', () {
    expect(kMotionPage.inMilliseconds, 360);
    expect(kMotionTab.inMilliseconds, 320);
    expect(kMotionSegmentPage.inMilliseconds, 360);
    expect(kMotionPill.inMilliseconds, 280);
  });

  testWidgets('iOS: dragging from the left edge pops a smoothPage route; '
      'a short drag cancels', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('first')),
        ),
        GoRoute(
          path: '/second',
          pageBuilder: (_, state) => smoothPage(
            key: state.pageKey,
            child: const Scaffold(body: Text('second')),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    unawaited(router.push('/second'));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);

    // Let go early: stays.
    var gesture = await tester.startGesture(const Offset(5, 300));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);

    // Past half the width: goes back.
    gesture = await tester.startGesture(const Offset(5, 300));
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
    expect(find.text('first'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}

void unawaited(Future<void> f) {}
