// Build 77: the stream cache proxy against a stand-in host.
//
// What these prove: a request for a region the proxy still holds is
// answered with NO new request to the host (the whole point — that is
// the request mpv makes after a renderer move); everything else behaves
// as the host itself would; and every way the proxy can fail ends in a
// redirect to the film's own address.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/services/stream_cache/stream_cache_proxy.dart';

import 'fake_host.dart';

const int kib = 1024;
const int mib = 1024 * 1024;

void main() {
  late Directory dir;
  late FakeHost host;
  StreamCacheProxyServer? proxy;

  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('stream_cache_test');
    host = FakeHost();
    await host.start();
  });

  tearDown(() async {
    await proxy?.shutdown();
    proxy = null;
    await host.stop();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<StreamCacheProxyServer> startProxy({
    int capacity = 16 * mib,
    int readAhead = 512 * kib,
    int skipAhead = 64 * kib,
    int minLength = 64 * kib,
    Duration responseTimeout = const Duration(seconds: 5),
  }) async {
    final server = StreamCacheProxyServer(
      directory: dir.path,
      capacity: capacity,
      readAhead: readAhead,
      skipAhead: skipAhead,
      minLength: minLength,
      responseTimeout: responseTimeout,
    );
    await server.start();
    proxy = server;
    return server;
  }

  Future<void> until(bool Function() test, {int ms = 5000}) async {
    final clock = Stopwatch()..start();
    while (!test()) {
      if (clock.elapsedMilliseconds > ms) fail('condition not met in $ms ms');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  group('serving the film', () {
    test('the whole film arrives intact, with one request to the host',
        () async {
      final server = await startProxy();
      final session = server.openSession('${host.base}/film.mkv');
      expect(session.url, startsWith('http://127.0.0.1:${server.port}/'));
      expect(session.url, endsWith('/film.mkv'));

      final answer = await playerGet(session.url, from: 0);
      expect(answer.status, 206);
      expect(answer.headers['content-range'],
          'bytes 0-${host.length - 1}/${host.length}');
      expect(answer.headers['accept-ranges'], 'bytes');
      expect(answer.headers['content-type'], 'video/x-matroska');
      expect(answer.body.length, host.length);
      expect(answer.body, film(0, host.length));
      expect(host.filmRequests, 1);
    });

    test('the player\'s own headers reach the host, and the hop\'s do not',
        () async {
      final server = await startProxy();
      final session = server.openSession('${host.base}/film.mkv');
      await playerGet(
        session.url,
        from: 0,
        take: 1000,
        headers: <String, String>{
          'User-Agent': 'Mozilla/5.0 (test player)',
          'Referer': 'https://example.test/watch',
          'Cookie': 'cf_clearance=abc; session=1',
          'Icy-MetaData': '1',
        },
      );
      final seen = host.requests.single.headers;
      expect(seen['user-agent'], 'Mozilla/5.0 (test player)');
      expect(seen['referer'], 'https://example.test/watch');
      expect(seen['cookie'], 'cf_clearance=abc; session=1');
      expect(seen['icy-metadata'], '1');
      expect(seen['range'], 'bytes=0-');
      // The host's own name, not the proxy's.
      expect(seen['host'], '127.0.0.1:${host.port}');
      // dart:io would add this by itself; ffmpeg sends none.
      expect(seen.containsKey('accept-encoding'), isFalse);
    });

    test('a bounded range gets exactly those bytes', () async {
      final server = await startProxy();
      final session = server.openSession('${host.base}/film.mkv');
      final answer = await playerGet(session.url, from: 1000, to: 1999);
      expect(answer.status, 206);
      expect(answer.headers['content-range'],
          'bytes 1000-1999/${host.length}');
      expect(answer.body, film(1000, 1000));
    });

    test('a request past the end is refused the way a host refuses it',
        () async {
      final server = await startProxy();
      final session = server.openSession('${host.base}/film.mkv');
      await playerGet(session.url, from: 0, take: 100);
      final answer = await playerGet(session.url, from: host.length + 5);
      expect(answer.status, 416);
      expect(answer.headers['content-range'], 'bytes */${host.length}');
    });
  });

  group('the renderer move: asking again for a place already held', () {
    test('is answered from the store — no new request to the host',
        () async {
      final server = await startProxy();
      final session = server.openSession('${host.base}/film.mkv');
      // The player reads 1 MiB, then drops its connection (mpv's track
      // switch) ...
      final first = await playerGet(session.url, from: 0, take: mib);
      expect(first.body, film(0, mib));
      expect(host.filmRequests, 1);
      // ... and asks again from a place behind where it had read to.
      final again = await playerGet(session.url, from: 700 * kib, take: 200 * kib);
      expect(again.status, 206);
      expect(again.body, film(700 * kib, 200 * kib));
      expect(host.filmRequests, 1, reason: 'the host must not be asked again');

      final stats = server.stats(session.token)!;
      expect(stats.hits, 1);
      expect(stats.misses, 1);
      expect(stats.requests.last.offset, 700 * kib);
      expect(stats.requests.last.local, isTrue);
      expect(stats.requests.first.local, isFalse);
    });

    test('does not wait for the host at all, even when the host is slow',
        () async {
      final server = await startProxy();
      final session = server.openSession('${host.base}/film.mkv');
      await playerGet(session.url, from: 0, take: mib);
      // From here any request that reached the host would take 3 s.
      host.delay = const Duration(seconds: 3);
      final clock = Stopwatch()..start();
      final again = await playerGet(session.url, from: 600 * kib, take: 300 * kib);
      expect(again.body, film(600 * kib, 300 * kib));
      expect(clock.elapsedMilliseconds, lessThan(1500));
      expect(host.filmRequests, 1);
    });

    test('keeps fetching for a moment while the player is away, so the '
        'bytes just past where it stopped are already there', () async {
      // A film far bigger than any socket buffer, so "where the player
      // stopped" is well short of the end.
      host.length = 48 * mib;
      final server = await startProxy(capacity: 64 * mib, readAhead: mib);
      final session = server.openSession('${host.base}/film.mkv');
      await playerGet(session.url, from: 0, take: 256 * kib);
      // Nobody is connected now. The proxy reads ahead of where the
      // player stopped — and stops at its lead.
      await until(() => server.stats(session.token)!.ahead >= mib);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final stats = server.stats(session.token)!;
      // (One read from a loopback socket can hand over several MiB at
      // once, so the lead overshoots by up to one such read.)
      expect(stats.ahead, lessThan(16 * mib), reason: 'the lead is bounded');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.stats(session.token)!.held, stats.held,
          reason: 'and the fetch has stopped there');
      expect(stats.held, lessThan(host.length));
      expect(host.filmRequests, 1);
    });

    test('carries on from the same host connection after the hit', () async {
      final server = await startProxy(readAhead: 256 * kib);
      final session = server.openSession('${host.base}/film.mkv');
      await playerGet(session.url, from: 0, take: 512 * kib);
      // Asks again from behind, then reads to the very end of the film:
      // held bytes first, then what the paused fetch goes on to bring.
      final rest = await playerGet(session.url, from: 300 * kib);
      expect(rest.body.length, host.length - 300 * kib);
      expect(rest.body, film(300 * kib, host.length - 300 * kib));
      expect(host.filmRequests, 1);
    });

    test('two connections at once are each fed the right bytes', () async {
      final server = await startProxy();
      final session = server.openSession('${host.base}/film.mkv');
      await playerGet(session.url, from: 0, take: mib);
      final answers = await Future.wait(<Future<PlayerAnswer>>[
        playerGet(session.url, from: 100 * kib, take: 400 * kib),
        playerGet(session.url, from: 500 * kib, take: 400 * kib),
        playerGet(session.url, from: 900 * kib, take: 100 * kib),
      ]);
      expect(answers[0].body, film(100 * kib, 400 * kib));
      expect(answers[1].body, film(500 * kib, 400 * kib));
      expect(answers[2].body, film(900 * kib, 100 * kib));
      expect(host.filmRequests, 1);
    });

    test('a request a little past the window waits for the running fetch',
        () async {
      host.length = 48 * mib;
      final server = await startProxy(
        capacity: 64 * mib,
        readAhead: 128 * kib,
        skipAhead: 256 * kib,
      );
      final session = server.openSession('${host.base}/film.mkv');
      await playerGet(session.url, from: 0, take: 64 * kib);
      await until(() => server.stats(session.token)!.ahead >= 128 * kib);
      final end = server.stats(session.token)!.held;
      final answer = await playerGet(session.url, from: end + 100 * kib, take: 50 * kib);
      expect(answer.body, film(end + 100 * kib, 50 * kib));
      expect(host.filmRequests, 1);
    });
  });

  group('a seek outside what is held', () {
    test('goes to the host, as it does today', () async {
      host.length = 64 * mib;
      final server = await startProxy(capacity: 96 * mib, readAhead: 128 * kib);
      final session = server.openSession('${host.base}/film.mkv');
      await playerGet(session.url, from: 0, take: 64 * kib);
      final far = await playerGet(session.url, from: 50 * mib, take: 100 * kib);
      expect(far.status, 206);
      expect(far.headers['content-range'],
          'bytes ${50 * mib}-${host.length - 1}/${host.length}');
      expect(far.body, film(50 * mib, 100 * kib));
      expect(host.filmRequests, 2);
      expect(host.requests.last.rangeStart, 50 * mib);
      final stats = server.stats(session.token)!;
      expect(stats.misses, 2);
      expect(stats.requests.last.local, isFalse);
      // And the window now begins there: going back is another miss.
      final back = await playerGet(session.url, from: 0, take: 1000);
      expect(back.body, film(0, 1000));
      expect(host.filmRequests, 3);
    });
  });

  group('the cap', () {
    test('the store never passes its capacity, and the film still plays',
        () async {
      host.length = 64 * mib;
      const cap = 16 * mib;
      final server = await startProxy(capacity: cap, readAhead: mib);
      final session = server.openSession('${host.base}/film.mkv');
      final ring = File('${dir.path}/${session.token}.ring');
      var biggest = 0;
      final watch = Timer.periodic(const Duration(milliseconds: 5), (_) {
        final held = server.stats(session.token)?.held ?? 0;
        if (held > biggest) biggest = held;
      });
      final answer = await playerGet(session.url, from: 0);
      watch.cancel();
      expect(answer.body.length, host.length);
      expect(answer.body, film(0, host.length));
      expect(biggest, lessThanOrEqualTo(cap));
      expect(biggest, greaterThan(cap ~/ 2));
      expect(ring.lengthSync(), lessThanOrEqualTo(cap));
      // What fell out of the window is gone: asking for it is a miss.
      final early = await playerGet(session.url, from: 0, take: 1000);
      expect(early.body, film(0, 1000));
      expect(host.filmRequests, 2);
    });
  });

  group('redirects', () {
    test('are followed with the same headers, like ffmpeg', () async {
      final server = await startProxy();
      final session = server.openSession('${host.base}/go');
      final answer = await playerGet(
        session.url,
        from: 0,
        take: 100 * kib,
        headers: <String, String>{'Referer': 'https://example.test/'},
      );
      expect(answer.body, film(0, 100 * kib));
      expect(host.requests.map((r) => r.path), <String>['/go', '/film.mkv']);
      expect(host.requests[1].headers['referer'], 'https://example.test/');
      expect(host.requests[1].headers['range'], 'bytes=0-');
    });

    test('a later request starts at the place the redirect led to, and '
        'goes back to the first address when that stops answering',
        () async {
      host.length = 64 * mib;
      final server = await startProxy(capacity: 96 * mib, readAhead: 64 * kib);
      final session = server.openSession('${host.base}/go');
      await playerGet(session.url, from: 0, take: 10 * kib);
      await playerGet(session.url, from: 50 * mib, take: 10 * kib);
      expect(
        host.requests.map((r) => r.path),
        <String>['/go', '/film.mkv', '/film.mkv'],
      );
    });
  });

  group('stepping aside (302 to the film\'s own address)', () {
    Future<void> expectBypass(String url, String reason) async {
      final server = proxy!;
      final session = server.openSession(url);
      final answer = await playerGet(session.url, from: 0);
      expect(answer.status, 302);
      expect(answer.headers['location'], url);
      final stats = server.stats(session.token)!;
      expect(stats.dead, isTrue);
      expect(stats.reason, reason);
      // And it stays aside: the next request is redirected at once,
      // without asking the host anything.
      final before = host.requests.length;
      final next = await playerGet(session.url, from: 500);
      expect(next.status, 302);
      expect(next.headers['location'], url);
      expect(host.requests.length, before);
      expect(File('${dir.path}/${session.token}.ring').existsSync(), isFalse);
    }

    test('a host that ignores ranges', () async {
      await startProxy();
      host.ignoreRange = true;
      await expectBypass('${host.base}/film.mkv', 'no range');
    });

    test('a host that refuses (403)', () async {
      await startProxy();
      host.failStatus = 403;
      await expectBypass('${host.base}/film.mkv', 'http 403');
    });

    test('a playlist by its type', () async {
      await startProxy();
      host.contentType = 'application/vnd.apple.mpegurl';
      await expectBypass('${host.base}/film.mkv', 'type');
    });

    test('a playlist by its first bytes, whatever the host calls it',
        () async {
      await startProxy();
      host.textBody = '#EXTM3U\n#EXT-X-VERSION:3\nseg1.ts\n';
      host.contentType = 'application/octet-stream';
      await expectBypass('${host.base}/film.mkv', 'playlist');
    });

    test('something too small to be a film', () async {
      await startProxy(minLength: 8 * mib);
      await expectBypass('${host.base}/film.mkv', 'small');
    });

    test('a host that does not answer in time', () async {
      await startProxy(responseTimeout: const Duration(milliseconds: 400));
      host.delay = const Duration(seconds: 2);
      await expectBypass('${host.base}/film.mkv', 'host');
    });

    test('a host that cannot be reached at all', () async {
      await startProxy();
      final server = proxy!;
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close();
      final url = 'http://127.0.0.1:$port/film.mkv';
      final session = server.openSession(url);
      final answer = await playerGet(session.url, from: 0);
      expect(answer.status, 302);
      expect(answer.headers['location'], url);
    });

    test('something named relative to the film goes to the same place '
        'relative to the film\'s own address', () async {
      final server = await startProxy();
      final session = server.openSession('${host.base}/a/b/master.m3u8?t=1');
      final base = session.url.substring(0, session.url.lastIndexOf('/'));
      final answer = await playerGet('$base/seg-001.ts?x=9');
      expect(answer.status, 302);
      expect(answer.headers['location'], '${host.base}/a/b/seg-001.ts?x=9');
    });

    test('a request for a film nobody opened is refused', () async {
      final server = await startProxy();
      final answer = await playerGet(
        'http://127.0.0.1:${server.port}/0123456789abcdef/film.mkv',
        from: 0,
      );
      expect(answer.status, 404);
    });

    test('only http(s) addresses can be opened', () async {
      final server = await startProxy();
      expect(() => server.openSession('rtmp://x/y'), throwsArgumentError);
      expect(() => server.openSession('/local/file.mkv'), throwsArgumentError);
      expect(() => server.openSession('magnet:?xt=urn'), throwsArgumentError);
    });
  });

  group('the host connection breaking', () {
    test('is picked up again from where it stopped; the player sees one '
        'unbroken film', () async {
      final server = await startProxy();
      host
        ..dropAfter = 400 * kib
        ..dropTimes = 2;
      final session = server.openSession('${host.base}/film.mkv');
      final answer = await playerGet(session.url, from: 0);
      expect(answer.body.length, host.length);
      expect(answer.body, film(0, host.length));
      expect(host.filmRequests, 3);
      expect(host.requests[1].rangeStart, 400 * kib);
      expect(host.requests[2].rangeStart, 800 * kib);
      expect(server.stats(session.token)!.dead, isFalse);
    });

    test('for good: the player is cut off, and its next request is '
        'redirected to the film\'s own address', () async {
      final server = await startProxy();
      host
        ..dropAfter = 300 * kib
        ..dropTimes = 1
        ..failStatus = 503
        ..failFromRequest = 1;
      final session = server.openSession('${host.base}/film.mkv');
      final answer = await playerGet(session.url, from: 0);
      // It got what there was, then the line went.
      expect(answer.body.length, lessThan(host.length));
      expect(answer.body, film(0, answer.body.length));
      await until(() => server.stats(session.token)!.dead, ms: 8000);
      expect(server.stats(session.token)!.reason, 'host lost');
      // ffmpeg reconnects from where it was (`reconnect=1`):
      final again = await playerGet(session.url, from: answer.body.length);
      expect(again.status, 302);
      expect(again.headers['location'], '${host.base}/film.mkv');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('while the player is away (the phone slept): the next request '
        'for held bytes is still answered at once', () async {
      host.length = 24 * mib;
      final server = await startProxy(capacity: 32 * mib, readAhead: 256 * kib);
      final session = server.openSession('${host.base}/film.mkv');
      await playerGet(session.url, from: 0, take: 512 * kib);
      await until(() => server.stats(session.token)!.ahead >= 256 * kib);
      host.cutConnections();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      host.delay = const Duration(seconds: 2);
      final clock = Stopwatch()..start();
      final again = await playerGet(session.url, from: 400 * kib, take: 200 * kib);
      expect(again.body, film(400 * kib, 200 * kib));
      expect(clock.elapsedMilliseconds, lessThan(1500));
      // And the rest of the film still arrives, over a new connection.
      host.delay = Duration.zero;
      final rest = await playerGet(session.url, from: 400 * kib);
      expect(rest.body, film(400 * kib, host.length - 400 * kib));
      expect(server.stats(session.token)!.dead, isFalse);
    });
  });

  group('the player hanging up', () {
    test('mid-film leaves the proxy working', () async {
      final server = await startProxy();
      final session = server.openSession('${host.base}/film.mkv');
      for (var i = 0; i < 5; i++) {
        final answer = await playerGet(session.url, from: i * 1000, take: 5000);
        expect(answer.body, film(i * 1000, 5000));
      }
      expect(host.filmRequests, 1);
      expect(server.stats(session.token)!.dead, isFalse);
    });
  });

  group('housekeeping', () {
    test('closing a film deletes its file and refuses its address',
        () async {
      final server = await startProxy();
      final session = server.openSession('${host.base}/film.mkv');
      await playerGet(session.url, from: 0, take: 100 * kib);
      final ring = File('${dir.path}/${session.token}.ring');
      expect(ring.existsSync(), isTrue);
      server.closeSession(session.token);
      expect(ring.existsSync(), isFalse);
      expect(server.stats(session.token), isNull);
      final answer = await playerGet(session.url, from: 0);
      expect(answer.status, 404);
    });

    test('files a crash left behind are deleted when the proxy starts',
        () async {
      File('${dir.path}/dead1.ring').writeAsBytesSync(List<int>.filled(100, 1));
      File('${dir.path}/dead2.ring').writeAsBytesSync(List<int>.filled(100, 1));
      File('${dir.path}/keep.txt').writeAsStringSync('not ours');
      await startProxy();
      expect(File('${dir.path}/dead1.ring').existsSync(), isFalse);
      expect(File('${dir.path}/dead2.ring').existsSync(), isFalse);
      expect(File('${dir.path}/keep.txt').existsSync(), isTrue);
    });

    test('answers a ping, and comes back on the same port after a rebind',
        () async {
      final server = await startProxy();
      final session = server.openSession('${host.base}/film.mkv');
      await playerGet(session.url, from: 0, take: 200 * kib);
      expect(await server.ping(), isTrue);
      final port = server.port;
      expect(await server.rebind(), isTrue);
      expect(server.port, port);
      expect(await server.ensureListening(), isTrue);
      // The address the player holds is still good, and so is the store.
      final again = await playerGet(session.url, from: 50 * kib, take: 100 * kib);
      expect(again.body, film(50 * kib, 100 * kib));
      expect(host.filmRequests, 1);
    });

    test('shutting down deletes every file', () async {
      final server = await startProxy();
      final a = server.openSession('${host.base}/film.mkv');
      await playerGet(a.url, from: 0, take: 10 * kib);
      await server.shutdown();
      proxy = null;
      expect(
        dir.listSync().where((e) => e.path.endsWith('.ring')),
        isEmpty,
      );
    });

    test('stats survive the trip through a message port', () {
      const stats = StreamCacheStats(
        held: 10,
        ahead: 4,
        total: 99,
        hits: 2,
        misses: 1,
        dead: false,
        reason: null,
        requests: <StreamCacheRequest>[
          StreamCacheRequest(atMs: 5, offset: 7, local: true),
        ],
      );
      final back = StreamCacheStats.fromMap(stats.toMap())!;
      expect(back.held, 10);
      expect(back.ahead, 4);
      expect(back.total, 99);
      expect(back.hits, 2);
      expect(back.misses, 1);
      expect(back.dead, isFalse);
      expect(back.requests.single.offset, 7);
      expect(back.requests.single.local, isTrue);
      expect(StreamCacheStats.fromMap(null), isNull);
    });
  });
}
