/// The plugin detail page's Cast row uses TMDB credits (photos + character
/// roles, like Browse) when the resolved tmdbId yields them, and falls back
/// to the plugin's own cast (a text line) when it does not.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/models/tmdb_details.dart';
import 'package:zorox/core/providers/device_info_provider.dart';
import 'package:zorox/core/storage/episode_watch_repository.dart';
import 'package:zorox/core/storage/history_repository.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/features/details/data/tmdb_details_provider.dart';
import 'package:zorox/features/details/presentation/details_controller.dart';
import 'package:zorox/features/details/presentation/details_screen.dart';
import 'package:zorox/features/details/presentation/downloaded_file_provider.dart';
import 'package:zorox/features/details/presentation/widgets/movie_cast_list.dart';
import 'package:zorox/features/details/presentation/widgets/premium_details_widgets.dart';
import 'package:zorox/features/library/presentation/library_provider.dart';
import 'package:zorox/features/library/presentation/library_state.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

const String _kUrl = 'https://ext.test/title';

class _NoHistory extends HistoryRepository {
  _NoHistory() : super(StorageService());

  @override
  List<HistoryItem> getWatchHistory() => const <HistoryItem>[];
  @override
  int getPosition(String url) => 0;
  @override
  int getDuration(String url) => 0;
  @override
  int getEpisodePosition(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
  @override
  int getEpisodeDuration(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
}

class _NoEpisodeWatch extends EpisodeWatchRepository {
  _NoEpisodeWatch(HistoryRepository history)
    : super(StorageService(), history, _ignore);

  static void _ignore() {}

  @override
  bool? getExplicitState(String mainUrl, Episode episode) => null;
  @override
  bool isWatched(String mainUrl, Episode episode) => false;
}

class _FakeDownloadedFiles extends DownloadedFiles {
  @override
  Map<String, File?> build() => const <String, File?>{};
  @override
  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {}
}

class _FakeLibrary extends Library {
  @override
  LibraryState build() => const LibraryEmpty();
}

class _FakeController extends DetailsController {
  _FakeController(this._item);

  final MultimediaItem _item;

  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncValue.data(_item),
    isMovie: true,
    item: _item,
    seasonMap: {1: _item.episodes ?? const []},
  );

  @override
  Future<void> loadDetails(
    MultimediaItem item, {
    bool autoPlay = false,
    bool forceRefresh = false,
  }) async {}
}

TmdbDetails _tmdbDetails({required List<TmdbCast> cast}) => TmdbDetails(
  id: 123,
  mediaType: 'movie',
  title: 'A Title',
  releaseDate: '2025-01-01',
  voteAverage: 8.0,
  overview: '',
  runtime: 120,
  certification: '',
  director: '',
  seasons: const [],
  tmdbCast: cast,
  genres: const [],
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

MultimediaItem _film({int? tmdbId}) => MultimediaItem(
  title: 'A Title',
  url: _kUrl,
  posterUrl: 'https://img.test/poster.png',
  contentType: MultimediaContentType.movie,
  tmdbId: tmdbId,
  // The plugin's own cast: names + roles, but no photos.
  cast: [
    Actor(name: 'Plugin Actor', role: 'Hero'),
    Actor(name: 'Second Plugin Actor', role: 'Sidekick'),
  ],
  episodes: [Episode(name: 'A Title', url: 'cs3data:eA==', season: 1, episode: 1)],
);

Future<void> _pump(
  WidgetTester tester,
  MultimediaItem item, {
  TmdbDetails? tmdbDetails,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(590, 1200);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = 0.9;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final history = _NoHistory();
  final container = ProviderContainer(
    overrides: [
      historyRepositoryProvider.overrideWithValue(history),
      episodeWatchRepositoryProvider.overrideWithValue(
        _NoEpisodeWatch(history),
      ),
      downloadedFilesProvider.overrideWith(_FakeDownloadedFiles.new),
      deviceProfileProvider.overrideWithValue(
        const AsyncValue.data(DeviceProfile()),
      ),
      detailsControllerProvider.overrideWith2((_) => _FakeController(item)),
      libraryProvider.overrideWith(_FakeLibrary.new),
      tmdbDetailsProvider.overrideWith((ref, params) async => tmdbDetails),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DetailsScreen(item: item),
      ),
    ),
  );
  // Never settle: the artwork placeholders never resolve under test.
  await tester.pump();
  // A second frame lets the overridden TMDB provider resolve and rebuild.
  await tester.pump();
}

void main() {
  testWidgets('TMDB credits win: photo cards, not the plugin text line', (
    tester,
  ) async {
    await _pump(
      tester,
      _film(tmdbId: 123),
      tmdbDetails: _tmdbDetails(
        cast: [
          TmdbCast(
            name: 'Tmdb Star',
            character: 'Hero',
            profilePath: '/star.jpg',
          ),
          TmdbCast(
            name: 'Tmdb Second',
            character: 'Sidekick',
            profilePath: '/second.jpg',
          ),
        ],
      ),
    );
    expect(find.byType(MovieCastList, skipOffstage: false), findsOneWidget);
    expect(find.byType(CastCarousel, skipOffstage: false), findsNothing);
    expect(find.text('Tmdb Star'), findsOneWidget);
    expect(find.text('Hero'), findsOneWidget);
    expect(find.text('Plugin Actor'), findsNothing);
  });

  testWidgets('TMDB with no credits falls back to the plugin text line', (
    tester,
  ) async {
    await _pump(
      tester,
      _film(tmdbId: 123),
      tmdbDetails: _tmdbDetails(cast: const []),
    );
    expect(find.byType(MovieCastList, skipOffstage: false), findsNothing);
    expect(find.byType(CastCarousel, skipOffstage: false), findsOneWidget);
    expect(find.textContaining('Plugin Actor'), findsOneWidget);
    expect(find.text('Tmdb Star'), findsNothing);
  });

  testWidgets('no tmdbId keeps the plugin text line, never a fake photo', (
    tester,
  ) async {
    await _pump(
      tester,
      _film(tmdbId: null),
      tmdbDetails: _tmdbDetails(
        cast: [
          TmdbCast(
            name: 'Tmdb Star',
            character: 'Hero',
            profilePath: '/star.jpg',
          ),
        ],
      ),
    );
    expect(find.byType(MovieCastList, skipOffstage: false), findsNothing);
    expect(find.byType(CastCarousel, skipOffstage: false), findsOneWidget);
    expect(find.textContaining('Plugin Actor'), findsOneWidget);
    expect(find.text('Tmdb Star'), findsNothing);
  });
}
