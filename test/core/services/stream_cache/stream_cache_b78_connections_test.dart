// Build 78: the host connections the proxy keeps.
//
// The player moving on (mpv's own start does it twice: the film's
// head, the index at its end, back to the start) must leave exactly
// one host connection running — the one the player is fed from — and
// no request to the host for a place nobody is reading.

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

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('stream_cache_b78');
    host = FakeHost(length: 256 * mib)
      // ~3 MiB/s: slow enough that a connection left behind is still
      // running when the test looks.
      ..pace = const Duration(milliseconds: 10);
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

  Future<StreamCacheProxyServer> startProxy() async {
    final server = StreamCacheProxyServer(
      directory: dir.path,
      capacity: 512 * mib,
      readAhead: 32 * mib,
      skipAhead: 64 * kib,
      minLength: 64 * kib,
    );
    await server.start();
    proxy = server;
    return server;
  }

  /// How many host connections are still sending, measured over
  /// [window].
  Future<int> stillSending(Duration window) async {
    final before = Map<int, int>.of(host.sentBy);
    await Future<void>.delayed(window);
    var moving = 0;
    host.sentBy.forEach((index, sent) {
      if (sent > (before[index] ?? 0)) moving++;
    });
    return moving;
  }

  test('mpv\'s start (head, index at the end, back to the start) leaves '
      'ONE host connection running, not several', () async {
    final server = await startProxy();
    final session = server.openSession('${host.base}/film.mkv');
    await playerGet(session.url, from: 0, take: 256 * kib);
    await playerGet(session.url, from: host.length - 200 * kib);
    // Back to the start, and keep reading like a player does.
    final playing = playerGet(session.url, from: 300 * kib, take: 6 * mib);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(await stillSending(const Duration(milliseconds: 500)), 1);
    expect(host.openConnections, 1);
    final body = (await playing).body;
    expect(body, film(300 * kib, 6 * mib));
  });

  test('a far seek closes the connection it leaves', () async {
    final server = await startProxy();
    final session = server.openSession('${host.base}/film.mkv');
    await playerGet(session.url, from: 0, take: 256 * kib);
    final far = playerGet(session.url, from: 120 * mib, take: 3 * mib);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(await stillSending(const Duration(milliseconds: 500)), 1);
    expect(host.openConnections, 1);
    expect((await far).body, film(120 * mib, 3 * mib));
    // Nothing was asked of the host but the two places the player went.
    expect(
      host.requests.map((r) => r.rangeStart).toList(),
      <int?>[0, 120 * mib],
    );
  });
}
