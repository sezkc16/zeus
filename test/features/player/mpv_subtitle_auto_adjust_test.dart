/// Auto-Adjust + the Manual slider for the subtitle position (+27).
///
/// The Style tab's Position dropdown stays the coarse preset; the Manual
/// slider is the fine control (0–100% of the raise range [0, 0.2]), and
/// Auto-Adjust positions the caption itself — just above the bottom
/// controls while they are visible, low when hidden — ignoring the saved
/// raise. Any manual lift (swipe, dropdown, slider) turns Auto-Adjust
/// off.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/features/player/domain/subtitle_style.dart';
import 'package:zorox/features/player/presentation/mpv/golden_subtitle_style_drawer.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_subtitle_style.dart';
import 'package:zorox/features/settings/presentation/player_settings_provider.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

void main() {
  group('the Manual slider maps 0–100% to the raise range', () {
    test('0% is the bottom edge, 100% the top of the range', () {
      expect(subtitleRaiseToSliderPercent(0.0), 0.0);
      expect(subtitleRaiseToSliderPercent(0.2), 100.0);
      expect(subtitleRaiseToSliderPercent(0.1), 50.0);
      expect(subtitleRaiseToSliderPercent(0.05), 25.0);
      expect(subtitleRaiseFromSliderPercent(0), 0.0);
      expect(subtitleRaiseFromSliderPercent(100), 0.2);
      expect(subtitleRaiseFromSliderPercent(50), 0.1);
    });

    test('a drag past either end lands on the end', () {
      expect(subtitleRaiseToSliderPercent(0.5), 100.0);
      expect(subtitleRaiseToSliderPercent(-0.1), 0.0);
      expect(subtitleRaiseFromSliderPercent(150), 0.2);
      expect(subtitleRaiseFromSliderPercent(-10), 0.0);
    });

    test('the mapping round-trips', () {
      for (final raise in <double>[0.0, 0.05, 0.1, 0.15, 0.2]) {
        expect(
          subtitleRaiseFromSliderPercent(subtitleRaiseToSliderPercent(raise)),
          closeTo(raise, 0.0001),
        );
      }
    });
  });

  group('Auto-Adjust in the mpv caption', () {
    SubtitleViewConfiguration configOf({
      PlayerSettings s = const PlayerSettings(),
      double screenHeight = 360,
      required bool controlsVisible,
      bool isPip = false,
    }) => mpvSubtitleViewConfiguration(
      s,
      screenHeight: screenHeight,
      controlsVisible: controlsVisible,
      isPip: isPip,
    );

    test('off: the saved raise lifts from the low base, as before', () {
      final config = configOf(
        s: const PlayerSettings(subtitleRaise: 0.1),
        controlsVisible: true,
      );
      expect(config.padding.bottom, 16.0 + 0.1 * 360);
    });

    test('on, chrome hidden: low, and the saved raise is ignored', () {
      final config = configOf(
        s: const PlayerSettings(
          subtitleRaise: 0.2,
          subtitleAutoAdjust: true,
        ),
        controlsVisible: false,
      );
      expect(config.padding.bottom, 16.0);
    });

    test('on, chrome visible: just above the bottom controls', () {
      final config = configOf(
        s: const PlayerSettings(
          subtitleRaise: 0.2,
          subtitleAutoAdjust: true,
        ),
        controlsVisible: true,
      );
      expect(config.padding.bottom, 116.0);
    });

    test('on, chrome visible, no saved raise: still above the controls', () {
      final config = configOf(
        s: const PlayerSettings(subtitleAutoAdjust: true),
        controlsVisible: true,
      );
      expect(config.padding.bottom, 116.0);
    });

    test('on, in PiP: ignored — the manual raise applies, no chrome there',
        () {
      final config = configOf(
        s: const PlayerSettings(
          subtitleRaise: 0.2,
          subtitleAutoAdjust: true,
        ),
        controlsVisible: true,
        isPip: true,
      );
      expect(config.padding.bottom, 8.0 + 0.2 * 360);
    });
  });

  group('Auto-Adjust in the libVLC look', () {
    test('the effective raise is 0 while Auto-Adjust is on', () {
      expect(
        subtitleEffectiveRaise(const PlayerSettings(subtitleRaise: 0.2)),
        0.2,
      );
      expect(
        subtitleEffectiveRaise(
          const PlayerSettings(
            subtitleRaise: 0.2,
            subtitleAutoAdjust: true,
          ),
        ),
        0.0,
      );
    });

    test('the playing look carries the effective raise', () {
      expect(
        subtitleLookFrom(
          const PlayerSettings(subtitleRaise: 0.2),
          createdRelativeSize: 24,
        ).raise,
        0.2,
      );
      expect(
        subtitleLookFrom(
          const PlayerSettings(
            subtitleRaise: 0.2,
            subtitleAutoAdjust: true,
          ),
          createdRelativeSize: 24,
        ).raise,
        0.0,
      );
    });
  });

  group('the Auto-Adjust setting', () {
    late Directory dir;
    late StorageService storage;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('player_settings_auto');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (MethodCall call) async => dir.path,
          );
      storage = StorageService();
      await storage.init();
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
    });

    tearDown(() async {
      await Hive.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
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

    Future<PlayerSettingsNotifier> notifierOf(
      ProviderContainer container,
    ) async {
      await container.read(playerSettingsProvider.future);
      return container.read(playerSettingsProvider.notifier);
    }

    test('is off on a fresh install', () async {
      final settings = await boot().read(playerSettingsProvider.future);
      expect(settings.subtitleAutoAdjust, isFalse);
    });

    test('persists across launches', () async {
      await (await notifierOf(boot())).setSubtitleAutoAdjust(true);
      expect(
        (await boot().read(playerSettingsProvider.future))
            .subtitleAutoAdjust,
        isTrue,
      );
      await (await notifierOf(boot())).setSubtitleAutoAdjust(false);
      expect(
        (await boot().read(playerSettingsProvider.future))
            .subtitleAutoAdjust,
        isFalse,
      );
    });

    test('a manual lift turns it off — swipe, dropdown and slider alike',
        () async {
      final notifier = await notifierOf(boot());
      await notifier.setSubtitleAutoAdjust(true);
      await notifier.setSubtitleRaise(0.1);
      final settings = await boot().read(playerSettingsProvider.future);
      expect(settings.subtitleAutoAdjust, isFalse);
      expect(settings.subtitleRaise, 0.1);
      expect(
        storage.getPlayerSetting<bool>('player_sub_auto_adjust'),
        isFalse,
      );
    });

    test('a lift while it is already off does not rewrite the key', () async {
      final notifier = await notifierOf(boot());
      await notifier.setSubtitleRaise(0.1);
      expect(storage.getPlayerSetting<bool>('player_sub_auto_adjust'), isNull);
    });

    test('Reset puts it back off', () async {
      final notifier = await notifierOf(boot());
      await notifier.setSubtitleAutoAdjust(true);
      await notifier.resetSubtitleSettings();
      expect(
        (await boot().read(playerSettingsProvider.future))
            .subtitleAutoAdjust,
        isFalse,
      );
    });
  });

  group('the drawer rows', () {
    late Directory dir;
    late StorageService storage;
    late ProviderContainer container;
    late FakeVlcEngine engine;
    late VlcPlayerController controller;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('subtitle_drawer_auto');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (MethodCall call) async => dir.path,
          );
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      storage = StorageService();
      await storage.init();
      container = ProviderContainer(
        overrides: [storageServiceProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      engine = FakeVlcEngine()..install();
      addTearDown(engine.dispose);
      controller = await engine.attach();
      addTearDown(controller.dispose);
      await engine.emit(const <String, Object?>{'state': 'paused'});
    });

    tearDown(() async {
      await Hive.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<void> pumpDrawer(
      WidgetTester tester,
      ValueNotifier<PlayerSettings> settings,
    ) async {
      // A tall viewport: the drawer is full-height and its ListView
      // builds every row without scrolling — no test scrolls this
      // drawer (see the +26 fix: scrollUntilVisible hung here).
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // The screen's own wiring, in miniature: the drawer's settings
      // listenable follows the provider, so a write through the
      // notifier repaints the rows.
      container.listen(playerSettingsProvider, (_, next) {
        final value = next.asData?.value;
        if (value != null) settings.value = value;
      });
      await container.read(playerSettingsProvider.future);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoldenSubtitleStyleDrawer(
              settings: settings,
              notifier: container.read(playerSettingsProvider.notifier),
              controller: controller,
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> tapAutoAdjust(WidgetTester tester) async {
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('subtitle-auto-adjust')),
          matching: find.byType(Switch),
        ),
      );
      // The toggle writes through the notifier (Hive, async): let the
      // write land and the synced settings repaint before asserting.
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }

    Future<void> settleSlider(WidgetTester tester) async {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }

    testWidgets('Auto-Adjust off shows the Manual slider', (tester) async {
      final settings = ValueNotifier<PlayerSettings>(
        const PlayerSettings(),
      );
      addTearDown(settings.dispose);
      await pumpDrawer(tester, settings);

      expect(find.text('Auto-Adjust'), findsOneWidget);
      expect(find.text('Manual'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('0%'), findsOneWidget);
      // The drawer's bottom Reset button uses the same icon, so the
      // Manual row's reset is found through the row's key.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('subtitle-manual-slider')),
          matching: find.byIcon(Icons.restart_alt_rounded),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('turning Auto-Adjust on hides the Manual slider',
        (tester) async {
      final settings = ValueNotifier<PlayerSettings>(
        const PlayerSettings(),
      );
      addTearDown(settings.dispose);
      await pumpDrawer(tester, settings);

      await tapAutoAdjust(tester);

      expect(find.text('Auto-Adjust'), findsOneWidget);
      expect(find.text('Manual'), findsNothing);
      expect(find.byType(Slider), findsNothing);
      final stored = await container.read(playerSettingsProvider.future);
      expect(stored.subtitleAutoAdjust, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('turning it back off brings the Manual slider back',
        (tester) async {
      final settings = ValueNotifier<PlayerSettings>(
        const PlayerSettings(),
      );
      addTearDown(settings.dispose);
      await pumpDrawer(tester, settings);
      await tapAutoAdjust(tester);
      expect(find.text('Manual'), findsNothing);
      await tapAutoAdjust(tester);
      expect(find.text('Manual'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      final stored = await container.read(playerSettingsProvider.future);
      expect(stored.subtitleAutoAdjust, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dragging the slider lifts the caption live', (tester) async {
      final settings = ValueNotifier<PlayerSettings>(
        const PlayerSettings(),
      );
      addTearDown(settings.dispose);
      await pumpDrawer(tester, settings);

      await tester.drag(find.byType(Slider), const Offset(100, 0));
      await settleSlider(tester);

      final stored = await container.read(playerSettingsProvider.future);
      expect(stored.subtitleRaise, greaterThan(0.0));
      expect(find.text('0%'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the reset button puts the caption back at the bottom',
        (tester) async {
      final settings = ValueNotifier<PlayerSettings>(
        const PlayerSettings(),
      );
      addTearDown(settings.dispose);
      await pumpDrawer(tester, settings);
      await container
          .read(playerSettingsProvider.notifier)
          .setSubtitleRaise(0.1);
      await settleSlider(tester);
      expect(find.text('50%'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('subtitle-manual-slider')),
          matching: find.byIcon(Icons.restart_alt_rounded),
        ),
      );
      await settleSlider(tester);

      final stored = await container.read(playerSettingsProvider.future);
      expect(stored.subtitleRaise, 0.0);
      expect(find.text('0%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
