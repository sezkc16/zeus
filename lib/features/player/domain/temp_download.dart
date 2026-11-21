/// Progressive "download while watching" for a film on a host that does not
/// serve byte ranges (build 107).
///
/// b103–b106 proved, on the phone, that no amount of proxy cleverness makes
/// a far seek work on such a host: the bytes at 04:22 have to be fetched
/// from byte 0 at host speed, and mpv cannot seek into a stream it cannot
/// range. So this build stops pretending and fetches the film for real —
/// sequentially, into the app's temp directory — while the stream plays
/// from the start. A seek to a position already downloaded reopens the
/// local temp file at that position, where seeking is instant because a
/// local file supports ranges. A seek past the downloaded frontier waits
/// with honest progress and resumes when the bytes arrive.
///
/// The temp file lives as long as Zeus is open (b119): it is NOT
/// deleted when the player closes, so Continue Watching reopens the
/// film from the bytes already fetched instead of downloading it
/// again from byte 0. It is deleted when Zeus closes (the app
/// lifecycle observer in main.dart sweeps it on detach), when the
/// viewer cancels the download, and when the host turns out to serve
/// ranges after all. A new film gets its own file (the name is a
/// stable hash of the URL); the old file stays until Zeus closes.
/// It never lands in Documents/ZoroX. Stale files from a crashed
/// session are swept at app launch (see [sweepStale]).
///
/// Pure Dart (no Flutter): the download, the time↔byte mapping and the
/// lifecycle are unit-tested against a local HTTP server (see
/// `temp_download_test.dart`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// The temp file's name prefix in the app's temp directory. [sweepStale]
/// deletes everything with this prefix.
const String kTempDownloadFilePrefix = 'zeus_temp_download_';

/// How much run-up past a seek target must be downloaded before the seek
/// is handed to the local file: the keyframe at or before the target, plus
/// a little decode run-up. At least 5 MiB, or 10 s of the film, whichever
/// is more — a 4K remux's GOP is longer than a 1080p one's.
const int kTempDownloadSeekMarginBytes = 5 * 1024 * 1024;

/// See [kTempDownloadSeekMarginBytes].
const Duration kTempDownloadSeekMarginTime = Duration(seconds: 10);

/// How long the download may go without a byte before it is given up on.
/// A host that trickles is still alive; a host that says nothing for a
/// minute and a half is dead. The partial file is kept either way: seeks
/// inside what arrived still work.
const Duration kTempDownloadNoDataAfter = Duration(seconds: 90);

/// How often progress is emitted while downloading (the screen rebuilds
/// the pending-seek card on it).
const Duration kTempDownloadProgressInterval = Duration(milliseconds: 250);

enum TempDownloadStatus {
  /// Checking whether the host serves ranges.
  probing,

  /// Fetching sequentially from byte 0.
  downloading,

  /// The whole file arrived.
  complete,

  /// The fetch died (host, network, no space). The partial file is kept:
  /// seeks inside what arrived still work.
  failed,

  /// The host serves ranges after all — no temp download needed.
  notNeeded,

  /// The viewer cancelled. The file is deleted.
  cancelled,

  /// The download was stopped (player closed, episode ended, a new
  /// film started) but the file is KEPT: seeks inside what arrived
  /// still work, and reopening the film resumes the download from
  /// the kept bytes. Deleted only when Zeus closes or the viewer
  /// cancels.
  stopped,
}

/// One progress reading. Immutable; the screen reads [snapshot].
class TempDownloadProgress {
  const TempDownloadProgress({
    required this.status,
    required this.downloadedBytes,
    this.totalBytes,
    this.bytesPerSecond = 0,
    this.error,
  });

  final TempDownloadStatus status;

  /// Bytes written to the temp file so far.
  final int downloadedBytes;

  /// The film's full size from Content-Length, or null when the host
  /// would not say (chunked). Without it, no time↔byte mapping exists.
  final int? totalBytes;

  /// Recent arrival rate, bytes per second. 0 when nothing is arriving.
  final double bytesPerSecond;

  /// Why [status] is [TempDownloadStatus.failed], if known.
  final String? error;

