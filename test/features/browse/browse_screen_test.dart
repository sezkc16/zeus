/// The Browse tab, without the shell behind it. It has no content of its
/// own: blank with a hint and a button until a catalog add-on is installed,
/// then that add-on's catalogs as rows. No network: the add-on client is a
/// fake.
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
import 'package:zorox/features/addons/presentation/addons_screen.dart';
import 'package:zorox/features/browse/presentation/browse_catalogue.dart';
import 'package:zorox/features/browse/presentation/browse_screen.dart';
import 'package:zorox/features/settings/presentation/general_settings_provider.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// A fresh install: nothing installed.
class _Repo extends AddonRepository {
  @override
  AddonsState build() => const AddonsState(isLoading: false, addons: []);
}

const String _kitsuUrl = 'https://kitsu.test/manifest.json';

/// One installed catalog add-on. Its first catalog answers empty, so there
/// is no banner carousel and its timers stay out of the test.
class _KitsuRepo extends AddonRepository {
  @override
  AddonsState build() => AddonsState(
    isLoading: false,
    addons: [
      ManagedAddon(
        manifestUrl: _kitsuUrl,
        addedAt: DateTime(2026),
        manifest: const AddonManifest(
          id: 'kitsu',
          name: 'Anime Kitsu',
          version: '1',
          resources: [AddonResource(name: 'catalog')],
          types: ['anime'],
          catalogs: [
            AddonCatalog(type: 'anime', id: 'blank', name: 'Blank'),
            AddonCatalog(
              type: 'anime',
              id: 'trending',
              name: 'Trending anime',
              extra: [AddonExtraProperty(name: 'search')],
            ),
          ],
        ),
      ),
    ],
  );
}

/// One installed catalog add-on whose catalogs cannot be searched.
class _ListsRepo extends AddonRepository {
  @override
  AddonsState build() => AddonsState(
    isLoading: false,
    addons: [
      ManagedAddon(
        manifestUrl: _kitsuUrl,
        addedAt: DateTime(2026),
        manifest: const AddonManifest(
          id: 'lists',
          name: 'Lists',
          version: '1',
          resources: [AddonResource(name: 'catalog')],
          types: ['anime'],
          catalogs: [
            AddonCatalog(type: 'anime', id: 'blank', name: 'Blank'),
            AddonCatalog(type: 'anime', id: 'trending', name: 'Trending anime'),
          ],
        ),
      ),
    ],
  );
}

const String _xmasUrl = 'https://xmas.test/manifest.json';

ManagedAddon _kitsuAddon() => ManagedAddon(
  manifestUrl: _kitsuUrl,
  addedAt: DateTime(2026),
  manifest: const AddonManifest(
    id: 'kitsu',
    name: 'Anime Kitsu',
    version: '1',
    resources: [AddonResource(name: 'catalog')],
    types: ['anime'],
    catalogs: [
      AddonCatalog(type: 'anime', id: 'blank', name: 'Blank'),
      AddonCatalog(type: 'anime', id: 'trending', name: 'Trending anime'),
    ],
  ),
);

ManagedAddon _xmasAddon() => ManagedAddon(
  manifestUrl: _xmasUrl,
  addedAt: DateTime(2026),
  manifest: const AddonManifest(
    id: 'xmas',
    name: 'Christmas Movies',
    version: '1',
    resources: [AddonResource(name: 'catalog')],
    types: ['movie'],
    catalogs: [
      AddonCatalog(type: 'movie', id: 'xblank', name: 'Blank'),
      AddonCatalog(type: 'movie', id: 'xmas', name: 'Festive'),
    ],
  ),
);

/// Two installed catalog add-ons; the second can be taken away.
class _TwoRepo extends AddonRepository {
  @override
  AddonsState build() =>
      AddonsState(isLoading: false, addons: [_kitsuAddon(), _xmasAddon()]);

  void dropXmas() =>
      state = AddonsState(isLoading: false, addons: [_kitsuAddon()]);
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
/// says that catalog is empty.
class _Client extends AddonClient {
  _Client() : super(Dio());

  final List<_Call> calls = [];
  final Set<String> empty = {'anime/blank/none', 'movie/xblank/none'};

  @override
  Future<List<CommunityAddon>> communityAddons({
    bool forceRefresh = false,
  }) async => const <CommunityAddon>[];

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
    if (empty.contains(key)) return const <AddonMetaPreview>[];
    return [
      for (var i = 0; i < 10; i++)
        AddonMetaPreview(
          id: 'kitsu:$id$i',
          type: type,
          name: 'Title $key $i',
          poster: 'https://img.test/$key/$i.jpg',
        ),
    ];
  }
}

final String _year = '${DateTime.now().year}';

