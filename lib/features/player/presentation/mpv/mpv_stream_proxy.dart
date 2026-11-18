/// Build 77: when the mpv screen opens a film through the stream cache
/// proxy (`core/services/stream_cache`), and what the QoE overlay says
/// about it.
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
}) {
  if (!isIos) return 'platform';
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

String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);

/// The overlay's `proxy:` line.
///
/// `proxy: on held 412MB ahead 31s hit 3 miss 1` — `held`: what the
/// phone is keeping of the film; `ahead`: how far past the player's
/// reading point that reaches, in film time; `hit`: requests answered
/// from the phone; `miss`: requests that had to go to the host (the
/// first one, and every far seek).
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
      'hit ${stats.hits} miss ${stats.misses}';
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
  return during.length == host ? ' src host' : ' src host $host/${during.length}';
}