  /// 0..1 of the film downloaded, or 0 when the total is unknown.
  double fraction(Duration duration) {
    if (totalBytes == null || totalBytes! <= 0) return 0;
    return (downloadedBytes / totalBytes!).clamp(0.0, 1.0);
  }

  @override
  String toString() =>
      'TempDownloadProgress($status, $downloadedBytes/${totalBytes ?? '?'}'
      ' @ ${bytesPerSecond.toStringAsFixed(0)} B/s)';
}

/// The seek the screen should make for [target] on a film of [duration].
///
/// Pure, so the player test can drive it without an engine.
enum TempSeekAction {
  /// No temp file to use: seek the stream as before.
  normalSeek,

  /// The target is downloaded: reopen the local temp file at it.
  openLocalFile,

  /// The download is still running and the target is past the frontier:
  /// wait with progress, then reopen the local file when the bytes land.
  waitForDownload,
}

/// Which seek [TempSeekAction] a target earns. A dead download never
/// earns a wait: its bytes are never coming, so the stream is the only
/// move left.
TempSeekAction tempSeekAction({
  required TempDownload? download,
  required Duration target,
  required Duration duration,
}) {
  if (download == null || !download.hasUsableFile) {
    return TempSeekAction.normalSeek;
  }
  if (duration <= Duration.zero) return TempSeekAction.normalSeek;
  if (download.isDownloaded(target)) return TempSeekAction.openLocalFile;
  if (download.status == TempDownloadStatus.downloading) {
    return TempSeekAction.waitForDownload;
  }
  return TempSeekAction.normalSeek;
}

/// One sequential fetch of a film into the app's temp directory.
///
/// A single download only: [start] probes the host first (a ranged GET
/// for one byte — 206 means the host seeks fine and no download is
/// needed, 200 means it does not and the fetch begins). The fetch is
/// sequential from byte 0 because that is the only thing a no-range
/// host can do; it is rate-capped (see [setRateCap]) so it never
/// starves the stream playing alongside it.
class TempDownload {
  TempDownload({
    required this.url,
    this.headers,
    required this.duration,
    required this.directory,
  }) : _file = File(
         p.join(
           directory.path,
           '$kTempDownloadFilePrefix'
           '${_urlHash(url)}'
           '${_extensionOf(url)}',
         ),
       );

  /// A stable hash of the stream URL, so the same film always maps to
  /// the same temp file (b119): the file can be kept while Zeus is
  /// open and reused when the film is opened again. SHA-256, first 16
  /// hex chars. Dart's String.hashCode is NOT stable across runs, so
  /// it must not be used here.
  static String _urlHash(String url) {
    return sha256.convert(utf8.encode(url)).toString().substring(0, 16);
  }

  /// The film's own address (the origin, not a proxy address).
  final String url;

  /// The headers the source carries (User-Agent, Referer, …): the host
  /// must be asked the same way the player asks it.
  final Map<String, String>? headers;

  /// The film's length, for the time↔byte mapping. Known by the time
  /// the download starts (first play).
  final Duration duration;

  /// The temp directory the file lives in. Never Documents.
  final Directory directory;

  /// The temp file itself.
  final File _file;

  /// The temp file's path, for the player to open.
  String get localFilePath => _file.path;

  TempDownloadStatus _status = TempDownloadStatus.probing;
  TempDownloadStatus get status => _status;

  int _downloadedBytes = 0;
  int get downloadedBytes => _downloadedBytes;

  int? _totalBytes;
  int? get totalBytes => _totalBytes;

  double _bytesPerSecond = 0;
  double get bytesPerSecond => _bytesPerSecond;

  String? _error;
  String? get error => _error;

  /// Whether there is a temp file with bytes in it that a seek can use.
  /// A failed download keeps its partial file, so it counts; a
  /// stopped one keeps it too (b119), so it counts; a cancelled one
  /// deletes it, so it does not.
  bool get hasUsableFile =>
      _downloadedBytes > 0 &&
      (_status == TempDownloadStatus.downloading ||
          _status == TempDownloadStatus.complete ||
          _status == TempDownloadStatus.failed ||
          _status == TempDownloadStatus.stopped);

