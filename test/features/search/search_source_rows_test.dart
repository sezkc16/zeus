// A test's ProviderScope is its root scope; the rule only recognises one
// passed to runApp.
// ignore_for_file: riverpod_lint/scoped_providers_should_specify_dependencies

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/extensions/base_provider.dart';
import 'package:zorox/core/extensions/extension_manager.dart';
import 'package:zorox/features/search/data/search_history_store.dart';
import 'package:zorox/features/search/presentation/search_provider.dart';
import 'package:zorox/features/search/presentation/search_screen.dart';
import 'package:zorox/features/search/presentation/search_source_grid_screen.dart';
import 'package:zorox/features/search/presentation/search_sources.dart';
import 'package:zorox/features/search/presentation/widgets/search_source_row.dart';
import 'package:zorox/features/settings/presentation/general_settings_provider.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// Search results, v5 design A "Rows": one section per source that
/// answered, each a header (icon, clean name, count, View All) over a
/// horizontal poster row.

class _Manager extends ExtensionManager {
  @override
  List<SkyStreamProvider> build() => const [];
}

class _History implements SearchHistoryStore {
  @override
  List<String> read() => const [];
  @override
  Future<void> write(List<String> next) async {}
}

/// A source that notes what it was asked to open.
class _Source implements SearchSource {
  _Source(this.kind);

  @override
  final SearchSourceKind kind;
  final opened = <MultimediaItem>[];

  @override
  Future<void> open(BuildContext context, MultimediaItem item) async =>
      opened.add(item);
}

MultimediaItem _item(
  String title, {
  MultimediaContentType type = MultimediaContentType.anime,
}) => MultimediaItem(
  title: title,
  url: 'u/$title',
  posterUrl: '',
  contentType: type,
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pump(WidgetTester tester, SearchAggregateState state) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        searchHistoryStoreProvider.overrideWithValue(_History()),
        searchResultsProvider.overrideWith((ref) => Stream.value(state)),
        extensionManagerProvider.overrideWith(_Manager.new),
        generalSettingsProvider.overrideWithValue(const GeneralSettings()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData.dark(),
        home: const SearchScreen(),
      ),
    ),
  );
  await _settle(tester);
}

