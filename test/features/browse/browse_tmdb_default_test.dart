/// Browse opens on TMDB "Movies & Shows" by default (build 84): the
/// default, a kept add-on choice, the switcher's order, and the clean
/// fallback when the build has no TMDB key. No network: the TMDB rows
/// are overridden.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/addons/data/addon_repository.dart';
import 'package:zorox/core/addons/models/addon_manifest.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/theme/app_theme.dart';
import 'package:zorox/features/browse/presentation/browse_catalogue.dart';
import 'package:zorox/features/browse/presentation/browse_screen.dart';
import 'package:zorox/features/browse/presentation/browse_tmdb_view.dart';
import 'package:zorox/features/explore/data/explore_mode_provider.dart';
import 'package:zorox/features/explore/data/explore_tmdb_provider.dart';
import 'package:zorox/features/settings/presentation/general_settings_provider.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

const _kitsuUrl = 'https://kitsu.test/manifest.json';
const _xmasUrl = 'https://xmas.test/manifest.json';

ManagedAddon _addon(String url, String name) => ManagedAddon(
  manifestUrl: url,
  addedAt: DateTime(2026),
  manifest: AddonManifest(
    id: name,
    name: name,
    version: '1',
    resources: const [AddonResource(name: 'catalog')],
    types: const ['movie'],
    catalogs: const [AddonCatalog(type: 'movie', id: 'c', name: 'C')],
  ),
);

class _NoAddons extends AddonRepository {
  @override
  AddonsState build() => const AddonsState(isLoading: false, addons: []);
}

