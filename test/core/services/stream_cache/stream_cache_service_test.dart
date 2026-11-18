// Build 77: the stream cache proxy running in its own isolate, the way
// the app runs it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/services/stream_cache/stream_cache_service.dart';

import 'fake_host.dart';

void main() {
  late Directory dir;
  late FakeHost host;

  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('stream_cache_service_test');
    host = FakeHost(length: 24 * 1024 * 1024);
    await host.start();
  });

  tearDown(() async {
    await StreamCacheService.instance.debugShutdown();
    StreamCacheService.debugDirectory = null;
    await host.stop();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('off this platform it gives no address and starts nothing', () async {
    // (The build machine is not an iPhone.)
    expect(StreamCacheService.supported, isFalse);
    expect(
      await StreamCacheService.instance.open('${host.base}/film.mkv'),
      isNull,
    );
    expect(await StreamCacheService.instance.ensureListening(), isFalse);
    await StreamCacheService.sweepLeftovers();
    expect(host.requests, isEmpty);
  });

  test('a film opened through the isolate plays, a repeat request is '
      'served from the store, and closing deletes the file', () async {
    StreamCacheService.debugDirectory = dir.path;
    File('${dir.path}/old.ring').writeAsBytesSync(<int>[1, 2, 3]);
    await StreamCacheService.sweepLeftovers();
    expect(File('${dir.path}/old.ring').existsSync(), isFalse);

    final service = StreamCacheService.instance;
    final handle = await service.open('${host.base}/film.mkv');
    expect(handle, isNotNull);
    expect(handle!.url, startsWith('http://127.0.0.1:'));
    // Opening asks nothing of the host.
    expect(host.requests, isEmpty);

    final first = await playerGet(handle.url, from: 0, take: 1024 * 1024);
    expect(first.status, 206);
    expect(first.body, film(0, 1024 * 1024));
    final again = await playerGet(handle.url, from: 500000, take: 300000);
    expect(again.body, film(500000, 300000));
    expect(host.filmRequests, 1);

    final stats = await service.stats(handle.token);
    expect(stats, isNotNull);
    expect(stats!.hits, 1);
    expect(stats.misses, 1);
    expect(stats.total, host.length);
    expect(stats.requests.last.local, isTrue);
    expect(await service.ensureListening(), isTrue);

    expect(File('${dir.path}/${handle.token}.ring').existsSync(), isTrue);
    service.close(handle.token);
    expect(await service.stats(handle.token), isNull);
    expect(File('${dir.path}/${handle.token}.ring').existsSync(), isFalse);
  });

  test('an address it cannot proxy gives null, not an exception', () async {
    StreamCacheService.debugDirectory = dir.path;
    final service = StreamCacheService.instance;
    expect(await service.open('magnet:?xt=urn:btih:abc'), isNull);
    expect(service.lastFailure, isNotNull);
    // And it still works afterwards.
    expect(await service.open('${host.base}/film.mkv'), isNotNull);
  });
}
