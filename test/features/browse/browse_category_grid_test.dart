import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zorox/features/browse/presentation/browse_category_grid.dart';
import 'package:zorox/features/search/presentation/search_category.dart';
import 'package:zorox/features/search/presentation/search_provider.dart';

/// The Browse grid, without the shell behind it: a tap sets the Search
/// chips' filter and switches to the Search tab.
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

  testWidgets('tapping Anime opens Search on the Anime chip', (tester) async {
    await pumpGrid(tester);

    // The tile's art block carries the emoji + title; the title below it
    // carries the title alone. Tap the art block.
    await tester.tap(find.text('🍥 Anime'));
    await tester.pumpAndSettle();

    expect(container.read(searchCategoryProvider), SearchCategory.anime);
    expect(router.routeInformationProvider.value.uri.toString(), '/search');
    expect(find.text('search page'), findsOneWidget);
  });

  testWidgets('tapping Top Rated opens Search unfiltered', (tester) async {
    await pumpGrid(tester);

    await tester.tap(find.text('🏆 Top Rated'));
    await tester.pumpAndSettle();

    expect(container.read(searchCategoryProvider), SearchCategory.all);
    expect(router.routeInformationProvider.value.uri.toString(), '/search');
  });
}