  final _progress = StreamController<TempDownloadProgress>.broadcast();

  /// Progress readings, throttled to [kTempDownloadProgressInterval]
  /// while downloading, immediate on every status change.
  Stream<TempDownloadProgress> get progress => _progress.stream;

  TempDownloadProgress get snapshot => TempDownloadProgress(
    status: _status,
    downloadedBytes: _downloadedBytes,
    totalBytes: _totalBytes,
    bytesPerSecond: _bytesPerSecond,
    error: _error,
  );

  HttpClient? _client;
  IOSink? _sink;
  Timer? _noDataTimer;
  bool _started = false;
  bool _cancelled = false;
  bool _halted = false;

  /// b119: bytes already on disk from an earlier open, adopted by
  /// [_adoptExistingFile]. [_runDownload] discards this many bytes
  /// from the front of the fetch, then appends the rest.
  int _existingBytes = 0;
  DateTime? _lastEmitAt;
  int _rateCapBytesPerSecond = 2 * 1024 * 1024;
  double _throttleDebtSeconds = 0;

  /// Caps the fetch rate (0 = unlimited). The screen lowers it while
  /// the engine is buffering so the download never starves playback,
  /// and raises it while playback is smooth.
  void setRateCap(int bytesPerSecond) {
    _rateCapBytesPerSecond = bytesPerSecond;
  }

