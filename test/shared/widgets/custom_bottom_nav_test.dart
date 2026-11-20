import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_bottom_nav/liquid_glass_bottom_nav.dart';
import 'package:reicons/reicons.dart';
import 'package:zorox/core/theme/theme_variant.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';
import 'package:zorox/shared/widgets/custom_bottom_nav.dart';

/// The v20 bar: the `liquid_glass_bottom_nav` package's floating glass pill
/// with the five Reicon icons — Filled, except Search which is Outline
/// (M M, 2026-11-14). The package renders its glass only
/// on Impeller; in the test environment the renderer falls back, but the
/// tabs, labels, selection colour and tap routing are all plain widgets and
/// are what this tests.
void main() {
  Future<void> pump(
    WidgetTester tester,
    Brightness brightness, {
    int currentIndex = 0,
    void Function(int)? onTap,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Stack(
          children: [
            const SizedBox.expand(),
            CustomBottomNavBar(
              currentIndex: currentIndex,
              onTap: onTap ?? (_) {},
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets('shows all five tabs with their labels', (tester) async {
    await pump(tester, Brightness.dark);
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Plugins'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Browse'), findsOneWidget);
  });

  testWidgets('shows the five Reicon icons', (tester) async {
    await pump(tester, Brightness.dark);
    await tester.pumpAndSettle();
    expect(find.byIcon(ReiconFilledIcons.home), findsOneWidget);
    // Search is Outline, not Filled (M M, 2026-11-14); the other four
    // stay Filled.
    expect(find.byIcon(ReiconIcons.search), findsOneWidget);
    expect(find.byIcon(ReiconFilledIcons.puzzle), findsOneWidget);
    expect(find.byIcon(ReiconFilledIcons.library), findsOneWidget);
    expect(find.byIcon(ReiconFilledIcons.grid), findsOneWidget);
  });

  testWidgets('tapping a tab reports its index', (tester) async {
    var tapped = -1;
    await pump(tester, Brightness.dark, onTap: (i) => tapped = i);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(tapped, 3);
  });

  testWidgets('the selected tab wears the theme accent on its dark bubble', (
    tester,
  ) async {
    await pump(tester, Brightness.dark, currentIndex: 2);
    await tester.pumpAndSettle();
    // Build 110 (user 2026-11-21 01:44): nav-follows-accent is back —
    // the selected tab takes colorScheme.primary (the user's accent)
    // on the package's dark bubble; build 109's white is gone.
    final accent = Theme.of(tester.element(find.byType(CustomBottomNavBar)))
        .colorScheme
        .primary;
    expect(
      tester.widget<Icon>(find.byIcon(ReiconFilledIcons.puzzle)).color,
      accent,
    );
    // ... and an unselected tab does not wear it.
    expect(
      tester.widget<Icon>(find.byIcon(ReiconFilledIcons.home)).color,
      isNot(accent),
    );
  });

  testWidgets('the legacy fallback renders the same tabs', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Stack(
            children: [
              const SizedBox.expand(),
              CustomBottomNavBar(
                currentIndex: 0,
                onTap: (_) {},
                impellerSupported: false,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Plugins'), findsOneWidget);
    expect(find.byIcon(ReiconFilledIcons.grid), findsOneWidget);
  });

  // v20+21: the pill must sit at the bottom edge on iOS. The package
  // positions its root Positioned at
  // MediaQuery.padding.bottom + insets, so with the shell's MediaQuery
  // override the pill's bottom must equal targetBottomGap even when the
  // real safe-area padding is 34 (iPhone home indicator).
  testWidgets('pill lands at the bottom edge on an iPhone-like safe area', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            padding: EdgeInsets.only(bottom: 34),
          ),
          child: Scaffold(
            body: Stack(
              children: [
                const SizedBox.expand(),
                Builder(
                  builder: (context) {
                    final mq = MediaQuery.of(context);
                    return MediaQuery(
                      data: mq.copyWith(
                        padding: mq.padding.copyWith(
                          bottom: CustomBottomNavBar.navPaddingBottom(context),
                        ),
                      ),
                      child: CustomBottomNavBar(currentIndex: 0, onTap: (_) {}),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The package's root Positioned: left/right are the side margins
    // (insets = 16, build 111) and bottom is the pill's gap from the
    // screen edge. The neutral rim is a second Positioned with the same
    // margins but a fixed height, so it is filtered out here.
    final positioned = tester
        .widgetList<Positioned>(find.byType(Positioned))
        .where((p) => p.left == 16.0 && p.right == 16.0 && p.height == null)
        .toList();
    expect(positioned, hasLength(1));
    expect(positioned.single.bottom, CustomBottomNavBar.targetBottomGap);
  });

  testWidgets('navPaddingBottom sets the pill to the target gap', (
    tester,
  ) async {
    double? seen34;
    double? seen0;
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            MediaQuery(
              data: const MediaQueryData(padding: EdgeInsets.only(bottom: 34)),
              child: Builder(
                builder: (context) {
                  seen34 = CustomBottomNavBar.navPaddingBottom(context);
                  return const SizedBox.shrink();
                },
              ),
            ),
            MediaQuery(
              data: const MediaQueryData(padding: EdgeInsets.zero),
              child: Builder(
                builder: (context) {
                  seen0 = CustomBottomNavBar.navPaddingBottom(context);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ],
        ),
      ),
    );
    // Build 109: the padding is exactly gap − insets (4 since build
    // 111, when insets went 8 → 16) — it lowers the pill on iOS (real
    // 34) and raises it on Android (real 0), so the pill lands 20 pt
    // up on both.
    expect(seen34, 4.0);
    expect(seen0, 4.0);
  });

  test('content clearance covers the pill top plus buffer', () {
    expect(CustomBottomNavBar.targetBottomGap, 20.0);
    // 20 (gap) + 63 (pill) + 12 (buffer).
    expect(CustomBottomNavBar.contentClearance, 95.0);
  });

  testWidgets('the pill is 63 pt tall', (tester) async {
    await pump(tester, Brightness.dark);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(LiquidGlassNavBar)).height, 63.0);
  });

  testWidgets('the pill is a 24 pt rounded rectangle, not a stadium', (
    tester,
  ) async {
    await pump(tester, Brightness.dark);
    await tester.pumpAndSettle();
    // Build 111 (user 2026-11-21 04:03: "thoda round corner pe"):
    // slightly round, the curve clearly visible at both ends, still
    // not a stadium. The package paints the selected bubble with this
    // same radius, so the two stay consistent.
    expect(
      tester
          .widget<LiquidGlassNavBar>(find.byType(LiquidGlassNavBar))
          .borderRadius,
      24.0,
    );
  });

  testWidgets('the fork glass pill renders in both dark and light mode', (
    tester,
  ) async {
    // v4: the pill is the fork's translucent frosted glass in both
    // brightnesses — never a solid bar, in dark mode or light. The
    // package renders its glass only on Impeller, but the widget itself
    // is in the tree either way; a theme-gated fallback would show up
    // here as its absence.
    for (final brightness in [Brightness.dark, Brightness.light]) {
      await pump(tester, brightness);
      await tester.pumpAndSettle();
      expect(
        find.byType(LiquidGlassNavBar),
        findsOneWidget,
        reason: 'glass pill under $brightness',
      );
    }
  });

  // Build 85: light Liquid Glass gets the package's clear (dark) glass.
  group('clear pill on light Liquid Glass', () {
    Future<void> pumpTheme(WidgetTester tester, ThemeData theme) =>
        tester.pumpWidget(
          MaterialApp(
            theme: theme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Stack(
                children: [
                  const SizedBox.expand(),
                  CustomBottomNavBar(currentIndex: 0, onTap: (_) {}),
                ],
              ),
            ),
          ),
        );

    ThemeData themed(Brightness brightness, {required bool glass}) => ThemeData(
      brightness: brightness,
      extensions: [ZoroxThemeExtension(isGlass: glass)],
    );

    Brightness barBrightness(WidgetTester tester) =>
        Theme.of(tester.element(find.byType(LiquidGlassNavBar))).brightness;

    testWidgets('light Liquid Glass: the bar is drawn as the dark glass, '
        'icons keep the light theme colours', (tester) async {
      final theme = themed(Brightness.light, glass: true);
      await pumpTheme(tester, theme);
      expect(tester.takeException(), isNull);
      expect(barBrightness(tester), Brightness.dark);
      final bar = tester.widget<LiquidGlassNavBar>(
        find.byType(LiquidGlassNavBar),
      );
      expect(bar.inactiveColor, theme.colorScheme.onSurfaceVariant);
      // Build 110 (user 2026-11-21 01:44): nav-follows-accent is back —
      // the selected tab wears the theme accent on the dark glass pill.
      expect(bar.activeColor, theme.colorScheme.primary);
      expect(bar.labelStyle?.shadows, isNotEmpty);
    });

    testWidgets('Frost (light) gets the clear glass too', (tester) async {
      // Build 109 (user 2026-11-21 00:46): Frost's pill was milky and
      // frosted; it now gets the same clear (dark) glass as light
      // Liquid Glass — pure liquid glass, not frosted.
      await pumpTheme(tester, themed(Brightness.light, glass: false));
      expect(barBrightness(tester), Brightness.dark);
      final bar = tester.widget<LiquidGlassNavBar>(
        find.byType(LiquidGlassNavBar),
      );
      expect(bar.labelStyle?.shadows, isNotEmpty);
    });

    testWidgets('dark Liquid Glass is untouched', (tester) async {
      await pumpTheme(tester, themed(Brightness.dark, glass: true));
      expect(barBrightness(tester), Brightness.dark);
      final bar = tester.widget<LiquidGlassNavBar>(
        find.byType(LiquidGlassNavBar),
      );
      expect(bar.inactiveColor, const Color(0xFF9D9A92));
      expect(bar.labelStyle?.shadows, isNull);
    });

    testWidgets('the pill sits in the same place on Frost and on light '
        'Liquid Glass', (tester) async {
      // Both light themes get the clear glass now (build 109); the
      // geometry must not move between them.
      await pumpTheme(tester, themed(Brightness.light, glass: false));
      final frost = tester.getRect(find.byType(LiquidGlassNavBar));
      await pumpTheme(tester, themed(Brightness.light, glass: true));
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byType(LiquidGlassNavBar)), frost);
    });
  });
}
