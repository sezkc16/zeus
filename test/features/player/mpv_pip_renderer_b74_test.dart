// Build 74: the pure decisions behind the in-place renderer swap and
// its overlay diagnostics.
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_pip_renderer.dart';

void main() {
  group('rendererMoveRoute', () {
    test('the same stream is moved in place', () {
      expect(
        rendererMoveRoute(qualityDropped: false),
        RendererMoveRoute.inPlace,
      );
    });
    test('a PiP quality drop in force needs the re-open', () {
      expect(
        rendererMoveRoute(qualityDropped: true),
        RendererMoveRoute.reopen,
      );
    });
  });

  group('inPlaceVideoTrack', () {
    test('keeps the selected track number', () {
      expect(inPlaceVideoTrack('1'), '1');
      expect(inPlaceVideoTrack(' 2 '), '2');
    });
    test('falls back to auto', () {
      expect(inPlaceVideoTrack(null), 'auto');
      expect(inPlaceVideoTrack(''), 'auto');
      expect(inPlaceVideoTrack('no'), 'auto');
      expect(inPlaceVideoTrack('auto'), 'auto');
      expect(inPlaceVideoTrack('0'), 'auto');
    });
  });

  group('voConfigured', () {
    test('reads mpv flags', () {
      expect(voConfigured('yes'), isTrue);
      expect(voConfigured('true'), isTrue);
      expect(voConfigured(' YES '), isTrue);
      expect(voConfigured('no'), isFalse);
      expect(voConfigured(''), isFalse);
      expect(voConfigured(null), isFalse);
    });
  });

  group('switchWaitReason', () {
    test('no data at all (the build 73 return)', () {
      expect(
        switchWaitReason(
          voConfiguredRaw: 'no',
          cacheSeconds: '0.000000',
          pausedForCache: 'yes',
          cacheSpeed: '1024',
        ),
        'vo=no cache=0.0s net=1K pfc=yes',
      );
    });
    test('data but no frame', () {
      expect(
        switchWaitReason(
          voConfiguredRaw: 'no',
          cacheSeconds: '12.34',
          pausedForCache: 'no',
          cacheSpeed: '2097152',
        ),
        'vo=no cache=12.3s net=2048K pfc=no',
      );
    });
    test('unreadable values', () {
      expect(
        switchWaitReason(
          voConfiguredRaw: null,
          cacheSeconds: null,
          pausedForCache: null,
          cacheSpeed: null,
        ),
        'vo=no cache=?s net=?K pfc=no',
      );
    });
  });

  group('pipFeedLine', () {
    test('nothing read', () {
      expect(pipFeedLine(null), 'pip-feed: -');
      expect(pipFeedLine('  '), 'pip-feed: -');
    });
    test('picks the feed counters out of the native diag', () {
      expect(
        pipFeedLine(
          'state=live ingest=120 liveEnq=118 liveDrop=2 primes=3 '
          'layerFail=0 upd=130 rend=120 rendMs=9',
        ),
        'pip-feed: in 120 shown 118 drop 2 fail 0 render 9ms',
      );
    });
    test('a missing counter reads ?', () {
      expect(
        pipFeedLine('ingest=0 liveEnq=0'),
        'pip-feed: in 0 shown 0 drop ? fail ? render ?ms',
      );
    });
  });

  test('the timing line carries the in-place steps', () {
    expect(
      switchTimingLine(
        direction: '>sw',
        steps: const {'hold': 5, 'swap': 60, 'vid': 10, 'frame': 900},
        outcome: 'ok',
      ),
      'switch >sw: hold 5 swap 60 vid 10 frame 900 = 975ms ok',
    );
  });
}
