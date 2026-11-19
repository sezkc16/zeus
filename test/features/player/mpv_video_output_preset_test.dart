import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/golden_video_drawer.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_ios_options.dart';
import 'package:zorox/features/settings/presentation/player_settings_provider.dart';

/// The Video panel (+57, reworked in v9): PICTURE — three sliders that
/// are real mpv properties — and HDR — two choices, Bright (clip) and
/// Balanced (bt.2390), shown on HDR videos only. These tests pin the
/// migration of the four old presets onto the two, the preset → option
/// map, the preset → LUT-curve table, the slider → property map and its
/// clamp, the stored defaults, and the drawer itself.
void main() {
  group('migrateVideoOutputPreset', () {
    test('Native EDR stays Bright', () {
      expect(
        migrateVideoOutputPreset('nativeEdr'),
        VideoOutputPreset.nativeEdr,
      );
    });

    test('SDR tone mapped stays Balanced', () {
      expect(
        migrateVideoOutputPreset('sdrToneMapped'),
        VideoOutputPreset.sdrToneMapped,
      );
    });

    test('Compatibility becomes Balanced', () {
      expect(
        migrateVideoOutputPreset('compatibility'),
        VideoOutputPreset.sdrToneMapped,
      );
    });

    test('Custom with clip stored becomes Bright', () {
      expect(
        migrateVideoOutputPreset('custom', customToneMapping: 'clip'),
        VideoOutputPreset.nativeEdr,
      );
    });

    test('Custom with any other curve stored becomes Balanced', () {
      for (final curve in <String>['bt.2390', 'mobius', 'hable', 'auto']) {
        expect(
          migrateVideoOutputPreset('custom', customToneMapping: curve),
          VideoOutputPreset.sdrToneMapped,
          reason: curve,
        );
      }
    });

    test('Custom with nothing stored behaved as clip, so it is Bright', () {
      expect(migrateVideoOutputPreset('custom'), VideoOutputPreset.nativeEdr);
    });

    test('nothing stored, or an unknown name, is Bright (the default)', () {
      expect(migrateVideoOutputPreset(null), VideoOutputPreset.nativeEdr);
      expect(migrateVideoOutputPreset(''), VideoOutputPreset.nativeEdr);
      expect(migrateVideoOutputPreset('future'), VideoOutputPreset.nativeEdr);
    });

    test('the result is only ever one of the two', () {
      for (final preset in VideoOutputPreset.values) {
        for (final curve in <String?>[null, 'clip', 'bt.2390', 'mobius']) {
          expect(
            migrateVideoOutputPreset(preset.name, customToneMapping: curve),
            anyOf(VideoOutputPreset.nativeEdr, VideoOutputPreset.sdrToneMapped),
          );
        }
      }
    });
  });

  group('videoOutputPresetToneMapping', () {
    test('Bright is clip (the behaviour every install already had)', () {
      expect(videoOutputPresetToneMapping(VideoOutputPreset.nativeEdr), 'clip');
    });

    test('Balanced is the bt.2390 reference curve', () {
      expect(
        videoOutputPresetToneMapping(VideoOutputPreset.sdrToneMapped),
        'bt.2390',
      );
    });

    test('a legacy Compatibility is Balanced: bt.2390, never auto', () {
      expect(
        videoOutputPresetToneMapping(VideoOutputPreset.compatibility),
        'bt.2390',
      );
    });

    test('a legacy Custom with nothing stored is clip', () {
      expect(videoOutputPresetToneMapping(VideoOutputPreset.custom), 'clip');
    });

    test('a legacy Custom never selects a third curve', () {
      expect(
        videoOutputPresetToneMapping(
          VideoOutputPreset.custom,
          customToneMapping: 'mobius',
        ),
        'bt.2390',
      );
      expect(
        videoOutputPresetToneMapping(
          VideoOutputPreset.custom,
          customToneMapping: 'clip',
        ),
        'clip',
      );
    });
  });

  group('videoOutputPresetOptions (hardware path)', () {
    void expectCheapRender(Map<String, String> options) {
      expect(options['target-peak'], 'auto');
      expect(options['scale'], 'bilinear');
      expect(options['cscale'], 'bilinear');
      expect(options['dscale'], 'bilinear');
      expect(options['deband'], 'no');
      expect(options['dither-depth'], 'no');
      expect(options['correct-downscaling'], 'no');
    }

    test('Bright: clip + the +34 cheap render', () {
      final options = videoOutputPresetOptions(VideoOutputPreset.nativeEdr);
      expect(options['tone-mapping'], 'clip');
      expectCheapRender(options);
    });

    test('Balanced: bt.2390 + the same cheap render', () {
      final options = videoOutputPresetOptions(VideoOutputPreset.sdrToneMapped);
      expect(options['tone-mapping'], 'bt.2390');
      expectCheapRender(options);
    });

    test('a legacy Compatibility no longer brings the lanczos set', () {
      final options = videoOutputPresetOptions(VideoOutputPreset.compatibility);
      expect(options['tone-mapping'], 'bt.2390');
      expectCheapRender(options);
    });

    test('a legacy Custom target peak is ignored', () {
      final options = videoOutputPresetOptions(
        VideoOutputPreset.custom,
        customToneMapping: 'clip',
        customTargetPeak: '400',
      );
      expect(options['tone-mapping'], 'clip');
      expectCheapRender(options);
    });

    test('switching is a deterministic state: same keys for every preset', () {
      final keys = videoOutputPresetOptions(VideoOutputPreset.nativeEdr).keys
          .toSet();
      for (final preset in VideoOutputPreset.values) {
        expect(videoOutputPresetOptions(preset).keys.toSet(), keys);
      }
    });

    test('no preset ever re-adds the v20+1 black-screen value', () {
      for (final preset in VideoOutputPreset.values) {
        expect(
          videoOutputPresetOptions(preset).containsKey('hdr-compute-peak'),
          isFalse,
        );
      }
    });
  });

  group('pictureOptions (the PICTURE sliders)', () {
    test('each slider is its own mpv property, one to one', () {
      expect(pictureOptions(brightness: 10, contrast: -20, saturation: 30), {
        'brightness': '10',
        'contrast': '-20',
        'saturation': '30',
      });
    });

    test('zero is mpv untouched', () {
      expect(pictureOptions(brightness: 0, contrast: 0, saturation: 0), {
        'brightness': '0',
        'contrast': '0',
        'saturation': '0',
      });
    });

    test('values are held to -50…+50', () {
      expect(pictureOptions(brightness: 90, contrast: -90, saturation: 51), {
        'brightness': '50',
        'contrast': '-50',
        'saturation': '50',
      });
    });

    test('clampPictureValue: range, rounding and junk', () {
      expect(kPictureMin, -50);
      expect(kPictureMax, 50);
      expect(clampPictureValue(null), 0);
      expect(clampPictureValue(12.4), 12);
      expect(clampPictureValue(-1000), -50);
      expect(clampPictureValue(1000), 50);
      expect(clampPictureValue(double.nan), 0);
    });

    test('the value label shows a sign only above zero', () {
      expect(pictureValueLabel(0), '0');
      expect(pictureValueLabel(10), '+10');
      expect(pictureValueLabel(-10), '-10');
    });
  });

  group('videoGammaIsHdr', () {
    test('PQ and HLG are HDR', () {
      expect(videoGammaIsHdr('pq'), isTrue);
      expect(videoGammaIsHdr('hlg'), isTrue);
      expect(videoGammaIsHdr(' PQ '), isTrue);
    });

    test('every other transfer is SDR', () {
      expect(videoGammaIsHdr('bt.1886'), isFalse);
      expect(videoGammaIsHdr('srgb'), isFalse);
      expect(videoGammaIsHdr('gamma2.2'), isFalse);
    });

    test('unreadable is unknown, not SDR', () {
      expect(videoGammaIsHdr(null), isNull);
      expect(videoGammaIsHdr(''), isNull);
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

  group('swLutOverlayLabel (QoE overlay, build 88)', () {
    test('bt.1886 is the build-87 exact SDR LUT', () {
      expect(
        swLutOverlayLabel(gamma: 'bt.1886', toneMapping: 'clip'),
        'sdr-exact',
      );
      expect(
        swLutOverlayLabel(gamma: 'gamma2.4', toneMapping: 'clip'),
        'sdr-exact',
      );
      expect(
        swLutOverlayLabel(gamma: 'gamma2.6', toneMapping: 'bt.2390'),
        'sdr-exact',
      );
    });

    test('bt.709 / sRGB-like sources pass through (no LUT)', () {
      expect(swLutOverlayLabel(gamma: 'bt.709', toneMapping: 'clip'), 'none');
      expect(swLutOverlayLabel(gamma: 'srgb', toneMapping: 'clip'), 'none');
      expect(swLutOverlayLabel(gamma: 'gamma2.2', toneMapping: 'clip'), 'none');
    });

    test('HDR takes the tone-map LUT matching the live preset', () {
      expect(swLutOverlayLabel(gamma: 'pq', toneMapping: 'clip'), 'pq-clip');
      expect(swLutOverlayLabel(gamma: 'pq', toneMapping: 'bt.2390'), 'pq-eetf');
      expect(swLutOverlayLabel(gamma: 'hlg', toneMapping: 'auto'), 'hlg-eetf');
    });

    test('unreadable gamma is unknown, not a LUT', () {
      expect(swLutOverlayLabel(gamma: null, toneMapping: 'clip'), '?');
      expect(swLutOverlayLabel(gamma: '', toneMapping: 'clip'), '?');
    });
  });

  group('hardware and software paths agree (PiP colour match)', () {
    test('every preset drives the same tone map on both paths', () {
      // The +50 principle, build 87: the hardware path's
      // `tone-mapping` option and the software renderer's LUT curve
      // must be the same choice, or PiP (the software buffer) and
      // fullscreen (hardware) show different colours on the same HDR
      // file. Bright is clip on both; Balanced is bt.2390 / EETF on
      // both. Legacy names go through the migration first, like the
      // real option builder does.
      for (final preset in VideoOutputPreset.values) {
        final hw = videoOutputPresetToneMapping(preset);
        final sw = swToneMapCurveForToneMapping(hw);
        final effective = migrateVideoOutputPreset(preset.name);
        expect(
          sw,
          effective == VideoOutputPreset.sdrToneMapped
              ? SwToneMapCurve.eetf
              : SwToneMapCurve.clip,
          reason: '$preset -> hw $hw',
        );
      }
    });

    test('the default preset is Bright: clip on both paths', () {
      expect(videoOutputPresetToneMapping(VideoOutputPreset.nativeEdr), 'clip');
      expect(
        swToneMapCurveForToneMapping(
          videoOutputPresetToneMapping(VideoOutputPreset.nativeEdr),
        ),
        SwToneMapCurve.clip,
      );
    });

    test('SDR is never tone-mapped: no preset changes the SDR LUT', () {
      // The SDR gamma LUT in TextureSW is built from the file's TRC
      // alone (build 87: exact bt.1886 -> sRGB); the preset only
      // picks the HDR (PQ/HLG) curve. So the tone-map value a preset
      // selects must never leak into the SDR path — asserted here as
      // the table above: only 'bt.2390'/'auto' mean the EETF, and the
      // SDR branch ignores the preset entirely.
      for (final preset in VideoOutputPreset.values) {
        final hw = videoOutputPresetToneMapping(preset);
        expect(
          <String>['clip', 'bt.2390'].contains(hw),
          isTrue,
          reason: '$preset -> $hw',
        );
      }
    });
  });

  group('PlayerSettings', () {
    test('defaults: Bright, sliders at zero', () {
      const settings = PlayerSettings();
      expect(settings.videoOutputPreset, VideoOutputPreset.nativeEdr);
      expect(settings.pictureBrightness, 0);
      expect(settings.pictureContrast, 0);
      expect(settings.pictureSaturation, 0);
    });

    test('copyWith sets the preset and the sliders', () {
      final settings = const PlayerSettings().copyWith(
        videoOutputPreset: VideoOutputPreset.sdrToneMapped,
        pictureBrightness: 5,
        pictureContrast: -6,
        pictureSaturation: 7,
      );
      expect(settings.videoOutputPreset, VideoOutputPreset.sdrToneMapped);
      expect(settings.pictureBrightness, 5);
      expect(settings.pictureContrast, -6);
      expect(settings.pictureSaturation, 7);
    });

    test('copyWith without them keeps the current values', () {
      final settings = const PlayerSettings()
          .copyWith(
            videoOutputPreset: VideoOutputPreset.sdrToneMapped,
            pictureContrast: 9,
          )
          .copyWith(pictureBrightness: 1);
      expect(settings.videoOutputPreset, VideoOutputPreset.sdrToneMapped);
      expect(settings.pictureContrast, 9);
      expect(settings.pictureBrightness, 1);
    });
  });

  group('GoldenVideoDrawer', () {
    Future<void> pumpDrawer(
      WidgetTester tester, {
      required ValueNotifier<PlayerSettings> settings,
      ValueChanged<VideoOutputPreset>? onPresetPicked,
      ValueListenable<bool?>? isHdr,
      ValueChanged<PictureValues>? onPictureChanged,
      _RecordingPicture? recorder,
    }) async {
      // Tall enough for every row: the drawer is a ListView, so rows
      // below the fold are not built at the default 600 px height.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // The drawer persists the sliders through the settings
            // notifier; the recorder keeps the write off Hive.
            playerSettingsProvider.overrideWith(
              () => recorder ?? _RecordingPicture(),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.black,
              body: GoldenVideoDrawer(
                settings: settings,
                onPresetPicked: onPresetPicked ?? (_) {},
                isHdr: isHdr,
                onPictureChanged: onPictureChanged,
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    bool tileChecked(Key key) => find
        .descendant(
          of: find.byKey(key),
          matching: find.byIcon(Icons.radio_button_checked_rounded),
        )
        .evaluate()
        .isNotEmpty;

    const bright = ValueKey('video-hdr-bright');
    const balanced = ValueKey('video-hdr-balanced');
    const sdrInfo = ValueKey('video-hdr-sdr-info');

    testWidgets('one list: PICTURE with three sliders, then HDR', (
      tester,
    ) async {
      final settings = ValueNotifier<PlayerSettings>(const PlayerSettings());
      addTearDown(settings.dispose);
      await pumpDrawer(tester, settings: settings);
      expect(find.text('PICTURE'), findsOneWidget);
      expect(find.text('HDR'), findsOneWidget);
      expect(find.text('Reset'), findsOneWidget);
      expect(find.text('Brightness'), findsOneWidget);
      expect(find.text('Contrast'), findsOneWidget);
      expect(find.text('Saturation'), findsOneWidget);
      expect(find.byType(Slider), findsNWidgets(3));
      expect(
        tester.getTopLeft(find.text('PICTURE')).dy,
        lessThan(tester.getTopLeft(find.text('HDR')).dy),
      );
    });

    testWidgets('the old preset names and Custom selectors are gone', (
      tester,
    ) async {
      final settings = ValueNotifier<PlayerSettings>(
        const PlayerSettings().copyWith(
          videoOutputPreset: VideoOutputPreset.custom,
        ),
      );
      addTearDown(settings.dispose);
      await pumpDrawer(tester, settings: settings);
      for (final gone in <String>[
        'Native EDR',
        'SDR tone mapped',
        'Compatibility',
        'Custom',
        'Reset tuning',
        'Tone mapping',
        'Target peak',
        'Video output',
      ]) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
    });

    testWidgets('an SDR video shows the info card and no options', (
      tester,
    ) async {
      final settings = ValueNotifier<PlayerSettings>(const PlayerSettings());
      final isHdr = ValueNotifier<bool?>(false);
      addTearDown(settings.dispose);
      addTearDown(isHdr.dispose);
      await pumpDrawer(tester, settings: settings, isHdr: isHdr);
      expect(find.byKey(sdrInfo), findsOneWidget);
      expect(
        find.text('This video is SDR. HDR options appear only on HDR videos.'),
        findsOneWidget,
      );
      expect(find.byKey(bright), findsNothing);
      expect(find.byKey(balanced), findsNothing);
      // The sliders are there on SDR all the same.
      expect(find.byType(Slider), findsNWidgets(3));
    });

    testWidgets('an HDR video shows the two cards', (tester) async {
      final settings = ValueNotifier<PlayerSettings>(const PlayerSettings());
      final isHdr = ValueNotifier<bool?>(true);
      addTearDown(settings.dispose);
      addTearDown(isHdr.dispose);
      await pumpDrawer(tester, settings: settings, isHdr: isHdr);
      expect(find.byKey(sdrInfo), findsNothing);
      expect(find.text('Bright'), findsOneWidget);
      expect(find.text('Punchy highlights'), findsOneWidget);
      expect(find.text('Balanced'), findsOneWidget);
      expect(find.text('Softer highlights, more detail'), findsOneWidget);
    });

    testWidgets('the cards follow the video as it turns out to be HDR', (
      tester,
    ) async {
      final settings = ValueNotifier<PlayerSettings>(const PlayerSettings());
      final isHdr = ValueNotifier<bool?>(false);
      addTearDown(settings.dispose);
      addTearDown(isHdr.dispose);
      await pumpDrawer(tester, settings: settings, isHdr: isHdr);
      expect(find.byKey(sdrInfo), findsOneWidget);
      isHdr.value = true;
      await tester.pump();
      expect(find.byKey(sdrInfo), findsNothing);
      expect(find.byKey(bright), findsOneWidget);
    });

    testWidgets('unknown is never hidden on a guess: the two cards show', (
      tester,
    ) async {
      final settings = ValueNotifier<PlayerSettings>(const PlayerSettings());
      final isHdr = ValueNotifier<bool?>(null);
      addTearDown(settings.dispose);
      addTearDown(isHdr.dispose);
      await pumpDrawer(tester, settings: settings, isHdr: isHdr);
      expect(find.byKey(bright), findsOneWidget);
      expect(find.byKey(balanced), findsOneWidget);
    });

    testWidgets('tapping a card fires onPresetPicked with it', (tester) async {
      final settings = ValueNotifier<PlayerSettings>(const PlayerSettings());
      addTearDown(settings.dispose);
      final picked = <VideoOutputPreset>[];
      await pumpDrawer(tester, settings: settings, onPresetPicked: picked.add);
      await tester.tap(find.text('Balanced'));
      await tester.pump();
      await tester.tap(find.text('Bright'));
      await tester.pump();
      expect(picked, <VideoOutputPreset>[
        VideoOutputPreset.sdrToneMapped,
        VideoOutputPreset.nativeEdr,
      ]);
    });

    testWidgets('the checkmark follows the active choice', (tester) async {
      final settings = ValueNotifier<PlayerSettings>(const PlayerSettings());
      addTearDown(settings.dispose);
      await pumpDrawer(tester, settings: settings);
      expect(tileChecked(bright), isTrue);
      expect(tileChecked(balanced), isFalse);
      settings.value = settings.value.copyWith(
        videoOutputPreset: VideoOutputPreset.sdrToneMapped,
      );
      await tester.pump();
      expect(tileChecked(bright), isFalse);
      expect(tileChecked(balanced), isTrue);
    });

    testWidgets('the sliders open on the saved values', (tester) async {
      final settings = ValueNotifier<PlayerSettings>(
        const PlayerSettings().copyWith(
          pictureBrightness: 10,
          pictureContrast: -5,
          pictureSaturation: 0,
        ),
      );
      addTearDown(settings.dispose);
      await pumpDrawer(tester, settings: settings);
      expect(find.text('+10'), findsOneWidget);
      expect(find.text('-5'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
      expect([for (final s in sliders) s.value], [10.0, -5.0, 0.0]);
      expect(sliders.every((s) => s.min == -50 && s.max == 50), isTrue);
    });

    testWidgets('dragging applies live and persists when the drag ends', (
      tester,
    ) async {
      final settings = ValueNotifier<PlayerSettings>(const PlayerSettings());
      addTearDown(settings.dispose);
      final recorder = _RecordingPicture();
      final live = <PictureValues>[];
      await pumpDrawer(
        tester,
        settings: settings,
        onPictureChanged: live.add,
        recorder: recorder,
      );
      final slider = find.descendant(
        of: find.byKey(const ValueKey('video-picture-brightness')),
        matching: find.byType(Slider),
      );
      await tester.drag(slider, const Offset(60, 0));
      await tester.pumpAndSettle();
      expect(live, isNotEmpty);
      expect(live.last.brightness, greaterThan(0));
      expect(live.last.contrast, 0);
      expect(live.last.saturation, 0);
      expect(recorder.brightness, isNotEmpty);
      expect(recorder.brightness.last, live.last.brightness);
      expect(recorder.contrast, isEmpty);
      expect(recorder.saturation, isEmpty);
    });

    testWidgets('Reset sets the three to zero, live and saved', (tester) async {
      final settings = ValueNotifier<PlayerSettings>(
        const PlayerSettings().copyWith(
          pictureBrightness: 10,
          pictureContrast: -5,
          pictureSaturation: 20,
        ),
      );
      addTearDown(settings.dispose);
      final recorder = _RecordingPicture();
      final live = <PictureValues>[];
      await pumpDrawer(
        tester,
        settings: settings,
        onPictureChanged: live.add,
        recorder: recorder,
      );
      await tester.tap(find.byKey(const ValueKey('video-picture-reset')));
      await tester.pump();
      expect(live.last, (brightness: 0, contrast: 0, saturation: 0));
      expect(recorder.brightness, [0]);
      expect(recorder.contrast, [0]);
      expect(recorder.saturation, [0]);
      final sliders = tester.widgetList<Slider>(find.byType(Slider));
      expect([for (final s in sliders) s.value], [0.0, 0.0, 0.0]);
    });
  });
}

/// A settings notifier that records the PICTURE writes instead of
/// persisting them.
class _RecordingPicture extends PlayerSettingsNotifier {
  final List<int> brightness = <int>[];
  final List<int> contrast = <int>[];
  final List<int> saturation = <int>[];

  @override
  Future<PlayerSettings> build() async => const PlayerSettings();

  @override
  Future<void> setPictureBrightness(int value) async {
    brightness.add(value);
  }

  @override
  Future<void> setPictureContrast(int value) async {
    contrast.add(value);
  }

  @override
  Future<void> setPictureSaturation(int value) async {
    saturation.add(value);
  }
}
