// Build 75: the film is held for an in-place renderer move, and the
// picture wait is split for the QoE overlay.
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_pip_renderer.dart';

void main() {
  group('pauseForInPlaceMove', () {
    test('a playing film is held', () {
      expect(pauseForInPlaceMove(playing: true), isTrue);
    });
    test('a paused film is left alone', () {
      expect(pauseForInPlaceMove(playing: false), isFalse);
    });
  });

  group('splitSwitchWait', () {
    test('the seek lands at the first sample behind the old place', () {
      final split = splitSwitchWait(
        beforePos: 1000000,
        samples: const [
          (50, 1000000),
          (100, 1000000),
          (900, 400000),
          (1500, 700000),
        ],
        frameMs: 1500,
      );
      expect(split.netMs, 900);
      expect(split.decodeMs, 600);
      expect(split.backBytes, 600000);
      expect(split.fetchedBytes, 300000);
    });
    test('no jump back seen reads unknown', () {
      final split = splitSwitchWait(
        beforePos: 1000,
        samples: const [(50, 1000), (100, 1200)],
        frameMs: 100,
      );
      expect(split.netMs, isNull);
      expect(split.decodeMs, isNull);
    });
    test('no place before the move reads unknown', () {
      final split = splitSwitchWait(
        beforePos: null,
        samples: const [(50, 10)],
        frameMs: 50,
      );
      expect(split.netMs, isNull);
      expect(split.backBytes, isNull);
    });
    test('no samples at all', () {
      final split = splitSwitchWait(
        beforePos: 5,
        samples: const [],
        frameMs: 0,
      );
      expect(split.netMs, isNull);
    });
  });

  group('switchDetailLine', () {
    test('nothing yet', () {
      expect(
        switchDetailLine(
          split: null,
          cacheBefore: null,
          cacheAfter: null,
          paused: false,
        ),
        'switch-wait: -',
      );
    });
    test('a measured wait', () {
      expect(
        switchDetailLine(
          split: const SwitchWaitSplit(
            netMs: 900,
            decodeMs: 600,
            backBytes: 3 * 1024 * 1024,
            fetchedBytes: 5 * 1024 * 1024 + 512 * 1024,
          ),
          cacheBefore: '61.959000',
          cacheAfter: '0.84',
          paused: true,
        ),
        'switch-wait: net 900 dec 600 back 3.0MB got 5.5MB '
        'cache 62.0>0.8s paused yes',
      );
    });
    test('unknown parts read ?', () {
      expect(
        switchDetailLine(
          split: const SwitchWaitSplit(
            netMs: null,
            decodeMs: null,
            backBytes: null,
            fetchedBytes: null,
          ),
          cacheBefore: null,
          cacheAfter: 'x',
          paused: false,
        ),
        'switch-wait: net ? dec ? back ? got ? cache ?>?s paused no',
      );
    });
  });
}
