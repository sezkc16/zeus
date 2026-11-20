/// The TMDB id for a plugin title (build 111): MoviesMod's Bull Run
/// carries no moviedbId, so the id must resolve by title + year.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/config/tmdb_config.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/services/tmdb_service.dart';
import 'package:zorox/features/details/data/addon_tmdb_id_provider.dart';
import 'package:zorox/features/details/data/metadata_resolution_service.dart';

/// TMDB answers with the one film the query names, or with nothing.
class _FakeTmdbService extends TmdbService {
  _FakeTmdbService({this.match = true}) : super(Dio());

  final bool match;
  var searched = false;

  @override
  Future<List<MultimediaItem>> multiSearch({
    required String query,
    String language = 'en-US',
    int page = 1,
  }) async {
    searched = true;
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

void main() {
  setUp(() => TmdbConfig.setUserApiKey('test-key'));
  tearDown(() => TmdbConfig.setUserApiKey(null));

  Future<int?> resolve(ProviderContainer container, AddonTmdbIdParams params) =>
      container.read(addonTmdbIdProvider(params).future);

  test('a title without moviedbId resolves by title + year', () async {
    final container = ProviderContainer(
      overrides: [
        metadataResolutionServiceProvider.overrideWithValue(
          MetadataResolutionService(_FakeTmdbService()),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      await resolve(
        container,
        const AddonTmdbIdParams(
          moviedbId: null,
          title: 'Bull Run',
          year: 2025,
          isShow: false,
        ),
      ),
      12345,
    );
  });

  test('an add-on that already knows its id never searches', () async {
    final fake = _FakeTmdbService();
    final container = ProviderContainer(
      overrides: [
        metadataResolutionServiceProvider.overrideWithValue(
          MetadataResolutionService(fake),
        ),
      ],
    );
    addTearDown(container.dispose);

    // The fake would answer 12345 for any query; a known id must win
    // without asking it at all.
    expect(
      await resolve(
        container,
        const AddonTmdbIdParams(
          moviedbId: 999,
          title: 'Bull Run',
          year: 2025,
          isShow: false,
        ),
      ),
      999,
    );
    expect(fake.searched, isFalse);
  });

  test('a title TMDB cannot match stays null — no fake id', () async {
    final container = ProviderContainer(
      overrides: [
        metadataResolutionServiceProvider.overrideWithValue(
          MetadataResolutionService(_FakeTmdbService(match: false)),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      await resolve(
        container,
        const AddonTmdbIdParams(
          moviedbId: null,
          title: 'Some Film Nobody Made',
          year: 2025,
          isShow: false,
        ),
      ),
      isNull,
    );
  });

  test('no TMDB key means no resolution', () async {
    TmdbConfig.setUserApiKey(null);
    final container = ProviderContainer(
      overrides: [
        metadataResolutionServiceProvider.overrideWithValue(
          MetadataResolutionService(_FakeTmdbService()),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      await resolve(
        container,
        const AddonTmdbIdParams(
          moviedbId: null,
          title: 'Bull Run',
          year: 2025,
          isShow: false,
        ),
      ),
      isNull,
    );
  });

  group('MobLand (build 112)', () {
    test('the 4KHDHub item — title "MobLand", no year, series — resolves '
        'to the MobLand TMDB id', () async {
      final container = ProviderContainer(
        overrides: [
          metadataResolutionServiceProvider.overrideWithValue(
            MetadataResolutionService(_YearFilteredFakeTmdbService()),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(
        await resolve(
          container,
          const AddonTmdbIdParams(
            moviedbId: null,
            title: 'MobLand',
            year: null,
            isShow: true,
          ),
        ),
        247718,
      );
    });

    test('a wrong scraper year does not veto an exact title — the '
        'title-only retry resolves it', () async {
      final container = ProviderContainer(
        overrides: [
          metadataResolutionServiceProvider.overrideWithValue(
            MetadataResolutionService(_YearFilteredFakeTmdbService()),
          ),
        ],
      );
      addTearDown(container.dispose);

      // The year-qualified search returns nothing (the strict year
      // filter drops the true result); the retry must still find it.
      expect(
        await resolve(
          container,
          const AddonTmdbIdParams(
            moviedbId: null,
            title: 'MobLand',
            year: 2026,
            isShow: true,
          ),
        ),
        247718,
      );
    });

    test(
      'an unmatchable title stays null even with the retry — no fake id',
      () async {
        final container = ProviderContainer(
          overrides: [
            metadataResolutionServiceProvider.overrideWithValue(
              MetadataResolutionService(_YearFilteredFakeTmdbService()),
            ),
          ],
        );
        addTearDown(container.dispose);

        expect(
          await resolve(
            container,
            const AddonTmdbIdParams(
              moviedbId: null,
              title: 'Some Film Nobody Made',
              year: 2025,
              isShow: false,
            ),
          ),
          isNull,
        );
      },
    );
  });
}

/// Mimics the real [TmdbService.multiSearch] year filter: a year in the
/// query drops every candidate whose year does not match it. The live
/// /search/multi answer for "MobLand" is the show (id 247718, 2025) plus
/// the unrelated "Mob Land" film (2023).
class _YearFilteredFakeTmdbService extends TmdbService {
  _YearFilteredFakeTmdbService() : super(Dio());

  static final _year = RegExp(r'\b(19|20)\d{2}\b');

  @override
  Future<List<MultimediaItem>> multiSearch({
    required String query,
    String language = 'en-US',
    int page = 1,
  }) async {
    if (!query.toLowerCase().contains('mobland')) {
      return const <MultimediaItem>[];
    }
    final filterYear = _year.firstMatch(query) == null
        ? null
        : int.parse(_year.firstMatch(query)!.group(0)!);
    final candidates = [
      MultimediaItem(
        title: 'MobLand',
        url: 'tmdb:247718',
        posterUrl: 'https://image.test/mobland.jpg',
        year: 2025,
        tmdbId: 247718,
        contentType: MultimediaContentType.series,
      ),
      MultimediaItem(
        title: 'Mob Land',
        url: 'tmdb:979275',
        posterUrl: 'https://image.test/mob-land.jpg',
        year: 2023,
        tmdbId: 979275,
        contentType: MultimediaContentType.movie,
      ),
    ];
    return candidates
        .where((c) => filterYear == null || c.year == filterYear)
        .toList();
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
