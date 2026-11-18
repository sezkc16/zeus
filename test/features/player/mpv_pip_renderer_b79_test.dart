// Build 79: a renderer move lands exactly on the playhead when the
// phone still holds the film around it (the stream cache proxy), and
// on the keyframe before it otherwise (build 76).
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_pip_renderer.dart';

const _mb = 1024 * 1024;

void main() {
  group('exactLandingForMove', () {
    test('on the proxy with the playhead well inside what is held', () {
      expect(
        exactLandingForMove(
          proxyServing: true,
          behind: 300 * _mb,
          forwardBytes: 200 * _mb,
        ),
        isTrue,
      );
    });

    test('not when the film is not on the proxy', () {
      expect(
        exactLandingForMove(
          proxyServing: false,
          behind: 300 * _mb,
          forwardBytes: 10 * _mb,
        ),
        isFalse,
      );
    });

    test('not when the playhead is before what is held', () {
      // The player had read 200 MB ahead; the phone holds only 150 MB
      // behind the reading point: the playhead's bytes are gone.
      expect(
        exactLandingForMove(
          proxyServing: true,
          behind: 150 * _mb,
          forwardBytes: 200 * _mb,
        ),
        isFalse,
      );
    });

    test('a margin is kept for what sits between player and proxy', () {
      expect(
        exactLandingForMove(
          proxyServing: true,
          behind: 200 * _mb + 4 * _mb,
          forwardBytes: 200 * _mb,
        ),
        isFalse,
      );
      expect(
        exactLandingForMove(
          proxyServing: true,
          behind: 200 * _mb + 200 * _mb ~/ 32 + 8 * _mb,
          forwardBytes: 200 * _mb,
        ),
        isTrue,
      );
    });

    test('just after an open: a few MB played is enough', () {
      expect(
        exactLandingForMove(
          proxyServing: true,
          behind: 13 * _mb,
          forwardBytes: 3 * _mb,
        ),
        isTrue,
      );
      expect(
        exactLandingForMove(
          proxyServing: true,
          behind: 5 * _mb,
          forwardBytes: 3 * _mb,
        ),
        isFalse,
      );
    });

    test('anything unknown: no', () {
      expect(
        exactLandingForMove(
          proxyServing: true,
          behind: null,
          forwardBytes: 1,
        ),
        isFalse,
      );
      expect(
        exactLandingForMove(
          proxyServing: true,
          behind: 300 * _mb,
          forwardBytes: null,
        ),
        isFalse,
      );
      expect(
        exactLandingForMove(proxyServing: true, behind: 0, forwardBytes: 0),
        isFalse,
      );
      expect(
        exactLandingForMove(
          proxyServing: true,
          behind: 300 * _mb,
          forwardBytes: -1,
        ),
        isFalse,
      );
    });
  });

  group('exactSeekCommand', () {
    test('an exact absolute seek to the millisecond', () {
      expect(
        exactSeekCommand(const Duration(minutes: 30, milliseconds: 15042)),
        <String>['seek', '1815.042', 'absolute+exact'],
      );
    });

    test('differs from the keyframe landing only in the flag', () {
      const place = Duration(seconds: 90);
      final exact = exactSeekCommand(place);
      final key = keyframeSeekCommand(place);
      expect(exact.sublist(0, 2), key.sublist(0, 2));
      expect(key.last, 'absolute+keyframes');
      expect(exact.last, 'absolute+exact');
    });
  });

  group('exactLandingNote', () {
    test('the same frame reads +0.00s', () {
      expect(
        exactLandingNote(
          before: const Duration(seconds: 100),
          after: const Duration(seconds: 100),
        ),
        ' exact +0.00s',
      );
    });

    test('a frame either way is shown to the hundredth', () {
      expect(
        exactLandingNote(
          before: const Duration(milliseconds: 100000),
          after: const Duration(milliseconds: 100042),
        ),
        ' exact +0.04s',
      );
      expect(
        exactLandingNote(
          before: const Duration(milliseconds: 100000),
          after: const Duration(milliseconds: 99958),
        ),
        ' exact -0.04s',
      );
    });

    test('place not read', () {
      expect(
        exactLandingNote(before: null, after: const Duration(seconds: 1)),
        ' exact ?',
      );
      expect(
        exactLandingNote(before: const Duration(seconds: 1), after: null),
        ' exact ?',
      );
    });

    test('it sits on the switch-wait line where the keyframe note did', () {
      final line = switchWaitLine(
        wait: const SwitchWait(
          netMs: 12,
          decodeMs: 480,
          gotBytes: 6 * _mb,
          seeks: 1,
          requests: 1,
        ),
        cacheBefore: '36.3',
        cacheAfter: '1.2',
        paused: true,
        extra:
            '${exactLandingNote(before: const Duration(seconds: 100), after: const Duration(seconds: 100))}'
            ' src local',
      );
      expect(line, contains('net 12 dec 480'));
      expect(line, endsWith('paused yes exact +0.00s src local'));
    });
  });

  test('the keyframe landing still reads as in build 76', () {
    expect(
      keyframeLandingNote(
        used: true,
        before: const Duration(milliseconds: 100000),
        after: const Duration(milliseconds: 98600),
      ),
      ' key -1.4s',
    );
  });
}
