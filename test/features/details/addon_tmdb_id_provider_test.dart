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

  Future<int?> resolve(
    ProviderContainer container,
    AddonTmdbIdParams params,
  ) => container.read(addonTmdbIdProvider(params).future);

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
}
