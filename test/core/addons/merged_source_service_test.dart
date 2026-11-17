/// Sources for a title opened from Browse: installed plugins, Nuvio
/// providers and Stremio add-ons asked together, each link labelled with
/// where it came from, shown as each one answers.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/addons/data/addon_stream_service.dart';
import 'package:zorox/core/addons/data/merged_source_service.dart';
import 'package:zorox/core/addons/models/addon_manifest.dart';
import 'package:zorox/core/addons/models/addon_stream_source.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/extensions/base_provider.dart';
import 'package:zorox/core/nuvio/data/nuvio_stream_service.dart';
import 'package:zorox/core/nuvio/models/nuvio_models.dart';

class _Plugin extends SkyStreamProvider {
  _Plugin(
    this.name, {
    this.results = const [],
    this.details,
    this.streams = const {},
    this.failSearch = false,
    this.gate,
  });

  @override
  final String name;
  final List<MultimediaItem> results;
  final MultimediaItem? details;
  final Map<String, List<StreamResult>> streams;
  final bool failSearch;
  final Completer<void>? gate;

  final List<String> searched = [];
  final List<String> loaded = [];

  @override
  String get packageName => 'pkg.${name.toLowerCase()}';
  @override
  String get mainUrl => 'https://$name.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['en'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.movie};

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    searched.add(query);
    if (gate != null) await gate!.future;
    if (failSearch) throw Exception('site down');
    return results;
  }

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};

  @override
  Future<MultimediaItem> getDetails(String url) async => details!;

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    loaded.add(url);
    return streams[url] ?? const [];
  }
}

MultimediaItem _item(
  String title, {
  String url = 'u',
  int? year,
  MultimediaContentType type = MultimediaContentType.movie,
  List<Episode>? episodes,
}) => MultimediaItem(
  title: title,
  url: url,
  posterUrl: '',
  year: year,
  contentType: type,
  episodes: episodes,
);

final _addon = ManagedAddon(
  manifestUrl: 'https://torrentio.test/manifest.json',
  addedAt: DateTime(2026),
);

const _addonLink = AddonStreamSource(
  addonId: 'torrentio',
  addonName: 'Torrentio',
  url: 'https://cdn.test/inception.1080p.mkv',
  name: 'Torrentio 1080p',
);

MergedSourceService _service({
  List<SkyStreamProvider> plugins = const [],
  List<ManagedAddon> addons = const [],
  Stream<AddonStreamProgress> Function(AddonStreamRequest)? addonAnswers,
  Stream<NuvioProgress> Function(String id, String type, int? s, int? e)?
  nuvioAnswers,
}) => MergedSourceService(
  plugins: () => plugins,
  streamAddons: () => addons,
  askAddons: ({
    required addons,
    required request,
    required forceRefresh,
    required personWaiting,
  }) => addonAnswers!(request),
  askNuvio:
      ({
        required id,
        required mediaType,
        season,
        episode,
        required personWaiting,
        required fresh,
      }) =>
          nuvioAnswers?.call(id, mediaType, season, episode) ??
          Stream.value(const NuvioProgress()),
);

const _movie = AddonStreamRequest(
  type: 'movie',
  contentId: 'tt1375666',
  imdbId: 'tt1375666',
  title: 'Inception',
  year: 2010,
);

