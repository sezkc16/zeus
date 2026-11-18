// Build 77: which sources the mpv screen opens through the stream
// cache proxy, and what the overlay says about it.

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/services/stream_cache/stream_cache_proxy.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_stream_proxy.dart';

MultimediaItem item({
  MultimediaContentType type = MultimediaContentType.movie,
}) => MultimediaItem(
  title: 'A Film',
  url: 'https://example.com/film',
  posterUrl: '',
  contentType: type,
  provider: 'Remote',
);

StreamResult stream(
  String url, {
  String source = 'FSLv2',
  String? drmKey,
  String? drmKid,
  String? licenseUrl,
}) => StreamResult(
  url: url,
  source: source,
  drmKey: drmKey,
  drmKid: drmKid,
  licenseUrl: licenseUrl,
);

String? reason(
  String url, {
  bool isIos = true,
  bool blocked = false,
  String source = 'FSLv2',
  MultimediaContentType type = MultimediaContentType.movie,
  String? drmKey,
  String? licenseUrl,
}) => streamProxyBypassReason(
  isIos: isIos,
  stream: stream(url, source: source, drmKey: drmKey, licenseUrl: licenseUrl),
  item: item(type: type),
  blocked: blocked,
);

void main() {
  group('what goes through the proxy', () {
    test('a plain film file over https or http on the iPhone', () {
      expect(reason('https://cdn.example/Avengers.2160p.mkv'), isNull);
      expect(reason('http://cdn.example/a/b/film.mp4?token=abc&e=1'), isNull);
      // No extension at all (signed download links) is still a file.
      expect(reason('https://pixel.example/api/file/AbCd123'), isNull);
    });
  });

  group('what does not', () {
    test('any other platform', () {
      expect(
        reason('https://cdn.example/film.mkv', isIos: false),
        'platform',
      );
    });

    test('a source that already failed through the proxy', () {
      expect(reason('https://cdn.example/film.mkv', blocked: true), 'failed');
    });

    test('HLS and DASH', () {
      expect(reason('https://cdn.example/master.m3u8'), 'hls');
      expect(reason('https://cdn.example/play?file=x.m3u8&t=1'), 'hls');
      expect(reason('https://cdn.example/list.m3u'), 'hls');
      expect(reason('https://cdn.example/manifest.mpd'), 'dash');
      expect(reason('https://cdn.example/seg-001.ts'), 'segment');
    });

    test('live streams', () {
      expect(
        reason(
          'https://cdn.example/channel.mkv',
          type: MultimediaContentType.livestream,
        ),
        'live',
      );
      expect(reason('http://iptv.example/live/user/pass/1.ts'), 'live');
    });

    test('torrents and local files', () {
      expect(reason('magnet:?xt=urn:btih:abc'), 'torrent');
      expect(reason('https://cdn.example/film.torrent'), 'torrent');
      expect(reason('/var/mobile/film.mkv', source: 'Torrent'), 'torrent');
      expect(reason('/var/mobile/Downloads/film.mkv'), 'scheme');
      expect(reason('file:///var/mobile/film.mkv'), 'scheme');
    });

    test('other schemes', () {
      expect(reason('rtmp://live.example/app/stream'), isNotNull);
      expect(reason('rtsp://cam.example/1'), isNotNull);
      expect(reason('ftp://files.example/film.mkv'), 'scheme');
      expect(reason(''), isNotNull);
    });

    test('what the phone already serves itself', () {
      expect(reason('http://127.0.0.1:8080/stream/0'), 'local');
      expect(reason('http://localhost:9000/film.mkv'), 'local');
      expect(reason('http://[::1]:9000/film.mkv'), 'local');
    });

    test('protected streams', () {
      expect(reason('https://cdn.example/film.mp4', drmKey: 'abcd'), 'drm');
      expect(
        reason('https://cdn.example/film.mp4', licenseUrl: 'https://l.example'),
        'drm',
      );
    });
  });

  group('the overlay line', () {
    StreamCacheStats stats({
      int held = 0,
      int ahead = 0,
      int? total,
      int hits = 0,
      int misses = 0,
      bool dead = false,
      String? reason,
      List<StreamCacheRequest> requests = const <StreamCacheRequest>[],
    }) => StreamCacheStats(
      held: held,
      ahead: ahead,
      total: total,
      hits: hits,
      misses: misses,
      dead: dead,
      reason: reason,
      requests: requests,
    );

    test('off, with the reason', () {
      expect(
        streamProxyOverlayLine(
          opened: false,
          bypassReason: 'hls',
          stats: null,
          duration: Duration.zero,
        ),
        'proxy: off(hls)',
      );
    });

    test('on: held in MB, ahead in film seconds, hits and misses', () {
      // A 3 h film of 22.88 GB is about 2.1 MB a second.
      const total = 22880 * 1024 * 1024;
      const duration = Duration(hours: 3);
      final perSecond = total / duration.inSeconds;
      expect(
        streamProxyOverlayLine(
          opened: true,
          bypassReason: null,
          stats: stats(
            held: 412 * 1024 * 1024,
            ahead: (perSecond * 31).round(),
            total: total,
            hits: 3,
            misses: 1,
          ),
          duration: duration,
        ),
        startsWith('proxy: on held 412MB ahead 31s hit 3 miss 1'),
      );
    });

    test('on, before the length or the duration is known', () {
      expect(
        streamProxyOverlayLine(
          opened: true,
          bypassReason: null,
          stats: stats(held: 1024 * 1024, misses: 1),
          duration: Duration.zero,
        ),
        startsWith('proxy: on held 1MB ahead ?s hit 0 miss 1'),
      );
      expect(
        streamProxyOverlayLine(
          opened: true,
          bypassReason: null,
          stats: null,
          duration: Duration.zero,
        ),
        'proxy: on ?',
      );
    });

    test('stepped aside mid-film: off with what the proxy saw', () {
      expect(
        streamProxyOverlayLine(
          opened: true,
          bypassReason: null,
          stats: stats(dead: true, reason: 'no range', misses: 1),
          duration: const Duration(hours: 1),
        ),
        'proxy: off(no range) hit 0 miss 1',
      );
    });

    group('switch-wait source', () {
      StreamCacheRequest request(int atMs, {required bool local}) =>
          StreamCacheRequest(atMs: atMs, offset: 1, local: local);

      test('local when every request of the move came from the phone', () {
        expect(
          switchSourceNote(
            stats: stats(
              requests: <StreamCacheRequest>[
                request(100, local: false), // the open, long before
                request(5000, local: true),
              ],
            ),
            sinceMs: 4000,
          ),
          ' src local',
        );
      });

      test('host when the move had to ask the host', () {
        expect(
          switchSourceNote(
            stats: stats(
              requests: <StreamCacheRequest>[request(5000, local: false)],
            ),
            sinceMs: 4000,
          ),
          ' src host',
        );
        expect(
          switchSourceNote(
            stats: stats(
              requests: <StreamCacheRequest>[
                request(5000, local: true),
                request(5100, local: false),
              ],
            ),
            sinceMs: 4000,
          ),
          ' src host 1/2',
        );
      });

      test('"-" with no proxy, a proxy that stepped aside, or no request',
          () {
        expect(switchSourceNote(stats: null, sinceMs: 0), ' src -');
        expect(
          switchSourceNote(stats: stats(dead: true), sinceMs: 0),
          ' src -',
        );
        expect(
          switchSourceNote(
            stats: stats(
              requests: <StreamCacheRequest>[request(100, local: true)],
            ),
            sinceMs: 4000,
          ),
          ' src -',
        );
      });
    });
  });
}
