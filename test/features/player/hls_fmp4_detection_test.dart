/// Build 100: fMP4 HLS detection — software decode only for fragmented
/// MP4, VideoToolbox kept for plain .ts HLS.
///
/// Fixtures are the real playlists: Nebula's The Odyssey master + 1080p
/// media head (saved 2026-11-20, `/tmp/odyssey/master.m3u8` +
/// `pl1080.m3u8`) and Paris's live media head (fetched the same day).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/domain/hls_fmp4_detection.dart';

/// Nebula's The Odyssey master, verbatim: two variants, no CODECS, and
/// the variant URIs disguised as .jpg.
const String _nebulaMaster = '''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-STREAM-INF:BANDWIDTH=4192000,RESOLUTION=1920x1080,NAME="1080p"
1080p/playlist.jpg
#EXT-X-STREAM-INF:BANDWIDTH=1928000,RESOLUTION=1280x720,NAME="720p"
720p/playlist.jpg
''';

/// The same master as the local proxy rewrites it: variant lines are
/// absolute proxy URLs carrying `&extension=.m3u8`.
const String _nebulaMasterProxied = '''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-STREAM-INF:BANDWIDTH=4192000,RESOLUTION=1920x1080,NAME="1080p"
http://127.0.0.1:8899/proxy?url=https%3A%2F%2Fnebula.bright67.online%2Fhls%2F15e4865c%2F1080p%2Fplaylist.jpg&extension=.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1928000,RESOLUTION=1280x720,NAME="720p"
http://127.0.0.1:8899/proxy?url=https%3A%2F%2Fnebula.bright67.online%2Fhls%2F15e4865c%2F720p%2Fplaylist.jpg&extension=.m3u8
''';

/// Nebula's 1080p media head, verbatim: the init segment is line 6,
/// segments disguised as .jpg / .png / .jpeg.
const String _nebulaMediaHead = '''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:8
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MAP:URI="init.mp4"
#EXTINF:7.924583,
playlist_000.jpg
#EXTINF:3.962292,
playlist_001.png
#EXTINF:3.962292,
playlist_002.jpeg
''';

/// Paris's live media head, verbatim: plain .ts segments, no init
/// segment anywhere in its 153 KB.
const String _parisMediaHead = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:14
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:11.803456,
JOnon9yvpsVrR0Cq2YFzAH4YQw05maEFcVp0.ts
#EXTINF:3.169833,
JOnon9yvpsVrR0Cq2YFzAH4YQw05maEFcVp1.ts
#EXTINF:10.385378,
JOnon9yvpsVrR0Cq2YFzAH4YQw05maEFcVp2.ts
''';

/// A media playlist whose segments name .mp4 parts outright.
const String _mp4Segments = '''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
seg-0.m4s
#EXTINF:6.0,
seg-1.m4s
''';

/// Answers from [pages] and records what was asked for.
class _Web {
  _Web(this.pages);

  final Map<String, String> pages;
  final List<Uri> asked = <Uri>[];

  Future<String?> fetch(Uri url) async {
    asked.add(url);
    return pages[url.toString()];
  }
}

void main() {
  group('isFmp4MediaPlaylist', () {
    test('Nebula head: init segment means fMP4', () {
      expect(isFmp4MediaPlaylist(_nebulaMediaHead), isTrue);
    });

    test('Paris head: .ts segments, no init segment means .ts', () {
      expect(isFmp4MediaPlaylist(_parisMediaHead), isFalse);
    });

    test('.mp4 / .m4s segment names mean fMP4', () {
      expect(isFmp4MediaPlaylist(_mp4Segments), isTrue);
    });

    test('a header with neither marker says nothing', () {
      expect(
        isFmp4MediaPlaylist('#EXTM3U\n#EXT-X-VERSION:3\n'),
        isNull,
      );
    });

    test('empty text says nothing', () {
      expect(isFmp4MediaPlaylist(''), isNull);
    });
  });

  group('isHlsMasterPlaylist', () {
    test('Nebula master lists variants', () {
      expect(isHlsMasterPlaylist(_nebulaMaster), isTrue);
    });

    test('a media playlist lists none', () {
      expect(isHlsMasterPlaylist(_nebulaMediaHead), isFalse);
      expect(isHlsMasterPlaylist(_parisMediaHead), isFalse);
    });
  });

  group('detectFmp4Hls', () {
    test('Nebula master + variant reads fMP4', () async {
      final master = Uri.parse(
        'https://nebula.bright67.online/hls/15e4865c/master.m3u8',
      );
      final web = _Web(<String, String>{
        '$master': _nebulaMaster,
        'https://nebula.bright67.online/hls/15e4865c/1080p/playlist.jpg':
            _nebulaMediaHead,
      });
      expect(await detectFmp4Hls(master, web.fetch), isTrue);
      expect(web.asked, hasLength(2));
    });

    test('Nebula master as the proxy rewrites it reads fMP4', () async {
      final master = Uri.parse(
        'http://127.0.0.1:8899/proxy?url=https%3A%2F%2Fnebula.bright67.online%2Fhls%2F15e4865c%2Fmaster.m3u8',
      );
      const variant =
          'http://127.0.0.1:8899/proxy?url=https%3A%2F%2Fnebula.bright67.online%2Fhls%2F15e4865c%2F1080p%2Fplaylist.jpg&extension=.m3u8';
      final web = _Web(<String, String>{
        '$master': _nebulaMasterProxied,
        variant: _nebulaMediaHead,
      });
      expect(await detectFmp4Hls(master, web.fetch), isTrue);
      expect(web.asked, hasLength(2));
    });

    test('Paris media playlist reads .ts with one request', () async {
      final media = Uri.parse(
        'https://of265724.ofbax.com/files/aa/JOnon9yvpsVrR0Cq2YFzAH4YQw05maEFcVp.m3u8',
      );
      final web = _Web(<String, String>{'$media': _parisMediaHead});
      expect(await detectFmp4Hls(media, web.fetch), isFalse);
      expect(web.asked, hasLength(1));
    });

    test('an unreadable playlist is unknown, not .ts', () async {
      final master = Uri.parse('https://cdn.test/dead/master.m3u8');
      expect(
        await detectFmp4Hls(master, (_) async => null),
        isNull,
      );
    });

    test('a master with no variant is unknown', () async {
      final master = Uri.parse('https://cdn.test/empty/master.m3u8');
      final web = _Web(<String, String>{
        '$master': '#EXTM3U\n#EXT-X-VERSION:3\n',
      });
      expect(await detectFmp4Hls(master, web.fetch), isNull);
    });
  });
}