void main() {
  String? stored;

  ProviderContainer boot({
    required bool tmdb,
    List<ManagedAddon> addons = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        browseTmdbAvailableProvider.overrideWithValue(tmdb),
        browseCatalogueAddonsProvider.overrideWithValue(addons),
        browseCatalogueStoreProvider.overrideWithValue(
          BrowseCatalogueStore(
            read: () => stored,
            write: (v) async => stored = v,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() => stored = null);

  group('what Browse shows', () {
    test('a fresh install with a TMDB key opens on Movies & Shows', () {
      final c = boot(tmdb: true);
      expect(c.read(browseSelectionProvider), kBrowseTmdbSelection);
      expect(c.read(browseShowsTmdbProvider), isTrue);
      expect(c.read(exploreModeProvider), ExploreModeType.movies);
    });

    test('add-ons installed but nothing chosen: still Movies & Shows', () {
      final c = boot(
        tmdb: true,
        addons: [_addon(_kitsuUrl, 'Kitsu'), _addon(_xmasUrl, 'Xmas')],
      );
      expect(c.read(browseShowsTmdbProvider), isTrue);
    });

    test('someone who already chose an add-on catalogue keeps it', () {
      stored = _xmasUrl;
      final c = boot(
        tmdb: true,
        addons: [_addon(_kitsuUrl, 'Kitsu'), _addon(_xmasUrl, 'Xmas')],
      );
      expect(c.read(browseSelectionProvider), _xmasUrl);
      expect(c.read(browseShowsTmdbProvider), isFalse);
      expect(c.read(browseCatalogueProvider), _xmasUrl);
      expect(c.read(exploreModeProvider), ExploreModeType.stremio);
    });

    test('a chosen add-on that was removed falls back to Movies & Shows', () {
      stored = _xmasUrl;
      final c = boot(tmdb: true, addons: [_addon(_kitsuUrl, 'Kitsu')]);
      expect(c.read(browseSelectionProvider), kBrowseTmdbSelection);
    });

    test('no TMDB key: add-on catalogues as before, never TMDB', () {
      final c = boot(tmdb: false, addons: [_addon(_kitsuUrl, 'Kitsu')]);
      expect(c.read(browseShowsTmdbProvider), isFalse);
      expect(c.read(browseSelectionProvider), kBrowseAllChoice);
      expect(c.read(browseCatalogueProvider), isNull);
      expect(c.read(exploreModeProvider), ExploreModeType.stremio);
      expect(c.read(browseSelectionOptionsProvider).map((o) => o.value), [
        _kitsuUrl,
      ]);
    });

    test('no TMDB key and a stored add-on: that add-on', () {
      stored = _xmasUrl;
      final c = boot(
        tmdb: false,
        addons: [_addon(_kitsuUrl, 'Kitsu'), _addon(_xmasUrl, 'Xmas')],
      );
      expect(c.read(browseSelectionProvider), _xmasUrl);
    });
  });

  group('the switcher', () {
    test('order: Movies & Shows, All catalogues, then each add-on', () {
      final c = boot(
        tmdb: true,
        addons: [_addon(_kitsuUrl, 'Kitsu'), _addon(_xmasUrl, 'Xmas')],
      );
      final options = c.read(browseSelectionOptionsProvider);
      expect(options.map((o) => o.value), [
        kBrowseTmdbSelection,
        kBrowseAllChoice,
        _kitsuUrl,
        _xmasUrl,
      ]);
      expect(options.first.label, 'Movies & Shows');
    });

    test('one add-on: Movies & Shows then that add-on, no All entry', () {
      final c = boot(tmdb: true, addons: [_addon(_kitsuUrl, 'Kitsu')]);
      expect(c.read(browseSelectionOptionsProvider).map((o) => o.value), [
        kBrowseTmdbSelection,
        _kitsuUrl,
      ]);
    });

    test('nothing installed: one entry, so no line is shown', () {
      final c = boot(tmdb: true);
      expect(c.read(browseSelectionOptionsProvider), hasLength(1));
    });

    test('choices are kept: add-on, All catalogues, back to TMDB', () async {
      final c = boot(
        tmdb: true,
        addons: [_addon(_kitsuUrl, 'Kitsu'), _addon(_xmasUrl, 'Xmas')],
      );
      final choice = c.read(browseCatalogueChoiceProvider.notifier);

      await choice.choose(_kitsuUrl);
      expect(stored, _kitsuUrl);
      expect(c.read(browseSelectionProvider), _kitsuUrl);

      await choice.choose(kBrowseAllChoice);
      expect(stored, kBrowseAllChoice);
      expect(c.read(browseSelectionProvider), kBrowseAllChoice);
      expect(c.read(browseShowsTmdbProvider), isFalse);

      await choice.choose(kBrowseTmdbSelection);
      expect(stored, isNull);
      expect(c.read(browseShowsTmdbProvider), isTrue);
    });
  });

  group('the Browse page', () {
    Future<void> pump(
      WidgetTester tester, {
      required bool tmdb,
      List<MultimediaItem> popular = const [],
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      Future<List<MultimediaItem>> none(Ref ref) async => const [];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            addonRepositoryProvider.overrideWith(_NoAddons.new),
            generalSettingsProvider.overrideWithValue(const GeneralSettings()),
            browseTmdbAvailableProvider.overrideWithValue(tmdb),
            browseCatalogueStoreProvider.overrideWithValue(
              BrowseCatalogueStore(
                read: () => stored,
                write: (v) async => stored = v,
              ),
            ),
            exploreHeroMovieProvider.overrideWith(none),
            trendingTVProvider.overrideWith(none),
            popularMoviesProvider.overrideWith((ref) async => popular),
            popularTVProvider.overrideWith(none),
            nowPlayingMoviesProvider.overrideWith(none),
            onTheAirTVProvider.overrideWith(none),
            topRatedMoviesProvider.overrideWith(none),
            topRatedTVProvider.overrideWith(none),
            airingTodayTVProvider.overrideWith(none),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: AppTheme.createDarkTheme(null),
            home: const BrowseScreen(),
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('with a key and nothing installed it shows TMDB rows', (
      tester,
    ) async {
      await pump(
        tester,
        tmdb: true,
        popular: [
          MultimediaItem(title: 'A Film', url: '1', posterUrl: ''),
        ],
      );
      expect(find.byType(BrowseTmdbView), findsOneWidget);
      expect(find.byKey(const ValueKey('browse-tmdb-content')), findsOneWidget);
      expect(find.text('Popular Movies'), findsOneWidget);
      expect(find.byKey(const ValueKey('browse-empty-hint')), findsNothing);
      expect(find.byKey(const ValueKey('browse-filter-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('browse-search-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('browse-addons-button')), findsOneWidget);
      // One source only, so no "from ..." line.
      expect(find.byKey(BrowseCatalogueBar.tapKey), findsNothing);
    });

    testWidgets('without a key it is the blank page with the add-ons button', (
      tester,
    ) async {
      await pump(tester, tmdb: false);
      expect(find.byType(BrowseTmdbView), findsNothing);
      expect(find.byKey(const ValueKey('browse-empty-hint')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('browse-empty-addons-button')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('browse-filter-button')), findsNothing);
    });

    testWidgets('when TMDB answers nothing it says so, without error text', (
      tester,
    ) async {
      await pump(tester, tmdb: true);
      expect(
        find.byKey(const ValueKey('browse-tmdb-unavailable')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('browse-tmdb-retry')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('browse-tmdb-addons-button')),
        findsOneWidget,
      );
      expect(find.textContaining('api_key'), findsNothing);
    });
  });
}
