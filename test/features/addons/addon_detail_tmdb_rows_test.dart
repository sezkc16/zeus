/// A plugin title's detail page shows Cast + "More Like This" (build
/// 111): MoviesMod's Bull Run carries no moviedbId, so the id resolves
/// by title + year and both rows render. A title TMDB cannot match
/// shows neither row — never a fake one.
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/addons/models/addon_meta.dart';
import 'package:zorox/core/config/tmdb_config.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/models/tmdb_details.dart';
import 'package:zorox/core/services/tmdb_service.dart';
import 'package:zorox/features/details/data/cast_photo_service.dart';
import 'package:zorox/features/details/data/metadata_resolution_service.dart';
import 'package:zorox/features/details/data/tmdb_details_provider.dart';
import 'package:zorox/features/details/data/tmdb_recommendations_provider.dart';
import 'package:zorox/features/settings/presentation/general_settings_provider.dart';

import 'stremio_page_fakes.dart';

/// MultimediaCard reads the title-position setting; the harness has no
/// StorageService, so the settings notifier is faked with defaults.
class _FakeGeneralSettings extends GeneralSettingsNotifier {
  @override
  GeneralSettings build() => const GeneralSettings();
}

const Size _kPhone = Size(430, 932);

/// TMDB answers with the one film the query names, or with nothing.
class _FakeTmdbService extends TmdbService {
  _FakeTmdbService({this.match = true}) : super(Dio());

  final bool match;

  @override
  Future<List<MultimediaItem>> multiSearch({
    required String query,
    String language = 'en-US',
    int page = 1,
  }) async {
    if (!match) return const <MultimediaItem>[];
    return [
      MultimediaItem(
        title: 'Bull Run',
        url: 'tmdb:12345',
        posterUrl: 'https://image.test/bull.jpg',
        year: 2025,
        tmdbId: 12345,
      ),
    ];
  }

  @override
  Future<Map<String, dynamic>?> getMovieExtra(
    int movieId, {
    String language = 'en-US',
  }) async => null;

  @override
  Future<Map<String, dynamic>?> getTvExtra(
    int tvId, {
    String language = 'en-US',
  }) async => null;
}

/// MoviesMod's Bull Run, as the plugin lists it: no moviedbId, no cast.
const _bullRun = AddonMeta(
  id: 'moviesmod:bull-run',
  type: 'movie',
  name: 'Bull Run',
  addonId: 'com.moviesmod',
  addonName: 'MoviesMod',
  description:
      'In the wilds of Wall Street, one junior banker discovers that '
      'the only thing more dangerous than billion-dollar deals are the '
      'men signing them.',
  releaseInfo: '2025',
  imdbRating: '4.2',
  genres: ['Comedy'],
);

TmdbDetails _bullRunDetails() => TmdbDetails(
  id: 12345,
  mediaType: 'movie',
  title: 'Bull Run',
  releaseDate: '2025-01-01',
  voteAverage: 4.2,
  overview: 'In the wilds of Wall Street.',
  runtime: 0,
  certification: '',
  director: '',
  seasons: const [],
  tmdbCast: [TmdbCast(name: 'Test Actor', character: 'The Banker')],
  genres: const ['Comedy'],
  tmdbTrailers: const [],
  productionCompanies: const [],
  tmdbStatus: '',
  budget: 0,
  revenue: 0,
  tagline: '',
  originCountry: '',
  originalLanguage: 'en',
  releaseDateFull: '2025-01-01',
);

void main() {
  useTestClearance();

  setUp(() => TmdbConfig.setUserApiKey('test-key'));
  tearDown(() => TmdbConfig.setUserApiKey(null));

  testWidgets('a plugin title without moviedbId shows Cast + More Like This', (
    tester,
  ) async {
    await openStremioPage(
      tester,
      _bullRun,
      size: _kPhone,
      overrides: [
        generalSettingsProvider.overrideWith(_FakeGeneralSettings.new),
        metadataResolutionServiceProvider.overrideWithValue(
          MetadataResolutionService(_FakeTmdbService()),
        ),
        tmdbDetailsProvider(
          MovieDetailsParams(12345, 'movie'),
        ).overrideWith((ref) async => _bullRunDetails()),
        tmdbRecommendationsProvider(
          MovieDetailsParams(12345, 'movie'),
        ).overrideWith(
          (ref) async => [
            MultimediaItem(
              title: 'Wolf of Wall Street',
              url: 'tmdb:106646',
              posterUrl: 'https://image.test/wolf.jpg',
              tmdbId: 106646,
            ),
          ],
        ),
        castPhotoProvider('Test Actor').overrideWith((ref) async => null),
      ],
    );
    // Let the id resolve, then details + recommendations.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Cast', skipOffstage: false), findsOneWidget);
    expect(find.text('Test Actor', skipOffstage: false), findsOneWidget);
    expect(find.text('The Banker', skipOffstage: false), findsOneWidget);
    expect(find.text('More Like This', skipOffstage: false), findsOneWidget);
    expect(
      find.text('Wolf of Wall Street', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('a title TMDB cannot match shows neither row', (tester) async {
    await openStremioPage(
      tester,
      _bullRun,
      size: _kPhone,
      overrides: [
        generalSettingsProvider.overrideWith(_FakeGeneralSettings.new),
        metadataResolutionServiceProvider.overrideWithValue(
          MetadataResolutionService(_FakeTmdbService(match: false)),
        ),
      ],
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Cast', skipOffstage: false), findsNothing);
    expect(find.text('More Like This', skipOffstage: false), findsNothing);
  });
}
