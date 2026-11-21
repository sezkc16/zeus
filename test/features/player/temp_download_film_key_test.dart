/// Build 120: the temp file is keyed by the film + source, not by the
/// stream URL — signed links (HubCloud/FSL) are re-issued on every load,
/// so a hash of the full URL orphans the kept file (b119's bug,
/// phone-proven 2026-11-22). The same film resolved twice with
/// DIFFERENT signed URLs (same host/path, different query token) must
/// map to the same temp file, and the second open must find the kept
/// file through [TempDownload.findKept] without re-resolution — the
/// player asks findKept before it resolves anything, so this is the
/// layer the fast path stands on.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/domain/temp_download.dart';

import '../../core/services/stream_cache/fake_host.dart';

/// A 10-minute film, so a byte position maps to a clock position at
/// [filmBytes] / 600 per second.
const Duration kFilmDuration = Duration(minutes: 10);

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  String what = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  late FakeHost host;
  late Directory dir;

  setUp(() async {
    host = FakeHost(length: 3 * 1024 * 1024)..ignoreRange = true;
    await host.start();
    dir = await Directory.systemTemp.createTemp('zeus_temp_filmkey_');
  });

  tearDown(() async {
    await host.stop();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// The film's identity: one title, one source. The two signed URLs
  /// below are what two resolutions of the same film return — same
  /// host and path, a fresh token in the query each time.
  const itemUrl = 'https://hdhub4u.example/film/om-operation-mole';
  const sourceKey = 'HDHub4u\u0001FSL 1080p\u00011080';
  String fileKey({String? source, String? episode}) => tempFileKeyFor(
    itemUrl: itemUrl,
    episodeKey: episode,
    sourceKey: source ?? sourceKey,
  );

  TempDownload download({
    required String url,
    required String key,
    int? length,
  }) {
    final temp = TempDownload(
      url: url,
      directory: dir,
      duration: kFilmDuration,
      fileKey: key,
    );
    // No rate cap: the loopback host is instant, and the test must not
    // wait on the 2 MiB/s playback cap.
    temp.setRateCap(0);
    return temp;
  }

  test('the key is stable for one film+source, different across sources',
      () {
    expect(fileKey(), fileKey());
    expect(fileKey(), isNot(fileKey(source: 'HDHub4u\u0001FSL 720p\u0001720')));
    expect(
      fileKey(),
      isNot(fileKey(source: 'HDHub4u\u0001PixelDrain 1080p\u00011080')),
    );
    expect(fileKey(), isNot(fileKey(episode: 'https://x/episode-2')));
    expect(fileKey(episode: 'https://x/episode-2'), fileKey(episode: 'https://x/episode-2'));
  });

  test('the same film twice with different signed URLs shares one file',
      () async {
    final key = fileKey();
    final first = download(
      url: '${host.base}/film.mkv?token=aaa&expires=111',
      key: key,
    );
    expect(await first.start(), isTrue);
    await waitFor(
      () => first.status == TempDownloadStatus.complete,
      what: 'first complete',
    );
    final requestsAfterFirst = host.filmRequests;
    await first.stop();

    // The second resolution issues a fresh signed URL for the same
    // film: same host and path, a different token.
    final second = download(
      url: '${host.base}/film.mkv?token=bbb&expires=222',
      key: key,
    );
    expect(second.localFilePath, first.localFilePath);
    expect(await second.start(), isTrue);
    // Already whole: no new fetch, just the probe.
    expect(second.status, TempDownloadStatus.complete);
    expect(second.downloadedBytes, 3 * 1024 * 1024);
    expect(host.filmRequests, requestsAfterFirst + 1);
    final bytes = await File(second.localFilePath).readAsBytes();
    expect(bytes.sublist(100, 200), film(100, 100));
    expect(bytes.sublist(bytes.length - 100), film(bytes.length - 100, 100));
    await second.dispose();
  });

  test('findKept finds the kept file and covers the resume point', () async {
    final key = fileKey();
    final first = download(
      url: '${host.base}/film.mkv?token=aaa&expires=111',
      key: key,
    );
    expect(await first.start(), isTrue);
    await waitFor(
      () => first.status == TempDownloadStatus.complete,
      what: 'first complete',
    );
    await first.stop();

    final kept = await TempDownload.findKept(directory: dir, fileKey: key);
    expect(kept, isNotNull);
    expect(kept!.filePath, first.localFilePath);
    expect(kept.totalBytes, 3 * 1024 * 1024);
    expect(kept.duration, kFilmDuration);
    expect(kept.downloadedBytes, 3 * 1024 * 1024);
    // A complete file covers any position inside the film.
    expect(kept.covers(const Duration(minutes: 4, seconds: 34)), isTrue);
    expect(kept.covers(const Duration(minutes: 9, seconds: 59)), isTrue);
    expect(kept.covers(kFilmDuration), isFalse);

    // A different film's key finds nothing.
    final other = await TempDownload.findKept(
      directory: dir,
      fileKey: fileKey(source: 'HDHub4u\u0001FSL 720p\u0001720'),
    );
    expect(other, isNull);
  });

  test('a partial kept file covers only what it holds', () async {
    // A 30 MiB film, truncated at 10 MiB by the host hanging up: the
    // download fails and keeps its partial file.
    host.length = 30 * 1024 * 1024;
    host.dropAfter = 10 * 1024 * 1024;
    host.dropTimes = 1;
    final key = fileKey();
    final first = download(
      url: '${host.base}/film.mkv?token=aaa&expires=111',
      key: key,
    );
    expect(await first.start(), isTrue);
    await waitFor(
      () => first.status == TempDownloadStatus.failed,
      what: 'first failed (truncated)',
    );
    await first.stop();
    expect(await File(first.localFilePath).length(), 10 * 1024 * 1024);

    final kept = await TempDownload.findKept(directory: dir, fileKey: key);
    expect(kept, isNotNull);
    expect(kept!.downloadedBytes, 10 * 1024 * 1024);
    // 10 MiB of a 30 MiB / 10-minute film reaches ~3:20, plus the
    // keyframe run-up: 1 minute is covered, 5 minutes is not.
    expect(kept.covers(const Duration(minutes: 1)), isTrue);
    expect(kept.covers(const Duration(minutes: 5)), isFalse);

    // The second open (fresh signed URL, same key) adopts the kept
    // 10 MiB and completes the film into the same file.
    final second = download(
      url: '${host.base}/film.mkv?token=bbb&expires=222',
      key: key,
    );
    expect(second.localFilePath, first.localFilePath);
    expect(await second.start(), isTrue);
    expect(second.downloadedBytes, greaterThanOrEqualTo(10 * 1024 * 1024));
    await waitFor(
      () => second.status == TempDownloadStatus.complete,
      what: 'second complete',
    );
    final bytes = await File(second.localFilePath).readAsBytes();
    expect(bytes.length, 30 * 1024 * 1024);
    expect(bytes.sublist(100, 200), film(100, 100));
    expect(bytes.sublist(bytes.length - 100), film(bytes.length - 100, 100));
    await second.dispose();
  });

  test('findKept returns null without a sidecar, a file, or a sane total',
      () async {
    final key = fileKey();
    // No file and no sidecar at all.
    expect(await TempDownload.findKept(directory: dir, fileKey: key), isNull);

    // A sidecar but no video file.
    final sidecar = File('${dir.path}/$kTempDownloadFilePrefix$key.json');
    await sidecar.writeAsString(
      '{"v":1,"totalBytes":3145728,"durationMicros":600000000,"ext":".mkv"}',
    );
    expect(await TempDownload.findKept(directory: dir, fileKey: key), isNull);

    // A video file but a corrupt sidecar.
    final video = File('${dir.path}/$kTempDownloadFilePrefix$key.mkv');
    await video.writeAsBytes(const [1, 2, 3]);
    await sidecar.writeAsString('not json');
    expect(await TempDownload.findKept(directory: dir, fileKey: key), isNull);

    // A video file longer than the film (a different encode): stale.
    await sidecar.writeAsString(
      '{"v":1,"totalBytes":2,"durationMicros":600000000,"ext":".mkv"}',
    );
    expect(await TempDownload.findKept(directory: dir, fileKey: key), isNull);
  });
}
