/// Build 77: when the mpv screen opens a film through the stream cache
/// proxy (`core/services/stream_cache`), and what the QoE overlay says
/// about it. Build 86: the libVLC screen opens through the same proxy
/// for the same plain files (see `streamProxyBypassReason`) — its
/// prefetch fills from the phone instead of the host at the host's pace,
/// so its buffered band keeps up with mpv's.
///
/// The proxy exists for ONE case: a plain film file over HTTP(S) on the
/// iPhone, where a renderer move (the PiP button, coming back from the
/// PiP window) makes mpv ask again for bytes it had already been given.
/// Everything else opens exactly as it did before build 77.
library;

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/services/stream_cache/stream_cache_proxy.dart';
import '../../domain/hls_video_length.dart';
import '../../domain/stream_resolver.dart';

/// Why a source is NOT opened through the proxy, or null when it is.
///
/// The word is what the overlay shows after `proxy: off`.
String? streamProxyBypassReason({
  required bool isIos,
  required StreamResult stream,
  required MultimediaItem item,
  bool blocked = false,
  bool slow = false,
}) {
  if (!isIos) return 'platform';
  // Build 78: this source kept stopping to buffer through the proxy.
  if (slow) return 'slow';
  // This source already failed through the proxy once in this screen.
  if (blocked) return 'failed';
  final url = stream.url.trim();
  if (isTorrentSource(stream)) return 'torrent';
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return 'url';
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return 'scheme';
  if (uri.host.isEmpty) return 'url';
  // Already served from the phone itself (the HLS helper proxy, the
  // torrent server): nothing to gain, and never proxy a proxy.
  final host = uri.host.toLowerCase();
  if (host == '127.0.0.1' ||
      host == 'localhost' ||
      host == '::1' ||
      host == '[::1]' ||
      host == '0.0.0.0') {
    return 'local';
  }
  if (isLiveSource(item, url)) return 'live';
  if (looksLikeHls(uri)) return 'hls';
  final path = uri.path.toLowerCase();
  final query = uri.query.toLowerCase();
  if (path.endsWith('.mpd') || query.contains('.mpd')) return 'dash';
  if (path.endsWith('.ts') || path.endsWith('.m4s')) return 'segment';
  // Protected streams are adaptive (DASH/HLS) whatever the address
  // looks like.
  if ((stream.drmKey ?? '').isNotEmpty ||
      (stream.drmKid ?? '').isNotEmpty ||
      (stream.licenseUrl ?? '').isNotEmpty) {
    return 'drm';
  }
  return null;
}

/// Whether a source may earn a temp download (build 107): a plain film
/// file over HTTP(S) — the same shape the proxy takes, minus the
/// platform and local-host checks, because the download fetches from
/// the host itself on any platform. HLS, DASH, segments, live, DRM and
/// torrents never do: their bytes do not come from one sequential file.
bool isTempDownloadEligible({
  required StreamResult stream,
  required MultimediaItem item,
}) {
  final url = stream.url.trim();
  if (isTorrentSource(stream)) return false;
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return false;
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;
  if (uri.host.isEmpty) return false;
  if (isLiveSource(item, url)) return false;
  if (looksLikeHls(uri)) return false;
  final path = uri.path.toLowerCase();
  final query = uri.query.toLowerCase();
  if (path.endsWith('.mpd') || query.contains('.mpd')) return false;
  if (path.endsWith('.ts') || path.endsWith('.m4s')) return false;
  if ((stream.drmKey ?? '').isNotEmpty ||
      (stream.drmKid ?? '').isNotEmpty ||
      (stream.licenseUrl ?? '').isNotEmpty) {
    return false;
  }
  return true;
}

String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);

String _rate(int bytesPerSecond) =>
    (bytesPerSecond / (1024 * 1024)).toStringAsFixed(1);

