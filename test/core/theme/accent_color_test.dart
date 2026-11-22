/// Which accent the app comes up in when the user has never chosen one.
///
/// Green is the default (user 2026-11-17: fresh installs open green).
/// An explicit choice in Settings > Accent color is honoured and
/// persisted across restarts; a value no release ever wrote (storage
/// outlives downgrades and hand-editing) falls back to Green, the same
/// as nothing recorded.
///
/// These tests drive the real [StorageService] against a real Hive box in
/// a temp directory, so "nothing recorded yet" is the genuine state rather
/// than a fake's idea of it.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/core/theme/accent_color.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late StorageService storage;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('accent_color');
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

  group('nothing chosen yet', () {
    test('comes up Green', () {
      expect(storage.getAccentColor(), isNull, reason: 'nothing recorded yet');

      expect(boot().read(accentColorProvider), ZoroxAccent.green);
    });
  });

  group('an explicit choice in Settings', () {
    test('Blue is honoured', () async {
      await storage.saveAccentColor('blue');

      expect(boot().read(accentColorProvider), ZoroxAccent.blue);
    });

    test('every preset round-trips through storage', () async {
      for (final accent in ZoroxAccent.values) {
        await storage.saveAccentColor(accent.name);

        expect(
          boot().read(accentColorProvider),
          accent,
          reason: '${accent.name} should survive a restart',
        );
      }
    });
  });

  // Whether the user has ever picked an accent: Green is both the fallback
  // and a preset, so the accent state alone cannot tell "never chose" from
  // "chose Green" — only the stored value can. The theme reads this to
  // decide whether Android's Material You keeps winning.
  group('whether the user has ever picked one', () {
    test('is false when nothing is recorded, though the accent reads Green',
        () {
      expect(storage.getAccentColor(), isNull);

      final container = boot();
      expect(container.read(accentColorProvider), ZoroxAccent.green);
      expect(
        container.read(accentColorProvider.notifier).hasExplicitChoice,
        isFalse,
      );
    });

    test('is true once Green itself is picked', () async {
      await storage.saveAccentColor('green');

      final container = boot();
      expect(container.read(accentColorProvider), ZoroxAccent.green);
      expect(
        container.read(accentColorProvider.notifier).hasExplicitChoice,
        isTrue,
      );
    });

    test('is true for any other preset too', () async {
      await storage.saveAccentColor('blue');

      expect(
        boot().read(accentColorProvider.notifier).hasExplicitChoice,
        isTrue,
      );
    });
  });

  test('a value no release ever wrote falls back to Green', () async {
    await storage.saveAccentColor('sepia');

    expect(boot().read(accentColorProvider), ZoroxAccent.green);
  });

  test('choosing an accent records it', () async {
    final container = boot();

    await container
        .read(accentColorProvider.notifier)
        .setAccent(ZoroxAccent.violet);

    expect(container.read(accentColorProvider), ZoroxAccent.violet);
    expect(storage.getAccentColor(), 'violet');
  });

  test('the palette has 9 distinct, named presets', () {
    expect(ZoroxAccent.values.length, 9);
    expect(
      ZoroxAccent.values.map((a) => a.color).toSet().length,
      9,
      reason: 'no two presets share a color',
    );
    for (final accent in ZoroxAccent.values) {
      expect(accent.label, isNotEmpty);
    }
  });

  test('White is a preset again (b126); retired Black / Cyan fall back to Green (v4, 2.9.19+60)', () {
    expect(ZoroxAccent.silver.color, const Color(0xFFE8E8EC));
    expect(ZoroxAccent.white.color, const Color(0xFFFFFFFF));
    expect(ZoroxAccent.fromName('white'), ZoroxAccent.white);
    expect(ZoroxAccent.fromName('black'), ZoroxAccent.green);
    expect(ZoroxAccent.fromName('cyan'), ZoroxAccent.green);
    expect(ZoroxAccent.fromName('violet'), ZoroxAccent.violet);
  });
}