void main() {
  testWidgets('each source that answered gets its own row, named cleanly '
      'with its count; an empty or failed source gets none', (tester) async {
    final anikoto = _Source(SearchSourceKind.cloudstream);
    final miruro = _Source(SearchSourceKind.cloudstream);
    await _pump(
      tester,
      SearchAggregateState(
        results: [
          ProviderSearchResult(
            providerId: 'p.anikoto',
            providerName: 'AnikotoProvider',
            results: [_item('One Piece'), _item('One Piece Film Red')],
            source: anikoto,
          ),
          ProviderSearchResult(
            providerId: 'p.miruro',
            providerName: 'Miruro',
            results: [_item('One Piece (Miruro)')],
            source: miruro,
          ),
          ProviderSearchResult(
            providerId: 'p.empty',
            providerName: 'EmptyProvider',
            results: const [],
          ),
          ProviderSearchResult(
            providerId: 'p.broken',
            providerName: 'BrokenProvider',
            results: const [],
            error: 'boom',
          ),
        ],
      ),
    );

    expect(find.byType(SearchSourceRow), findsNWidgets(2));
    expect(find.text('Anikoto · 2'), findsOneWidget);
    expect(find.text('Miruro · 1'), findsOneWidget);
    expect(find.textContaining('AnikotoProvider'), findsNothing);
    expect(find.textContaining('Empty'), findsNothing);
    expect(find.textContaining('Broken'), findsNothing);
    expect(find.text('View All'), findsNWidgets(2));
    // No flat mixed grid.
    expect(find.byType(GridView), findsNothing);

    // The posters of a row scroll sideways.
    final row = tester.widget<ListView>(
      find.descendant(
        of: find.byKey(const ValueKey('search-section-p.anikoto')),
        matching: find.byType(ListView),
      ),
    );
    expect(row.scrollDirection, Axis.horizontal);

    // A poster opens the title in ITS source.
    await tester.tap(
      find.byKey(const ValueKey('search-poster-p.miruro-u/One Piece (Miruro)')),
    );
    await _settle(tester);
    expect(miruro.opened.single.title, 'One Piece (Miruro)');
    expect(anikoto.opened, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('View All opens that source\'s 3-column grid, and a poster '
      'there opens in the same source', (tester) async {
    final anikoto = _Source(SearchSourceKind.cloudstream);
    await _pump(
      tester,
      SearchAggregateState(
        results: [
          ProviderSearchResult(
            providerId: 'p.anikoto',
            providerName: 'AnikotoProvider',
            results: [for (var i = 0; i < 7; i++) _item('One Piece $i')],
            source: anikoto,
          ),
          ProviderSearchResult(
            providerId: 'p.miruro',
            providerName: 'Miruro',
            results: [_item('Other')],
          ),
        ],
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('search-source-view-all-p.anikoto')),
    );
    await _settle(tester);

    expect(find.byType(SearchSourceGridScreen), findsOneWidget);
    expect(find.text('Anikoto · 7'), findsWidgets);
    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      3,
    );
    expect(find.byKey(const ValueKey('search-grid-u/Other')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('search-grid-u/One Piece 3')));
    await _settle(tester);
    expect(anikoto.opened.single.title, 'One Piece 3');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a chip filters the rows: a source with nothing under the '
      'chip loses its row, the others recount', (tester) async {
    await _pump(
      tester,
      SearchAggregateState(
        results: [
          ProviderSearchResult(
            providerId: 'p.anikoto',
            providerName: 'AnikotoProvider',
            results: [
              _item('One Piece'),
              _item('One Piece Film', type: MultimediaContentType.movie),
            ],
          ),
          ProviderSearchResult(
            providerId: 'p.miruro',
            providerName: 'Miruro',
            results: [_item('One Piece M')],
          ),
        ],
      ),
    );
    expect(find.text('Anikoto · 2'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Movies'));
    await _settle(tester);

    expect(find.text('Anikoto · 1'), findsOneWidget);
    expect(find.textContaining('Miruro'), findsNothing);
    expect(find.byType(SearchSourceRow), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rows appear while other sources are still searching, and '
      '"No results" only shows once every source finished empty', (
    tester,
  ) async {
    // Still loading with one answer: that row shows, no empty state.
    await _pump(
      tester,
      SearchAggregateState(
        isLoading: true,
        results: [
          ProviderSearchResult(
            providerId: 'p.anikoto',
            providerName: 'AnikotoProvider',
            results: [_item('One Piece')],
          ),
        ],
      ),
    );
    expect(find.text('Anikoto · 1'), findsOneWidget);
    expect(find.text('No Results Found'), findsNothing);
    await tester.pumpWidget(const SizedBox());

    // Still loading with nothing yet: no "No results" either.
    await _pump(tester, const SearchAggregateState(isLoading: true));
    expect(find.text('No Results Found'), findsNothing);
    expect(find.byType(SearchSourceRow), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the popcorn scope button is gone from the phone search bar', (
    tester,
  ) async {
    await _pump(tester, const SearchAggregateState());
    expect(find.text('🍿'), findsNothing);
    expect(find.textContaining('🍿'), findsNothing);
    expect(find.byTooltip('Search scope'), findsNothing);
    expect(find.byType(PopupMenuButton<SearchFilter>), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('plugin sections come first, in the order they answered; Stremio '
      'add-ons\' and Nuvio\'s follow under their own names', () {
    ProviderSearchResult r(String id, SearchSourceKind kind) =>
        ProviderSearchResult(
          providerId: id,
          providerName: id,
          results: [_item(id)],
          kind: kind,
        );
    final ordered = orderSearchSections([
      for (final s in [
        r('stremio:cinemeta', SearchSourceKind.stremio),
        r('p.anikoto', SearchSourceKind.cloudstream),
        r('nuvio', SearchSourceKind.nuvio),
        r('p.js', SearchSourceKind.zorox),
      ])
        (s, s.results),
    ]);
    expect(ordered.map((e) => e.$1.providerId).toList(), [
      'p.anikoto',
      'p.js',
      'stremio:cinemeta',
      'nuvio',
    ]);
  });
}
