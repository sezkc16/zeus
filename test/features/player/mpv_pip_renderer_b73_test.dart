// Build 73: the pure decisions behind the fast renderer move, the small
// PiP render and "PiP only from the button".
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_ios_options.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_pip_renderer.dart';

void main() {
  group('softwareRenderSize', () {
    RenderSize? size(int? w, int? h) => softwareRenderSize(
          videoWidth: w,
          videoHeight: h,
          is4K: is4KVideo(width: w, height: h),
        );

    test('a 4K film is drawn 960 wide with its own aspect', () {
      expect(size(3840, 2160), const RenderSize(960, 540));
      // Scope 4K (the 22 GB file's shape): not squeezed into 16:9.
      expect(size(3840, 1600), const RenderSize(960, 400));
      expect(size(3840, 1608), const RenderSize(960, 402));
      // DCI 4K.
      expect(size(4096, 2160), const RenderSize(960, 506));
    });

    test('both sides are always even', () {
      for (final h in <int>[1596, 1598, 1600, 1604, 1610, 1634, 2076]) {
        final s = size(3840, h)!;
        expect(s.width.isEven, isTrue);
        expect(s.height.isEven, isTrue, reason: 'height for $h');
      }
    });

    test('below 4K keeps its own size: it stays on software full screen', () {
      expect(size(1920, 1080), isNull);
      expect(size(2560, 1440), isNull);
      expect(size(1280, 720), isNull);
    });

    test('an unknown size is never shrunk', () {
      expect(size(null, null), isNull);
      expect(size(0, 0), isNull);
      expect(
        softwareRenderSize(videoWidth: null, videoHeight: null, is4K: true),
        isNull,
      );
    });

    test('shrinks exactly the films that go back to hardware after PiP', () {
      for (final (w, h) in <(int, int)>[
        (3840, 2160),
        (3840, 1600),
        (2560, 1440),
        (1920, 1080),
        (1920, 800),
      ]) {
        final is4K = is4KVideo(width: w, height: h);
        expect(
          size(w, h) != null,
          pipEndNeedsHardware(is4K: is4K, qualityDropped: false),
          reason: '${w}x$h',
        );
      }
    });
  });

  group('pipBridgeWanted', () {
    test('the native controller exists only for a window', () {
      expect(pipBridgeWanted(entering: false, windowUp: false), isFalse);
      expect(pipBridgeWanted(entering: true, windowUp: false), isTrue);
      expect(pipBridgeWanted(entering: false, windowUp: true), isTrue);
    });
  });

  group('pipEndPauses', () {
    test('tapping the window back into the player never pauses', () {
      expect(pipEndPauses(restored: true, appForeground: false), isFalse);
      expect(pipEndPauses(restored: true, appForeground: true), isFalse);
    });

    test('closing the window in the background pauses', () {
      expect(pipEndPauses(restored: false, appForeground: false), isTrue);
    });

    test('a window that ends in the foreground keeps playing', () {
      expect(pipEndPauses(restored: false, appForeground: true), isFalse);
    });
  });

  group('the move back from PiP', () {
    RendererCarryOver carry({required bool wasPlaying}) => RendererCarryOver(
          position: const Duration(minutes: 24, seconds: 50),
          duration: const Duration(hours: 3, minutes: 4, seconds: 50),
          wasPlaying: wasPlaying,
          rate: 1,
          volume: 100,
          streamIndex: 0,
        );

    test('a film playing in the window plays again by itself', () {
      expect(carry(wasPlaying: true).autoPlay(toSoftware: false), isTrue);
    });

    test('a film paused in the window comes back paused', () {
      expect(carry(wasPlaying: false).autoPlay(toSoftware: false), isFalse);
    });

    test('a foreground return moves at once, a background end waits', () {
      expect(
        pipEndPlan(
          phase: MpvRendererPhase.software,
          pipWindowUp: false,
          appResumed: true,
          needsHardware: true,
        ),
        PipEndPlan.switchNow,
      );
      expect(
        pipEndPlan(
          phase: MpvRendererPhase.software,
          pipWindowUp: false,
          appResumed: false,
          needsHardware: true,
        ),
        PipEndPlan.pauseAndDefer,
      );
    });
  });

  group('switchTimingLine', () {
    test('no move yet', () {
      expect(
        switchTimingLine(direction: '', steps: const {}, outcome: ''),
        'switch: -',
      );
    });

    test('lists every step and the total', () {
      expect(
        switchTimingLine(
          direction: '>hw',
          steps: const {'hold': 4, 'new': 310, 'open': 620, 'frame': 540},
          outcome: 'ok',
        ),
        'switch >hw: hold 4 new 310 open 620 frame 540 = 1474ms ok',
      );
    });
  });
}
