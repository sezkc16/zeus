import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/addons/data/builtin_addons.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/shimmer_placeholder.dart';
import '../../addons/presentation/addon_providers.dart';
import '../../explore/presentation/view_all_screen.dart';
import '../../explore/presentation/widgets/media_horizontal_list.dart';

/// One Browse row: a catalog of the built-in Cinemeta add-on.
///
/// Every row is a catalog Cinemeta's live manifest really publishes - `top`
/// ("Popular"), `imdbRating` ("Featured"; it is not sorted by rating, so it
/// is never called Top Rated) and `year` ("New", which needs a year as its
/// `genre` extra).
class BrowseRowSpec {
  final String type;
  final String id;

  /// The catalog's `genre` extra: a genre, or the year for `year`.
  final String? genre;
  final String Function(AppLocalizations l10n) title;

  /// Title of the grid "View All" opens. A genre row opens the whole
  /// catalog with its genre chip selected, so the grid carries the
  /// catalog's name - the chip, which can be changed there, says the genre.
  final String Function(AppLocalizations l10n) gridTitle;

  const BrowseRowSpec({
    required this.type,
    required this.id,
    required this.title,
    this.genre,
    String Function(AppLocalizations l10n)? gridTitle,
  }) : gridTitle = gridTitle ?? title;

  String get slug => '$type-$id-${genre ?? 'none'}';

  Key get rowKey => ValueKey('browse-row-$slug');
  Key get retryKey => ValueKey('browse-row-retry-$slug');

  AddonCatalogItemsProvider get provider => addonCatalogItemsProvider(
    BuiltInAddons.cinemetaUrl,
    type,
    id,
    genre: genre,
  );
}

String _popularMovies(AppLocalizations l10n) => l10n.browsePopularMovies;
String _popularSeries(AppLocalizations l10n) => l10n.browsePopularSeries;

/// The Browse rows, top to bottom. [year] is the year the two "New" rows
/// ask for.
List<BrowseRowSpec> browseRowSpecs({required int year}) => [
  const BrowseRowSpec(type: 'movie', id: 'top', title: _popularMovies),
  const BrowseRowSpec(type: 'series', id: 'top', title: _popularSeries),
  BrowseRowSpec(
    type: 'movie',
    id: 'imdbRating',
    title: (l10n) => l10n.browseFeaturedMovies,
  ),
  BrowseRowSpec(
    type: 'series',
    id: 'imdbRating',
    title: (l10n) => l10n.browseFeaturedSeries,
  ),
  BrowseRowSpec(
    type: 'movie',
    id: 'year',
    genre: '$year',
    title: (l10n) => l10n.browseNewMovies,
  ),
  BrowseRowSpec(
    type: 'series',
    id: 'year',
    genre: '$year',
    title: (l10n) => l10n.browseNewSeries,
  ),
  BrowseRowSpec(
    type: 'movie',
    id: 'top',
    genre: 'Action',
    title: (l10n) => l10n.browseActionMovies,
    gridTitle: _popularMovies,
  ),
  BrowseRowSpec(
    type: 'movie',
    id: 'top',
    genre: 'Comedy',
    title: (l10n) => l10n.browseComedyMovies,
    gridTitle: _popularMovies,
  ),
  BrowseRowSpec(
    type: 'series',
    id: 'top',
    genre: 'Drama',
    title: (l10n) => l10n.browseDramaSeries,
    gridTitle: _popularSeries,
  ),
  BrowseRowSpec(
    type: 'movie',
    id: 'top',
    genre: 'Animation',
    title: (l10n) => l10n.browseAnimation,
    gridTitle: _popularMovies,
  ),
];

/// A Browse row: posters once its catalog answers, a skeleton until then, an
/// honest message with Retry when it fails. An empty catalog reports itself
/// through [onEmpty] so the screen can drop the row.
class BrowseCatalogRow extends ConsumerWidget {
  final BrowseRowSpec spec;
  final VoidCallback onEmpty;

