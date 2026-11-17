import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/features/details/domain/season_download.dart';
import 'package:zorox/features/player/domain/stream_resolver.dart'
    show streamSourceKey;

StreamResult _s(
  String provider,
  String source,
  int? quality, {
  String? url,
}) => StreamResult(
  url: url ?? 'https://cdn.example.com/$provider-$source-${quality ?? 0}.mkv',
  source: source,
  providerName: provider,
  quality: quality,
);

Episode _ep(int number, {int season = 1}) => Episode(
  name: 'Episode $number',
  url: 'https://example.com/show/s$season/e$number',
  season: season,
  episode: number,
);

void main() {
  group('isDirectDownloadCandidate', () {
    test('a plain http file is downloadable', () {
      expect(isDirectDownloadCandidate(_s('A', 'Drive', 1080)), isTrue);
      expect(
        isDirectDownloadCandidate(
          _s('A', 'Worker', 720, url: 'https://x.example/dl?id=42'),
        ),
        isTrue,
      );
    });

    test('playlists, torrents, DRM and non-http are not', () {
      for (final url in <String>[
        'https://cdn.example.com/master.m3u8',
        'https://cdn.example.com/master.m3u8?token=1',
        'https://cdn.example.com/play?file=index.m3u8&x=1',
        'https://cdn.example.com/manifest.mpd',
        'https://cdn.example.com/a.torrent',
        'magnet:?xt=urn:btih:abc',
        'rtmp://cdn.example.com/live',
        '',
      ]) {
        expect(
          isDirectDownloadCandidate(_s('A', 'S', 1080, url: url)),
          isFalse,
          reason: url,
        );
      }
      expect(
        isDirectDownloadCandidate(
          const StreamResult(
            url: 'https://cdn.example.com/a.mp4',
            source: 'S',
            drmKid: 'kid',
            drmKey: 'key',
          ),
        ),
        isFalse,
      );
    });

    test('isNonFileMimeType', () {
      expect(isNonFileMimeType('video/mp4'), isFalse);
      expect(isNonFileMimeType(null), isFalse);
      expect(isNonFileMimeType('application/vnd.apple.mpegurl'), isTrue);
      expect(isNonFileMimeType('application/x-mpegURL'), isTrue);
      expect(isNonFileMimeType('application/dash+xml'), isTrue);
      expect(isNonFileMimeType('text/html; charset=utf-8'), isTrue);
    });
  });

  group('chooseSeasonSource', () {
    final candidates = <StreamResult>[
      _s('Alpha', 'HLS', 1080, url: 'https://a.example/master.m3u8'), // 0
      _s('Alpha', 'Drive', 480), // 1
      _s('Alpha', 'Drive', 1080), // 2
      _s('Beta', 'Pixel', 720), // 3
      _s('Beta', 'Pixel', 2160), // 4
      _s('Gamma', 'Mirror', null), // 5
    ];

    test('the remembered last-used source wins, by exact key', () {
      expect(
        chooseSeasonSource(
          candidates: candidates,
          rememberedKey: streamSourceKey(candidates[3]),
          batchPick: SeasonSourcePick.of(candidates[2]),
        ),
        3,
      );
    });

    test('a remembered source that is not downloadable is not used', () {
      // The last-played source was the HLS one.
      expect(
        chooseSeasonSource(
          candidates: candidates,
          rememberedKey: streamSourceKey(candidates[0]),
        ),
        isNull,
        reason: 'nothing picked yet: the batch must ask',
      );
      expect(
        chooseSeasonSource(
          candidates: candidates,
          rememberedKey: streamSourceKey(candidates[0]),
          batchPick: SeasonSourcePick.of(candidates[4]),
        ),
        4,
      );
    });

    test('nothing remembered, nothing picked: null (ask)', () {
      expect(chooseSeasonSource(candidates: candidates), isNull);
      expect(
        chooseSeasonSource(
          candidates: candidates,
          rememberedKey: 'Gone\u0001Away\u00011080',
        ),
        isNull,
      );
    });

    test('the batch pick by exact key', () {
      expect(
        chooseSeasonSource(
          candidates: candidates,
          batchPick: const SeasonSourcePick(
            providerName: 'Beta',
            source: 'Pixel',
            quality: 2160,
          ),
        ),
        4,
      );
    });

    test('no exact key: the same provider, closest quality', () {
      // Picked Alpha · Other 720p; this episode has Alpha at 480 and 1080.
      expect(
        chooseSeasonSource(
          candidates: candidates,
          batchPick: const SeasonSourcePick(
            providerName: 'Alpha',
            source: 'Other',
            quality: 720,
          ),
        ),
        1,
        reason: '480 is 240 away, 1080 is 360 away; Beta 720 is exact but '
            'the provider comes first',
      );
      expect(
        chooseSeasonSource(
          candidates: candidates,
          batchPick: const SeasonSourcePick(
            providerName: 'Alpha',
            source: 'Other',
            quality: 1440,
          ),
        ),
        2,
      );
    });

    test('provider gone: the closest quality overall', () {
      expect(
        chooseSeasonSource(
          candidates: candidates,
          batchPick: const SeasonSourcePick(
            providerName: 'Delta',
            source: 'X',
            quality: 720,
          ),
        ),
        3,
      );
      expect(
        chooseSeasonSource(
          candidates: candidates,
          batchPick: const SeasonSourcePick(
            providerName: 'Delta',
            source: 'X',
            quality: 4320,
          ),
        ),
        4,
      );
    });

    test('ties keep the plugin order; unknown quality sorts last', () {
      final tied = <StreamResult>[
        _s('P', 'A', null),
        _s('P', 'B', 720),
        _s('P', 'C', 720),
      ];
      const pick = SeasonSourcePick(
        providerName: 'Q',
        source: 'Z',
        quality: 720,
      );
      expect(
        rankSeasonSources(candidates: tied, batchPick: pick),
        <int>[1, 2, 0],
      );
    });

    test('the full ranking never repeats and never lists a playlist', () {
      final ranked = rankSeasonSources(
        candidates: candidates,
        rememberedKey: streamSourceKey(candidates[3]),
        batchPick: SeasonSourcePick.of(candidates[2]),
      );
      expect(ranked, <int>[3, 2, 1, 4, 5]);
    });

    test('none downloadable: null whatever is remembered or picked', () {
      final onlyHls = <StreamResult>[
        _s('A', 'HLS', 1080, url: 'https://a.example/1.m3u8'),
        _s('B', 'Torrent', 1080, url: 'magnet:?xt=urn:btih:abc'),
      ];
      expect(
        chooseSeasonSource(
          candidates: onlyHls,
          rememberedKey: streamSourceKey(onlyHls[0]),
          batchPick: SeasonSourcePick.of(onlyHls[0]),
        ),
        isNull,
      );
      expect(chooseSeasonSource(candidates: const <StreamResult>[]), isNull);
    });
  });

  group('planSeasonDownload', () {
    test('filters downloaded and queued episodes, in episode order', () async {
      final episodes = <Episode>[_ep(3), _ep(1), _ep(4), _ep(2), _ep(5)];
      final plan = await planSeasonDownload(
        episodes: episodes,
        isDownloaded: (e) async => e.episode == 2,
        isQueued: (e) => e.episode == 4,
      );
      expect(plan.toDownload.map((e) => e.episode), <int>[1, 3, 5]);
      expect(plan.alreadyDownloaded, 1);
      expect(plan.alreadyQueued, 1);
    });

    test('everything downloaded: nothing to do', () async {
      final plan = await planSeasonDownload(
        episodes: <Episode>[_ep(1), _ep(2)],
        isDownloaded: (e) async => true,
        isQueued: (e) => false,
      );
      expect(plan.toDownload, isEmpty);
      expect(plan.alreadyDownloaded, 2);
    });
  });

  group('runSeasonDownload', () {
    final drive1080 = _s('Alpha', 'Drive', 1080);
    final drive720 = _s('Alpha', 'Drive', 720);
    final pixel720 = _s('Beta', 'Pixel', 720);
    final hls = _s('Alpha', 'HLS', 1080, url: 'https://a.example/m.m3u8');

    test('queues every episode in order, one at a time', () async {
      final log = <String>[];
      var inFlight = 0;
      var maxInFlight = 0;
      final result = await runSeasonDownload(
        episodes: <Episode>[_ep(1), _ep(2), _ep(3)],
        rememberedKey: streamSourceKey(drive1080),
        isCancelled: () => false,
        resolve: (e) async {
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          log.add('resolve ${e.episode}');
          await Future<void>.delayed(Duration.zero);
          return <StreamResult>[hls, drive720, drive1080];
        },
        enqueue: (e, s) async {
          log.add('enqueue ${e.episode} ${s.quality}');
          await Future<void>.delayed(Duration.zero);
          inFlight--;
          return SeasonEnqueueResult.queued;
        },
        askPick: (e, list) async => fail('must not ask: source remembered'),
      );
      expect(log, <String>[
        'resolve 1',
        'enqueue 1 1080',
        'resolve 2',
        'enqueue 2 1080',
        'resolve 3',
        'enqueue 3 1080',
      ]);
      expect(maxInFlight, 1, reason: 'sequential');
      expect(result.queued, 3);
      expect(result.processed, 3);
      expect(result.finished, isTrue);
      expect(result.cancelled, isFalse);
    });

    test('asks once, on the first episode that needs it', () async {
      final asked = <int>[];
      final enqueued = <String>[];
      final result = await runSeasonDownload(
        episodes: <Episode>[_ep(1), _ep(2), _ep(3)],
        isCancelled: () => false,
        resolve: (e) async => switch (e.episode) {
          // Episode 2 lacks the exact pick: same provider, other quality.
          2 => <StreamResult>[pixel720, drive1080],
          // Episode 3 lacks the provider: closest quality overall.
          3 => <StreamResult>[hls, pixel720],
          _ => <StreamResult>[hls, pixel720, drive720, drive1080],
        },
        askPick: (e, downloadable) async {
          asked.add(e.episode);
          expect(downloadable, isNot(contains(hls)));
          return drive720;
        },
        enqueue: (e, s) async {
          enqueued.add('${e.episode}:${s.providerName}/${s.quality}');
          return SeasonEnqueueResult.queued;
        },
      );
      expect(asked, <int>[1]);
      expect(enqueued, <String>['1:Alpha/720', '2:Alpha/1080', '3:Beta/720']);
      expect(result.queued, 3);
    });

    test('an episode with no downloadable source is skipped and counted', () async {
      final progress = <SeasonDownloadProgress>[];
      final result = await runSeasonDownload(
        episodes: <Episode>[_ep(1), _ep(2), _ep(3), _ep(4)],
        rememberedKey: streamSourceKey(drive1080),
        isCancelled: () => false,
        resolve: (e) async {
          if (e.episode == 2) return <StreamResult>[hls];
          if (e.episode == 3) throw StateError('plugin failed');
          return <StreamResult>[drive1080];
        },
        askPick: (e, list) async => fail('must not ask'),
        enqueue: (e, s) async => e.episode == 4
            ? SeasonEnqueueResult.failed
            : SeasonEnqueueResult.queued,
        onProgress: progress.add,
      );
      expect(result.queued, 1);
      expect(result.noSource, 1);
      expect(result.failed, 2, reason: 'links failed + manager refused');
      expect(result.processed, 4);
      expect(progress.map((p) => p.processed), <int>[1, 2, 3, 4, 4]);
      expect(progress.last.finished, isTrue);
    });

    test('a source that is not a file falls through to the next best', () async {
      final tried = <String>[];
      final result = await runSeasonDownload(
        episodes: <Episode>[_ep(1)],
        rememberedKey: streamSourceKey(drive1080),
        isCancelled: () => false,
        resolve: (e) async => <StreamResult>[drive1080, drive720, pixel720],
        askPick: (e, downloadable) async {
          // The remembered source was tried and is not offered again.
          expect(downloadable, <StreamResult>[drive720, pixel720]);
          return pixel720;
        },
        enqueue: (e, s) async {
          tried.add('${s.providerName}/${s.quality}');
          return s == drive720
              ? SeasonEnqueueResult.queued
              : SeasonEnqueueResult.notDownloadable;
        },
      );
      expect(tried, <String>['Alpha/1080', 'Beta/720', 'Alpha/720']);
      expect(result.queued, 1);
    });

    test('gives an episode up after the attempt limit', () async {
      var attempts = 0;
      final many = <StreamResult>[
        for (var i = 0; i < 10; i++) _s('P$i', 'S', 720),
      ];
      final result = await runSeasonDownload(
        episodes: <Episode>[_ep(1)],
        isCancelled: () => false,
        resolve: (e) async => many,
        askPick: (e, list) async => list.first,
        enqueue: (e, s) async {
          attempts++;
          return SeasonEnqueueResult.notDownloadable;
        },
      );
      expect(attempts, kSeasonMaxSourceAttempts);
      expect(result.noSource, 1);
      expect(result.queued, 0);
    });

    test('cancel stops queuing more and keeps what is queued', () async {
      var cancelled = false;
      final enqueued = <int>[];
      final resolved = <int>[];
      final result = await runSeasonDownload(
        episodes: <Episode>[for (var i = 1; i <= 6; i++) _ep(i)],
        rememberedKey: streamSourceKey(drive1080),
        isCancelled: () => cancelled,
        resolve: (e) async {
          resolved.add(e.episode);
          return <StreamResult>[drive1080];
        },
        askPick: (e, list) async => fail('must not ask'),
        enqueue: (e, s) async {
          enqueued.add(e.episode);
          if (e.episode == 2) cancelled = true; // Stop pressed meanwhile
          return SeasonEnqueueResult.queued;
        },
      );
      expect(enqueued, <int>[1, 2]);
      expect(resolved, <int>[1, 2], reason: 'episode 3 is never started');
      expect(result.queued, 2);
      expect(result.processed, 2);
      expect(result.cancelled, isTrue);
      expect(result.finished, isTrue);
      expect(result.skipped, 4);
    });

    test('cancel during a links call drops that episode', () async {
      var cancelled = false;
      final enqueued = <int>[];
      final result = await runSeasonDownload(
        episodes: <Episode>[_ep(1), _ep(2)],
        rememberedKey: streamSourceKey(drive1080),
        isCancelled: () => cancelled,
        resolve: (e) async {
          if (e.episode == 2) cancelled = true;
          return <StreamResult>[drive1080];
        },
        askPick: (e, list) async => fail('must not ask'),
        enqueue: (e, s) async {
          enqueued.add(e.episode);
          return SeasonEnqueueResult.queued;
        },
      );
      expect(enqueued, <int>[1]);
      expect(result.cancelled, isTrue);
      expect(result.skipped, 1);
    });

    test('dismissing the source question cancels the batch', () async {
      var enqueues = 0;
      final result = await runSeasonDownload(
        episodes: <Episode>[_ep(1), _ep(2)],
        isCancelled: () => false,
        resolve: (e) async => <StreamResult>[drive1080],
        askPick: (e, list) async => null,
        enqueue: (e, s) async {
          enqueues++;
          return SeasonEnqueueResult.queued;
        },
      );
      expect(enqueues, 0);
      expect(result.cancelled, isTrue);
      expect(result.queued, 0);
      expect(result.skipped, 2);
    });
  });
}
