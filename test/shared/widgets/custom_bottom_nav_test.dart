import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_bottom_nav/liquid_glass_bottom_nav.dart';
import 'package:reicons/reicons.dart';
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
  }) =>
      tester.pumpWidget(
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

  testWidgets('the selected tab wears the gold accent', (tester) async {
    await pump(tester, Brightness.dark, currentIndex: 2);
    await tester.pumpAndSettle();
    final element = tester.element(find.byType(CustomBottomNavBar));
    final primary = Theme.of(element).colorScheme.primary;
    // The package tints the selected tab's icon with the active colour,
    // which the bar sets to the theme primary (gold).
    expect(
      tester.widget<Icon>(find.byIcon(ReiconFilledIcons.puzzle)).color,
      primary,
    );
    // ... and an unselected tab does not wear it.
    expect(
      tester.widget<Icon>(find.byIcon(ReiconFilledIcons.home)).color,
      isNot(primary),
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
  testWidgets('pill lands at the bottom edge on an iPhone-like safe area',
      (tester) async {
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
                          bottom: CustomBottomNavBar.navPaddingBottom(
                            context,
                          ),
                        ),
                      ),
                      child: CustomBottomNavBar(
                        currentIndex: 0,
                        onTap: (_) {},
                      ),
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
    // (insets = 8) and bottom is the pill's gap from the screen edge.
    // v5: two of them — the frost layer behind the pill and the package's
    // pill itself — on exactly the same rect.
    final positioned = tester
        .widgetList<Positioned>(find.byType(Positioned))
        .where((p) => p.left == 8.0 && p.right == 8.0)
        .toList();
    expect(positioned, hasLength(2));
    for (final p in positioned) {
      expect(p.bottom, CustomBottomNavBar.targetBottomGap);
    }
    expect(
      tester.getRect(find.byKey(CustomBottomNavBar.frostKey)),
      // The test surface is 800x600 (the MediaQuery above only feeds
      // the padding): 8 from each side and the bottom, 68 tall.
      const Rect.fromLTRB(8, 600 - 8 - 68, 800 - 8, 600 - 8),
    );
  });

  testWidgets('navPaddingBottom only ever lowers the pill', (tester) async {
    double? seen34;
    double? seen0;
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            MediaQuery(
              data: const MediaQueryData(
                padding: EdgeInsets.only(bottom: 34),
              ),
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
    expect(seen34, 0.0);
    expect(seen0, 0.0);
  });

  test('content clearance covers the pill top plus buffer', () {
    expect(CustomBottomNavBar.targetBottomGap, 8.0);
    // 8 (gap) + 68 (pill) + 12 (buffer).
    expect(CustomBottomNavBar.contentClearance, 88.0);
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

  // v5: list text scrolling under the pill was readable through it (the
  // package's own blur is sigma 1). A frost layer directly behind the pill
  // blurs it away — translucent, never a solid slab.
  testWidgets('the pill frosts what is under it, in dark and light', (
    tester,
  ) async {
    expect(CustomBottomNavBar.frostSigma, 24.0);
    for (final brightness in [Brightness.dark, Brightness.light]) {
      await pump(tester, brightness);
      await tester.pumpAndSettle();
      final frost = find.byKey(CustomBottomNavBar.frostKey);
      expect(frost, findsOneWidget, reason: 'frost under $brightness');
      final filter = tester.widget<BackdropFilter>(frost).filter;
      expect(
        filter.toString(),
        ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24).toString(),
      );
      // Clipped to the pill, so the blur never spills past it.
      expect(
        find.ancestor(of: frost, matching: find.byType(ClipPath)),
        findsWidgets,
      );
      // The tint is translucent and adapts to the brightness.
      final tint = tester
          .widget<ColoredBox>(
            find.descendant(of: frost, matching: find.byType(ColoredBox)),
          )
          .color;
      expect(
        tint,
        brightness == Brightness.dark
            ? CustomBottomNavBar.frostTintDark
            : CustomBottomNavBar.frostTintLight,
      );
      expect(tint.a, greaterThan(0.1));
      expect(tint.a, lessThan(0.5));
      // No fully opaque backing anywhere in the bar.
      for (final box in tester.widgetList<ColoredBox>(
        find.descendant(
          of: find.byType(CustomBottomNavBar),
          matching: find.byType(ColoredBox),
        ),
      )) {
        expect(box.color.a, lessThan(1.0));
      }
      for (final box in tester.widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(CustomBottomNavBar),
          matching: find.byType(DecoratedBox),
        ),
      )) {
        final decoration = box.decoration;
        if (decoration is BoxDecoration && decoration.color != null) {
          expect(decoration.color!.a, lessThan(1.0));
        }
      }
      // The package's glass pill is still there, on top of the frost.
      expect(find.byType(LiquidGlassNavBar), findsOneWidget);
    }
    expect(CustomBottomNavBar.frostTintDark.a, closeTo(0.40, 0.01));
    expect(CustomBottomNavBar.frostTintLight.a, closeTo(0.20, 0.01));
  });

  testWidgets('the nav Positioned stays a direct child of a Stack', (
    tester,
  ) async {
    await pump(tester, Brightness.dark);
    await tester.pumpAndSettle();
    // A Transform/Padding between a Stack and its Positioned throws
    // "Incorrect use of ParentDataWidget" (the +15..+19 freeze).
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(CustomBottomNavBar),
        matching: find.byType(LiquidGlassNavBar),
      ),
      findsOneWidget,
    );
    Element parentRenderObjectElement(Element e) {
      late Element found;
      e.visitAncestorElements((a) {
        if (a is RenderObjectElement) {
          found = a;
          return false;
        }
        return true;
      });
      return found;
    }

    for (final p in tester.elementList(
      find.descendant(
        of: find.byType(CustomBottomNavBar),
        matching: find.byWidgetPredicate(
          (w) => w is Positioned && w.left == 8.0 && w.right == 8.0,
        ),
      ),
    )) {
      expect(parentRenderObjectElement(p).widget, isA<Stack>());
    }
    expect(
      parentRenderObjectElement(
        tester.element(find.byType(CustomBottomNavBar)),
      ).widget,
      isA<Stack>(),
    );
  });

  testWidgets('the legacy fallback gets no frost layer', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
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
    expect(find.byKey(CustomBottomNavBar.frostKey), findsNothing);
  });
}
