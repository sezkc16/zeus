// Build 77: the stream cache proxy with a REAL player's HTTP client.
//
// mpv reads the network through ffmpeg's libavformat. This runs the
// `ffmpeg` tool (same HTTP client) against the proxy, when the machine
// has it and a film to serve (ZEUS_TEST_FILM), and is skipped otherwise.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/services/stream_cache/stream_cache_proxy.dart';

import 'fake_host.dart';

Future<String> decodeMd5(String url, {int? seek, int seconds = 3}) async {
  final result = await Process.run('ffmpeg', <String>[
    '-v', 'error',
    '-user_agent', 'ZeusTest/1.0',
    '-headers', 'Referer: https://example.test/watch\r\n',
    '-reconnect', '1',
    '-reconnect_streamed', '1',
    '-reconnect_delay_max', '2',
    if (seek != null) ...<String>['-ss', '$seek'],
    '-i', url,
    '-t', '$seconds',
    '-map', '0:v:0',
    '-f', 'md5', '-',
  ]);
  if (result.exitCode != 0) {
    fail('ffmpeg failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

void main() {
  final filmPath = Platform.environment['ZEUS_TEST_FILM'];
  final hasFfmpeg = () {
    try {
      return Process.runSync('ffmpeg', <String>['-version']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }();
  final skip = filmPath == null || !File(filmPath).existsSync() || !hasFfmpeg
      ? 'needs ffmpeg and ZEUS_TEST_FILM'
      : null;

  late Directory dir;
  late FakeHost host;
  late StreamCacheProxyServer proxy;

  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('stream_cache_ffmpeg');
    host = FakeHost()..filePath = filmPath;
    await host.start();
    proxy = StreamCacheProxyServer(directory: dir.path);
    await proxy.start();
  });

  tearDown(() async {
    await proxy.shutdown();
    await host.stop();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('ffmpeg decodes the same pictures through the proxy as from the '
      'host, at the start and after a seek, with its headers passed on',
      () async {
    final direct0 = await decodeMd5('${host.base}/film.mkv');
    final direct150 = await decodeMd5('${host.base}/film.mkv', seek: 150);
    host.requests.clear();

    final session = proxy.openSession('${host.base}/film.mkv');
    expect(await decodeMd5(session.url), direct0);
    expect(host.requests, isNotEmpty);
    expect(host.requests.first.headers['user-agent'], 'ZeusTest/1.0');
    expect(
      host.requests.first.headers['referer'],
      'https://example.test/watch',
    );
    expect(host.requests.first.headers.containsKey('accept-encoding'), isFalse);

    final session2 = proxy.openSession('${host.base}/film.mkv');
    expect(await decodeMd5(session2.url, seek: 150), direct150);
    expect(proxy.stats(session2.token)!.dead, isFalse);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

  test('ffmpeg follows the proxy\'s step-aside (302) and plays from the '
      'host itself', () async {
    final direct150 = await decodeMd5('${host.base}/film.mkv', seek: 150);
    // Something the proxy refuses to carry (the host calls it text):
    // it answers 302 to the film's own address, from the first request.
    host.contentType = 'text/plain';
    final session = proxy.openSession('${host.base}/film.mkv');
    final md5 = await decodeMd5(session.url, seek: 150);
    expect(proxy.stats(session.token)!.dead, isTrue);
    expect(proxy.stats(session.token)!.reason, 'type');
    // ffmpeg followed it, seeked and decoded the same pictures.
    expect(md5, direct150);
    expect(proxy.stats(session.token)!.hits, 0);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
