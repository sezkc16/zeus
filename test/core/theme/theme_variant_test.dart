/// The four named theme variants (Settings → General).
///
/// Arena Gold is the theme the app has always shipped — the default.
/// Midnight takes the same structure to near-black, Frost is the light
/// theme, Liquid Glass is dark with a glass treatment. The accent still
/// drives `primary` in all four, and picking a variant applies it live
/// (the theme mode flips to match its brightness) and persists it.
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
    test('are the four named in the spec, each with a label and a line', () {
      expect(ZoroxThemeVariant.values.length, 4);
      expect(
        ZoroxThemeVariant.values.map((v) => v.label).toList(),
        ['Arena Gold', 'Midnight', 'Frost', 'Liquid Glass'],
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
      ]) {
        expect(variant.isDark, isTrue, reason: variant.name);
      }
    });

    test('fromName round-trips every variant', () {
      for (final variant in ZoroxThemeVariant.values) {
        expect(ZoroxThemeVariant.fromName(variant.name), variant);
      }
    });

    test('fromName falls back to Arena Gold for null or unknown', () {
      expect(ZoroxThemeVariant.fromName(null), ZoroxThemeVariant.arenaGold);
      expect(
        ZoroxThemeVariant.fromName('sepia'),
        ZoroxThemeVariant.arenaGold,
      );
    });
  });

  group('each variant produces a ThemeData', () {
    test('Arena Gold is the dark theme that shipped before', () {
      final theme = AppTheme.createDarkTheme(
        null,
        variant: ZoroxThemeVariant.arenaGold,
      );
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0A0A0B));
      expect(theme.cardTheme.color, const Color(0xFF161618));
      expect(theme.colorScheme.surface, const Color(0xFF161618));
      expect(theme.extension<ZoroxThemeExtension>()?.isGlass, isFalse);
    });

    test('the default build is Arena Gold', () {
      final theme = AppTheme.createDarkTheme(null);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0A0A0B));
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

    test('Liquid Glass is dark, cooler, and marked glass', () {
      final theme = AppTheme.createDarkTheme(
        null,
        variant: ZoroxThemeVariant.liquidGlass,
      );
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0B0D12));
      expect(theme.cardTheme.color, const Color(0xFF15181F));
      expect(theme.colorScheme.surface, const Color(0xFF15181F));
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
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0A0A0B));
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
      expect(theme.scaffoldBackgroundColor, AppTheme.lightBackground);
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

    test('the monochrome pair still pins primary in the dark variants', () {
      for (final variant in [
        ZoroxThemeVariant.arenaGold,
        ZoroxThemeVariant.midnight,
        ZoroxThemeVariant.liquidGlass,
      ]) {
        for (final accent in [ZoroxAccent.white, ZoroxAccent.black]) {
          final theme = AppTheme.createDarkTheme(
            null,
            seedColor: accent.color,
            variant: variant,
          );
          expect(
            theme.colorScheme.primary,
            accent.color,
            reason: '${accent.name} on ${variant.name}',
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

    test('nothing chosen yet comes up Arena Gold', () {
      expect(storage.getThemeVariant(), isNull, reason: 'nothing recorded yet');

      expect(boot().read(themeVariantProvider), ZoroxThemeVariant.arenaGold);
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

    test('a value no release ever wrote falls back to Arena Gold', () async {
      await storage.saveThemeVariant('sepia');

      expect(boot().read(themeVariantProvider), ZoroxThemeVariant.arenaGold);
    });

    test('choosing a variant records it and applies it live', () async {
      final container = boot();
      expect(container.read(themeVariantProvider), ZoroxThemeVariant.arenaGold);

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
          .setVariant(ZoroxThemeVariant.liquidGlass);

      expect(
        container.read(themeVariantProvider),
        ZoroxThemeVariant.liquidGlass,
      );
      expect(container.read(appThemeModeProvider), ThemeMode.dark);
    });
  });
}
