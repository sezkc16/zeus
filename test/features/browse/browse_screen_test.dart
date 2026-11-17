/// The Browse tab, without the shell behind it: the six category tiles are
/// gone, and under the title sit poster rows from the built-in Cinemeta
/// add-on, then the APP card. No network: the add-on client is a fake.
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zorox/core/addons/data/addon_client.dart';
import 'package:zorox/core/addons/data/addon_repository.dart';
import 'package:zorox/core/addons/data/builtin_addons.dart';
import 'package:zorox/core/addons/models/addon_manifest.dart';
import 'package:zorox/core/addons/models/addon_meta.dart';
import 'package:zorox/core/theme/app_theme.dart';
import 'package:zorox/features/addons/presentation/addon_catalog_screen.dart';
import 'package:zorox/features/addons/presentation/addon_providers.dart';
import 'package:zorox/features/browse/presentation/browse_category_grid.dart';
import 'package:zorox/features/browse/presentation/browse_screen.dart';
import 'package:zorox/features/settings/presentation/general_settings_provider.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// Nothing installed: every row has to come from the built-in Cinemeta.
class _Repo extends AddonRepository {
  @override
  AddonsState build() => const AddonsState(isLoading: false, addons: []);
}

String _key(String type, String id, String? genre) =>
    '$type/$id/${genre ?? 'none'}';

class _Call {
  final String addonUrl;
  final String key;
  final Map<String, String>? extra;
  final bool forceRefresh;
  _Call(this.addonUrl, this.key, this.extra, this.forceRefresh);
}

/// Answers each catalog with ten titles named after it, unless the test
/// says that catalog is empty or failing.
class _Client extends AddonClient {
  _Client() : super(Dio());

  final List<_Call> calls = [];
  final Set<String> empty = {};
  final Set<String> failing = {};

  int count(String key) => calls.where((c) => c.key == key).length;

