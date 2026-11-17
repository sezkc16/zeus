import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/addons/data/builtin_addons.dart';
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
/// Movies, TV Shows and Top Rated open the built-in Cinemeta addon's
/// catalog (v4) — a real poster grid from the Stremio addon that is
/// already in the app for metadata. The other tiles have no matching
/// Cinemeta catalog, so a tap opens Search on that tile's category: it
/// sets the Search chips' filter ([searchCategoryProvider]) and switches
/// to the Search tab, so the results the viewer then searches for are
/// already filtered. With no query typed yet there is nothing to filter,
/// and the chips show the choice.
class BrowseCategoryGrid extends ConsumerWidget {
  const BrowseCategoryGrid({super.key});

  static const List<_BrowseCategoryTile> _tiles = [
    _BrowseCategoryTile(
      emoji: '🎬',
      title: 'Movies',
      subtitle: 'Cinemeta',
      category: SearchCategory.movies,
      tint: Color(0xFF3D2C12),
    ),
    _BrowseCategoryTile(
      emoji: '📺',
      title: 'TV Shows',
      subtitle: 'Cinemeta',
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
      subtitle: 'IMDb top',
      category: SearchCategory.all,
      tint: Color(0xFF3D3412),
    ),
  ];

  /// (type, catalogId, title) for the Cinemeta catalog a tile opens, or
  /// null when the tile has no matching catalog and keeps the Search
  /// shortcut. Cinemeta's `top` catalog is the IMDb-ranked one, so Top
  /// Rated opens the same list under its own title.
  (String, String, String)? _cinemetaCatalog(SearchCategory category) {
    return switch (category) {
      SearchCategory.movies => ('movie', 'top', 'Movies'),
      SearchCategory.tvShows => ('series', 'top', 'TV Shows'),
      SearchCategory.all => ('movie', 'top', 'Top Rated'),
      _ => null,
    };
  }

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
              final catalog = _cinemetaCatalog(tile.category);
              if (catalog != null) {
                AddonCatalogRoute(
                  addonUrl: BuiltInAddons.cinemetaUrl,
                  type: catalog.$1,
                  catalogId: catalog.$2,
                  title: catalog.$3,
                ).push<void>(context);
                return;
              }
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
