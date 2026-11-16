import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../search_category.dart';
import '../search_provider.dart';

/// The Search screen's category chips — the design preview's All / Movies /
/// TV Shows / Anime / K-Drama / 4K row under the search box.
///
/// The chips filter the results already on screen (see
/// [matchesSearchCategory]); they do not re-run the search. One chip is
/// always on: All is the unfiltered state, not the absence of a filter.
class SearchCategoryChips extends ConsumerWidget {
  const SearchCategoryChips({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // A scrollable Row, not a ListView: the results below are horizontal
    // ListViews, and the search D-pad tests find "the" horizontal ListView
    // to jump its scroll position. A second one here made that finder match
    // two widgets and broke the "down waits for a first result scrolled
    // away" tests.
    return Semantics(
      label: 'Filter search results by category',
      child: SizedBox(
        height: 44,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              for (var i = 0; i < SearchCategory.values.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                _chip(context, ref, theme, SearchCategory.values[i]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    SearchCategory category,
  ) {
    final selected = ref.watch(searchCategoryProvider);
    final isSelected = category == selected;
    return ChoiceChip(
      label: Text(searchCategoryLabel(category)),
      selected: isSelected,
      onSelected: (_) =>
          ref.read(searchCategoryProvider.notifier).set(category),
      selectedColor: theme.colorScheme.primary,
      backgroundColor: theme.colorScheme.surfaceContainerHighest.withValues(
        alpha: 0.5,
      ),
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        color: isSelected
            ? theme.colorScheme.onPrimary
            : theme.colorScheme.onSurfaceVariant,
      ),
      side: BorderSide(
        color: isSelected
            ? theme.colorScheme.primary
            : theme.colorScheme.outline.withValues(alpha: 0.3),
      ),
      showCheckmark: false,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }
}
