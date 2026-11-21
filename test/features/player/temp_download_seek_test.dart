/// Build 107: the seek decision while a temp download runs — pure, so
/// it is proven here without an engine or a screen.
///
/// The screen asks [tempSeekAction] first on every seek: a downloaded
/// target reopens the local temp file (instant), a target past the
/// frontier waits with progress, and a dead or absent download seeks
/// the stream as before.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/domain/temp_download.dart';

import '../../core/services/stream_cache/fake_host.dart';
import 'temp_download_test.dart' show kFilmDuration, waitFor;

void main() {
  late FakeHost host;
  late Directory dir;

  setUp(() async {
    host = FakeHost(length: 20 * 1024 * 1024)..ignoreRange = true;
    await host.start();
    dir = await Directory.systemTemp.createTemp('zeus_temp_seek_test_');
  });

  tearDown(() async {
    await host.stop();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  TempDownload download() {
    return TempDownload(
      url: '${host.base}/film.mkv',
      directory: dir,
      duration: kFilmDuration,
    );
  }

  TempSeekAction decide(TempDownload? temp, Duration target) {
    return tempSeekAction(
      download: temp,
      target: target,
      duration: kFilmDuration,
    );
  }

  test('no download: seek the stream as before', () {
    expect(decide(null, const Duration(minutes: 2)), TempSeekAction.normalSeek);
  });

  test('a download with no bytes yet: seek the stream', () {
    final temp = download();
    expect(decide(temp, const Duration(minutes: 2)), TempSeekAction.normalSeek);
  });

  test('a downloaded target reopens the local file', () async {
    final temp = download();
    temp.setRateCap(2 * 1024 * 1024);
    expect(await temp.start(), isTrue);
    await waitFor(
      () => temp.downloadedBytes >= 8 * 1024 * 1024,
      what: '8 MiB downloaded',
    );
    expect(
      decide(temp, const Duration(minutes: 1)),
      TempSeekAction.openLocalFile,
    );
    await temp.cancel();
  });

  test('a target past the frontier waits for its bytes', () async {
    final temp = download();
    temp.setRateCap(2 * 1024 * 1024);
    expect(await temp.start(), isTrue);
    await waitFor(
      () => temp.downloadedBytes >= 8 * 1024 * 1024,
      what: '8 MiB downloaded',
    );
    expect(
      decide(temp, const Duration(minutes: 9)),
      TempSeekAction.waitForDownload,
    );
    await temp.cancel();
  });

  test('a finished download opens the local file for any target', () async {
    await host.stop();
    host = FakeHost(length: 3 * 1024 * 1024)..ignoreRange = true;
    await host.start();
    final temp = download();
    expect(await temp.start(), isTrue);
    await waitFor(
      () => temp.status == TempDownloadStatus.complete,
      what: 'complete',
    );
    expect(
      decide(temp, const Duration(minutes: 9)),
      TempSeekAction.openLocalFile,
    );
    await temp.dispose();
  });

  test('a failed download with a usable partial still opens it', () async {
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
    // 1:00 is inside the 8 MiB that arrived; 9:00 is not.
    expect(
      decide(temp, const Duration(minutes: 1)),
      TempSeekAction.openLocalFile,
    );
    expect(decide(temp, const Duration(minutes: 9)), TempSeekAction.normalSeek);
    await temp.dispose();
  });

  test('a failed download with no usable file seeks the stream', () async {
    host.failStatus = HttpStatus.internalServerError;
    final temp = download();
    expect(await temp.start(), isFalse);
    expect(temp.status, TempDownloadStatus.failed);
    expect(decide(temp, const Duration(minutes: 1)), TempSeekAction.normalSeek);
    await temp.dispose();
  });

  test('a kept file that covers the resume target opens the local '
      'file at once', () async {
    final first = download();
    first.setRateCap(2 * 1024 * 1024);
    expect(await first.start(), isTrue);
    await waitFor(
      () => first.downloadedBytes >= 8 * 1024 * 1024,
      what: '8 MiB downloaded',
    );
    await first.stop();
    // Reopen: the kept 8 MiB are adopted at once, so 1:00 (~7 MiB
    // needed) earns an immediate local-file open — no waiting for
    // the re-fetch to catch up.
    final second = download();
    expect(await second.start(), isTrue);
    expect(
      decide(second, const Duration(minutes: 1)),
      TempSeekAction.openLocalFile,
    );
    await second.cancel();
  });

  test('an unknown duration seeks the stream', () async {
    final temp = download();
    temp.setRateCap(2 * 1024 * 1024);
    expect(await temp.start(), isTrue);
    await waitFor(
      () => temp.downloadedBytes >= 8 * 1024 * 1024,
      what: '8 MiB downloaded',
    );
    expect(
      tempSeekAction(
        download: temp,
        target: const Duration(minutes: 1),
        duration: Duration.zero,
      ),
      TempSeekAction.normalSeek,
    );
    await temp.cancel();
  });
}
