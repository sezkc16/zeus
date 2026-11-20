/// Build 107: the temp download — progressive "download while watching"
/// for a host that does not serve ranges.
///
/// The manager is pure Dart and is tested against [FakeHost], the same
/// stand-in the stream-cache proxy's tests use: it can answer ranges
/// (206), ignore them (200 + the whole film from byte 0), fail, and
/// hang up mid-film.
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
    dir = await Directory.systemTemp.createTemp('zeus_temp_test_');
  });

  tearDown(() async {
    await host.stop();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  TempDownload download({int? length}) {
    return TempDownload(
      url: '${host.base}/film.mkv',
      directory: dir,
      duration: kFilmDuration,
    );
  }

  test('a no-range host downloads from byte 0 and completes', () async {
    final temp = download();
    expect(await temp.start(), isTrue);
    await waitFor(
      () => temp.status == TempDownloadStatus.complete,
      what: 'complete',
    );
    final file = File(temp.localFilePath);
    expect(await file.exists(), isTrue);
    expect(await file.length(), 3 * 1024 * 1024);
    // The bytes are the film's, at both ends.
    final bytes = await file.readAsBytes();
    expect(bytes.sublist(100, 200), film(100, 100));
    expect(bytes.sublist(bytes.length - 100), film(bytes.length - 100, 100));
    // The file lives in the temp directory given, never Documents.
    expect(temp.localFilePath, startsWith(dir.path));
    expect(temp.localFilePath, contains(kTempDownloadFilePrefix));
    expect(temp.localFilePath, endsWith('.mkv'));
    await temp.dispose();
  });

  test('a 206 host needs no download', () async {
    host.ignoreRange = false;
    final temp = download();
    expect(await temp.start(), isFalse);
    expect(temp.status, TempDownloadStatus.notNeeded);
    expect(await File(temp.localFilePath).exists(), isFalse);
    await temp.dispose();
  });

  test('a failing host fails and keeps the player on the stream', () async {
    host.failStatus = HttpStatus.internalServerError;
    final temp = download();
    expect(await temp.start(), isFalse);
    expect(temp.status, TempDownloadStatus.failed);
    expect(temp.error, isNotNull);
    expect(await File(temp.localFilePath).exists(), isFalse);
    await temp.dispose();
  });

  test('progress reports the fraction up to 1.0', () async {
    final temp = download();
    final fractions = <double>[];
    final sub = temp.progress.listen((p) {
      fractions.add(p.fraction(kFilmDuration));
    });
    expect(await temp.start(), isTrue);
    await waitFor(
      () => temp.status == TempDownloadStatus.complete,
      what: 'complete',
    );
    await sub.cancel();
    expect(fractions, isNotEmpty);
    expect(fractions.last, 1.0);
    for (var i = 1; i < fractions.length; i++) {
      expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1]));
    }
    await temp.dispose();
  });

  test('a seek inside the downloaded frontier is available', () async {
    // A 20 MiB film, so the 5 MiB seek margin leaves room to tell a
    // downloaded position from one past the frontier.
    await host.stop();
    host = FakeHost(length: 20 * 1024 * 1024)
      ..ignoreRange = true
      ..pace = const Duration(milliseconds: 5);
    await host.start();
    final temp = download();
    temp.setRateCap(2 * 1024 * 1024);
    expect(await temp.start(), isTrue);
    // 1:00 needs ~2 MiB of film + the 5 MiB margin: ~7 MiB.
    await waitFor(
      () => temp.downloadedBytes >= 8 * 1024 * 1024,
      what: '8 MiB downloaded',
    );
    expect(temp.isDownloaded(const Duration(minutes: 1)), isTrue);
    expect(temp.isDownloaded(const Duration(minutes: 9)), isFalse);
    expect(temp.downloadedUpTo(), isNotNull);
    expect(temp.downloadedUpTo()!, greaterThan(Duration.zero));
    expect(temp.etaTo(const Duration(minutes: 9)), isNotNull);
    await temp.cancel();
  });

  test('cancel deletes the file', () async {
    final temp = download();
    expect(await temp.start(), isTrue);
    await waitFor(() => temp.downloadedBytes > 0, what: 'first bytes');
    final path = temp.localFilePath;
    expect(await File(path).exists(), isTrue);
    await temp.cancel();
    expect(temp.status, TempDownloadStatus.cancelled);
    expect(await File(path).exists(), isFalse);
  });

  test('dispose deletes the file', () async {
    final temp = download();
    expect(await temp.start(), isTrue);
    await waitFor(() => temp.downloadedBytes > 0, what: 'first bytes');
    final path = temp.localFilePath;
    await temp.dispose();
    expect(await File(path).exists(), isFalse);
  });

  test('a cut connection fails but keeps the partial file', () async {
    await host.stop();
    host = FakeHost(length: 20 * 1024 * 1024)..ignoreRange = true;
    await host.start();
    final temp = download();
    temp.setRateCap(2 * 1024 * 1024);
    expect(await temp.start(), isTrue);
    await waitFor(
      () => temp.downloadedBytes >= 8 * 1024 * 1024,
      what: '8 MiB downloaded',
    );
    host.cutConnections();
    await waitFor(
      () => temp.status == TempDownloadStatus.failed,
      what: 'failed',
    );
    // The partial file stays: seeks inside what arrived still work.
    expect(await File(temp.localFilePath).exists(), isTrue);
    expect(temp.isDownloaded(const Duration(minutes: 1)), isTrue);
    expect(temp.isDownloaded(const Duration(minutes: 9)), isFalse);
    await temp.dispose();
  });

  test('the rate cap slows the download', () async {
    final temp = download();
    temp.setRateCap(32 * 1024);
    expect(await temp.start(), isTrue);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(temp.status, isNot(TempDownloadStatus.complete));
    expect(temp.downloadedBytes, lessThan(512 * 1024));
    await temp.cancel();
  });

  test('sweepStale deletes only stale temp files', () async {
    final stale = File('${dir.path}/${kTempDownloadFilePrefix}123456.mkv');
    await stale.writeAsBytes(const [1, 2, 3]);
    final other = File('${dir.path}/other.txt');
    await other.writeAsString('keep me');
    await TempDownload.sweepStale(dir);
    expect(await stale.exists(), isFalse);
    expect(await other.exists(), isTrue);
  });

  test('the overlay line names the download and its reach', () {
    const snapshot = TempDownloadProgress(
      status: TempDownloadStatus.downloading,
      downloadedBytes: 60 * 1024 * 1024,
      totalBytes: 600 * 1024 * 1024,
      bytesPerSecond: 400 * 1024,
    );
    final line = tempDownloadOverlayLine(snapshot, kFilmDuration);
    expect(line, startsWith('temp: downloading'));
    expect(line, contains('up to 01:00'));
    const done = TempDownloadProgress(
      status: TempDownloadStatus.complete,
      downloadedBytes: 600 * 1024 * 1024,
      totalBytes: 600 * 1024 * 1024,
    );
    expect(
      tempDownloadOverlayLine(done, kFilmDuration),
      startsWith('temp: done'),
    );
  });
}
