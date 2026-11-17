import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zorox/core/addons/data/builtin_addons.dart';
import 'package:zorox/features/browse/presentation/browse_category_grid.dart';
import 'package:zorox/features/search/presentation/search_category.dart';
import 'package:zorox/features/search/presentation/search_provider.dart';

/// The Browse grid, without the shell behind it: Movies, TV Shows and Top
/// Rated open the built-in Cinemeta addon's catalog (v4); the other tiles
/// set the Search chips' filter and switch to the Search tab.
void main() {
  late ProviderContainer container;
  late GoRouter router;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    router = GoRouter(
      initialLocation: '/browse',
      routes: [
        GoRoute(
          path: '/browse',
          builder: (_, _) => const Scaffold(body: BrowseCategoryGrid()),
        ),
        GoRoute(
          path: '/search',
          builder: (_, _) => const Scaffold(body: Text('search page')),
        ),
        GoRoute(
          path: '/addon-catalog',
          // The stub echoes the pushed route's query params, so the test
          // can prove the tile pushed the right Cinemeta catalog. The
          // pushed page's params are NOT visible through
          // `routeInformationProvider.value.uri`: a push is an imperative
          // match in go_router 18, and the reported URI only reflects
          // non-imperative matches — it stays on the page below.
          builder: (_, state) {
            final q = state.uri.queryParameters;
            return Scaffold(
              body: Text(
                'catalog page ${q['addon-url']} ${q['type']} '
                '${q['catalog-id']} ${q['title']}',
              ),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);
  });

  Future<void> pumpGrid(WidgetTester tester) async {
    // A phone-sized surface: at the default 800x600 the two-column tiles
    // are ~300 px tall each and the third row sits below the fold, unbuilt.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the grid shows all six categories', (tester) async {
    await pumpGrid(tester);

    for (final title in [
      'Movies',
      'TV Shows',
      'Anime',
      'K-Drama',
      '4K & HDR',
      'Top Rated',
    ]) {
      expect(find.text(title), findsWidgets, reason: title);
    }
  });

  testWidgets('tapping Movies opens the Cinemeta movie catalog', (
    tester,
  ) async {
    await pumpGrid(tester);

    await tester.tap(find.text('🎬 Movies'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'catalog page ${BuiltInAddons.cinemetaUrl} movie top Movies',
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping TV Shows opens the Cinemeta series catalog', (
    tester,
  ) async {
    await pumpGrid(tester);

    await tester.tap(find.text('📺 TV Shows'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'catalog page ${BuiltInAddons.cinemetaUrl} series top TV Shows',
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping Top Rated opens the Cinemeta top catalog', (
    tester,
  ) async {
    await pumpGrid(tester);

    await tester.tap(find.text('🏆 Top Rated'));
    await tester.pumpAndSettle();

    // Cinemeta's `top` catalog is the IMDb-ranked one, so Top Rated
    // opens the same list under its own title — it no longer opens
    // Search unfiltered.
    expect(
      find.text(
        'catalog page ${BuiltInAddons.cinemetaUrl} movie top Top Rated',
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping Anime still opens Search on the Anime chip', (
    tester,
  ) async {
    await pumpGrid(tester);

    await tester.tap(find.text('🍥 Anime'));
    await tester.pumpAndSettle();

    expect(container.read(searchCategoryProvider), SearchCategory.anime);
    expect(router.routeInformationProvider.value.uri.toString(), '/search');
    expect(find.text('search page'), findsOneWidget);
  });
}