void main() {
  v8Tests();
  group('bestTitleMatch', () {
    test('takes the title itself over a longer one', () {
      final match = bestTitleMatch(
        [_item('Inception: The Cobol Job'), _item('Inception', url: 'right')],
        title: 'Inception',
        year: 2010,
      );
      expect(match?.url, 'right');
    });

    test('accepts a release-style name that starts with the title', () {
      final match = bestTitleMatch(
        [_item('Inception (2010) Hindi Dubbed 1080p', url: 'right')],
        title: 'Inception',
        year: 2010,
      );
      expect(match?.url, 'right');
    });

    test('passes over another year and unrelated titles', () {
      expect(
        bestTitleMatch(
          [_item('Dune', year: 1984), _item('Interstellar')],
          title: 'Dune',
          year: 2021,
        ),
        isNull,
      );
    });

    test('prefers the right year when two share a name', () {
      final match = bestTitleMatch(
        [
          _item('Dune', year: 1984, url: 'old'),
          _item('Dune (2021)', url: 'new'),
        ],
        title: 'Dune',
        year: 2021,
      );
      expect(match?.url, 'new');
    });

    test('a series picks the page of the wanted season', () {
      final match = bestTitleMatch(
        [
          _item('Dark Season 1', url: 's1', type: MultimediaContentType.series),
          _item('Dark Season 2', url: 's2', type: MultimediaContentType.series),
        ],
        title: 'Dark',
        isSeries: true,
        season: 2,
      );
      expect(match?.url, 's2');
    });
  });

  group('playUrlFor', () {
    test('a film plays its own data url', () {
      expect(
        playUrlFor(
          _item(
            'Inception',
            episodes: [Episode(name: 'Movie', url: 'data')],
          ),
          isSeries: false,
        ),
        'data',
      );
      expect(
        playUrlFor(_item('Inception', url: 'page'), isSeries: false),
        'page',
      );
    });

    test('a series plays the wanted season and episode', () {
      final show = _item(
        'Dark',
        episodes: [
          Episode(name: 'a', url: 's1e1', season: 1, episode: 1),
          Episode(name: 'b', url: 's1e2', season: 1, episode: 2),
          Episode(name: 'c', url: 's2e1', season: 2, episode: 1),
        ],
      );
      expect(playUrlFor(show, isSeries: true, season: 1, episode: 2), 's1e2');
      expect(playUrlFor(show, isSeries: true, season: 2, episode: 1), 's2e1');
      expect(playUrlFor(show, isSeries: true, season: 3, episode: 1), isNull);
    });

    test('a one-season page matches on the episode number', () {
      final show = _item(
        'Dark Season 2',
        episodes: [
          Episode(name: 'a', url: 'e1', episode: 1),
          Episode(name: 'b', url: 'e2', episode: 2),
        ],
      );
      expect(playUrlFor(show, isSeries: true, season: 2, episode: 2), 'e2');
      expect(playUrlFor(show, isSeries: true, season: 1, episode: 2), isNull);
    });
  });

  group('MergedSourceService', () {
    test(
      'plugin, Nuvio and add-on links arrive together, each labelled',
      () async {
        final plugin = _Plugin(
          'Anikoto',
          results: [_item('Inception', url: 'page', year: 2010)],
          details: _item(
            'Inception',
            url: 'page',
            episodes: [Episode(name: 'Movie', url: 'data')],
          ),
          streams: {
            'data': const [
              StreamResult(
                url: 'https://plug.test/a.m3u8',
                source: 'Server 1',
                quality: 1080,
                headers: {'Referer': 'https://plug.test/'},
              ),
            ],
          },
        );
        String? nuvioAskedWith;
        final service = _service(
          plugins: [plugin],
          addons: [_addon],
          addonAnswers: (_) => Stream.value(
            const AddonStreamProgress(
              streams: [_addonLink],
              statuses: [
                AddonQueryStatus(
                  addonName: 'Torrentio',
                  outcome: AddonQueryOutcome.links,
                  linkCount: 1,
                ),
              ],
              completedCount: 1,
              totalCount: 1,
            ),
          ),
          nuvioAnswers: (id, type, s, e) {
            nuvioAskedWith = '$id|$type';
            return Stream.value(
              const NuvioProgress(
                streams: [
                  NuvioStreamResult(
                    scraperId: 'showbox',
                    scraperName: 'ShowBox',
                    title: 'Inception 2010',
                    url: 'https://nuvio.test/b.mp4',
                    quality: '720p',
                  ),
                ],
                statuses: [
                  NuvioScraperStatus(
                    scraperName: 'ShowBox',
                    outcome: NuvioScraperOutcome.links,
                    linkCount: 1,
                  ),
                ],
                completedCount: 1,
                totalCount: 1,
              ),
            );
          },
        );

        final last = await service.resolve(request: _movie).last;

        expect(last.isLoading, isFalse);
        expect(
          {for (final s in last.streams) s.addonName},
          {'Anikoto', 'ShowBox', 'Torrentio'},
        );
        final fromPlugin = last.streams.firstWhere(
          (s) => s.addonId.startsWith(kPluginSourcePrefix),
        );
        expect(fromPlugin.url, 'https://plug.test/a.m3u8');
        expect(fromPlugin.headline, 'Anikoto');
        expect(fromPlugin.qualityLabel, '1080p');
        expect(fromPlugin.proxyHeaders, {'Referer': 'https://plug.test/'});
        expect(fromPlugin.isPlayable, isTrue);
        final fromNuvio = last.streams.firstWhere(
          (s) => s.addonId.startsWith(kNuvioSourcePrefix),
        );
        expect(fromNuvio.headline, 'ShowBox');
        expect(fromNuvio.qualityLabel, '720p');
        expect(nuvioAskedWith, 'tt1375666|movie');
        expect(plugin.searched, ['Inception']);
        expect(plugin.loaded, ['data']);
        expect(last.totalCount, 3);
        expect(last.completedCount, 3);
      },
    );

    test('links show as each source answers, not after the slowest', () async {
      final gate = Completer<void>();
      final fast = _Plugin(
        'Fast',
        results: [_item('Inception', url: 'p')],
        details: _item('Inception', url: 'p'),
        streams: {
          'p': const [StreamResult(url: 'https://fast.test/1', source: 'S')],
        },
      );
      final slow = _Plugin(
        'Slow',
        gate: gate,
        results: [_item('Inception', url: 'p')],
        details: _item('Inception', url: 'p'),
        streams: {
          'p': const [StreamResult(url: 'https://slow.test/1', source: 'S')],
        },
      );
      final seen = <AddonStreamProgress>[];
      final done = Completer<void>();
      _service(plugins: [fast, slow])
          .resolve(request: _movie)
          .listen(seen.add, onDone: done.complete);

      await pumpEventQueue();
      expect(seen.last.isLoading, isTrue);
      expect(seen.last.streams.map((s) => s.addonName), ['Fast']);

      gate.complete();
      await done.future;
      expect(seen.last.isLoading, isFalse);
      expect(
        {for (final s in seen.last.streams) s.addonName},
        {'Fast', 'Slow'},
      );
    });

    test('a plugin that fails or finds nothing is skipped quietly', () async {
      final broken = _Plugin('Broken', failSearch: true);
      final empty = _Plugin('Empty', results: [_item('Something Else')]);
      final good = _Plugin(
        'Good',
        results: [_item('Inception', url: 'p')],
        details: _item('Inception', url: 'p'),
        streams: {
          'p': const [StreamResult(url: 'https://good.test/1', source: 'S')],
        },
      );
      final last = await _service(plugins: [broken, empty, good])
          .resolve(request: _movie)
          .last;

      expect(last.error, isNull);
      expect(last.streams.map((s) => s.addonName), ['Good']);
      final byName = {for (final s in last.statuses) s.addonName: s.outcome};
      expect(byName['Broken'], AddonQueryOutcome.failed);
      expect(byName['Empty'], AddonQueryOutcome.empty);
      expect(byName['Good'], AddonQueryOutcome.links);
    });

    test(
      'nothing installed, or nothing found: an empty, finished answer',
      () async {
        final nothing = await _service().resolve(request: _movie).last;
        expect(nothing.streams, isEmpty);
        expect(nothing.isLoading, isFalse);
        expect(nothing.error, isNull);

        final none = await _service(
          plugins: [_Plugin('Empty')],
          addons: [_addon],
          addonAnswers: (_) => Stream.value(
            const AddonStreamProgress(error: 'No add-on returned links'),
          ),
        ).resolve(request: _movie).last;
        expect(none.streams, isEmpty);
        expect(none.isLoading, isFalse);
      },
    );

    test('a series asks each kind for the chosen season and episode', () async {
      final plugin = _Plugin(
        'Shows',
        results: [
          _item('Dark', url: 'show', type: MultimediaContentType.series),
        ],
        details: _item(
          'Dark',
          url: 'show',
          type: MultimediaContentType.series,
          episodes: [
            Episode(name: 'a', url: 's1e1', season: 1, episode: 1),
            Episode(name: 'b', url: 's2e3', season: 2, episode: 3),
          ],
        ),
        streams: {
          's2e3': const [
            StreamResult(url: 'https://shows.test/x', source: 'S'),
          ],
        },
      );
      AddonStreamRequest? addonRequest;
      String? nuvioAskedWith;
      final last =
          await _service(
                plugins: [plugin],
                addons: [_addon],
                addonAnswers: (request) {
                  addonRequest = request;
                  return Stream.value(const AddonStreamProgress());
                },
                nuvioAnswers: (id, type, s, e) {
                  nuvioAskedWith = '$id|$type|$s|$e';
                  return Stream.value(const NuvioProgress());
                },
              )
              .resolve(
                request: const AddonStreamRequest(
                  type: 'series',
                  contentId: 'tt5753856',
                  videoId: 'tt5753856:2:3',
                  season: 2,
                  episode: 3,
                  imdbId: 'tt5753856',
                  title: 'Dark',
                  year: 2017,
                ),
              )
              .last;

      expect(plugin.loaded, ['s2e3']);
      expect(last.streams.single.addonName, 'Shows');
      expect(addonRequest?.idCandidates.first, 'tt5753856:2:3');
      expect(nuvioAskedWith, 'tt5753856|tv|2|3');
    });
  });
}