void main() {
  late _Client client;
  // The catalogue choice, as the device would keep it.
  String? storedCatalogue;
  late GoRouter router;

  setUp(() {
    client = _Client();
    storedCatalogue = null;
    router = GoRouter(
      initialLocation: '/browse',
      routes: [
        GoRoute(path: '/browse', builder: (_, _) => const BrowseScreen()),
        // The stubs echo the pushed route's query params: a push is an
        // imperative match, which the router's reported URI does not show.
        GoRoute(
          path: '/settings/stremio',
          builder: (_, state) => Scaffold(
            body: Text(
              'addons page tab ${state.uri.queryParameters['initial-tab']}',
            ),
          ),
        ),
        GoRoute(
          path: '/addon-detail',
          builder: (_, state) {
            final q = state.uri.queryParameters;
            return Scaffold(
              body: Text(
                'detail page ${q['addon-url']} ${q['type']} ${q['id']} '
                'merged ${q['merged']}',
              ),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);
  });

  Future<void> pumpBrowse(
    WidgetTester tester, {
    required AddonRepository Function() repo,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          addonRepositoryProvider.overrideWith(repo),
          addonClientProvider.overrideWithValue(client),
          generalSettingsProvider.overrideWithValue(const GeneralSettings()),
          browseCatalogueStoreProvider.overrideWithValue(
            BrowseCatalogueStore(
              read: () => storedCatalogue,
              write: (v) async => storedCatalogue = v,
            ),
          ),
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

  testWidgets('with nothing installed Browse is blank: a hint, a button, '
      'no posters and no request', (tester) async {
    await pumpBrowse(tester, repo: _Repo.new);
    await settle(tester);

    expect(find.text('Browse'), findsOneWidget);
    expect(find.byKey(const ValueKey('browse-empty-hint')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('browse-empty-addons-button')),
      findsOneWidget,
    );
    // Nothing built in: no Cinemeta rows, nothing fetched, nothing to search.
    expect(find.text('Popular Movies'), findsNothing);
    expect(find.byKey(const ValueKey('browse-search-button')), findsNothing);
    expect(client.calls, isEmpty);

    await tearDownTree(tester);
  });

  // 1.0.1 build 67: the add-ons screen opens OVER Browse (it used to be
  // gone to in the Settings branch, so Back landed on Settings).
  int addonsTab(WidgetTester tester) =>
      DefaultTabController.of(tester.element(find.byType(TabBar))).index;

  testWidgets('the blank page button opens Stremio add-ons on Discover, '
      'and Back returns to Browse', (tester) async {
    await pumpBrowse(tester, repo: _Repo.new);

    await tester.tap(find.byKey(const ValueKey('browse-empty-addons-button')));
    await settle(tester);
    expect(find.byType(AddonsScreen), findsOneWidget);
    expect(addonsTab(tester), 1);
    // Still on the Browse route: nothing went to the Settings branch.
    expect(
      router.routerDelegate.currentConfiguration.uri.toString(),
      '/browse',
    );

    await tester.tap(find.byTooltip('Back'));
    await settle(tester);
    expect(find.byType(AddonsScreen), findsNothing);
    expect(find.byKey(const ValueKey('browse-empty-hint')), findsOneWidget);

    await tearDownTree(tester);
  });

  testWidgets('the header button opens Stremio add-ons on Installed, and '
      'the system back returns to Browse', (tester) async {
    await pumpBrowse(tester, repo: _Repo.new);

    await tester.tap(find.byKey(const ValueKey('browse-addons-button')));
    await settle(tester);
    expect(find.byType(AddonsScreen), findsOneWidget);
    expect(addonsTab(tester), 0);

    // Android back / the router's back dispatcher.
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.byType(AddonsScreen), findsNothing);
    expect(find.byKey(const ValueKey('browse-empty-hint')), findsOneWidget);

    await tearDownTree(tester);
  });

  testWidgets('an installed catalog add-on fills Browse with its own rows '
      'only', (tester) async {
    await pumpBrowse(tester, repo: _KitsuRepo.new);
    await settle(tester);

    expect(find.byKey(const ValueKey('browse-empty-hint')), findsNothing);
    expect(find.text('Trending anime'), findsOneWidget);
    // Build 67: the Browse hero is edge to edge, like the Home hero.
    expect(
      tester
          .widget<AddonCatalogsTabView>(find.byType(AddonCatalogsTabView))
          .fullBleedHero,
      isTrue,
    );
    expect(find.text('Title anime/trending/none 0'), findsOneWidget);
    // No built-in Cinemeta row beside it, and every request went to the
    // installed add-on.
    expect(find.text('Popular Movies'), findsNothing);
    expect(client.calls, isNotEmpty);
    expect(client.calls.map((c) => c.addonUrl).toSet(), {_kitsuUrl});
    // Both header buttons are there now.
    expect(find.byKey(const ValueKey('browse-addons-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('browse-search-button')), findsOneWidget);

    await tearDownTree(tester);
  });

  testWidgets('no catalogue line with no add-on or with one', (tester) async {
    await pumpBrowse(tester, repo: _Repo.new);
    expect(find.byKey(BrowseCatalogueBar.tapKey), findsNothing);
    await tearDownTree(tester);

    await pumpBrowse(tester, repo: _KitsuRepo.new);
    await settle(tester);
    expect(find.byKey(BrowseCatalogueBar.tapKey), findsNothing);
    expect(find.text(kBrowseAllCatalogues), findsNothing);
    await tearDownTree(tester);
  });

  testWidgets('two catalog add-ons: the line shows, defaults to All '
      'catalogues, and choosing an add-on shows only its rows', (tester) async {
    await pumpBrowse(tester, repo: _TwoRepo.new);
    await settle(tester);

    expect(find.byKey(BrowseCatalogueBar.tapKey), findsOneWidget);
    expect(find.text('from'), findsOneWidget);
    expect(find.text(kBrowseAllCatalogues), findsOneWidget);
    // Every add-on's rows, as before.
    expect(find.text('Trending anime'), findsOneWidget);
    expect(find.text('Festive · Movies'), findsOneWidget);

    await tester.tap(find.byKey(BrowseCatalogueBar.tapKey));
    await settle(tester);
    // All catalogues first, then the add-ons in their order.
    final all = tester.getTopLeft(
      find.byKey(const ValueKey('browse-catalogue-all')),
    );
    final kitsu = tester.getTopLeft(
      find.byKey(const ValueKey('browse-catalogue-$_kitsuUrl')),
    );
    final xmas = tester.getTopLeft(
      find.byKey(const ValueKey('browse-catalogue-$_xmasUrl')),
    );
    expect(all.dy, lessThan(kitsu.dy));
    expect(kitsu.dy, lessThan(xmas.dy));

    await tester.tap(find.byKey(const ValueKey('browse-catalogue-$_xmasUrl')));
    await settle(tester);

    expect(storedCatalogue, _xmasUrl);
    expect(find.text('Christmas Movies'), findsOneWidget); // the line
    expect(find.text('Festive · Movies'), findsOneWidget);
    expect(find.text('Trending anime'), findsNothing);
    expect(
      tester
          .widget<AddonCatalogsTabView>(find.byType(AddonCatalogsTabView))
          .onlyAddonUrl,
      _xmasUrl,
    );

    // Back to everything.
    await tester.tap(find.byKey(BrowseCatalogueBar.tapKey));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('browse-catalogue-all')));
    await settle(tester);
    expect(storedCatalogue, kBrowseAllChoice);
    expect(find.text('Trending anime'), findsOneWidget);
    expect(find.text('Festive · Movies'), findsOneWidget);

    await tearDownTree(tester);
  });

  testWidgets('a kept choice is used on open, and falls back to all when '
      'its add-on is removed', (tester) async {
    storedCatalogue = _xmasUrl;
    await pumpBrowse(tester, repo: _TwoRepo.new);
    await settle(tester);
    expect(find.text('Festive · Movies'), findsOneWidget);
    expect(find.text('Trending anime'), findsNothing);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(BrowseScreen)),
    );
    (container.read(addonRepositoryProvider.notifier) as _TwoRepo).dropXmas();
    await settle(tester);

    // One add-on left: no line, and its rows show although the kept
    // choice still names the removed add-on.
    expect(container.read(browseCatalogueProvider), isNull);
    expect(find.byKey(BrowseCatalogueBar.tapKey), findsNothing);
    expect(find.text('Trending anime'), findsOneWidget);

    await tearDownTree(tester);
  });

  testWidgets('no search button when no installed add-on can be searched: '
      'search never falls back to the built-in Cinemeta', (tester) async {
    await pumpBrowse(tester, repo: _ListsRepo.new);
    await settle(tester);

    expect(find.text('Trending anime'), findsOneWidget);
    expect(find.byKey(const ValueKey('browse-addons-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('browse-search-button')), findsNothing);

    await tearDownTree(tester);
  });

  testWidgets('a poster opens the title with the merged sources page', (
    tester,
  ) async {
    await pumpBrowse(tester, repo: _KitsuRepo.new);
    await settle(tester);

    await tester.tap(find.text('Title anime/trending/none 0'));
    await settle(tester);
    expect(
      find.text('detail page $_kitsuUrl anime kitsu:trending0 merged true'),
      findsOneWidget,
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
          browseCatalogueStoreProvider.overrideWithValue(
            BrowseCatalogueStore(
              read: () => storedCatalogue,
              write: (v) async => storedCatalogue = v,
            ),
          ),
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
