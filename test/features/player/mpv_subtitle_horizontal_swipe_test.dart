/// The subtitle's horizontal swipe (+26) is gone: a horizontal swipe
/// seeks now (+43), 90 s per full width like the stock chrome, with a
/// pill showing the target time and the seek landing on release. The
/// caption's raise is still adjustable — the centre-third vertical
/// slide (+25) and the Subtitle style drawer's Position dropdown read
/// the same [setSubtitleRaise], and the −10/−5/+5/+10 pills are still
/// gone from the Position row.
///
/// The duplicate cue the user reported in +25 could NOT be reproduced
/// here — every one of the video's 196 frames at 30 fps shows the
/// caption once, and a frame-diff over the whole clip shows the cue
/// animating as one copy between positions, never two at once. The code
/// has one SubtitleView, replace-not-append on the stream, no secondary
/// track, and a raise change touches no subtitle state. The one
/// remaining path by which a cue could double is mpv's secondary
/// subtitle: media_kit's state is [primary, secondary] and its
/// SubtitleView renders both, so an auto-picked secondary track in the
/// same language doubles the cue — closed in +26 by forcing
/// `secondary-sid: no` at player start (see kMpvSubtitleOptions).
/// That hardening is pinned below; the phone test is still the proof
/// that the user's duplicate is gone.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/features/player/presentation/mpv/golden_player_controls.dart';
import 'package:zorox/features/player/presentation/mpv/golden_subtitle_style_drawer.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_android_options.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_subtitle_style.dart';
import 'package:zorox/features/settings/presentation/player_settings_provider.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