/// The overlay's `proxy:` line.
///
/// `proxy: on held 412MB ahead 31s hit 3 miss 1` — `held`: what the
/// phone is keeping of the film; `ahead`: how far past the player's
/// reading point that reaches, in film time; `hit`: requests answered
/// from the phone; `miss`: requests that had to go to the host (the
/// first one, and every far seek).
///
/// Build 78 adds, after those: `side`: short reads (the film's index)
/// answered with their own host request; `host`: MiB/s arriving from
/// the host; `out`: MiB/s going to the player; `mem`: MB received and
/// not on the phone's disk yet. `host` low = the host (or the network)
/// is slow; `host` fine and `out` low = the player is not taking it;
/// `mem` large and growing = the disk is behind.
///
/// `proxy: off(reason)` — this film is playing straight from the host.
String streamProxyOverlayLine({
  required bool opened,
  required String? bypassReason,
  required StreamCacheStats? stats,
  required Duration duration,
}) {
  if (!opened) return 'proxy: off(${bypassReason ?? '-'})';
  if (stats == null) return 'proxy: on ?';
  if (stats.dead) {
    return 'proxy: off(${stats.reason ?? 'failed'}) '
        'hit ${stats.hits} miss ${stats.misses}';
  }
  var ahead = '?';
  final total = stats.total;
  if (total != null && total > 0 && duration > Duration.zero) {
    final bytesPerSecond = total / (duration.inMilliseconds / 1000);
    if (bytesPerSecond > 0) {
      ahead = (stats.ahead / bytesPerSecond).toStringAsFixed(0);
    }
  }
  return 'proxy: on held ${_megabytes(stats.held)}MB ahead ${ahead}s '
      'hit ${stats.hits} miss ${stats.misses} side ${stats.sides} '
      'host ${_rate(stats.hostRate)} out ${_rate(stats.clientRate)} MiB/s '
      'mem ${_megabytes(stats.unwritten)}MB';
}

/// What `switch-wait` gets appended for the last renderer move: where
/// the request(s) mpv made for it were answered from.
///
/// ` src local` — every one from the phone (no host round trip);
/// ` src host` — at least one went to the host; ` src -` — the film is
/// not on the proxy, or mpv made no request (it still had the data).
String switchSourceNote({
  required StreamCacheStats? stats,
  required int sinceMs,
}) {
  if (stats == null || stats.dead) return ' src -';
  final during = stats.requests.where((r) => r.atMs >= sinceMs).toList();
  if (during.isEmpty) return ' src -';
  final host = during.where((r) => !r.local).length;
  if (host == 0) return ' src local';
  return during.length == host
      ? ' src host'
      : ' src host $host/${during.length}';
}

/// Build 78: notices a film that keeps stopping to buffer while it
/// plays through the proxy, so the screen can open it straight from
/// the host instead (`proxy: off(slow)`) — playback through the proxy
/// must never be worse than without it.
///
/// It is fed the engine's buffering changes and a regular tick. A
/// stop counts once the film has had [settle] to get going after an
/// open or a jump (a seek always buffers once; that is not the proxy).
/// [stallsToTrip] stops inside [window], or one stop lasting
/// [longStall], trips it.
class StreamProxySlowWatch {
  StreamProxySlowWatch({
    this.settle = const Duration(seconds: 4),
    this.window = const Duration(seconds: 20),
    this.stallsToTrip = 3,
    this.longStall = const Duration(seconds: 8),
    this.jump = const Duration(seconds: 6),
  });

  final Duration settle;
  final Duration window;
  final int stallsToTrip;
  final Duration longStall;

  /// A playhead move bigger than this between two looks is a seek.
  final Duration jump;

  int _armedAtMs = -1;
  int? _bufferingSinceMs;
  Duration? _lastPosition;
  final List<int> _stalls = <int>[];

  bool get armed => _armedAtMs >= 0;

  /// A film was opened (or re-opened) through the proxy.
  void arm(int nowMs) {
    _armedAtMs = nowMs;
    _bufferingSinceMs = null;
    _lastPosition = null;
    _stalls.clear();
  }

  /// The film is not on the proxy (any more).
  void disarm() {
    _armedAtMs = -1;
    _bufferingSinceMs = null;
    _lastPosition = null;
    _stalls.clear();
  }

  bool _jumped(Duration position) {
    final last = _lastPosition;
    _lastPosition = position;
    if (last == null) return false;
    return (position - last).abs() > jump;
  }

  /// The engine started or stopped buffering. True when the film
  /// should leave the proxy.
  bool onBuffering({
    required bool buffering,
    required Duration position,
    required int nowMs,
  }) {
    if (!armed) return false;
    if (_jumped(position)) {
      arm(nowMs);
      if (buffering) _bufferingSinceMs = null;
      return false;
    }
    if (!buffering) {
      _bufferingSinceMs = null;
      return false;
    }
    if (_bufferingSinceMs != null) return false;
    if (nowMs - _armedAtMs < settle.inMilliseconds) return false;
    _bufferingSinceMs = nowMs;
    _stalls
      ..removeWhere((at) => nowMs - at > window.inMilliseconds)
      ..add(nowMs);
    return _stalls.length >= stallsToTrip;
  }

  /// The regular look. True when the film should leave the proxy.
  bool onTick({
    required bool buffering,
    required Duration position,
    required int nowMs,
  }) {
    if (!armed) return false;
    if (_jumped(position)) {
      arm(nowMs);
      return false;
    }
    final since = _bufferingSinceMs;
    if (!buffering) {
      _bufferingSinceMs = null;
      return false;
    }
    if (since == null) return false;
    return nowMs - since >= longStall.inMilliseconds;
  }
}