// v8 ------------------------------------------------------------------------

void v8Tests() {
  group('v8: Nuvio id and per-kind status', () {
    test('Nuvio is asked with the TMDB id when the title has one', () {
      expect(
        MergedSourceService.nuvioIdFor(
          const AddonStreamRequest(
            type: 'movie',
            contentId: 'tt33764258',
            imdbId: 'tt33764258',
            tmdbId: 1368337,
            title: 'The Odyssey',
          ),
        ),
        '1368337',
      );
      expect(MergedSourceService.nuvioIdFor(_movie), 'tt1375666');
    });

    test('every kind reports, also with nothing to ask', () async {
      final last = await _service().resolve(request: _movie).last;
      final lines = [for (final l in originSummaries(last.statuses)) l.text];
      expect(lines, [
        'Plugins: none installed',
        'Nuvio: no provider enabled for movies',
        'Stremio: no stream add-on installed',
      ]);
    });

    test('a Nuvio failure is said, not swallowed', () async {
      final last = await _service(
        nuvioAnswers: (_, _, _, _) => Stream.error(Exception('runtime down')),
      ).resolve(request: _movie).last;
      final nuvio = originSummaries(last.statuses)
          .firstWhere((l) => l.origin == kOriginNuvio);
      expect(nuvio.isError, isTrue);
      expect(nuvio.text, contains('runtime down'));
    });

    test('rows say which kind they came from', () {
      expect(sourceOriginTag(_addonLink), 'STREMIO');
      expect(
        sourceOriginTag(
          const AddonStreamSource(
            addonId: '${kNuvioSourcePrefix}showbox',
            addonName: 'ShowBox',
            url: 'https://x.test/a.mp4',
          ),
        ),
        'NUVIO',
      );
      expect(
        sourceOriginTag(
          const AddonStreamSource(
            addonId: '${kPluginSourcePrefix}pkg.goku',
            addonName: 'GokuHD',
            url: 'https://x.test/a.mp4',
          ),
        ),
        'PLUGIN',
      );
    });
  });
}