  @override
  Future<List<AddonMetaPreview>> catalog(
    ManagedAddon addon, {
    required String type,
    required String id,
    Map<String, String>? extra,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    final key = _key(type, id, extra?['genre']);
    calls.add(_Call(addon.manifestUrl, key, extra, forceRefresh));
    if (failing.contains(key)) throw Exception('cinemeta answered 500');
    if (empty.contains(key)) return const <AddonMetaPreview>[];
    return [
      for (var i = 0; i < 10; i++)
        AddonMetaPreview(
          id: 'tt-$type-$id-${extra?['genre'] ?? 'none'}-$i',
          type: type,
          name: 'Title $key $i',
          poster: 'https://img.test/$key/$i.jpg',
        ),
    ];
  }
}

final String _year = '${DateTime.now().year}';

/// Title → the catalog it must come from, top to bottom.
final List<(String, String, String, String?)> _rows = [
  ('Popular Movies', 'movie', 'top', null),
  ('Popular Series', 'series', 'top', null),
  ('Featured Movies', 'movie', 'imdbRating', null),
  ('Featured Series', 'series', 'imdbRating', null),
  ('New Movies', 'movie', 'year', _year),
  ('New Series', 'series', 'year', _year),
  ('Action Movies', 'movie', 'top', 'Action'),
  ('Comedy Movies', 'movie', 'top', 'Comedy'),
  ('Drama Series', 'series', 'top', 'Drama'),
  ('Animation', 'movie', 'top', 'Animation'),
];

Finder _row(String type, String id, String? genre) =>
    find.byKey(ValueKey('browse-row-$type-$id-${genre ?? 'none'}'));

void main() {
  late _Client client;
  late GoRouter router;

  setUp(() {
    client = _Client();
    router = GoRouter(
      initialLocation: '/browse',
      routes: [
        GoRoute(path: '/browse', builder: (_, _) => const BrowseScreen()),
        GoRoute(
          path: '/settings',
          builder: (_, _) => const Scaffold(body: Text('settings page')),
        ),
        // The stubs echo the pushed route's query params: a push is an
        // imperative match, which the router's reported URI does not show.
        GoRoute(
          path: '/addon-catalog',
          builder: (_, state) {
            final q = state.uri.queryParameters;
            return Scaffold(
              body: Text(
                'catalog page ${q['addon-url']} ${q['type']} '
                '${q['catalog-id']} ${q['genre']} ${q['title']}',
              ),
            );
          },
        ),
        GoRoute(
          path: '/addon-detail',
          builder: (_, state) {
            final q = state.uri.queryParameters;
            return Scaffold(
              body: Text(
                'detail page ${q['addon-url']} ${q['type']} ${q['id']}',
              ),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);
  });

  /// [height] 6000 lays every row out at once; a phone's 844 leaves the
  /// lower rows unbuilt.
  Future<void> pumpBrowse(WidgetTester tester, {double height = 6000}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = Size(390, height);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          addonRepositoryProvider.overrideWith(_Repo.new),
          addonClientProvider.overrideWithValue(client),
          generalSettingsProvider.overrideWithValue(const GeneralSettings()),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.createDarkTheme(null),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Riverpod disposes what the tree dropped on a timer of its own.
  Future<void> tearDownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  testWidgets('the tiles and their subtitle are gone, the title stays', (
    tester,
  ) async {
    await pumpBrowse(tester);

    expect(find.text('Browse'), findsOneWidget);
    expect(find.text('Explore by category'), findsNothing);
    expect(find.byType(BrowseCategoryGrid), findsNothing);
    for (final tile in ['TV Shows', 'Anime', 'K-Drama', '4K & HDR', 'Top Rated']) {
      expect(find.textContaining(tile), findsNothing, reason: tile);
    }
    expect(find.text('Movies'), findsNothing);
    expect(find.text('🎬 Movies'), findsNothing);

    await tearDownTree(tester);
  });

  testWidgets('the ten Cinemeta rows show in order, each from its catalog', (
    tester,
  ) async {
    await pumpBrowse(tester);

    double? previous;
    for (final (title, type, id, genre) in _rows) {
      final row = _row(type, id, genre);
      expect(row, findsOneWidget, reason: title);
      expect(
        find.descendant(of: row, matching: find.text(title)),
        findsOneWidget,
        reason: title,
      );
      // Its posters are that catalog's answer, not another row's.
      expect(
        find.descendant(
          of: row,
          matching: find.text('Title ${_key(type, id, genre)} 0'),
        ),
        findsWidgets,
        reason: title,
      );
      final top = tester.getTopLeft(row).dy;
      if (previous != null) expect(top, greaterThan(previous), reason: title);
      previous = top;
    }

    // One request per row, all to the built-in Cinemeta, nothing else.
    expect(client.calls, hasLength(10));
    expect(
      client.calls.map((c) => c.addonUrl).toSet(),
      {BuiltInAddons.cinemetaUrl},
    );
    expect(
      client.calls.map((c) => c.key).toSet(),
      {for (final (_, type, id, genre) in _rows) _key(type, id, genre)},
    );
    // The year rows ask for this year as their genre extra.
    expect(
      client.calls.firstWhere((c) => c.key == 'movie/year/$_year').extra,
      {'genre': _year},
    );

    await tearDownTree(tester);
  });

  testWidgets('rows below the fold are not asked for until scrolled to', (
    tester,
  ) async {
    await pumpBrowse(tester, height: 844);

    expect(client.calls.length, lessThan(10));
    expect(client.count('movie/top/Animation'), 0);
    expect(_row('movie', 'top', 'Animation'), findsNothing);

    await tearDownTree(tester);
  });

  testWidgets('a failed row says so, and Retry asks again', (tester) async {
    client.failing.add('series/top/none');
    await pumpBrowse(tester);

    final row = _row('series', 'top', null);
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('Popular Series')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining("Couldn't load this row"),
      ),
      findsOneWidget,
    );
    // No posters stand in for the ones that did not load.
    expect(find.textContaining('Title series/top/none'), findsNothing);
    // The rows around it are unaffected.
    expect(find.text('Popular Movies'), findsOneWidget);
    expect(find.text('Featured Movies'), findsOneWidget);
    expect(client.count('series/top/none'), 1);

    client.failing.clear();
    await tester.tap(
      find.byKey(const ValueKey('browse-row-retry-series-top-none')),
    );
    await settle(tester);

    expect(client.count('series/top/none'), 2);
    expect(find.textContaining("Couldn't load this row"), findsNothing);
    expect(
      find.descendant(
        of: _row('series', 'top', null),
        matching: find.text('Title series/top/none 0'),
      ),
      findsWidgets,
    );

    await tearDownTree(tester);
  });

  testWidgets('an empty row is hidden', (tester) async {
    client.empty.add('movie/imdbRating/none');
    await pumpBrowse(tester);
    await settle(tester);

    expect(client.count('movie/imdbRating/none'), 1);
    expect(find.text('Featured Movies'), findsNothing);
    expect(_row('movie', 'imdbRating', null), findsNothing);
    expect(find.text('Featured Series'), findsOneWidget);
    expect(find.text('Popular Movies'), findsOneWidget);

    await tearDownTree(tester);
  });

  testWidgets('View All opens that catalog, with its genre', (tester) async {
    Future<void> viewAll(String type, String id, String? genre) async {
      final button = find.descendant(
        of: _row(type, id, genre),
        matching: find.text('View All'),
      );
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    await pumpBrowse(tester);
    const url = BuiltInAddons.cinemetaUrl;

    await viewAll('movie', 'top', null);
    expect(
      find.text('catalog page $url movie top null Popular Movies'),
      findsOneWidget,
    );
    router.pop();
    await settle(tester);

    await viewAll('series', 'imdbRating', null);
    expect(
      find.text('catalog page $url series imdbRating null Featured Series'),
      findsOneWidget,
    );
    router.pop();
    await settle(tester);

    await viewAll('series', 'year', _year);
    expect(
      find.text('catalog page $url series year $_year New Series'),
      findsOneWidget,
    );
    router.pop();
    await settle(tester);

    // A genre row opens the Popular grid on that genre's chip.
    await viewAll('movie', 'top', 'Action');
    expect(
      find.text('catalog page $url movie top Action Popular Movies'),
      findsOneWidget,
    );

    await tearDownTree(tester);
  });

  testWidgets('a poster opens the title as a built-in Cinemeta title', (
    tester,
  ) async {
    await pumpBrowse(tester);

    await tester.tap(
      find
          .descendant(
            of: _row('series', 'top', 'Drama'),
            matching: find.text('Title series/top/Drama 0'),
          )
          .first,
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'detail page ${BuiltInAddons.cinemetaUrl} series '
        'tt-series-top-Drama-0',
      ),
      findsOneWidget,
    );

    await tearDownTree(tester);
  });

  testWidgets('the APP card with Settings is still at the bottom', (
    tester,
  ) async {
    await pumpBrowse(tester);

    expect(find.text('APP'), findsOneWidget);
    final settings = find.widgetWithText(ListTile, 'Settings');
    expect(settings, findsOneWidget);
    expect(
      tester.getTopLeft(settings).dy,
      greaterThan(tester.getBottomLeft(_row('movie', 'top', 'Animation')).dy),
    );
    // Clear of the floating nav pill.
    expect(tester.getBottomLeft(find.byType(Card).last).dy, lessThan(6000 - 99));

    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(find.text('settings page'), findsOneWidget);

    await tearDownTree(tester);
  });

  testWidgets('pulling down fetches the shown rows again past the cache', (
    tester,
  ) async {
    // A phone's height: the pull has to cover a quarter of the viewport.
    client.empty.add('series/top/none');
    await pumpBrowse(tester, height: 844);
    await settle(tester);
    expect(find.text('Popular Movies'), findsOneWidget);
    expect(find.text('Popular Series'), findsNothing);
    final before = client.calls.length;
    final shown = client.calls.map((c) => c.key).toSet();
    expect(client.calls.where((c) => c.forceRefresh), isEmpty);

    client.empty.clear();
    await tester.fling(
      find.byKey(const ValueKey('browse-scroll')),
      const Offset(0, 400),
      1000,
    );
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await settle(tester);

    final refetched = client.calls.skip(before).toList();
    // Every row that had been asked for is fetched again past the cache...
    expect(
      refetched.where((c) => c.forceRefresh).map((c) => c.key).toSet(),
      shown,
    );
    expect(shown, contains('movie/top/none'));
    // ...and a row that was empty before comes back once it has titles.
    expect(find.text('Popular Series'), findsOneWidget);
    expect(
      find.descendant(
        of: _row('series', 'top', null),
        matching: find.text('Title series/top/none 0'),
      ),
      findsWidgets,
    );

    await tearDownTree(tester);
  });

  testWidgets('the catalog grid starts on the genre it was opened with', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          addonRepositoryProvider.overrideWith(_Repo.new),
          addonClientProvider.overrideWithValue(client),
          generalSettingsProvider.overrideWithValue(const GeneralSettings()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.createDarkTheme(null),
          home: AddonCatalogScreen(
            addonUrl: BuiltInAddons.cinemetaUrl,
            type: 'movie',
            catalogId: 'year',
            title: 'New Movies',
            initialGenre: _year,
          ),
        ),
      ),
    );
    await settle(tester);

    expect(client.calls, isNotEmpty);
    expect(client.calls.first.key, 'movie/year/$_year');
    expect(client.calls.first.extra, {'genre': _year});
    // The year chip is the selected one, and a catalog that needs a year
    // offers no "All".
    final chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, _year),
    );
    expect(chip.selected, isTrue);
    expect(find.widgetWithText(ChoiceChip, 'All'), findsNothing);

    await tearDownTree(tester);
  });

  test('the built-in year and Featured catalogs are not search targets', () {
    final catalogs = BuiltInAddons.cinemeta.manifest!.catalogs;
    expect(
      [
        for (final c in catalogs)
          if (c.supportsSearch) c.key,
      ],
      ['movie/top', 'series/top'],
    );
    final year = catalogs.firstWhere((c) => c.key == 'movie/year');
    expect(year.requiresOtherExtra, isTrue);
    expect(year.genres.first, _year);
    expect(year.genres.last, '1920');
    expect(
      catalogs.firstWhere((c) => c.key == 'series/year').genres.last,
      '1960',
    );
    expect(
      catalogs.firstWhere((c) => c.key == 'series/imdbRating').genres,
      contains('Talk-Show'),
    );
  });

  test('the row provider reads a genre row from the built-in Cinemeta', () async {
    final container = ProviderContainer(
      overrides: [
        addonRepositoryProvider.overrideWith(_Repo.new),
        addonClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);

    final result = await container.read(
      addonCatalogItemsProvider(
        BuiltInAddons.cinemetaUrl,
        'movie',
        'top',
        genre: 'Comedy',
      ).future,
    );
    expect(result.failed, isFalse);
    expect(result.items, hasLength(10));
    expect(client.calls.single.extra, {'genre': 'Comedy'});
  });
}
