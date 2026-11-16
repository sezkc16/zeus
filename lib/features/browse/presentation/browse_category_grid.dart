import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/app_router.dart';
import '../../search/presentation/search_category.dart';
import '../../search/presentation/search_provider.dart';

/// One tile of the Browse category grid.
class _BrowseCategoryTile {
  const _BrowseCategoryTile({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.category,
    required this.tint,
  });

  final String emoji;
  final String title;
  final String subtitle;

  /// The Search chip the tile opens on. Top Rated has no chip of its own —
  /// it opens Search unfiltered ([SearchCategory.all]).
  final SearchCategory category;

  /// The art block's tint.
  final Color tint;
}

/// The design preview's Browse screen: a 6-tile category grid — Movies, TV
/// Shows, Anime, K-Drama, 4K & HDR, Top Rated — two columns, each tile an
/// art block with its emoji and name, a title and a subtitle underneath.
///
/// A tap opens Search on that tile's category: it sets the Search chips'
/// filter ([searchCategoryProvider]) and switches to the Search tab, so the
/// results the viewer then searches for are already filtered. With no query
/// typed yet there is nothing to filter, and the chips show the choice.
class BrowseCategoryGrid extends ConsumerWidget {
  const BrowseCategoryGrid({super.key});

  static const List<_BrowseCategoryTile> _tiles = [
    _BrowseCategoryTile(
      emoji: '🎬',
      title: 'Movies',
      subtitle: 'All providers',
      category: SearchCategory.movies,
      tint: Color(0xFF3D2C12),
    ),
    _BrowseCategoryTile(
      emoji: '📺',
      title: 'TV Shows',
      subtitle: 'All providers',
      category: SearchCategory.tvShows,
      tint: Color(0xFF12283D),
    ),
    _BrowseCategoryTile(
      emoji: '🍥',
      title: 'Anime',
      subtitle: 'Sub & dub',
      category: SearchCategory.anime,
      tint: Color(0xFF3D1230),
    ),
    _BrowseCategoryTile(
      emoji: '🎭',
      title: 'K-Drama',
      subtitle: 'KatDrama & more',
      category: SearchCategory.kDrama,
      tint: Color(0xFF123D2C),
    ),
    _BrowseCategoryTile(
      emoji: '💎',
      title: '4K & HDR',
      subtitle: 'Dolby Vision',
      category: SearchCategory.fourK,
      tint: Color(0xFF2C123D),
    ),
    _BrowseCategoryTile(
      emoji: '🏆',
      title: 'Top Rated',
      subtitle: 'TMDB picks',
      category: SearchCategory.all,
      tint: Color(0xFF3D3412),
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.25,
      ),
      itemCount: _tiles.length,
      itemBuilder: (context, index) {
        final tile = _tiles[index];
        return Semantics(
          button: true,
          label: 'Browse ${tile.title}',
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              ref.read(searchCategoryProvider.notifier).set(tile.category);
              const SearchRoute().go(context);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: tile.tint,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${tile.emoji} ${tile.title}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  tile.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  tile.subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