  /// Probes the host, then fetches the film in the background. True
  /// when the temp file is usable (the fetch started, or the whole
  /// film is already on disk from an earlier open); false when no
  /// download is needed or the probe failed — the stream plays on
  /// alone either way.
  Future<bool> start() async {
    if (_started) return _status == TempDownloadStatus.downloading;
    _started = true;
    _setStatus(TempDownloadStatus.probing);
    // The probe: one byte, ranged. 206 = the host seeks fine, so this
    // whole feature is unnecessary. 200 = it does not, and the
    // Content-Length (when the host gives one) sizes the mapping.
    // The probe client is force-closed after the headers: a 200
    // answer starts sending the whole film, and nobody reads it.
    final probe = HttpClient()..autoUncompress = false;
    probe.connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await probe.getUrl(Uri.parse(url));
      _applyHeaders(request);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            throw TimeoutException('probe', const Duration(seconds: 10)),
      );
      final total = response.contentLength;
      if (response.statusCode == HttpStatus.partialContent) {
        _setStatus(TempDownloadStatus.notNeeded);
        return false;
      }
      if (response.statusCode != HttpStatus.ok) {
        _error = 'probe http ${response.statusCode}';
        _setStatus(TempDownloadStatus.failed);
        return false;
      }
      _totalBytes = total >= 0 ? total : null;
    } catch (e) {
      _error = '$e';
      _setStatus(TempDownloadStatus.failed);
      return false;
    } finally {
      probe.close(force: true);
    }
    if (_cancelled) return false;
    // b119: a file kept from an earlier open of this film is adopted
    // (see [_adoptExistingFile]); a complete one needs no fetch at
    // all — the screen can open the local file at once.
    _adoptExistingFile();
    if (_totalBytes != null &&
        _totalBytes! > 0 &&
        _existingBytes >= _totalBytes!) {
      _setStatus(TempDownloadStatus.complete);
      return true;
    }
    unawaited(_runDownload());
    return true;
  }

  /// b119: if a file for this URL is already on disk (kept from an
  /// earlier open while Zeus stayed open), adopt its length as already
  /// downloaded. [_runDownload] fetches from byte 0 but discards the
  /// first [_existingBytes] and appends the rest, so the file stays
  /// continuous. A file longer than the film is stale (a different
  /// encode at the same URL, or a torn write): drop it and start over.
  void _adoptExistingFile() {
    try {
      if (_file.existsSync()) {
        final length = _file.lengthSync();
        if (_totalBytes != null && length > _totalBytes!) {
          _file.deleteSync();
          _existingBytes = 0;
          _downloadedBytes = 0;
        } else {
          _existingBytes = length;
          _downloadedBytes = length;
        }
      }
    } catch (_) {
      _existingBytes = 0;
      _downloadedBytes = 0;
    }
  }

  Future<void> _runDownload() async {
    if (_cancelled) return;
    _setStatus(TempDownloadStatus.downloading);
    final client = HttpClient()..autoUncompress = false;
    client.connectionTimeout = const Duration(seconds: 15);
    _client = client;
    try {
      final request = await client.getUrl(Uri.parse(url));
      _applyHeaders(request);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        _fail('http ${response.statusCode}');
        return;
      }
      // A host that would not say its length on the probe may say it
      // here; take it when it comes.
      if (_totalBytes == null && response.contentLength >= 0) {
        _totalBytes = response.contentLength;
      }
      // b119: append mode — the file may already hold the film's
      // first [_existingBytes] from an earlier open, and the fetch
      // below discards that prefix before appending the rest.
      final sink = _file.openWrite(mode: FileMode.append);
      _sink = sink;
      _armNoDataTimer();
      // b119: bytes to skip from the front of the fetch — the prefix
      // already on disk. The discard is NOT throttled: playback is on
      // the local file by then (or the stream), and the catch-up must
      // not take the whole film to run. Only written bytes are
      // throttled and counted (see [_downloadedBytes]).
      var toDiscard = _existingBytes;
      await for (final chunk in response) {
        if (_cancelled) break;
        // A burst the socket already holds can be megabytes on a fast
        // link: pace it in 32 KiB pieces, throttling BEFORE each piece
        // is written, so the rate cap binds from the first byte — and
        // flush after each network chunk, so the file on disk keeps up
        // with [_downloadedBytes] (mpv reads the file while it grows).
        var offset = 0;
        if (toDiscard > 0) {
          final skip = math.min(toDiscard, chunk.length);
          offset = skip;
          toDiscard -= skip;
          _armNoDataTimer();
        }
        var failed = false;
        while (offset < chunk.length) {
          if (_cancelled) break;
          final end = math.min(offset + 32 * 1024, chunk.length);
          final piece = chunk.sublist(offset, end);
          await _throttle(piece.length);
          if (_cancelled) break;
          try {
            sink.add(piece);
          } on FileSystemException catch (e) {
            // No space (ENOSPC) or a dead volume: stop, keep what
            // arrived.
            _error = e.osError?.message ?? '$e';
            _fail(_error!);
            failed = true;
            break;
          }
          _downloadedBytes += piece.length;
          _noteBytes(piece.length);
          _armNoDataTimer();
          offset = end;
        }
        if (failed) break;
        await sink.flush();
        _emitProgress();
      }
      await sink.flush();
      await sink.close();
      _sink = null;
      if (_cancelled) return;
      if (_status == TempDownloadStatus.failed) return;
      if (_totalBytes != null && _downloadedBytes < _totalBytes!) {
        _fail('truncated');
        return;
      }
      _setStatus(TempDownloadStatus.complete);
    } catch (e) {
      if (!_cancelled) _fail('$e');
    } finally {
      _noDataTimer?.cancel();
      _noDataTimer = null;
      try {
        await _sink?.close();
      } catch (_) {}
      _sink = null;
      _client?.close(force: true);
      _client = null;
      _emitProgress(force: true);
    }
  }

  /// The bytes the film needs at [target], plus the keyframe run-up.
  int bytesNeededFor(Duration target) {
    final total = _totalBytes;
    if (total == null || total <= 0 || duration <= Duration.zero) {
      return 1 << 62;
    }
    final atTarget = (total * target.inMicroseconds / duration.inMicroseconds)
        .round();
    return atTarget + _seekMarginBytes;
  }

  int get _seekMarginBytes {
    final total = _totalBytes;
    if (total == null || total <= 0 || duration <= Duration.zero) {
      return kTempDownloadSeekMarginBytes;
    }
    final tenSeconds =
        (total *
                kTempDownloadSeekMarginTime.inMicroseconds /
                duration.inMicroseconds)
            .round();
    return math.max(kTempDownloadSeekMarginBytes, tenSeconds);
  }

  /// Whether a seek to [target] can open the local file now: the bytes
  /// up to the target plus the keyframe run-up have arrived. A complete
  /// file answers any target inside the film.
  bool isDownloaded(Duration target) {
    if (target < Duration.zero) return false;
    if (_status == TempDownloadStatus.complete) {
      return target < duration;
    }
    if (_totalBytes == null || _totalBytes! <= 0) return false;
    if (duration <= Duration.zero) return false;
    return _downloadedBytes >= bytesNeededFor(target);
  }

  /// How far into the film the downloaded bytes reach, or null when
  /// the total is unknown (no mapping exists).
  Duration? downloadedUpTo() {
    final total = _totalBytes;
    if (total == null || total <= 0 || duration <= Duration.zero) {
      return null;
    }
    final micros = (_downloadedBytes * duration.inMicroseconds / total).round();
    final upTo = Duration(microseconds: micros);
    return upTo > duration ? duration : upTo;
  }

  /// 0..1 of the film downloaded, or 0 when the total is unknown.
  double downloadedFraction() {
    final upTo = downloadedUpTo();
    if (upTo == null || duration <= Duration.zero) return 0;
    return (upTo.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);
  }

  /// How long until [target] is downloaded at the recent rate, or null
  /// when the rate is unknown or the target is already here.
  Duration? etaTo(Duration target) {
    if (isDownloaded(target)) return Duration.zero;
    if (_bytesPerSecond <= 0) return null;
    final remaining = bytesNeededFor(target) - _downloadedBytes;
    if (remaining <= 0) return Duration.zero;
    return Duration(milliseconds: (remaining / _bytesPerSecond * 1000).round());
  }

  /// Stops the download but KEEPS the temp file (b119). The file lives
  /// as long as Zeus is open, so reopening the film resumes from the
  /// bytes already fetched instead of starting over. Idempotent: safe
  /// to call on player close, on episode end, and when a new film
  /// starts. The file is deleted only by [cancel] (the viewer
  /// cancelling) or by [sweepStale] (Zeus closing, or a stale file at
  /// launch).
  Future<void> stop() async {
    if (_halted) return;
    _halted = true;
    _cancelled = true;
    _noDataTimer?.cancel();
    _noDataTimer = null;
    _client?.close(force: true);
    _client = null;
    try {
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    if (_status == TempDownloadStatus.probing ||
        _status == TempDownloadStatus.downloading) {
      _setStatus(TempDownloadStatus.stopped);
    }
    await _progress.close();
  }

  /// Stops the download and deletes the temp file. Idempotent: the
  /// viewer cancelling the download. A [stop] first does not spare
  /// the file — the delete still runs.
  Future<void> cancel() async {
    await stop();
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {}
    if (_status != TempDownloadStatus.cancelled) {
      _setStatus(TempDownloadStatus.cancelled);
    }
  }

  /// Same as [stop]: the file outlives the player now (b119) — it is
  /// deleted only when Zeus closes or the viewer cancels.
  Future<void> dispose() => stop();

  /// Deletes temp files a crash or a kill left behind. Called once at
  /// app start, before any film can be open — and on app close
  /// (detached, b119), when Zeus is shut and the kept files are due
  /// to go. Either way, nothing can be playing yet (start) or any
  /// longer (detach), so clearing them is safe.
  static Future<void> sweepStale(Directory directory) async {
    try {
      await for (final entity in directory.list()) {
        if (entity is File &&
            p.basename(entity.path).startsWith(kTempDownloadFilePrefix)) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _applyHeaders(HttpClientRequest request) {
    final headers = this.headers;
    if (headers == null) return;
    for (final entry in headers.entries) {
      try {
        request.headers.set(entry.key, entry.value);
      } catch (_) {}
    }
  }

  void _fail(String error) {
    _error = error;
    _setStatus(TempDownloadStatus.failed);
  }

  void _noteBytes(int count) {
    // Exponential average over chunk arrivals: recent enough for an
    // ETA, smooth enough not to jump with every chunk.
    final now = DateTime.now();
    final last = _lastChunkAt;
    _lastChunkAt = now;
    if (last == null) {
      _bytesPerSecond = count.toDouble();
      return;
    }
    final gap = now.difference(last).inMilliseconds / 1000;
    if (gap <= 0) return;
    final instant = count / gap;
    _bytesPerSecond = _bytesPerSecond * 0.7 + instant * 0.3;
  }

  DateTime? _lastChunkAt;

  void _armNoDataTimer() {
    _noDataTimer?.cancel();
    _noDataTimer = Timer(kTempDownloadNoDataAfter, () {
      if (!_cancelled && _status == TempDownloadStatus.downloading) {
        _fail('no data for ${kTempDownloadNoDataAfter.inSeconds}s');
      }
    });
  }

  Future<void> _throttle(int bytes) async {
    final cap = _rateCapBytesPerSecond;
    if (cap <= 0) return;
    _throttleDebtSeconds += bytes / cap;
    while (_throttleDebtSeconds > 0.05 && !_cancelled) {
      final slice = math.min(_throttleDebtSeconds, 0.1);
      await Future<void>.delayed(
        Duration(milliseconds: (slice * 1000).round()),
      );
      _throttleDebtSeconds -= slice;
    }
    if (_throttleDebtSeconds < 0) _throttleDebtSeconds = 0;
  }

  void _emitProgress({bool force = false}) {
    if (_progress.isClosed) return;
    final now = DateTime.now();
    final last = _lastEmitAt;
    if (!force &&
        last != null &&
        now.difference(last) < kTempDownloadProgressInterval) {
      return;
    }
    _lastEmitAt = now;
    _progress.add(snapshot);
  }

  void _setStatus(TempDownloadStatus status) {
    _status = status;
    _emitProgress(force: true);
  }

  static String _extensionOf(String url) {
    final uri = Uri.tryParse(url);
    final path = uri?.path.toLowerCase() ?? '';
    for (final ext in const ['.mkv', '.mp4', '.webm', '.avi', '.mov']) {
      if (path.endsWith(ext)) return ext;
    }
    return '.mkv';
  }
}

/// The QoE overlay's `temp:` line: what the temp download holds, in
/// human units, and how far into the film that reaches.
String tempDownloadOverlayLine(TempDownloadProgress p, Duration duration) {
  String mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);
  String rate(double bytesPerSecond) =>
      (bytesPerSecond / (1024 * 1024)).toStringAsFixed(1);
  String clock(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  final total = p.totalBytes;
  final upTo = _downloadedUpTo(p, duration);
  final upToText = upTo == null ? '?' : clock(upTo);
  switch (p.status) {
    case TempDownloadStatus.downloading:
      final totalText = total == null ? '?' : '${mb(total)} MB';
      final percent = total == null
          ? ''
          : ' (${(p.downloadedBytes / total * 100).toStringAsFixed(0)}%)';
      return 'temp: downloading ${mb(p.downloadedBytes)} MB / $totalText'
          '$percent · ${rate(p.bytesPerSecond)} MiB/s · up to $upToText';
    case TempDownloadStatus.complete:
      return 'temp: done ${mb(p.downloadedBytes)} MB · up to $upToText';
    case TempDownloadStatus.failed:
      return 'temp: failed at ${mb(p.downloadedBytes)} MB (kept) · '
          'up to $upToText';
    case TempDownloadStatus.stopped:
      return 'temp: stopped at ${mb(p.downloadedBytes)} MB (kept) · '
          'up to $upToText';
    case TempDownloadStatus.notNeeded:
      return 'temp: not needed (host seeks)';
    case TempDownloadStatus.cancelled:
      return 'temp: off (cancelled)';
    case TempDownloadStatus.probing:
      return 'temp: probing…';
  }
}

Duration? _downloadedUpTo(TempDownloadProgress p, Duration duration) {
  final total = p.totalBytes;
  if (total == null || total <= 0 || duration <= Duration.zero) return null;
  final micros = (p.downloadedBytes * duration.inMicroseconds / total).round();
  final upTo = Duration(microseconds: micros);
  return upTo > duration ? duration : upTo;
}
