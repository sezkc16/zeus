// Build 78: the overlay's rate figures, and the watch that sends a film
// that keeps buffering through the proxy back to its host.

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/services/stream_cache/stream_cache_proxy.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_stream_proxy.dart';

const int mib = 1024 * 1024;

void main() {
  group('the overlay line', () {
    test('adds side reads, host and player rates, and what waits for the '
        'disk', () {
      const total = 22880 * mib;
      const duration = Duration(hours: 3);
      final line = streamProxyOverlayLine(
        opened: true,
        bypassReason: null,
        stats: StreamCacheStats(
          held: 412 * mib,
          ahead: 0,
          total: total,
          hits: 1,
          misses: 1,
          dead: false,
          reason: null,
          requests: const <StreamCacheRequest>[],
          hostRate: (5.5 * mib).round(),
          clientRate: (5.25 * mib).round(),
          unwritten: 3 * mib,
          sides: 1,
        ),
        duration: duration,
      );
      expect(
        line,
        'proxy: on held 412MB ahead 0s hit 1 miss 1 side 1 '
        'host 5.5 out 5.3 MiB/s mem 3MB',
      );
    });

    test('a film sent back to its host for being slow says so', () {
      expect(
        streamProxyOverlayLine(
          opened: false,
          bypassReason: 'slow',
          stats: null,
          duration: Duration.zero,
        ),
        'proxy: off(slow)',
      );
    });

    test('the new figures survive the trip through a message port', () {
      final back = StreamCacheStats.fromMap(
        const StreamCacheStats(
          held: 1,
          ahead: 2,
          total: 3,
          hits: 4,
          misses: 5,
          dead: false,
          reason: null,
          requests: <StreamCacheRequest>[],
          hostRate: 6,
          clientRate: 7,
          unwritten: 8,
          sides: 9,
        ).toMap(),
      )!;
      expect(back.hostRate, 6);
      expect(back.clientRate, 7);
      expect(back.unwritten, 8);
      expect(back.sides, 9);
    });

    test('figures from an older proxy read as zero', () {
      final back = StreamCacheStats.fromMap(<String, Object?>{
        'held': 1,
        'ahead': 0,
        'hits': 0,
        'misses': 1,
        'dead': false,
      })!;
      expect(back.hostRate, 0);
      expect(back.sides, 0);
    });
  });

  group('a source marked slow', () {
    test('opens straight from the host, and says why', () {
      expect(
        streamProxyBypassReason(
          isIos: true,
          stream: const StreamResult(
            url: 'https://cdn.example/film.mkv',
            source: 'FSLv2',
          ),
          item: MultimediaItem(
            title: 'A Film',
            url: 'https://example.com/film',
            posterUrl: '',
            contentType: MultimediaContentType.movie,
            provider: 'Remote',
          ),
          blocked: true,
          slow: true,
        ),
        'slow',
      );
    });
  });

  group('the slow watch', () {
    const p = Duration(seconds: 30);

    test('does nothing until a film is on the proxy', () {
      final watch = StreamProxySlowWatch();
      expect(
        watch.onBuffering(buffering: true, position: p, nowMs: 100000),
        isFalse,
      );
      expect(watch.onTick(buffering: true, position: p, nowMs: 200000), isFalse);
    });

    test('what build 77 did on the phone — a stop every two seconds — '
        'trips it on the third stop', () {
      final watch = StreamProxySlowWatch()..arm(0);
      var position = const Duration(seconds: 5);
      var tripped = false;
      var at = 5000;
      var stops = 0;
      while (!tripped && stops < 10) {
        stops++;
        tripped = watch.onBuffering(
          buffering: true,
          position: position,
          nowMs: at,
        );
        if (tripped) break;
        at += 1200;
        watch.onBuffering(buffering: false, position: position, nowMs: at);
        at += 800;
        position += const Duration(milliseconds: 800);
      }
      expect(tripped, isTrue);
      expect(stops, 3);
    });

    test('the opening seconds do not count', () {
      final watch = StreamProxySlowWatch()..arm(0);
      for (final at in <int>[500, 1500, 2500, 3500]) {
        expect(
          watch.onBuffering(buffering: true, position: p, nowMs: at),
          isFalse,
        );
        watch.onBuffering(buffering: false, position: p, nowMs: at + 300);
      }
    });

    test('one or two stops in the window are not enough, and old stops '
        'are forgotten', () {
      final watch = StreamProxySlowWatch()..arm(0);
      var at = 10000;
      for (var i = 0; i < 6; i++) {
        expect(
          watch.onBuffering(buffering: true, position: p, nowMs: at),
          isFalse,
          reason: 'stop $i',
        );
        watch.onBuffering(buffering: false, position: p, nowMs: at + 500);
        // One stop every 15 s: never three inside 20 s.
        at += 15000;
      }
    });

    test('a seek buffers once and starts the count again', () {
      final watch = StreamProxySlowWatch()..arm(0);
      watch.onBuffering(buffering: true, position: p, nowMs: 10000);
      watch.onBuffering(buffering: false, position: p, nowMs: 10500);
      watch.onBuffering(buffering: true, position: p, nowMs: 12000);
      watch.onBuffering(buffering: false, position: p, nowMs: 12500);
      // The viewer jumps ten minutes on: that buffering is the seek's.
      const there = Duration(minutes: 10, seconds: 30);
      expect(
        watch.onBuffering(buffering: true, position: there, nowMs: 14000),
        isFalse,
      );
      watch.onBuffering(buffering: false, position: there, nowMs: 15000);
      // And the two stops before it are forgotten.
      expect(
        watch.onBuffering(buffering: true, position: there, nowMs: 19500),
        isFalse,
      );
    });

    test('one stop that does not end trips it on a tick', () {
      final watch = StreamProxySlowWatch()..arm(0);
      watch.onBuffering(buffering: true, position: p, nowMs: 10000);
      expect(watch.onTick(buffering: true, position: p, nowMs: 12000), isFalse);
      expect(watch.onTick(buffering: true, position: p, nowMs: 16000), isFalse);
      expect(watch.onTick(buffering: true, position: p, nowMs: 18000), isTrue);
    });

    test('a tick while the film plays does nothing', () {
      final watch = StreamProxySlowWatch()..arm(0);
      var position = p;
      for (var at = 6000; at < 60000; at += 2000) {
        position += const Duration(seconds: 2);
        expect(
          watch.onTick(buffering: false, position: position, nowMs: at),
          isFalse,
        );
      }
    });

    test('disarmed, it stays quiet', () {
      final watch = StreamProxySlowWatch()
        ..arm(0)
        ..disarm();
      for (final at in <int>[10000, 11000, 12000, 13000]) {
        expect(
          watch.onBuffering(buffering: true, position: p, nowMs: at),
          isFalse,
        );
        watch.onBuffering(buffering: false, position: p, nowMs: at + 100);
      }
    });
  });
}
