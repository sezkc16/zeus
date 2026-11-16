import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/search/presentation/search_category.dart';
import 'package:zorox/features/search/presentation/search_provider.dart';
import 'package:zorox/features/search/presentation/widgets/search_category_chips.dart';

/// The chips, without a search behind them: tapping a chip is a filter
/// choice, and the choice is the provider's state.
void main() {
  testWidgets('tapping a chip selects that category', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SearchCategoryChips()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in ['All', 'Movies', 'TV Shows', 'Anime', 'K-Drama', '4K']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(container.read(searchCategoryProvider), SearchCategory.all);

    await tester.tap(find.text('Anime'));
    await tester.pump();
    expect(container.read(searchCategoryProvider), SearchCategory.anime);

    await tester.tap(find.text('4K'));
    await tester.pump();
    expect(container.read(searchCategoryProvider), SearchCategory.fourK);

    await tester.tap(find.text('All'));
    await tester.pump();
    expect(container.read(searchCategoryProvider), SearchCategory.all);
  });
}
