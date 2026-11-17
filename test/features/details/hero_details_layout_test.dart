/// The phone details page in the "Hero" layout: a banner with the source tag,
/// the title and a round Play button, an info strip, a short synopsis and
/// episodes as a horizontal row - with everything the page could do before.
library;

import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/providers/device_info_provider.dart';
import 'package:zorox/core/storage/episode_watch_repository.dart';
import 'package:zorox/core/storage/history_repository.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/features/details/presentation/details_controller.dart';
import 'package:zorox/features/details/presentation/details_screen.dart';
import 'package:zorox/features/details/presentation/download_launcher.dart';
import 'package:zorox/features/details/presentation/downloaded_file_provider.dart';
import 'package:zorox/features/details/presentation/widgets/details_layout_widgets.dart';
import 'package:zorox/features/details/presentation/widgets/episode_card.dart';
import 'package:zorox/features/details/presentation/widgets/hero_details_widgets.dart';
import 'package:zorox/features/details/presentation/widgets/premium_details_widgets.dart';
import 'package:zorox/features/library/presentation/library_provider.dart';
import 'package:zorox/features/library/presentation/library_state.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

const String _kUrl = 'https://ext.test/solo';
const String _kBanner = 'https://img.test/back.png';
const String _kPoster = 'https://img.test/poster.png';
const Size _kPhone = Size(430, 932);

String _epUrl(int n, {int season = 1}) => '$_kUrl/s$season/e$n';

/// Saved progress per episode url, in milliseconds of a 1 000 000 ms episode.
class _History extends HistoryRepository {
  _History([this.positions = const {}]) : super(StorageService());

  final Map<String, int> positions;

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
  }) => positions[url] ?? 0;
  @override
  int getEpisodeDuration(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => positions.containsKey(url) ? 1000000 : 0;
}

class _Watched extends EpisodeWatchRepository {
  _Watched(HistoryRepository history, this.watched)
    : super(StorageService(), history, _ignore);

  final Set<String> watched;

  static void _ignore() {}

  @override
  bool? getExplicitState(String mainUrl, Episode episode) => null;
  @override
  bool isWatched(String mainUrl, Episode episode) =>
      watched.contains(episode.url);
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

class _RecordingLauncher extends DownloadLauncher {
  _RecordingLauncher(super.ref);

  static final List<String?> launched = <String?>[];

  @override
  Future<void> launch(
    BuildContext context,
    MultimediaItem item, {
    String? episodeUrl,
  }) async {
    launched.add(episodeUrl);
  }
}

/// Records play presses instead of opening the player: 'target' for Play
/// itself, else the episode's url.
class _FakeController extends DetailsController {
  _FakeController(this._state);

  final DetailsState _state;
  static final List<String> played = <String>[];

  @override
  DetailsState build(String itemUrl) => _state;

  @override
  Future<void> loadDetails(
    MultimediaItem item, {
    bool autoPlay = false,
    bool forceRefresh = false,
  }) async {}

