/// Browse's TMDB hero (build 86) is the same hero Home shows (design A):
/// centred title logo, one meta line, one badge row, a white View Details
/// pill. The TMDB list payload carries no runtime, certification, status,
/// language or IMDb id, so the badge row comes from the same hero
/// enrichment Home uses — details for the carousel items, never invented.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:zorox/core/config/tmdb_config.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/features/explore/presentation/widgets/explore_carousel.dart';
import 'package:zorox/features/home/data/hero_enrichment.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// A Browse hero item as TMDB's list payload gives it: an id, a title, a
/// year and TMDB's own average — no genres, runtime, certification,
/// status, language or logo.
MultimediaItem _tmdbItem() => MultimediaItem(
  title: 'Avengers: Doomsday',
  url: '',
  posterUrl: '',
  bannerUrl: '',
  contentType: MultimediaContentType.movie,
  year: 2026,
  score: 8.4,
  tmdbId: 100,
);

/// The details the enrichment fetch returns for it.
Map<String, dynamic> _details() => {
  'id': 100,
  'genres': [
    {'id': 878, 'name': 'Science Fiction'},
    {'id': 28, 'name': 'Action'},
    {'id': 12, 'name': 'Adventure'},
  ],
  'runtime': 173,
  'release_date': '2026-12-17',
  'status': 'Released',
  'original_language': 'en',
  'vote_average': 8.4,
  'vote_count': 1200,
  'imdb_id': 'tt1234567',
  'release_dates': {
    'results': [
      {
        'iso_3166_1': 'US',
        'release_dates': [
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
      {'iso_639_1': null, 'file_path': '/clean.jpg', 'vote_average': 5},
    ],
    'backdrops': const <Map<String, dynamic>>[],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    // The key itself is faked below; this only opens the enrichment path,
    // which otherwise stays shut when no key is set.
    TmdbConfig.setUserApiKey('k');
  });
  tearDown(() {
    TmdbConfig.setUserApiKey('');
    VisibilityDetectorController.instance.updateInterval = const Duration(
      milliseconds: 500,
    );
  });

  HeroEnrichmentService fakeService() => HeroEnrichmentService(
    apiKey: () => 'k',
    get: (url, query) async {
      if (url.contains('cinemeta')) return {'meta': {'imdbRating': '8.4'}};
      return _details();
    },
  );

  Future<void> pump(
    WidgetTester tester, {
    required List<MultimediaItem> movies,
    bool showHomeHero = true,
    void Function(MultimediaItem)? onTap,
  }) async {
    tester.view.physicalSize = const Size(411 * 3, 915 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          heroEnrichmentServiceProvider.overrideWithValue(fakeService()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ExploreCarousel(
              movies: movies,
              showHomeHero: showHomeHero,
              fullBleed: true,
              onTap: onTap,
            ),
          ),
        ),
      ),
    );
    // The enrichment arrives on a FutureProvider; let it land.
    await tester.pump();
    await tester.pump();
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox()));
  }

  testWidgets('Browse hero shows the Home rows: meta, badge row, button',
      (tester) async {
    await pump(tester, movies: [_tmdbItem()]);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('home-hero-meta'))).data,
      'Movie • Science Fiction • 2h 53m • 2026',
    );
    expect(find.text('R | RELEASED'), findsOneWidget);
    expect(find.text('IMDb'), findsOneWidget);
    expect(find.text('8.4'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-hero-language')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('home-hero-language')))
          .data,
      'EN',
    );
    expect(find.text('View Details'), findsOneWidget);
    expect(find.text('Play'), findsNothing);
    expect(find.text('My List'), findsNothing);
    expect(find.text('Info'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without the flag the badge row stays off, as before',
      (tester) async {
    await pump(tester, movies: [_tmdbItem()], showHomeHero: false);
    expect(find.byKey(const ValueKey('home-hero-badges')), findsNothing);
    expect(find.text('IMDb'), findsNothing);
    expect(find.text('R | RELEASED'), findsNothing);
    expect(find.text('View Details'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('View Details opens the original item', (tester) async {
    MultimediaItem? opened;
    await pump(tester, movies: [_tmdbItem()], onTap: (m) => opened = m);
    await tester.tap(find.text('View Details'));
    await tester.pump();
    expect(opened?.title, 'Avengers: Doomsday');
    expect(opened?.tmdbId, 100);
  });
}
