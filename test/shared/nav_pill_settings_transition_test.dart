/// Repro: the bottom nav pill vanishes for a few seconds when navigating
/// to/from Settings (user 2026-11-19, build 85/86, recording
/// 6cc621ab...mp4). Frames show the pill missing mid-transition (Settings
/// sliding out over Home) and only back seconds later, even though the
/// branch switch itself is 360 ms.
///
/// Build 88: the pill is hidden on the Settings branch again — the user
/// saw build 87's always-visible pill on Settings and chose "Settings pe
/// chhupa do" — but it NEVER leaves the tree. The gap was the
/// re-insertion: the pill was destroyed on Settings and rebuilt on the
/// return (its glass layer re-rendering), so it only appeared ~2 frames
/// into the slide. Now the pill stays mounted on every branch and is
/// parked off-screen on Settings (hiddenNavPaddingBottom): the
/// visibility flips in the same build as the branch change, so the pill
/// is back on screen in the first frame of the return and gone in the
/// first frame of the way in. The pill keeps highlighting the tab the
/// user came from while on Settings: the package has no "no selection"
/// state, and passing 5 would slide its highlight capsule off the
/// bar's right edge.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zorox/core/providers/device_info_provider.dart';
import 'package:zorox/core/router/app_router.dart';
import 'package:zorox/core/utils/motion.dart';
import 'package:zorox/features/settings/presentation/general_settings_provider.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';
import 'package:zorox/shared/widgets/app_scaffold.dart';
import 'package:zorox/shared/widgets/custom_bottom_nav.dart';

void main() {
  Future<GoRouter> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(720, 1568);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    Widget page(String label, Color color) => ColoredBox(
      color: color,
      child: Center(child: Text(label)),
    );

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        StatefulShellRoute(
          builder: (context, state, shell) =>
              AppScaffold(navigationShell: shell),
          navigatorContainerBuilder:
              AppShellRouteData.$navigatorContainerBuilder,
          branches: [
            for (final (path, label, color) in const [
              ('/home', 'home', Colors.red),
              ('/search', 'search', Colors.green),
              ('/extensions', 'extensions', Colors.blue),
              ('/library', 'library', Colors.orange),
              ('/browse', 'browse', Colors.purple),
              ('/settings', 'settings', Colors.teal),
            ])
              StatefulShellBranch(
                routes: [
                  GoRoute(path: path, builder: (_, _) => page(label, color)),
                ],
              ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProfileProvider.overrideWithValue(
            const AsyncValue.data(DeviceProfile(isTv: false, isTablet: false)),
          ),
          generalSettingsProvider.overrideWithValue(const GeneralSettings()),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  bool pillPresent(WidgetTester tester) =>
      find.byType(CustomBottomNavBar).evaluate().isNotEmpty;

  /// The pill's top / bottom edge on screen. On a tab the pill hugs the
  /// bottom edge; on Settings it is parked above the screen top
  /// (build 88) — mounted, but invisible.
  double pillTop(WidgetTester tester) =>
      tester.getTopLeft(find.byType(CustomBottomNavBar)).dy;

  double pillBottom(WidgetTester tester) {
    final topLeft = tester.getTopLeft(find.byType(CustomBottomNavBar));
    final size = tester.getSize(find.byType(CustomBottomNavBar));
    return topLeft.dy + size.height;
  }

  testWidgets(
    'pill is hidden on Settings but mounted, and back on-screen in the '
    'first frame of the return',
    (tester) async {
      final router = await pumpShell(tester);
      final screenHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(pillPresent(tester), isTrue, reason: 'pill on Home');
      expect(
        pillBottom(tester),
        lessThanOrEqualTo(screenHeight),
        reason: 'pill on screen on Home',
      );
      expect(
        pillTop(tester),
        greaterThan(0),
        reason: 'pill fully on screen on Home',
      );

      router.go('/settings');
      // One frame: the branch has flipped and the slide-in has started.
      await tester.pump();
      expect(
        pillPresent(tester),
        isTrue,
        reason: 'pill stays mounted through the Settings slide-in',
      );
      expect(
        pillBottom(tester),
        lessThanOrEqualTo(0),
        reason: 'pill parked fully above the screen top on Settings',
      );
      // Mid slide-in.
      await tester.pump(kMotionPage ~/ 2);
      expect(
        pillPresent(tester),
        isTrue,
        reason: 'pill stays mounted mid slide-in',
      );
      expect(
        pillBottom(tester),
        lessThanOrEqualTo(0),
        reason: 'pill stays parked mid slide-in',
      );
      await tester.pumpAndSettle();
      expect(
        pillBottom(tester),
        lessThanOrEqualTo(0),
        reason: 'pill parked on Settings',
      );

      router.go('/home');
      await tester.pump();
      expect(
        pillPresent(tester),
        isTrue,
        reason: 'pill stays mounted through the slide-out',
      );
      expect(
        pillBottom(tester),
        lessThanOrEqualTo(screenHeight),
        reason: 'pill back on screen in the first frame of the return',
      );
      expect(
        pillTop(tester),
        greaterThan(0),
        reason: 'pill fully on screen in the first frame of the return',
      );
      await tester.pumpAndSettle();
      expect(
        pillBottom(tester),
        lessThanOrEqualTo(screenHeight),
        reason: 'pill on Home',
      );
    },
  );

  testWidgets('pill keeps the last tab highlighted on Settings', (
    tester,
  ) async {
    final router = await pumpShell(tester);

    router.go('/search');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CustomBottomNavBar>(find.byType(CustomBottomNavBar))
          .currentIndex,
      1,
      reason: 'Search highlighted on Search',
    );

    router.go('/settings');
    await tester.pumpAndSettle();
    expect(pillPresent(tester), isTrue, reason: 'pill on Settings');
    expect(
      tester
          .widget<CustomBottomNavBar>(find.byType(CustomBottomNavBar))
          .currentIndex,
      1,
      reason:
          'still Search highlighted on Settings — the package has '
          'no "no selection" state, and 5 would slide its capsule off '
          'the bar',
    );

    router.go('/home');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CustomBottomNavBar>(find.byType(CustomBottomNavBar))
          .currentIndex,
      0,
      reason: 'Home highlighted again on Home',
    );
  });
}