  BrowseCatalogRow({required this.spec, required this.onEmpty})
    : super(key: spec.rowKey);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final title = spec.title(l10n);
    final provider = spec.provider;
    final itemsAsync = ref.watch(provider);

    Widget problem(String message) => _BrowseRowProblem(
      title: title,
      message: message,
      retryKey: spec.retryKey,
      onRetry: () => ref.invalidate(provider),
    );

    return itemsAsync.when(
      // A retry or a pull-to-refresh shows the skeleton again over a failed
      // row, and keeps the posters over a loaded one.
      skipLoadingOnRefresh: !(itemsAsync.value?.failed ?? itemsAsync.hasError),
      loading: () => const _BrowseRowSkeleton(),
      error: (error, _) => problem(error.toString()),
      data: (result) {
        if (result.failed) return problem(result.error!);
        final items = result.items;
        if (items.isEmpty) {
          // After the frame: the list rebuilds without this row, and that is
          // not something to do from inside its build.
          WidgetsBinding.instance.addPostFrameCallback((_) => onEmpty());
          return const SizedBox.shrink();
        }

        final previews = {for (final item in items) item.id: item};
        return MediaHorizontalList(
          title: title,
          mediaList: [for (final item in items) item.toMultimediaItem()],
          category: ViewAllCategory.providerContent,
          showViewAll: true,
          heroTagPrefix: 'browse_${spec.slug}',
          onViewAll: () => AddonCatalogRoute(
            addonUrl: BuiltInAddons.cinemetaUrl,
            type: spec.type,
            catalogId: spec.id,
            title: spec.gridTitle(l10n),
            genre: spec.genre,
          ).push<void>(context),
          onTap: (mediaItem) {
            final type =
                previews[mediaItem.url]?.type ??
                (mediaItem.contentType == MultimediaContentType.series
                    ? 'series'
                    : 'movie');
            // Always the built-in Cinemeta URL: the detail page keys how it
            // gathers sources on it.
            AddonDetailRoute(
              type: type,
              id: mediaItem.url,
              addonUrl: BuiltInAddons.cinemetaUrl,
            ).push<void>(context);
          },
        );
      },
    );
  }
}

/// The same skeleton the Stremio catalog rows show while they load.
class _BrowseRowSkeleton extends StatelessWidget {
  const _BrowseRowSkeleton();

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    final cardWidth = isDesktop ? 200.0 : 130.0;
    final listHeight = cardWidth / (2 / 3) + 40.0;
    final side = isDesktop
        ? LayoutConstants.dashboardContentPadding
        : LayoutConstants.spacingMd;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            side,
            LayoutConstants.spacingLg,
            side,
            LayoutConstants.spacingSm,
          ),
          child: ShimmerPlaceholder.rectangular(
            width: 150,
            height: 24,
            borderRadius: 4,
          ),
        ),
        const SizedBox(height: LayoutConstants.spacingMd),
        SizedBox(
          height: listHeight,
          child: ListView.separated(
            padding: EdgeInsets.symmetric(horizontal: side),
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 8,
            separatorBuilder: (_, _) => SizedBox(
              width: isDesktop
                  ? LayoutConstants.spacingLg
                  : LayoutConstants.spacingSm,
            ),
            itemBuilder: (_, _) => SizedBox(
              width: cardWidth,
              child: ShimmerPlaceholder(borderRadius: 12),
            ),
          ),
        ),
      ],
    );
  }
}

class _BrowseRowProblem extends StatelessWidget {
  final String title;
  final String message;
  final Key retryKey;
  final VoidCallback onRetry;

  const _BrowseRowProblem({
    required this.title,
    required this.message,
    required this.retryKey,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.errorContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, size: 18, color: cs.error),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${l10n.browseRowLoadFailed} · $message',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              key: retryKey,
              onPressed: onRetry,
              child: Text(l10n.retry),
            ),
          ],
        ),
      ),
    );
  }
}
