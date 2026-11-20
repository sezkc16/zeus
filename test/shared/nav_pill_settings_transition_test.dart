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
///
/// Build 89: the park is ANIMATED. Build 88 flipped the padding in one
/// build, so the pill popped in/out with a jerk ("jhatak se") while the
/// page slid for 360 ms (user 2026-11-19). The padding now tweens over
/// kMotionPage with kMotionPageCurve — the Settings slide's own timing
/// — so the pill glides with the page: still hidden on settled
/// Settings, still back with no seconds-long gap, never a single-frame
/// jump in either direction.
///
/// Build 90: the glide goes DOWN, not up. Build 88/89 parked the pill
/// above the screen top (a screen-tall padding), so it slid up out of
/// view and down on the return; the user asked (2026-11-19, "upar
/// janese accha neeche jaye") for the natural bottom-bar direction.
/// Now the pill parks BELOW the bottom edge (a negative padding, see
/// hiddenNavPaddingBottom): it sinks down out of view as Settings
/// slides in and rises up from below as it slides out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_bottom_nav/liquid_glass_bottom_nav.dart';
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
  /// bottom edge; on Settings it is parked below the screen bottom
  /// (build 90) — mounted, but invisible.
  ///
  /// Measured on the package bar itself, not on [CustomBottomNavBar]:
  /// build 102 wraps the bar in a full-screen treatment Stack (gold glow
  /// + metallic rim), so the wrapper's box is the whole screen and says
  /// nothing about where the pill sits.
  double pillTop(WidgetTester tester) =>
      tester.getTopLeft(find.byType(LiquidGlassNavBar)).dy;

  double pillBottom(WidgetTester tester) {
    final topLeft = tester.getTopLeft(find.byType(LiquidGlassNavBar));
    final size = tester.getSize(find.byType(LiquidGlassNavBar));
    return topLeft.dy + size.height;
  }

  /// The pill's bottom edge after pumping [duration].
  Future<double> pumpAndBottom(WidgetTester tester, Duration duration) async {
    await tester.pump(duration);
    return pillBottom(tester);
  }

  /// The pill's top edge after pumping [duration].
  Future<double> pumpAndTop(WidgetTester tester, Duration duration) async {
    await tester.pump(duration);
    return pillTop(tester);
  }

  testWidgets('pill glides down out of view on Settings and up on return — '
      'mounted throughout, no single-frame jump (build 90)', (tester) async {
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
    final homeBottom = pillBottom(tester);

    router.go('/settings');
    // One frame: the branch has flipped and the slide-in has started,
    // but the pill's 360 ms glide has not moved yet — it must NOT pop
    // off-screen in a single frame (build 88 did exactly that: the
    // padding flipped in one build while the page slid for 360 ms).
    await tester.pump();
    expect(
      pillPresent(tester),
      isTrue,
      reason: 'pill stays mounted through the Settings slide-in',
    );
    expect(
      pillBottom(tester),
      closeTo(homeBottom, 1.0),
      reason: 'pill has not jumped on the first frame of the slide-in',
    );
    // Mid glide: sinking DOWN, bottom edge strictly increasing past
    // the screen bottom — one motion with the page, not a pop at
    // either end, and the wrong way (up, build 88/89) is ruled out
    // by the direction of the increase.
    final sink1 = await pumpAndBottom(tester, kMotionPage ~/ 4);
    final sink2 = await pumpAndBottom(tester, kMotionPage ~/ 4);
    final sink3 = await pumpAndBottom(tester, kMotionPage ~/ 4);
    expect(sink1, greaterThan(homeBottom), reason: 'pill gliding down');
    expect(sink2, greaterThan(sink1), reason: 'pill still gliding down');
    expect(sink3, greaterThan(sink2), reason: 'pill still gliding down');
    expect(
      sink3,
      greaterThan(screenHeight),
      reason: 'pill below the bottom edge by three quarters of the glide',
    );
    await tester.pumpAndSettle();
    expect(
      pillTop(tester),
      greaterThanOrEqualTo(screenHeight),
      reason: 'pill parked below the screen bottom on Settings',
    );
    final parkedTop = pillTop(tester);

    router.go('/home');
    await tester.pump();
    expect(
      pillPresent(tester),
      isTrue,
      reason: 'pill stays mounted through the slide-out',
    );
    expect(
      pillTop(tester),
      greaterThanOrEqualTo(screenHeight),
      reason: 'pill still parked below on the first frame of the return',
    );
    final rise1 = await pumpAndTop(tester, kMotionPage ~/ 4);
    final rise2 = await pumpAndTop(tester, kMotionPage ~/ 4);
    final rise3 = await pumpAndTop(tester, kMotionPage ~/ 4);
    // easeInOutCubic starts slowly, so at a quarter of the glide the
    // pill is still just below the edge — the glide is proven by the
    // steady rise, not by an early crossing.
    expect(rise1, lessThan(parkedTop), reason: 'pill gliding back up');
    expect(rise2, lessThan(rise1), reason: 'pill still gliding up');
    expect(rise3, lessThan(rise2), reason: 'pill still gliding up');
    expect(
      pillBottom(tester),
      lessThanOrEqualTo(screenHeight),
      reason: 'pill back on screen by three quarters of the glide',
    );
    await tester.pumpAndSettle();
    expect(
      pillBottom(tester),
      lessThanOrEqualTo(screenHeight),
      reason: 'pill on Home',
    );
    expect(
      pillTop(tester),
      greaterThan(0),
      reason: 'pill fully on screen on Home',
    );
  });

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