void main() {
  group('swipeSeekTarget — a full width is 90 s, like the stock chrome',
      () {
    test('a right swipe of a tenth of the width seeks 9 s forward', () {
      expect(
        swipeSeekTarget(
          const Duration(minutes: 2, seconds: 36),
          const Duration(hours: 2),
          0.1,
        ),
        const Duration(minutes: 2, seconds: 45),
      );
    });

    test('a left swipe of a tenth seeks 9 s back', () {
      expect(
        swipeSeekTarget(
          const Duration(minutes: 2, seconds: 36),
          const Duration(hours: 2),
          -0.1,
        ),
        const Duration(minutes: 2, seconds: 27),
      );
    });

    test('a full screen right is 90 s', () {
      expect(
        swipeSeekTarget(
          const Duration(minutes: 2, seconds: 36),
          const Duration(hours: 2),
          1.0,
        ),
        const Duration(minutes: 4, seconds: 6),
      );
    });

    test('it clamps at the start and the end', () {
      expect(
        swipeSeekTarget(
          const Duration(seconds: 5),
          const Duration(hours: 2),
          -1.0,
        ),
        Duration.zero,
      );
      expect(
        swipeSeekTarget(
          const Duration(hours: 1, minutes: 59, seconds: 30),
          const Duration(hours: 2),
          1.0,
        ),
        const Duration(hours: 2),
      );
    });

    test('a small swipe moves a little, not a step', () {
      // A 5% swipe is 4.5 s — smooth, not a jump.
      expect(
        swipeSeekTarget(
          const Duration(minutes: 2, seconds: 36),
          const Duration(hours: 2),
          0.05,
        ),
        const Duration(minutes: 2, seconds: 40, milliseconds: 500),
      );
    });

    test('an unseekable duration returns the start', () {
      expect(
        swipeSeekTarget(
          const Duration(minutes: 2),
          Duration.zero,
          1.0,
        ),
        const Duration(minutes: 2),
      );
    });
  });

  group('the vertical slide still lands in the rendered caption', () {
    test('sliding up from Bottom lifts the padding', () {
      final raise = subtitleRaiseAfterSlide(0.0, 0.5);
      final config = mpvSubtitleViewConfiguration(
        PlayerSettings(subtitleRaise: raise),
        screenHeight: 360,
        controlsVisible: false,
      );
      expect(config.padding.bottom, 16.0 + 0.1 * 360);
    });

    test('sliding down from Top drops it', () {
      final raise = subtitleRaiseAfterSlide(0.2, -0.5);
      final config = mpvSubtitleViewConfiguration(
        PlayerSettings(subtitleRaise: raise),
        screenHeight: 360,
        controlsVisible: false,
      );
      expect(config.padding.bottom, 16.0 + 0.1 * 360);
    });

    test('the base stays 16px after a slide — the slide only moves the raise',
        () {
      final config = mpvSubtitleViewConfiguration(
        PlayerSettings(
          subtitleRaise: subtitleRaiseAfterSlide(0.0, 0.25),
        ),
        screenHeight: 360,
        controlsVisible: false,
      );
      expect(config.padding.bottom, 16.0 + 0.05 * 360);
    });
  });

  group('the swipe persists like the dropdown and the vertical slide', () {
    late Directory dir;
    late StorageService storage;
    late ProviderContainer container;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('subtitle_swipe_persist');
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

    test('setSubtitleRaise — the vertical slide\'s write — sticks', () async {
      await container.read(playerSettingsProvider.future);
      // What the vertical slide writes on every update.
      await container
          .read(playerSettingsProvider.notifier)
          .setSubtitleRaise(0.13);
      expect(
        container.read(playerSettingsProvider).asData?.value.subtitleRaise,
        closeTo(0.13, 0.0001),
      );
    });
  });

  group('a Position change cannot duplicate the cue', () {
    test('the configuration carries no subtitle text: only the padding '
        'moves with the raise', () {
      // The render path has one SubtitleView, which replaces its text on
      // every stream event and never appends; there is no secondary
      // subtitle track; and a raise change fires no stream event — the
      // screen only rebuilds the configuration and pushes the padding.
      // So a Position change has no content channel to double through:
      // the only thing that may differ across raises is the padding.
      const screenHeight = 360.0;
      final low = mpvSubtitleViewConfiguration(
        const PlayerSettings(subtitleRaise: 0.0),
        screenHeight: screenHeight,
        controlsVisible: false,
      );
      final high = mpvSubtitleViewConfiguration(
        const PlayerSettings(subtitleRaise: 0.2),
        screenHeight: screenHeight,
        controlsVisible: false,
      );
      expect(high.padding.bottom, 16.0 + 0.2 * screenHeight);
      expect(high.padding.bottom, isNot(low.padding.bottom));
      expect(high.style, low.style);
      expect(high.textAlign, low.textAlign);
      expect(high.textScaler, low.textScaler);
    });

    test('the secondary subtitle slot is off, so no second copy can '
        'arrive through it', () {
      // media_kit renders both slots of its subtitle state; the only
      // way a cue could double is an auto-picked secondary track.
      // The player start forces it off (see applyMpvSubtitleOptions).
      expect(kMpvSubtitleOptions['secondary-sid'], 'no');
    });
  });

  group('the Position row has no nudge pills', () {
    late Directory dir;
    late StorageService storage;
    late ProviderContainer container;
    late FakeVlcEngine engine;
    late VlcPlayerController controller;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('subtitle_drawer_row');
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
      // Disposed before the container (tearDowns run in reverse
      // registration order): the controller still talks to the engine
      // on dispose, and a channel with no handler throws.
      addTearDown(controller.dispose);
      // Paused, so the controller's 1 s stall watchdog stands down and
      // the test can end (see fake_vlc_engine.dart).
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

    testWidgets('the drawer shows Position but no −10/−5/+5/+10',
        (tester) async {
      // A tall viewport: the drawer is full-height and its ListView
      // builds every row without scrolling. The old
      // `scrollUntilVisible` hung here — the row never settled into
      // view — so no test scrolls this drawer anymore.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = ValueNotifier<PlayerSettings>(
        const PlayerSettings(),
      );
      addTearDown(settings.dispose);
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

      expect(find.text('Position'), findsOneWidget);
      expect(find.text('Bottom'), findsOneWidget);
      for (final pill in ['−10', '−5', '+5', '+10']) {
        expect(find.text(pill), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  });
}
