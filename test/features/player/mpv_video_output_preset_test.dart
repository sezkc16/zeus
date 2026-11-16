import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/mpv/golden_video_drawer.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_ios_options.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';

/// The Video output panel (+57): four presets, each a REAL render
/// configuration — a hardware mpv option set (PiP OFF) and a software
/// LUT curve (PiP ON) — never a label that changes nothing. These
/// tests pin the preset → option map, the preset → LUT-curve table,
/// the stored default, and the drawer itself (tap a row, the pick
/// fires; Reset tuning picks Native EDR).
void main() {
  group('videoOutputPresetToneMapping', () {
    test('Native EDR is clip (the behaviour every install already had)', () {
      expect(videoOutputPresetToneMapping(VideoOutputPreset.nativeEdr), 'clip');
    });

    test('SDR tone mapped is the bt.2390 reference curve', () {
      expect(
        videoOutputPresetToneMapping(VideoOutputPreset.sdrToneMapped),
        'bt.2390',
      );
    });

    test('Compatibility is mpv auto (bt.2390 on vo=gpu)', () {
      expect(
        videoOutputPresetToneMapping(VideoOutputPreset.compatibility),
        'auto',
      );
    });

    test('Custom with nothing stored falls back to clip', () {
      expect(videoOutputPresetToneMapping(VideoOutputPreset.custom), 'clip');
    });

    test('Custom uses the stored tone-mapping value', () {
      expect(
        videoOutputPresetToneMapping(
          VideoOutputPreset.custom,
          customToneMapping: 'mobius',
        ),
        'mobius',
      );
    });
  });

  group('videoOutputPresetOptions (hardware path)', () {
    test('Native EDR: clip + the +34 cheap render', () {
      final options = videoOutputPresetOptions(VideoOutputPreset.nativeEdr);
      expect(options['tone-mapping'], 'clip');
      expect(options['target-peak'], 'auto');
      expect(options['scale'], 'bilinear');
      expect(options['cscale'], 'bilinear');
      expect(options['dscale'], 'bilinear');
      expect(options['deband'], 'no');
      expect(options['dither-depth'], 'no');
      expect(options['correct-downscaling'], 'no');
    });

    test('SDR tone mapped: bt.2390 + the +34 cheap render', () {
      final options = videoOutputPresetOptions(VideoOutputPreset.sdrToneMapped);
      expect(options['tone-mapping'], 'bt.2390');
      expect(options['target-peak'], 'auto');
      expect(options['scale'], 'bilinear');
      expect(options['dscale'], 'bilinear');
      expect(options['correct-downscaling'], 'no');
    });

    test('Compatibility: auto + mpv defaults, not the cheap render', () {
      final options = videoOutputPresetOptions(VideoOutputPreset.compatibility);
      expect(options['tone-mapping'], 'auto');
      expect(options['target-peak'], 'auto');
      // mpv's own defaults: the render before the +34 cheap scalers.
      expect(options['scale'], 'lanczos');
      expect(options['cscale'], 'lanczos');
      expect(options['dscale'], 'hermite');
      expect(options['deband'], 'no');
      expect(options['dither-depth'], 'auto');
      expect(options['correct-downscaling'], 'yes');
    });

    test('Custom with nothing stored behaves as Native EDR', () {
      final options = videoOutputPresetOptions(VideoOutputPreset.custom);
      expect(options['tone-mapping'], 'clip');
      expect(options['target-peak'], 'auto');
      expect(options['scale'], 'bilinear');
    });

    test('Custom uses the stored tone-mapping and target peak', () {
      final options = videoOutputPresetOptions(
        VideoOutputPreset.custom,
        customToneMapping: 'mobius',
        customTargetPeak: '100',
      );
      expect(options['tone-mapping'], 'mobius');
      expect(options['target-peak'], '100');
      // The stored values only replace the mapping — the render
      // stays the cheap one.
      expect(options['scale'], 'bilinear');
    });

    test('switching presets is a deterministic state', () {
      // Picking Native EDR after Compatibility restores the cheap
      // scalers — it does not leave lanczos behind.
      final afterCompatibility = videoOutputPresetOptions(
        VideoOutputPreset.nativeEdr,
      );
      expect(afterCompatibility['scale'], 'bilinear');
      expect(afterCompatibility['dither-depth'], 'no');
      expect(afterCompatibility['correct-downscaling'], 'no');
    });

    test('no preset ever re-adds the v20+1 black-screen value', () {
      for (final preset in VideoOutputPreset.values) {
        final options = videoOutputPresetOptions(preset);
        expect(options.containsKey('hdr-compute-peak'), isFalse);
      }
    });
  });

  group('swToneMapCurveForToneMapping (software path)', () {
    test('clip means the clip LUT', () {
      expect(swToneMapCurveForToneMapping('clip'), SwToneMapCurve.clip);
    });

    test('bt.2390 means the EETF LUT', () {
      expect(swToneMapCurveForToneMapping('bt.2390'), SwToneMapCurve.eetf);
    });

    test('auto means the EETF LUT (mpv auto maps to bt.2390)', () {
      expect(swToneMapCurveForToneMapping('auto'), SwToneMapCurve.eetf);
    });

    test('anything else — including unreadable — means the clip', () {
      expect(swToneMapCurveForToneMapping('mobius'), SwToneMapCurve.clip);
      expect(swToneMapCurveForToneMapping(''), SwToneMapCurve.clip);
      expect(swToneMapCurveForToneMapping('hable'), SwToneMapCurve.clip);
    });

    test('the table is case-insensitive', () {
      expect(swToneMapCurveForToneMapping('BT.2390'), SwToneMapCurve.eetf);
      expect(swToneMapCurveForToneMapping('Auto'), SwToneMapCurve.eetf);
      expect(swToneMapCurveForToneMapping('CLIP'), SwToneMapCurve.clip);
    });
  });

  group('PlayerSettings.videoOutputPreset', () {
    test('defaults to Native EDR', () {
      expect(
        const PlayerSettings().videoOutputPreset,
        VideoOutputPreset.nativeEdr,
      );
      expect(const PlayerSettings().videoCustomToneMapping, isNull);
      expect(const PlayerSettings().videoCustomTargetPeak, isNull);
    });

    test('copyWith sets the preset and the custom values', () {
      final settings = const PlayerSettings().copyWith(
        videoOutputPreset: VideoOutputPreset.sdrToneMapped,
        videoCustomToneMapping: 'mobius',
        videoCustomTargetPeak: '100',
      );
      expect(settings.videoOutputPreset, VideoOutputPreset.sdrToneMapped);
      expect(settings.videoCustomToneMapping, 'mobius');
      expect(settings.videoCustomTargetPeak, '100');
    });

    test('copyWith without the preset keeps the current one', () {
      final settings = const PlayerSettings()
          .copyWith(videoOutputPreset: VideoOutputPreset.compatibility)
          .copyWith(videoCustomToneMapping: 'mobius');
      expect(settings.videoOutputPreset, VideoOutputPreset.compatibility);
      expect(settings.videoCustomToneMapping, 'mobius');
    });

    test('copyWith clears the custom values when asked', () {
      final settings = const PlayerSettings()
          .copyWith(
            videoCustomToneMapping: 'mobius',
            videoCustomTargetPeak: '100',
          )
          .copyWith(
            clearVideoCustomToneMapping: true,
            clearVideoCustomTargetPeak: true,
          );
      expect(settings.videoCustomToneMapping, isNull);
      expect(settings.videoCustomTargetPeak, isNull);
    });
  });

  group('GoldenVideoDrawer', () {
    Future<void> pumpDrawer(
      WidgetTester tester, {
      required ValueNotifier<PlayerSettings> settings,
      required ValueChanged<VideoOutputPreset> onPresetPicked,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: GoldenVideoDrawer(
              settings: settings,
              onPresetPicked: onPresetPicked,
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('lists the four presets in the screenshot order', (
      tester,
    ) async {
      final settings = ValueNotifier<PlayerSettings>(const PlayerSettings());
      addTearDown(settings.dispose);
      await pumpDrawer(tester, settings: settings, onPresetPicked: (_) {});
      expect(find.text('Video'), findsOneWidget);
      expect(find.text('Native EDR'), findsOneWidget);
      expect(find.text('SDR tone mapped'), findsOneWidget);
      expect(find.text('Compatibility'), findsOneWidget);
      expect(find.text('Custom'), findsOneWidget);
      expect(
        find.text('Best for HDR-capable iPhones and iPads.'),
        findsOneWidget,
      );
      expect(
        find.text('More predictable whites and blacks on SDR-style output.'),
        findsOneWidget,
      );
      expect(
        find.text('Closest to the older iOS MPV behavior.'),
        findsOneWidget,
      );
      expect(find.text('Use your advanced values below.'), findsOneWidget);
      expect(find.text('Reset tuning'), findsOneWidget);
    });

    testWidgets('tapping a preset fires onPresetPicked with it', (
      tester,
    ) async {
      final settings = ValueNotifier<PlayerSettings>(const PlayerSettings());
      addTearDown(settings.dispose);
      VideoOutputPreset? picked;
      await pumpDrawer(
        tester,
        settings: settings,
        onPresetPicked: (preset) => picked = preset,
      );
      await tester.tap(find.text('SDR tone mapped'));
      await tester.pump();
      expect(picked, VideoOutputPreset.sdrToneMapped);
    });

    testWidgets('Reset tuning picks Native EDR', (tester) async {
      final settings = ValueNotifier<PlayerSettings>(
        const PlayerSettings().copyWith(
          videoOutputPreset: VideoOutputPreset.compatibility,
        ),
      );
      addTearDown(settings.dispose);
      VideoOutputPreset? picked;
      await pumpDrawer(
        tester,
        settings: settings,
        onPresetPicked: (preset) => picked = preset,
      );
      await tester.tap(find.text('Reset tuning'));
      await tester.pump();
      expect(picked, VideoOutputPreset.nativeEdr);
    });

    testWidgets('the checkmark follows the active preset', (tester) async {
      final settings = ValueNotifier<PlayerSettings>(
        const PlayerSettings().copyWith(
          videoOutputPreset: VideoOutputPreset.compatibility,
        ),
      );
      addTearDown(settings.dispose);
      await pumpDrawer(tester, settings: settings, onPresetPicked: (_) {});
      // One checked radio (Compatibility), three unchecked.
      expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);
      expect(
        find.byIcon(Icons.radio_button_unchecked_rounded),
        findsNWidgets(3),
      );
    });
  });
}
