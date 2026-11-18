// Build 76: the picture wait of an in-place renderer move is split
// from mpv's `demuxer-cache-state` (build 75 read `stream-pos`, which
// never moves back, and every figure came out "?").
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_pip_renderer.dart';

String _state({
  required int seeks,
  required int requests,
  required int fw,
  required int total,
}) =>
    '{"cache-end":123.4,"reader-pts":120.0,"cache-duration":3.4,"eof":false,'
    '"underrun":false,"idle":false,"total-bytes":$total,"fw-bytes":$fw,'
    '"raw-input-rate":5767168,"debug-low-level-seeks":$seeks,'
    '"debug-byte-level-seeks":$requests,"debug-ts-last":123.4,'
    '"bof-cached":false,"eof-cached":false,'
    '"seekable-ranges":[{"start":119.0,"end":123.4}]}';

void main() {
  group('parseDemuxState', () {
    test('reads the counters out of what mpv prints', () {
      final sample = parseDemuxState(
        _state(seeks: 3, requests: 5, fw: 1048576, total: 2097152),
        ms: 40,
      )!;
      expect(sample.ms, 40);
      expect(sample.lowLevelSeeks, 3);
      expect(sample.byteLevelSeeks, 5);
      expect(sample.forwardBytes, 1048576);
      expect(sample.totalBytes, 2097152);
    });

    test('anything else is no sample', () {
      expect(parseDemuxState(null, ms: 0), isNull);
      expect(parseDemuxState('', ms: 0), isNull);
      expect(parseDemuxState('null', ms: 0), isNull);
      expect(parseDemuxState('{"eof":false}', ms: 0), isNull);
    });
  });

  group('splitSwitchWaitByDemux', () {
    DemuxSample at(
      int ms, {
      int seeks = 3,
      int requests = 5,
      int fw = 0,
      int total = 0,
    }) => parseDemuxState(
      _state(seeks: seeks, requests: requests, fw: fw, total: total),
      ms: ms,
    )!;

    test('net ends at the first data after the seek, dec is the rest', () {
      final wait = splitSwitchWaitByDemux(
        before: at(0, seeks: 2, requests: 4, fw: 90000000, total: 95000000),
        samples: [
          // The track is on; the old buffer is still there.
          at(50, seeks: 2, requests: 4, fw: 90000000, total: 95000000),
          // The seek: the buffer is emptied.
          at(100),
          at(900),
          // The host answers.
          at(950, requests: 6, fw: 400000, total: 400000),
          at(1400, requests: 6, fw: 3000000, total: 3145728),
        ],
        frameMs: 1400,
      );
      expect(wait.netMs, 950);
      expect(wait.decodeMs, 450);
      expect(wait.gotBytes, 3145728);
      expect(wait.seeks, 1);
      expect(wait.requests, 2);
    });

    test('the old buffer, before the seek is seen, is not "data"', () {
      final wait = splitSwitchWaitByDemux(
        before: at(0, seeks: 2, fw: 90000000, total: 95000000),
        samples: [at(50, seeks: 2, fw: 90000000, total: 95000000)],
        frameMs: 60,
      );
      expect(wait.netMs, isNull);
      expect(wait.decodeMs, isNull);
      expect(wait.seeks, 0);
    });

    test('nothing sampled: nothing claimed', () {
      final wait = splitSwitchWaitByDemux(
        before: null,
        samples: const [],
        frameMs: 500,
      );
      expect(wait.netMs, isNull);
      expect(wait.gotBytes, isNull);
    });
  });

  group('switchWaitLine', () {
    test('reads as the overlay shows it', () {
      expect(
        switchWaitLine(
          wait: const SwitchWait(
            netMs: 950,
            decodeMs: 450,
            gotBytes: 3145728,
            seeks: 1,
            requests: 2,
          ),
          cacheBefore: '44.1',
          cacheAfter: '0.4',
          paused: true,
        ),
        'switch-wait: net 950 dec 450 got 3.0MB seek 1/2 '
        'cache 44.1>0.4s paused yes',
      );
    });

    test('unknowns stay unknown, no move stays a dash', () {
      expect(
        switchWaitLine(
          wait: const SwitchWait(
            netMs: null,
            decodeMs: null,
            gotBytes: null,
            seeks: null,
            requests: null,
          ),
          cacheBefore: null,
          cacheAfter: null,
          paused: false,
        ),
        'switch-wait: net ? dec ? got ? seek ?/? cache ?>?s paused no',
      );
      expect(
        switchWaitLine(
          wait: null,
          cacheBefore: null,
          cacheAfter: null,
          paused: false,
        ),
        'switch-wait: -',
      );
    });
  });

  group('keyframe landing', () {
    test('only a film with a known place that can be seeked', () {
      expect(
        keyframeLandingForMove(
          seekable: true,
          position: const Duration(minutes: 29, seconds: 31),
        ),
        isTrue,
      );
      expect(
        keyframeLandingForMove(seekable: false, position: Duration.zero),
        isFalse,
      );
      expect(
        keyframeLandingForMove(
          seekable: false,
          position: const Duration(minutes: 1),
        ),
        isFalse,
      );
      expect(keyframeLandingForMove(seekable: true, position: null), isFalse);
      expect(
        keyframeLandingForMove(seekable: true, position: Duration.zero),
        isFalse,
      );
    });

    test('the command lands at or before the place, on a keyframe', () {
      expect(
        keyframeSeekCommand(
          const Duration(minutes: 29, seconds: 31, milliseconds: 250),
        ),
        ['seek', '1771.250', 'absolute+keyframes'],
      );
    });

    test('time-pos as mpv prints it', () {
      expect(mpvTimePos('1771.250000'), const Duration(milliseconds: 1771250));
      expect(mpvTimePos(''), isNull);
      expect(mpvTimePos(null), isNull);
      expect(mpvTimePos('-1'), isNull);
    });

    test('the note says how far back the film continued', () {
      expect(
        keyframeLandingNote(
          used: true,
          before: const Duration(milliseconds: 1771250),
          after: const Duration(milliseconds: 1769450),
        ),
        ' key -1.8s',
      );
      expect(
        keyframeLandingNote(used: true, before: null, after: null),
        ' key ?',
      );
      expect(
        keyframeLandingNote(
          used: false,
          before: const Duration(seconds: 5),
          after: const Duration(seconds: 5),
        ),
        ' key off',
      );
    });
  });
}
