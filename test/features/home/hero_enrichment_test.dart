import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/features/explore/presentation/widgets/home_hero_meta.dart';
import 'package:zorox/features/home/data/hero_enrichment.dart';

MultimediaItem item(
  String title, {
  int? year,
  MultimediaContentType type = MultimediaContentType.movie,
  double? score,
}) => MultimediaItem(
  title: title,
  url: 'https://example.test/x',
  posterUrl: 'https://example.test/p.jpg',
  contentType: type,
  year: year,
  score: score,
);

Map<String, dynamic> movieDetails({String? imdb = 'tt1234567'}) => {
  'id': 10,
  'genres': [
    {'id': 1, 'name': 'Science Fiction'},
    {'id': 2, 'name': 'Action'},
  ],
  'runtime': 135,
  'release_date': '2026-11-03',
  'status': 'Released',
  'original_language': 'ja',
  'vote_average': 7.4,
  'vote_count': 900,
  'imdb_id': imdb,
  'release_dates': {
    'results': [
      {
        'iso_3166_1': 'US',
        'release_dates': [
          {'certification': ''},
          {'certification': 'R'},
        ],
      },
    ],
  },
  'images': {
    'logos': [
      {'iso_639_1': 'en', 'file_path': '/logo.png'},
    ],
    'posters': [
      {'iso_639_1': 'en', 'file_path': '/titled.jpg', 'vote_average': 9},
      {'iso_639_1': null, 'file_path': '/clean.jpg', 'vote_average': 5},
    ],
    'backdrops': [
      {'iso_639_1': null, 'file_path': '/back.jpg', 'vote_average': 5},
    ],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('cleanHeroTitle', () {
    test('plugin release names', () {
      var c = cleanHeroTitle(
        'Guarding Stars (2026) WEB-DL [Hindi (DD5.1) & English] 4K 1080p 720p',
      );
      expect(c.name, 'Guarding Stars');
      expect(c.year, 2026);
      c = cleanHeroTitle('Under Your Feet 2026 1080p WEB-DL Hindi');
      expect((c.name, c.year), ('Under Your Feet', 2026));
      c = cleanHeroTitle('The Law of Beasts Season 1 [Hindi Dubbed]');
      expect((c.name, c.year), ('The Law of Beasts', null));
      c = cleanHeroTitle('Avengers.Endgame.2019.BluRay');
      expect((c.name, c.year), ('Avengers Endgame', 2019));
      c = cleanHeroTitle('Dune: Part Two');
      expect((c.name, c.year), ('Dune: Part Two', null));
    });

    test('a title that is a year is kept', () {
      final c = cleanHeroTitle('2012 (2009) BluRay');
      expect((c.name, c.year), ('2012', 2009));
      expect(cleanHeroTitle('1917').name, '1917');
    });
  });

  group('pickHeroMatch', () {
    final results = [
      {'id': 1, 'title': 'Guarding Stars', 'release_date': '2026-10-01',
        'popularity': 20.0},
      {'id': 2, 'title': 'Guarding Stars', 'release_date': '1998-01-01',
        'popularity': 18.0},
      {'id': 3, 'title': 'Guarding the Stars', 'release_date': '2026-02-01',
        'popularity': 99.0},
    ];

    test('same name and year within one', () {
      expect(
        pickHeroMatch(results, title: 'Guarding Stars', year: 2026)?['id'],
        1,
      );
      expect(
        pickHeroMatch(results, title: 'guarding stars', year: 2027)?['id'],
        1,
      );
    });

    test('same name, wrong year: no match', () {
      expect(pickHeroMatch(results, title: 'Guarding Stars', year: 2010), null);
    });

    test('a near name is not a match', () {
      expect(pickHeroMatch(results, title: 'Guarding Star', year: 2026), null);
    });

    test('no year and two films of that name: no match', () {
      expect(pickHeroMatch(results, title: 'Guarding Stars', year: null), null);
    });

    test('no year: a single film, or one far more popular', () {
      expect(
        pickHeroMatch([results[0]], title: 'Guarding Stars', year: null)?['id'],
        1,
      );
      expect(
        pickHeroMatch(
          [
            {'id': 7, 'name': 'Dark', 'popularity': 90.0},
            {'id': 8, 'name': 'Dark', 'popularity': 4.0},
          ],
          title: 'Dark',
          year: null,
        )?['id'],
        7,
      );
    });

    test('articles, "&" and punctuation do not matter', () {
      expect(heroTitleKey('The Lord of the Rings: The Two Towers'),
          heroTitleKey('Lord of the Rings - The Two Towers'));
      expect(heroTitleKey('Fast & Furious'), heroTitleKey('Fast and Furious'));
    });
  });

  group('pickHeroAltMatch', () {
    // What TMDB's search for "Last Meal" returns (2026-11-19): several
    // films of that name, and the Turkish film "Son Yemek", listed in
    // English as "Last Dinner" — the most popular of them.
    final lastMealResults = [
      {'id': 1426874, 'title': 'Last Meal', 'original_title': 'Last Meal',
        'release_date': '2017-01-01', 'popularity': 0.6455},
      {'id': 1723859, 'title': 'Last Meal', 'original_title': 'Last Meal',
        'release_date': '2026-06-30', 'popularity': 0.5058},
      {'id': 1561834, 'title': 'Last Dinner', 'original_title': 'Son Yemek',
        'release_date': '2026-11-18', 'popularity': 0.9375},
    ];
    final lastMealAlternates = {
      1561834: ['Last Meal', 'Last Meal'],
    };

    test('the title match finds nothing; the alternate title does', () {
      expect(
        pickHeroMatch(lastMealResults, title: 'Last Meal', year: null),
        isNull,
      );
      expect(
        pickHeroAltMatch(
          lastMealResults,
          lastMealAlternates,
          title: 'Last Meal',
          year: null,
        )?['id'],
        1561834,
      );
    });

    test('a stated year must still agree within one', () {
      expect(
        pickHeroAltMatch(
          lastMealResults,
          lastMealAlternates,
          title: 'Last Meal',
          year: 2026,
        )?['id'],
        1561834,
      );
      expect(
        pickHeroAltMatch(
          lastMealResults,
          lastMealAlternates,
          title: 'Last Meal',
          year: 2010,
        ),
        isNull,
      );
    });

    test('a near name is not an alternate-title match', () {
      expect(
        pickHeroAltMatch(
          lastMealResults,
          lastMealAlternates,
          title: 'Last Meals',
          year: null,
        ),
        isNull,
      );
      expect(
        pickHeroAltMatch(
          lastMealResults,
          lastMealAlternates,
          title: 'Last Dinner',
          year: null,
        ),
        isNull,
        reason: 'that is the title itself, not an alternate title',
      );
    });

    test('two alternate-title matches need the same wide lead', () {
      final two = {
        1561834: ['Last Meal'],
        1426874: ['Last Meal'],
      };
      expect(
        pickHeroAltMatch(
          lastMealResults,
          two,
          title: 'Last Meal',
          year: null,
        ),
        isNull,
        reason: '0.9375 is not three times 0.6455',
      );
      final lead = {
        1561834: ['Last Meal'],
        1426874: ['Something Else'],
      };
      expect(
        pickHeroAltMatch(
          lastMealResults,
          lead,
          title: 'Last Meal',
          year: null,
        )?['id'],
        1561834,
      );
    });

    test('alternate titles come from the movie and the TV shapes', () {
      expect(
        heroAlternateTitles({
          'titles': [
            {'iso_3166_1': 'US', 'title': 'Last Meal'},
          ],
        }),
        ['Last Meal'],
      );
      expect(
        heroAlternateTitles({
          'results': [
            {'iso_3166_1': 'GB', 'title': 'Son Yemek'},
          ],
        }),
        ['Son Yemek'],
      );
      expect(heroAlternateTitles({}), isEmpty);
    });
  });

  group('details to hero', () {
    test('every field, and the art without lettering', () {
      final e = heroEnrichmentFromDetails(
        movieDetails(),
        tv: false,
        imdbScore: 7.9,
      );
      expect(e.genres, ['Science Fiction', 'Action']);
      expect(e.runtimeMinutes, 135);
      expect(e.year, 2026);
      expect(e.certification, 'R');
      expect(e.status, 'RELEASED');
      expect(e.language, 'ja');
      expect(e.imdbScore, 7.9);
      expect(e.tmdbScore, 7.4);
      expect(e.logoUrl, endsWith('/logo.png'));
      expect(e.artUrl, endsWith('/clean.jpg'));
    });

    test('the reference rows', () {
      final e = heroEnrichmentFromDetails(
        movieDetails(),
        tv: false,
        imdbScore: 7.9,
      );
      final shown = e.applyTo(item('Godzilla Minus Zero'));
      expect(
        heroMetaLine(shown),
        'Movie${kHeroDot}Science Fiction${kHeroDot}2h 15m${kHeroDot}2026',
      );
      final b = heroBadges(
        shown,
        language: e.language,
        statusLabel: e.status,
        scoreIsImdb: e.scoreIsImdb,
      );
      expect(b.chip, 'R | RELEASED');
      expect(b.score, '7.9');
      expect(b.scoreIsImdb, isTrue);
      expect(b.language, 'JA');
    });

    test('only TMDB\'s average: a star score, never IMDb', () {
      final e = heroEnrichmentFromDetails(movieDetails(), tv: false);
      final shown = e.applyTo(item('X'));
      final b = heroBadges(
        shown,
        language: e.language,
        statusLabel: e.status,
        scoreIsImdb: e.scoreIsImdb,
      );
      expect(b.score, '7.4');
      expect(b.scoreIsImdb, isFalse);
    });

    test('nothing stated, nothing shown', () {
      final e = heroEnrichmentFromDetails({'id': 1}, tv: false);
      final shown = e.applyTo(item('X'));
      expect(heroMetaLine(shown), 'Movie');
      expect(heroBadges(shown, statusLabel: e.status).isEmpty, isTrue);
      expect(e.logoUrl, isNull);
      expect(e.artUrl, isNull);
    });

    test('tv: rating, run time and status', () {
      final e = heroEnrichmentFromDetails({
        'first_air_date': '2024-01-05',
        'episode_run_time': [24],
        'status': 'Returning Series',
        'content_ratings': {
          'results': [
            {'iso_3166_1': 'US', 'rating': 'TV-MA'},
          ],
        },
      }, tv: true);
      expect(e.certification, 'TV-MA');
      expect(e.runtimeMinutes, 24);
      expect(e.status, 'ONGOING');
    });

    test('the plugin\'s own year and rating are kept', () {
      final e = heroEnrichmentFromDetails(movieDetails(), tv: false);
      final shown = e.applyTo(item('X', year: 2025, score: 6.1));
      expect(shown.year, 2025);
      expect(shown.score, 6.1);
    });
  });

  group('service', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    HeroEnrichmentService service(
      List<String> calls, {
      String key = 'k',
      bool offline = false,
      List<Map<String, dynamic>>? results,
    }) => HeroEnrichmentService(
      apiKey: () => key,
      get: (url, query) async {
        calls.add(url);
        if (offline) return null;
        if (url.contains('/search/')) {
          return {
            'results': results ??
                [
                  {'id': 10, 'title': 'Guarding Stars',
                    'release_date': '2026-10-01'},
                ],
          };
        }
        if (url.contains('cinemeta')) {
          return {
            'meta': {'imdbRating': '7.9'},
          };
        }
        return movieDetails();
      },
    );

    test('match, details, IMDb rating; then served from the cache', () async {
      final calls = <String>[];
      final s = service(calls);
      final it = item('Guarding Stars (2026) WEB-DL [Hindi] 4K');
      final e = await s.lookup(it);
      expect(e?.imdbScore, 7.9);
      expect(e?.certification, 'R');
      expect(calls.length, 3);
      await s.lookup(it);
      expect(calls.length, 3, reason: 'memory cache');
      final fresh = service(calls);
      expect((await fresh.lookup(it))?.imdbScore, 7.9);
      expect(calls.length, 3, reason: 'disk cache');
    });

    test('no key: nothing is asked', () async {
      final calls = <String>[];
      expect(await service(calls, key: '').lookup(item('X (2020)')), isNull);
      expect(calls, isEmpty);
    });

    test('a miss is null and is remembered', () async {
      final calls = <String>[];
      final s = service(calls, results: const []);
      expect(await s.lookup(item('Nothing Like It (2026)')), isNull);
      final n = calls.length;
      expect(await s.lookup(item('Nothing Like It (2026)')), isNull);
      expect(calls.length, n);
    });

    test('offline: null, and tried again next time', () async {
      final calls = <String>[];
      final s = service(calls, offline: true);
      expect(await s.lookup(item('Guarding Stars (2026)')), isNull);
      final n = calls.length;
      expect(await s.lookup(item('Guarding Stars (2026)')), isNull);
      expect(calls.length, greaterThan(n));
    });

    test('"Last Meal" is found by its alternate title', () async {
      final calls = <String>[];
      final s = HeroEnrichmentService(
        apiKey: () => 'k',
        get: (url, query) async {
          calls.add(url);
          if (url.contains('/search/')) {
            return {
              'results': [
                {'id': 1426874, 'title': 'Last Meal',
                  'original_title': 'Last Meal', 'release_date': '2017-01-01',
                  'popularity': 0.6455},
                {'id': 1723859, 'title': 'Last Meal',
                  'original_title': 'Last Meal', 'release_date': '2026-06-30',
                  'popularity': 0.5058},
                {'id': 1561834, 'title': 'Last Dinner',
                  'original_title': 'Son Yemek', 'release_date': '2026-11-18',
                  'popularity': 0.9375},
              ],
            };
          }
          if (url.contains('/alternative_titles')) {
            return {
              'titles': url.contains('/1561834/')
                  ? [
                      {'iso_3166_1': 'SG', 'title': 'Last Meal'},
                      {'iso_3166_1': 'US', 'title': 'Last Meal'},
                    ]
                  : const <Map<String, String>>[],
            };
          }
          if (url.contains('cinemeta')) {
            return {'meta': <String, dynamic>{}};
          }
          return {
            'id': 1561834,
            'genres': [
              {'id': 10749, 'name': 'Romance'},
              {'id': 18, 'name': 'Drama'},
            ],
            'release_date': '2026-11-18',
            'status': 'Released',
            'original_language': 'tr',
            'vote_average': 0.0,
            'vote_count': 0,
            'release_dates': {'results': const <Map<String, dynamic>>[]},
            'images': {
              'logos': const <Map<String, dynamic>>[],
              'posters': const <Map<String, dynamic>>[],
            },
          };
        },
      );
      final e = await s.lookup(item('Last Meal'));
      expect(e, isNotNull);
      expect(e?.genres, ['Romance', 'Drama']);
      expect(e?.year, 2026);
      expect(e?.language, 'tr');
      expect(e?.status, 'RELEASED');
      expect(e?.imdbScore, isNull);
      expect(e?.tmdbScore, isNull);
      expect(calls.any((u) => u.contains('/alternative_titles')), isTrue);
      final shown = e!.applyTo(item('Last Meal'));
      expect(
        heroMetaLine(shown),
        'Movie${kHeroDot}Romance${kHeroDot}2026',
      );
      final n = calls.length;
      expect((await s.lookup(item('Last Meal')))?.year, 2026);
      expect(calls.length, n, reason: 'memory cache');
    });
  });
}
