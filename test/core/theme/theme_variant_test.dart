/// The four named theme variants (Settings → General).
///
/// Liquid Glass is the fresh-install default (the approved design preview
/// wears the glass pill nav); Arena Gold is the theme the app shipped
/// before and stays selectable. Midnight takes the same structure to
/// near-black, Frost is the light theme. The accent still drives `primary`
/// in all four, and picking a variant applies it live (the theme mode
/// flips to match its brightness) and persists it.
///
/// These tests drive the real [StorageService] against a real Hive box in
/// a temp directory, so "nothing recorded yet" is the genuine state rather
/// than a fake's idea of it.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/core/theme/accent_color.dart';
import 'package:zorox/core/theme/app_theme.dart';
import 'package:zorox/core/theme/theme_provider.dart';
import 'package:zorox/core/theme/theme_variant.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the variants', () {
    test('are the five named in the spec, each with a label and a line', () {
      expect(ZoroxThemeVariant.values.length, 5);
      expect(
        ZoroxThemeVariant.values.map((v) => v.label).toList(),
        ['Arena Gold', 'Midnight', 'Frost', 'Liquid Glass', 'Obsidian'],
      );
      for (final variant in ZoroxThemeVariant.values) {
        expect(variant.label, isNotEmpty);
        expect(variant.detail, isNotEmpty);
      }
    });

    test('Frost is the only light one', () {
      expect(ZoroxThemeVariant.frost.isDark, isFalse);
      for (final variant in [
        ZoroxThemeVariant.arenaGold,
        ZoroxThemeVariant.midnight,
        ZoroxThemeVariant.liquidGlass,
        ZoroxThemeVariant.obsidian,
      ]) {
        expect(variant.isDark, isTrue, reason: variant.name);
      }
    });

    test('fromName round-trips every variant', () {
      for (final variant in ZoroxThemeVariant.values) {
        expect(ZoroxThemeVariant.fromName(variant.name), variant);
      }
    });

    test('fromName falls back to Liquid Glass for null or unknown', () {
      expect(ZoroxThemeVariant.fromName(null), ZoroxThemeVariant.liquidGlass);
      expect(
        ZoroxThemeVariant.fromName('sepia'),
        ZoroxThemeVariant.liquidGlass,
      );
    });
  });

  group('each variant produces a ThemeData', () {
    test('Arena Gold is the warm dark theme', () {
      final theme = AppTheme.createDarkTheme(
        null,
        variant: ZoroxThemeVariant.arenaGold,
      );
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0D0A07));
      expect(theme.cardTheme.color, const Color(0xFF1B150E));
      expect(theme.colorScheme.surface, const Color(0xFF1B150E));
      expect(theme.extension<ZoroxThemeExtension>()?.isGlass, isFalse);
    });

    test('the default build is Arena Gold', () {
      final theme = AppTheme.createDarkTheme(null);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0D0A07));
      expect(theme.extension<ZoroxThemeExtension>()?.isGlass, isFalse);
    });

    test('Midnight is purer black, same structure', () {
      final theme = AppTheme.createDarkTheme(
        null,
        variant: ZoroxThemeVariant.midnight,
      );
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF000000));
      expect(theme.cardTheme.color, const Color(0xFF0A0A0A));
      expect(theme.colorScheme.surface, const Color(0xFF0A0A0A));
      expect(
        theme.dialogTheme.backgroundColor,
        const Color(0xFF0A0A0A),
      );
      expect(
        theme.bottomSheetTheme.backgroundColor,
        const Color(0xFF0A0A0A),
      );
      expect(theme.appBarTheme.backgroundColor, const Color(0xFF000000));
      expect(theme.extension<ZoroxThemeExtension>()?.isGlass, isFalse);
      // Gold accent kept: the same seed produces the same primary as
      // Arena Gold — only the surfaces moved.
      final arenaGold = AppTheme.createDarkTheme(
        null,
        variant: ZoroxThemeVariant.arenaGold,
      );
      expect(theme.colorScheme.primary, arenaGold.colorScheme.primary);
    });

    test('Liquid Glass is dark, cool teal-green, and marked glass', () {
      final theme = AppTheme.createDarkTheme(
        null,
        variant: ZoroxThemeVariant.liquidGlass,
      );
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF081210));
      expect(theme.cardTheme.color, const Color(0xFF122019));
      expect(theme.colorScheme.surface, const Color(0xFF122019));
      expect(theme.extension<ZoroxThemeExtension>()?.isGlass, isTrue);
      // Gold accent kept: the same seed produces the same primary as
      // Arena Gold — only the surfaces moved.
      final arenaGold = AppTheme.createDarkTheme(
        null,
        variant: ZoroxThemeVariant.arenaGold,
      );
      expect(theme.colorScheme.primary, arenaGold.colorScheme.primary);
    });

    test('a dark theme asked for Frost falls back to Arena Gold', () {
      final theme = AppTheme.createDarkTheme(
        null,
        variant: ZoroxThemeVariant.frost,
      );
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0D0A07));
      expect(theme.extension<ZoroxThemeExtension>()?.isGlass, isFalse);
    });

    test('Frost is the existing light theme', () {
      final theme = AppTheme.createLightTheme(
        null,
        variant: ZoroxThemeVariant.frost,
      );
      expect(theme.brightness, Brightness.light);
      expect(theme.scaffoldBackgroundColor, AppTheme.lightBackground);
      expect(theme.extension<ZoroxThemeExtension>()?.isGlass, isFalse);
    });

    test('the default light build is Frost too', () {
      final theme = AppTheme.createLightTheme(null);
      expect(theme.brightness, Brightness.light);
      expect(theme.scaffoldBackgroundColor, AppTheme.lightBackground);
    });

    test('Liquid Glass keeps the glass flag on a light system', () {
      final theme = AppTheme.createLightTheme(
        null,
        variant: ZoroxThemeVariant.liquidGlass,
      );
      expect(theme.brightness, Brightness.light);
      expect(
        theme.scaffoldBackgroundColor,
        AppTheme.liquidGlassLightBackground,
      );
      expect(theme.extension<ZoroxThemeExtension>()?.isGlass, isTrue);
    });
  });

  group('the 8+2 accents keep working across all four variants', () {
    test('every accent builds a dark theme in each dark variant', () {
      for (final accent in ZoroxAccent.values) {
        for (final variant in [
          ZoroxThemeVariant.arenaGold,
          ZoroxThemeVariant.midnight,
          ZoroxThemeVariant.liquidGlass,
        ]) {
          final theme = AppTheme.createDarkTheme(
            null,
            seedColor: accent.color,
            variant: variant,
          );
          expect(theme.brightness, Brightness.dark, reason: variant.name);
        }
      }
    });

    test('every accent drives primary in the light theme', () {
      for (final accent in ZoroxAccent.values) {
        final theme = AppTheme.createLightTheme(
          null,
          accent: accent.color,
          variant: ZoroxThemeVariant.frost,
        );
        expect(
          theme.colorScheme.primary,
          accent.color,
          reason: '${accent.name} should drive Frost primary',
        );
      }
    });

    test('the lightest preset pins primary in the dark variants', () {
      // Silver is achromatic: fromSeed would collapse it onto the same
      // light blue as Blue (0xFF9ECAFC vs 0xFF9DCBFB), so the pin makes
      // the app actually silver. (White / Black retired in v3, 2.9.19+59;
      // the pin covers any near-achromatic seed.)
      for (final variant in [
        ZoroxThemeVariant.arenaGold,
        ZoroxThemeVariant.midnight,
        ZoroxThemeVariant.liquidGlass,
      ]) {
        final theme = AppTheme.createDarkTheme(
          null,
          seedColor: ZoroxAccent.silver.color,
          variant: variant,
        );
        expect(
          theme.colorScheme.primary,
          ZoroxAccent.silver.color,
          reason: 'silver on ${variant.name}',
        );
      }
    });

    test('the darkest preset still recolors in the dark variants', () {
      // Violet is chromatic, so it keeps the tonal primary (a light
      // lavender, not the seed) — but it must be its own colour, not
      // the neutral ramp's: the failure this guards is the extremes
      // collapsing onto one another.
      for (final variant in [
        ZoroxThemeVariant.arenaGold,
        ZoroxThemeVariant.midnight,
        ZoroxThemeVariant.liquidGlass,
      ]) {
        final theme = AppTheme.createDarkTheme(
          null,
          seedColor: ZoroxAccent.violet.color,
          variant: variant,
        );
        final primary = theme.colorScheme.primary;
        for (final other in ZoroxAccent.values.where(
          (a) => a != ZoroxAccent.violet,
        )) {
          final otherTheme = AppTheme.createDarkTheme(
            null,
            seedColor: other.color,
            variant: variant,
          );
          expect(
            primary,
            isNot(otherTheme.colorScheme.primary),
            reason: 'violet vs ${other.name} on ${variant.name}',
          );
        }
      }
    });
  });

  group('contrast', () {
    /// sRGB relative luminance, WCAG 2.x definition — the same helper
    /// shape as the theme contrast tests, kept local so this file stands
    /// alone.
    double luminance(Color c) {
      double channel(double v) => v <= 0.03928
          ? v / 12.92
          : math.pow((v + 0.055) / 1.055, 2.4) as double;
      return 0.2126 * channel(c.r) +
          0.7152 * channel(c.g) +
          0.0722 * channel(c.b);
    }

    double contrast(Color fg, Color bg) {
      final a = luminance(fg);
      final b = luminance(bg);
      final hi = math.max(a, b);
      final lo = math.min(a, b);
      return (hi + 0.05) / (lo + 0.05);
    }

    test('Midnight and Liquid Glass bodySmall clear AA on the scaffold', () {
      for (final variant in [
        ZoroxThemeVariant.midnight,
        ZoroxThemeVariant.liquidGlass,
      ]) {
        final theme = AppTheme.createDarkTheme(null, variant: variant);
        final style = theme.textTheme.bodySmall!;
        expect(
          contrast(style.color!, theme.scaffoldBackgroundColor),
          greaterThanOrEqualTo(4.5),
          reason: '${variant.name} bodySmall on its scaffold',
        );
      }
    });

    test('every variant is fully opaque in both dark and light (v4)', () {
      // The Liquid Glass ghosting the user reported — Settings rows over
      // the Home hero — came from translucent layers during navigation;
      // the themes themselves must never be one. Every scaffold and
      // surface is fully opaque, so at rest nothing can show through
      // another screen, on any variant in either brightness.
      for (final variant in ZoroxThemeVariant.values) {
        for (final theme in [
          AppTheme.createDarkTheme(null, variant: variant),
          AppTheme.createLightTheme(null, variant: variant),
        ]) {
          expect(
            theme.scaffoldBackgroundColor.a,
            1.0,
            reason: '${variant.name} ${theme.brightness} scaffold',
          );
          expect(
            theme.colorScheme.surface.a,
            1.0,
            reason: '${variant.name} ${theme.brightness} surface',
          );
          final cardColor = theme.cardTheme.color;
          if (cardColor != null) {
            expect(
              cardColor.a,
              1.0,
              reason: '${variant.name} ${theme.brightness} card',
            );
          }
        }
      }
    });
  });

  group('persistence and live switching', () {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();

    late Directory dir;
    late StorageService storage;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('theme_variant');
      // StorageService.init() asks path_provider where to put its boxes.
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => dir.path,
      );
      storage = StorageService();
      await storage.init();
    });

    tearDown(() async {
      await Hive.close();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    ProviderContainer boot() {
      final container = ProviderContainer(
        overrides: [storageServiceProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('nothing chosen yet comes up Liquid Glass', () {
      expect(storage.getThemeVariant(), isNull, reason: 'nothing recorded yet');

      expect(boot().read(themeVariantProvider), ZoroxThemeVariant.liquidGlass);
    });

    test('every variant round-trips through storage', () async {
      for (final variant in ZoroxThemeVariant.values) {
        await storage.saveThemeVariant(variant.name);

        expect(
          boot().read(themeVariantProvider),
          variant,
          reason: '${variant.name} should survive a restart',
        );
      }
    });

    test('a value no release ever wrote falls back to Liquid Glass', () async {
      await storage.saveThemeVariant('sepia');

      expect(boot().read(themeVariantProvider), ZoroxThemeVariant.liquidGlass);
    });

    test('choosing a variant records it and applies it live', () async {
      final container = boot();
      expect(
        container.read(themeVariantProvider),
        ZoroxThemeVariant.liquidGlass,
      );

      await container
          .read(themeVariantProvider.notifier)
          .setVariant(ZoroxThemeVariant.midnight);

      expect(container.read(themeVariantProvider), ZoroxThemeVariant.midnight);
      expect(storage.getThemeVariant(), 'midnight');
    });

    test('picking Frost flips the mode to light', () async {
      final container = boot();
      expect(container.read(appThemeModeProvider), ThemeMode.dark);

      await container
          .read(themeVariantProvider.notifier)
          .setVariant(ZoroxThemeVariant.frost);

      expect(container.read(themeVariantProvider), ZoroxThemeVariant.frost);
      expect(container.read(appThemeModeProvider), ThemeMode.light);
    });

    test('picking a dark variant flips the mode to dark', () async {
      final container = boot();
      await container
          .read(themeVariantProvider.notifier)
          .setVariant(ZoroxThemeVariant.frost);
      expect(container.read(appThemeModeProvider), ThemeMode.light);

      await container
          .read(themeVariantProvider.notifier)
          .setVariant(ZoroxThemeVariant.midnight);

      expect(container.read(themeVariantProvider), ZoroxThemeVariant.midnight);
      expect(container.read(appThemeModeProvider), ThemeMode.dark);
    });

    test('the Dark Mode toggle off goes to Frost, on returns to the last dark variant',
        () async {
      final container = boot();
      await container
          .read(themeVariantProvider.notifier)
          .setVariant(ZoroxThemeVariant.midnight);
      expect(container.read(appThemeModeProvider), ThemeMode.dark);

      await container.read(themeVariantProvider.notifier).setDarkMode(false);

      expect(container.read(themeVariantProvider), ZoroxThemeVariant.frost);
      expect(container.read(appThemeModeProvider), ThemeMode.light);

      await container.read(themeVariantProvider.notifier).setDarkMode(true);

      expect(container.read(themeVariantProvider), ZoroxThemeVariant.midnight);
      expect(container.read(appThemeModeProvider), ThemeMode.dark);
    });

    test('the toggle on from Frost with no dark variant remembered returns to Liquid Glass',
        () async {
      final container = boot();
      await container
          .read(themeVariantProvider.notifier)
          .setVariant(ZoroxThemeVariant.frost);
      expect(
        storage.getLastDarkThemeVariant(),
        isNull,
        reason: 'Frost is not a dark variant, so nothing is remembered',
      );

      await container.read(themeVariantProvider.notifier).setDarkMode(true);

      expect(
        container.read(themeVariantProvider),
        ZoroxThemeVariant.liquidGlass,
      );
      expect(container.read(appThemeModeProvider), ThemeMode.dark);
    });

    test('picking a dark variant remembers it for the toggle', () async {
      final container = boot();
      await container
          .read(themeVariantProvider.notifier)
          .setVariant(ZoroxThemeVariant.arenaGold);
      expect(storage.getLastDarkThemeVariant(), 'arenaGold');

      await container.read(themeVariantProvider.notifier).setDarkMode(false);
      await container.read(themeVariantProvider.notifier).setDarkMode(true);

      expect(container.read(themeVariantProvider), ZoroxThemeVariant.arenaGold);
    });

    test('the toggle is a no-op when already on its side', () async {
      final container = boot();
      // A fresh install is Liquid Glass / dark.
      await container.read(themeVariantProvider.notifier).setDarkMode(true);
      expect(
        container.read(themeVariantProvider),
        ZoroxThemeVariant.liquidGlass,
      );

      await container
          .read(themeVariantProvider.notifier)
          .setVariant(ZoroxThemeVariant.frost);
      await container.read(themeVariantProvider.notifier).setDarkMode(false);
      expect(container.read(themeVariantProvider), ZoroxThemeVariant.frost);
    });

    group('Liquid Glass with Dark Mode on and off (build 83)', () {
      Future<void> pick(ProviderContainer c, ZoroxThemeVariant v) =>
          c.read(themeVariantProvider.notifier).setVariant(v);
      Future<void> dark(ProviderContainer c, bool on) =>
          c.read(themeVariantProvider.notifier).setDarkMode(on);

      test('Dark Mode off on Liquid Glass stays Liquid Glass, light',
          () async {
        final c = boot();
        expect(c.read(themeVariantProvider), ZoroxThemeVariant.liquidGlass);
        await dark(c, false);
        expect(c.read(themeVariantProvider), ZoroxThemeVariant.liquidGlass);
        expect(c.read(appThemeModeProvider), ThemeMode.light);
        expect(storage.getThemeVariant() ?? 'liquidGlass', 'liquidGlass');
        expect(storage.getThemeMode(), 'light');

        await dark(c, true);
        expect(c.read(themeVariantProvider), ZoroxThemeVariant.liquidGlass);
        expect(c.read(appThemeModeProvider), ThemeMode.dark);
      });

      test('picking Liquid Glass from Frost keeps Dark Mode off', () async {
        final c = boot();
        await pick(c, ZoroxThemeVariant.frost);
        await pick(c, ZoroxThemeVariant.liquidGlass);
        expect(c.read(themeVariantProvider), ZoroxThemeVariant.liquidGlass);
        expect(c.read(appThemeModeProvider), ThemeMode.light);
      });

      test('picking Liquid Glass from a dark variant keeps Dark Mode on',
          () async {
        final c = boot();
        await pick(c, ZoroxThemeVariant.midnight);
        await pick(c, ZoroxThemeVariant.liquidGlass);
        expect(c.read(appThemeModeProvider), ThemeMode.dark);
      });

      test('his recording: Frost, Liquid Glass, Dark Mode on then off',
          () async {
        final c = boot();
        await pick(c, ZoroxThemeVariant.frost);
        await pick(c, ZoroxThemeVariant.liquidGlass);
        await dark(c, true);
        expect(c.read(appThemeModeProvider), ThemeMode.dark);
        await dark(c, false);
        expect(
          c.read(themeVariantProvider),
          ZoroxThemeVariant.liquidGlass,
          reason: 'used to jump back to Frost',
        );
        expect(c.read(appThemeModeProvider), ThemeMode.light);
      });

      test('the full matrix: what each variant does with the switch',
          () async {
        // variant -> (after Dark Mode off, after Dark Mode on again)
        const expected = {
          ZoroxThemeVariant.arenaGold: [
            ZoroxThemeVariant.frost,
            ZoroxThemeVariant.arenaGold,
          ],
          ZoroxThemeVariant.midnight: [
            ZoroxThemeVariant.frost,
            ZoroxThemeVariant.midnight,
          ],
          ZoroxThemeVariant.liquidGlass: [
            ZoroxThemeVariant.liquidGlass,
            ZoroxThemeVariant.liquidGlass,
          ],
        };
        for (final entry in expected.entries) {
          final c = boot();
          await pick(c, entry.key);
          await dark(c, true);
          expect(c.read(appThemeModeProvider), ThemeMode.dark);
          await dark(c, false);
          expect(c.read(themeVariantProvider), entry.value[0]);
          expect(c.read(appThemeModeProvider), ThemeMode.light);
          await dark(c, true);
          expect(c.read(themeVariantProvider), entry.value[1]);
          expect(c.read(appThemeModeProvider), ThemeMode.dark);
        }
      });

      test('light Liquid Glass after Frost: Dark Mode on stays Liquid Glass',
          () async {
        final c = boot();
        await pick(c, ZoroxThemeVariant.midnight);
        await pick(c, ZoroxThemeVariant.frost);
        await pick(c, ZoroxThemeVariant.liquidGlass);
        await dark(c, true);
        expect(c.read(themeVariantProvider), ZoroxThemeVariant.liquidGlass);
        expect(c.read(appThemeModeProvider), ThemeMode.dark);
      });

      test('an existing user keeps what he had after the update', () async {
        for (final saved in [
          ['liquidGlass', 'dark'],
          ['arenaGold', 'dark'],
          ['midnight', 'dark'],
          ['frost', 'light'],
        ]) {
          await storage.saveThemeVariant(saved[0]);
          await storage.saveThemeMode(saved[1]);
          final c = boot();
          expect(c.read(themeVariantProvider).name, saved[0]);
          expect(c.read(appThemeModeProvider).name, saved[1]);
        }
      });

      test('the dark look is untouched and the light look is its own', () {
        final darkTheme = AppTheme.createDarkTheme(
          null,
          variant: ZoroxThemeVariant.liquidGlass,
        );
        expect(darkTheme.scaffoldBackgroundColor, const Color(0xFF081210));
        expect(darkTheme.colorScheme.surface, const Color(0xFF122019));

        final light = AppTheme.createLightTheme(
          null,
          variant: ZoroxThemeVariant.liquidGlass,
        );
        final frost = AppTheme.createLightTheme(
          null,
          variant: ZoroxThemeVariant.frost,
        );
        expect(light.brightness, Brightness.light);
        expect(light.scaffoldBackgroundColor, const Color(0xFFEEF1F6));
        expect(frost.scaffoldBackgroundColor, AppTheme.lightBackground);
        for (final v in [
          ZoroxThemeVariant.arenaGold,
          ZoroxThemeVariant.midnight,
        ]) {
          expect(
            AppTheme.createLightTheme(null, variant: v).colorScheme,
            frost.colorScheme,
          );
        }
      });

      test('light Liquid Glass text is readable on every surface', () {
        final cs = AppTheme.createLightTheme(
          null,
          variant: ZoroxThemeVariant.liquidGlass,
        ).colorScheme;
        double lum(Color c) => c.computeLuminance();
        double ratio(Color a, Color b) {
          final hi = lum(a) > lum(b) ? lum(a) : lum(b);
          final lo = lum(a) > lum(b) ? lum(b) : lum(a);
          return (hi + 0.05) / (lo + 0.05);
        }

        for (final surface in [
          cs.surface,
          cs.surfaceContainerLowest,
          cs.surfaceContainerLow,
          cs.surfaceContainer,
          cs.surfaceContainerHigh,
          cs.surfaceContainerHighest,
        ]) {
          expect(ratio(cs.onSurface, surface), greaterThan(7.0));
          expect(ratio(cs.onSurfaceVariant, surface), greaterThan(4.5));
          expect(surface.a, 1.0);
        }
      });
    });
  });
}