  @override
  Future<void> handlePlayPress(
    BuildContext context,
    MultimediaItem details, {
    Episode? specificEpisode,
    String? overrideUrl,
  }) async {
    played.add(specificEpisode?.url ?? overrideUrl ?? 'target');
  }
}

List<Episode> _episodes(
  int count, {
  int season = 1,
  DubStatus Function(int n)? dub,
}) => [
  for (var n = 1; n <= count; n++)
    Episode(
      name: 'Episode $n',
      url: _epUrl(n, season: season),
      season: season,
      episode: n,
      runtime: 24,
      description: 'What happens in episode $n.',
      dubStatus: dub?.call(n) ?? DubStatus.none,
    ),
];

MultimediaItem _show(
  List<Episode> episodes, {
  String? provider = 'AnikotoProvider',
  int? year = 2025,
  int? duration = 24,
  ShowStatus status = ShowStatus.completed,
  String? description,
  String? bannerUrl = _kBanner,
  bool comingSoon = false,
}) => MultimediaItem(
  title: 'Solo Leveling Season 2',
  url: _kUrl,
  posterUrl: _kPoster,
  bannerUrl: bannerUrl,
  provider: provider,
  contentType: MultimediaContentType.anime,
  year: year,
  duration: duration,
  status: status,
  description: description,
  tags: const ['Action', 'Fantasy'],
  comingSoon: comingSoon,
  episodes: episodes,
);

Future<void> _pump(
  WidgetTester tester,
  MultimediaItem item, {
  Map<int, List<Episode>>? seasons,
  Episode? target,
  bool isMovie = false,
  Map<String, int> positions = const {},
  Set<String> watched = const {},
  DubStatus selectedDub = DubStatus.none,
}) async {
  _FakeController.played.clear();
  _RecordingLauncher.launched.clear();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = _kPhone;
  addTearDown(tester.view.reset);

  final history = _History(positions);
  final seasonMap = seasons ?? {1: item.episodes ?? const <Episode>[]};
  final container = ProviderContainer(
    overrides: [
      historyRepositoryProvider.overrideWithValue(history),
      episodeWatchRepositoryProvider.overrideWithValue(
        _Watched(history, watched),
      ),
      downloadedFilesProvider.overrideWith(_FakeDownloadedFiles.new),
      downloadLauncherProvider.overrideWith(_RecordingLauncher.new),
      deviceProfileProvider.overrideWithValue(
        const AsyncValue.data(DeviceProfile()),
      ),
      detailsControllerProvider.overrideWith2(
        (_) => _FakeController(
          DetailsState(
            details: AsyncValue.data(item),
            item: item,
            isMovie: isMovie,
            seasonMap: seasonMap,
            selectedSeason: seasonMap.keys.first,
            targetEpisode: target,
            selectedDubStatus: selectedDub,
          ),
        ),
      ),
      libraryProvider.overrideWith(_FakeLibrary.new),
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
  await tester.pump(const Duration(milliseconds: 400));
}

Finder get _fab => find.byKey(const ValueKey('details-play-fab'));
Finder get _strip => find.byKey(const ValueKey('details-info-strip'));
Finder get _row => find.byKey(const ValueKey('details-episode-row'));

String _fabLabel(WidgetTester tester) => tester
    .widget<Tooltip>(find.ancestor(of: _fab, matching: find.byType(Tooltip)))
    .message!;

Future<void> _reach(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('the banner', () {
    testWidgets('carries the title and the clean source tag, and there is no '
        'poster-and-title block under it', (tester) async {
      final eps = _episodes(13);
      await _pump(tester, _show(eps), target: eps.first);

      final banner = find.byType(DetailsHeroBanner);
      expect(banner, findsOneWidget);
      expect(
        find.descendant(
          of: banner,
          matching: find.text('Solo Leveling Season 2'),
        ),
        findsOneWidget,
      );
      // Once on the page: the banner's.
      expect(find.text('Solo Leveling Season 2'), findsOneWidget);
      // "AnikotoProvider" reads ANIKOTO, on the banner and nowhere else.
      expect(
        find.descendant(of: banner, matching: find.text('ANIKOTO')),
        findsOneWidget,
      );
      expect(find.text('ANIKOTO'), findsOneWidget);
      expect(find.textContaining('PROVIDER'), findsNothing);

      // The banner is a little under half the first view, and the backdrop is
      // the page's only title artwork: no poster beside a second title.
      final height = tester.getSize(banner).height - kDetailsPlayFabOverhang;
      expect(height / _kPhone.height, inInclusiveRange(0.40, 0.50));
      final art = tester
          .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .map((i) => i.imageUrl);
      expect(art, contains(_kBanner));
      expect(art, isNot(contains(_kPoster)));
      expect(
        find.byWidgetPredicate((w) => w is Hero && w.tag == 'poster_$_kUrl'),
        findsNothing,
      );

      // Back and bookmark stay over it.
      expect(find.byKey(const ValueKey('details-back')), findsOneWidget);
      expect(find.byKey(const ValueKey('details-bookmark')), findsOneWidget);
    });

    testWidgets('falls back to the poster when there is no backdrop', (
      tester,
    ) async {
      final eps = _episodes(3);
      await _pump(tester, _show(eps, bannerUrl: null), target: eps.first);
      final art = tester.widgetList<CachedNetworkImage>(
        find.descendant(
          of: find.byType(DetailsHeroBanner),
          matching: find.byType(CachedNetworkImage),
        ),
      );
      expect(art.single.imageUrl, _kPoster);
    });

    testWidgets('a title with no source has no tag', (tester) async {
      final eps = _episodes(3);
      await _pump(tester, _show(eps, provider: null), target: eps.first);
      expect(find.byType(DetailsSourceTag), findsNothing);
    });
  });

  group('the round Play button', () {
    testWidgets('names the episode it starts and plays it, as the full-width '
        'button did', (tester) async {
      final eps = _episodes(13);
      await _pump(tester, _show(eps), target: eps.first);

      expect(_fab, findsOneWidget);
      expect(_fabLabel(tester), 'Play E1');
      expect(find.bySemanticsLabel('Play E1'), findsOneWidget);
      expect(tester.getSize(_fab), const Size(56, 56));
      // Half on the banner, half on the page under it.
      final banner = tester.getRect(find.byType(DetailsHeroBanner));
      final fab = tester.getRect(_fab);
      expect(fab.bottom, banner.bottom);
      expect(fab.center.dy, banner.bottom - kDetailsPlayFabOverhang);

      // No full-width Play any more.
      expect(find.text('Play E1'), findsNothing);
      expect(find.text('Play'), findsNothing);

      await tester.tap(_fab);
      await tester.pump();
      expect(_FakeController.played, ['target']);
    });

    testWidgets('says Resume with saved progress on that episode', (
      tester,
    ) async {
      final eps = _episodes(13);
      await _pump(
        tester,
        _show(eps),
        target: eps[2],
        positions: {_epUrl(3): 400000},
      );
      expect(_fabLabel(tester), 'Resume E3');
    });

    testWidgets('names the season too when the title has several', (
      tester,
    ) async {
      final one = _episodes(3);
      final two = _episodes(3, season: 2);
      await _pump(
        tester,
        _show([...one, ...two]),
        seasons: {1: one, 2: two},
        target: two[1],
      );
      expect(_fabLabel(tester), 'Play S2 E2');
    });

    testWidgets('is not there for a title not out yet', (tester) async {
      await _pump(tester, _show(const [], comingSoon: true));
      expect(_fab, findsNothing);
      expect(find.byType(ComingSoonLabel), findsOneWidget);
    });

    testWidgets("a movie keeps Download under the strip, and Play is the "
        "banner's", (tester) async {
      final film = MultimediaItem(
        title: 'A Film',
        url: _kUrl,
        posterUrl: _kPoster,
        bannerUrl: _kBanner,
        contentType: MultimediaContentType.movie,
        year: 2024,
        duration: 116,
        score: 7.8,
        episodes: [Episode(name: 'A Film', url: _epUrl(1))],
      );
      await _pump(tester, film, isMovie: true);

      expect(_fabLabel(tester), 'Play');
      expect(find.text('Download'), findsOneWidget);
      expect(_row, findsNothing, reason: 'a film has no episode row');

      // Year, Runtime, Rating: what a film has.
      Finder inStrip(String text) =>
          find.descendant(of: _strip, matching: find.text(text));
      expect(inStrip('2024'), findsOneWidget);
      expect(inStrip('116m'), findsOneWidget);
      expect(inStrip('7.8'), findsOneWidget);
      expect(inStrip('Rating'), findsOneWidget);
      expect(inStrip('Episodes'), findsNothing);
      // Said once: the meta row leaves out what the strip shows.
      expect(find.text('7.8'), findsOneWidget);
      expect(find.text('MOVIE'), findsOneWidget);

      await tester.tap(find.text('Download'));
      await tester.pump();
      expect(_RecordingLauncher.launched, [_epUrl(1)]);
    });
  });

  group('the info strip', () {
    testWidgets('shows year, episodes, runtime and status in one card', (
      tester,
    ) async {
      final eps = _episodes(13);
      await _pump(tester, _show(eps), target: eps.first);

      Finder inStrip(String text) =>
          find.descendant(of: _strip, matching: find.text(text));
      expect(_strip, findsOneWidget);
      for (final text in [
        '2025',
        'Year',
        '13',
        'Episodes',
        '24m',
        'Runtime',
        'Completed',
        'Status',
      ]) {
        expect(inStrip(text), findsOneWidget, reason: text);
      }
      // The type stays, in the meta row under it.
      expect(find.text('ANIME'), findsOneWidget);
      // Said once: not again as chips.
      expect(find.text('2025'), findsOneWidget);
      expect(find.text('24m'), findsOneWidget);
    });

    testWidgets('shows only the columns the title has', (tester) async {
      final eps = _episodes(2);
      await _pump(
        tester,
        _show(eps, year: null, duration: null, status: ShowStatus.unknown),
        target: eps.first,
      );
      Finder inStrip(String text) =>
          find.descendant(of: _strip, matching: find.text(text));
      expect(inStrip('2'), findsOneWidget);
      expect(inStrip('Episodes'), findsOneWidget);
      expect(inStrip('Year'), findsNothing);
      expect(inStrip('Runtime'), findsNothing);
      expect(inStrip('Status'), findsNothing);
    });

    testWidgets('is absent with nothing to show', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: DetailsInfoStrip(columns: [])),
        ),
      );
      expect(_strip, findsNothing);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DetailsInfoStrip(
              columns: [
                DetailsInfoColumn(value: '2025', label: 'Year'),
                DetailsInfoColumn(value: ' ', label: 'Runtime'),
                DetailsInfoColumn(value: '13', label: 'Episodes'),
                DetailsInfoColumn(value: '24m', label: 'Runtime'),
                DetailsInfoColumn(value: 'Completed', label: 'Status'),
                DetailsInfoColumn(value: '8.1', label: 'Rating'),
              ],
            ),
          ),
        ),
      );
      // Four at most, blanks skipped, equal widths.
      expect(find.text('Rating'), findsNothing);
      expect(find.text('Status'), findsOneWidget);
      final widths = [
        for (final label in ['Year', 'Episodes', 'Runtime', 'Status'])
          tester
              .getSize(
                find
                    .ancestor(
                      of: find.text(label),
                      matching: find.byType(Expanded),
                    )
                    .first,
              )
              .width,
      ];
      expect(widths.toSet().length, 1);
    });
  });

  group('the synopsis', () {
    final long = List.filled(40, 'He hunts alone through the gate.').join(' ');

    testWidgets('is three lines until "more", all of it until "less", and has '
        'no heading', (tester) async {
      final eps = _episodes(3);
      await _pump(tester, _show(eps, description: long), target: eps.first);

      final toggle = find.byKey(const ValueKey('details-synopsis-more'));
      expect(find.text('Synopsis'), findsNothing);
      await _reach(tester, toggle);
      expect(find.text('more'), findsOneWidget);
      expect(tester.widget<Text>(find.text(long)).maxLines, 3);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('less'), findsOneWidget);
      expect(tester.widget<Text>(find.text(long)).maxLines, isNull);

      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('more'), findsOneWidget);
      expect(tester.widget<Text>(find.text(long)).maxLines, 3);
    });

    testWidgets('a short one has no toggle, and tags stay under it', (
      tester,
    ) async {
      final eps = _episodes(3);
      await _pump(tester, _show(eps, description: 'Short.'), target: eps.first);
      expect(find.text('Short.'), findsOneWidget);
      expect(find.byKey(const ValueKey('details-synopsis-more')), findsNothing);
      expect(find.byType(TagsRow, skipOffstage: false), findsOneWidget);
    });
  });

  group('the episode row', () {
    testWidgets('builds 500 episodes lazily, side by side', (tester) async {
      final eps = _episodes(500);
      await _pump(tester, _show(eps), target: eps.first);
      await _reach(tester, _row);

      expect(tester.widget<ListView>(_row).scrollDirection, Axis.horizontal);
      final built = find.byType(EpisodeCard).evaluate().length;
      expect(built, greaterThan(1));
      expect(built, lessThan(12), reason: 'only what is near the screen');

      // Number · name on one line, the runtime under it, a 16:9 thumbnail.
      expect(find.text('1 · Episode 1'), findsOneWidget);
      expect(find.text('2 · Episode 2'), findsOneWidget);
      expect(find.text('24m'), findsWidgets);
      expect(
        tester.getTopLeft(find.text('2 · Episode 2')).dy,
        tester.getTopLeft(find.text('1 · Episode 1')).dy,
      );
      expect(
        tester.getTopLeft(find.text('2 · Episode 2')).dx,
        greaterThan(tester.getTopLeft(find.text('1 · Episode 1')).dx),
      );
      final card = tester.getSize(find.byType(EpisodeRowCard).first);
      expect(card.width, 160);

      // The far end is reachable by swiping, and still lazy there.
      await tester.drag(_row, const Offset(-3000, 0));
      await tester.pumpAndSettle();
      expect(find.text('1 · Episode 1'), findsNothing);
      expect(find.byType(EpisodeCard).evaluate().length, lessThan(12));
    });

    testWidgets('a tap plays that episode', (tester) async {
      final eps = _episodes(500);
      await _pump(tester, _show(eps), target: eps.first);
      await _reach(tester, _row);

      await tester.tap(find.text('2 · Episode 2'));
      await tester.pump();
      expect(_FakeController.played, [_epUrl(2)]);
    });

    testWidgets('each card has its download button, which downloads it', (
      tester,
    ) async {
      final eps = _episodes(500);
      await _pump(tester, _show(eps), target: eps.first);
      await _reach(tester, _row);

      final buttons = find.byKey(const ValueKey('episode-row-download'));
      expect(
        buttons.evaluate().length,
        find.byType(EpisodeCard).evaluate().length,
      );
      // On the thumbnail's top-right corner.
      final thumb = tester.getRect(
        find
            .descendant(
              of: find.byType(EpisodeRowCard).first,
              matching: find.byType(AspectRatio),
            )
            .first,
      );
      final button = tester.getRect(buttons.first);
      expect(thumb.contains(button.center), isTrue);
      expect(button.center.dx, greaterThan(thumb.center.dx));
      expect(button.center.dy, lessThan(thumb.center.dy));

      await tester.tap(buttons.first);
      await tester.pump();
      expect(_RecordingLauncher.launched, [_epUrl(1)]);
      expect(_FakeController.played, isEmpty, reason: 'not a play');
    });

    testWidgets('shows progress, and what was watched', (tester) async {
      final eps = _episodes(500);
      await _pump(
        tester,
        _show(eps),
        target: eps.first,
        positions: {_epUrl(2): 500000},
        watched: {_epUrl(1)},
      );
      await _reach(tester, _row);

      final bars = tester.widgetList<LinearProgressIndicator>(
        find.byKey(const ValueKey('episode-row-progress')),
      );
      expect(bars.map((b) => b.value), containsAll(<double>[0.5, 1.0]));
      expect(find.text('WATCHED'), findsOneWidget);
      expect(find.text('WATCHING'), findsOneWidget);
    });

    testWidgets('a long press selects, then taps select, and the bar acts on '
        'the selection', (tester) async {
      final eps = _episodes(500);
      await _pump(tester, _show(eps), target: eps.first);
      await _reach(tester, _row);

      await tester.longPress(find.text('1 · Episode 1'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('1 selected'), findsOneWidget);
      // While picking, the corner is a tick box, not the download button.
      expect(find.byKey(const ValueKey('episode-row-download')), findsNothing);
      expect(
        find.byKey(const ValueKey('episode-row-select-mark')),
        findsWidgets,
      );

      await tester.ensureVisible(find.text('2 · Episode 2'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('2 · Episode 2'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('2 selected'), findsOneWidget);
      expect(_FakeController.played, isEmpty, reason: 'selecting, not playing');
      expect(find.text('Watched'), findsOneWidget);
      expect(find.text('Unwatched'), findsOneWidget);

      await tester.tap(find.byTooltip('Cancel selection'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('2 selected'), findsNothing);
      expect(find.byKey(const ValueKey('episode-row-download')), findsWidgets);
    });

    testWidgets('opens at the episode to resume, with the range picker on its '
        'range', (tester) async {
      final eps = _episodes(500);
      await _pump(tester, _show(eps), target: eps[236]);
      await _reach(tester, _row);
      await tester.pumpAndSettle();

      expect(find.text('237 · Episode 237'), findsOneWidget);
      expect(find.text('1 · Episode 1'), findsNothing);
      expect(
        tester.getTopLeft(find.text('237 · Episode 237')).dx,
        lessThan(60),
        reason: 'at the left edge of the row',
      );
      expect(find.text('221-240'), findsOneWidget);
    });

    testWidgets('the range picker scrolls the row to its range', (
      tester,
    ) async {
      final eps = _episodes(500);
      await _pump(tester, _show(eps), target: eps.first);
      await _reach(tester, _row);

      expect(find.text('1-20'), findsOneWidget);
      await tester.tap(find.text('1-20'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('41-60').last);
      await tester.pumpAndSettle();

      expect(find.text('41 · Episode 41'), findsOneWidget);
      expect(find.text('1 · Episode 1'), findsNothing);

      // And swiping the row moves the picker with it.
      await tester.drag(_row, const Offset(-172.0 * 25, 0));
      await tester.pumpAndSettle();
      expect(find.text('41-60'), findsNothing);
    });
  });

  group('what the header keeps', () {
    testWidgets('seasons, Sub/Dub, the range picker and sort', (tester) async {
      final one = _episodes(
        60,
        dub: (n) => n.isEven ? DubStatus.dubbed : DubStatus.subbed,
      );
      final two = _episodes(4, season: 2);
      await _pump(
        tester,
        _show([...one, ...two]),
        seasons: {1: one, 2: two},
        target: one.first,
        selectedDub: DubStatus.subbed,
      );
      await _reach(tester, _row);

      expect(find.byType(DetailsSeasonListWrapper), findsOneWidget);
      expect(find.text('Season 1'), findsOneWidget);
      expect(find.text('Season 2'), findsOneWidget);
      expect(find.text('Episodes'), findsWidgets);
      expect(find.byType(DetailsEpisodeFilterBar), findsOneWidget);
      expect(find.text('Sub'), findsOneWidget);
      expect(find.text('Dub'), findsOneWidget);
      expect(find.byIcon(Icons.swap_vert_rounded), findsOneWidget);
      expect(find.text('1-20'), findsOneWidget);

      // Sub is on: the odd ones.
      expect(find.text('1 · Episode 1'), findsOneWidget);
      expect(find.text('2 · Episode 2'), findsNothing);

      // The header is one line: title left, controls right.
      final title = tester.getRect(
        find
            .descendant(
              of: find.byType(DetailsEpisodeRowSection),
              matching: find.text('Episodes'),
            )
            .first,
      );
      final bar = tester.getRect(find.byType(DetailsEpisodeFilterBar));
      expect(bar.left, greaterThan(title.left));
      expect(bar.center.dy, closeTo(title.center.dy, 12));

      await tester.tap(find.text('Dub'));
      await tester.pumpAndSettle();
      expect(find.text('2 · Episode 2'), findsOneWidget);
      expect(find.text('1 · Episode 1'), findsNothing);

      await tester.tap(find.text('Season 2'));
      await tester.pumpAndSettle();
      // The other season's four, from its first.
      final cards = tester
          .widgetList<EpisodeCard>(find.byType(EpisodeCard))
          .toList();
      expect(cards, isNotEmpty);
      expect(cards.every((c) => c.episode.season == 2), isTrue);
      expect(cards.first.episode.episode, 1);
      expect(find.text('2 · Episode 2'), findsOneWidget);
    });
  });

  group('the shared pieces', () {
    testWidgets('HorizontalEpisodeRow builds lazily and reports where it '
        'rests', (tester) async {
      final built = <int>{};
      int? rested;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HorizontalEpisodeRow(
              itemCount: 500,
              initialIndex: 100,
              onFirstVisibleChanged: (i) => rested = i,
              itemBuilder: (context, index) {
                built.add(index);
                return EpisodeRowCard(
                  number: index + 1,
                  title: 'Episode ${index + 1}',
                  thumbnail: const ColoredBox(color: Colors.grey),
                  onTap: () {},
                );
              },
            ),
          ),
        ),
      );
      expect(built.length, lessThan(15));
      expect(built, contains(100));
      expect(built, isNot(contains(0)));
      expect(find.text('101 · Episode 101'), findsOneWidget);

      await tester.drag(
        find.byKey(const ValueKey('details-episode-row')),
        const Offset(-344, 0),
      );
      await tester.pumpAndSettle();
      expect(rested, isNotNull);
      expect(rested, greaterThan(100));
      expect(built.length, lessThan(40));
    });

    testWidgets('DetailsPlayFab is dimmed and inert with nothing to play', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DetailsPlayFab(label: 'Play', onPressed: null),
          ),
        ),
      );
      expect(find.byTooltip('Play'), findsOneWidget);
      final ink = tester.widget<InkWell>(
        find.descendant(of: _fab, matching: find.byType(InkWell)),
      );
      expect(ink.onTap, isNull);
    });
  });
}
