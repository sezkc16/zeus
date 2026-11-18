import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/shimmer_placeholder.dart';
import '../../explore/data/explore_tmdb_provider.dart';
import '../../explore/presentation/view_all_screen.dart';
import '../../explore/presentation/widgets/explore_carousel.dart';
import '../../explore/presentation/widgets/media_horizontal_list.dart';

/// Browse's TMDB "Movies & Shows" content: the trending banner and the
/// eight rows upstream's Explore showed (popular, trending, new, top
/// rated, airing), taken from that screen and placed in Zeus's Browse.
///
/// When every request fails - no connection, a refused key - the page
/// says so in one line with Retry and the way to Stremio add-ons. The
/// error text itself is never shown: a TMDB request address carries the
/// key.
class BrowseTmdbView extends ConsumerStatefulWidget {
  const BrowseTmdbView({
    super.key,
    required this.scrollController,
    required this.firstActionFocusNode,
    required this.onOpenAddons,
  });

  final ScrollController scrollController;
  final FocusNode firstActionFocusNode;
  final VoidCallback onOpenAddons;

  @override
  ConsumerState<BrowseTmdbView> createState() => _BrowseTmdbViewState();
}

class _BrowseTmdbViewState extends ConsumerState<BrowseTmdbView> {
  ScrollController get _scrollController => widget.scrollController;

  void _refreshAll() {
    ref.invalidate(exploreHeroMovieProvider);
    ref.invalidate(trendingTVProvider);
    ref.invalidate(popularMoviesProvider);
    ref.invalidate(popularTVProvider);
    ref.invalidate(nowPlayingMoviesProvider);
    ref.invalidate(onTheAirTVProvider);
    ref.invalidate(topRatedMoviesProvider);
    ref.invalidate(topRatedTVProvider);
    ref.invalidate(airingTodayTVProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final heroMoviesAsync = ref.watch(exploreHeroMovieProvider);
    final allSections = [
      heroMoviesAsync,
      ref.watch(trendingTVProvider),
      ref.watch(popularMoviesProvider),
      ref.watch(popularTVProvider),
      ref.watch(nowPlayingMoviesProvider),
      ref.watch(onTheAirTVProvider),
      ref.watch(topRatedMoviesProvider),
      ref.watch(topRatedTVProvider),
      ref.watch(airingTodayTVProvider),
    ];

    final isAnyLoading = allSections.any((s) => s.isLoading);
    final isAllFailedOrEmpty =
        !isAnyLoading &&
        allSections.every((s) {
          if (s.hasError) return true;
          if (s.hasValue && (s.value?.isEmpty ?? true)) return true;
          return false;
        });

    if (isAllFailedOrEmpty) return _buildUnavailable(context);

    final noHero = heroMoviesAsync.maybeWhen(
      data: (list) => list.isEmpty,
      error: (_, _) => true,
      orElse: () => false,
    );
    final topPadding = noHero
        ? (MediaQuery.paddingOf(context).top + kToolbarHeight)
        : 0.0;

    return RefreshIndicator(
      onRefresh: () async => _refreshAll(),
      child: CustomScrollView(
        key: const ValueKey('browse-tmdb-content'),
        controller: _scrollController,
        slivers: [
          if (topPadding > 0)
            SliverToBoxAdapter(child: SizedBox(height: topPadding)),
          SliverToBoxAdapter(
            child: switch (heroMoviesAsync) {
              AsyncData(:final value) =>
                value.isEmpty
                    ? const SizedBox.shrink()
                    : ExploreCarousel(
                        movies: value,
                        scrollController: _scrollController,
                        fullBleed: true,
                        // The same hero Home shows (design A, build 86):
                        // title logo, meta line, badge row, one View
                        // Details pill, dots inside the poster. The rows,
                        // switcher and TMDB default are untouched.
                        showHomeHero: true,
                        onNavigateUp: () =>
                            widget.firstActionFocusNode.requestFocus(),
                      ),
              AsyncLoading() => _buildCarouselShimmer(context),
              AsyncError() => const SizedBox.shrink(),
            },
          ),
      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(popularMoviesProvider),
          l10n.popularMovies,
          ViewAllCategory.popularMovies,
        ),
      ),

      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(trendingTVProvider),
          'Trending TV Shows',
          ViewAllCategory.trendingTV,
        ),
      ),

      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(popularTVProvider),
          l10n.popularTVShows,
          ViewAllCategory.popularTV,
        ),
      ),

      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(nowPlayingMoviesProvider),
          l10n.newMovies,
          ViewAllCategory.nowPlayingMovies,
        ),
      ),

      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(onTheAirTVProvider),
          l10n.newTVShows,
          ViewAllCategory.onTheAirTV,
        ),
      ),

      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(topRatedMoviesProvider),
          l10n.featuredMovies,
          ViewAllCategory.topRatedMovies,
        ),
      ),

      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(topRatedTVProvider),
          l10n.featuredTVShows,
          ViewAllCategory.topRatedTV,
        ),
      ),

      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(airingTodayTVProvider),
          l10n.lastVideosTVShows,
          ViewAllCategory.airingTodayTV,
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.only(
          bottom: LayoutConstants.shellBottomContentPadding(context),
        ),
      ),
        ],
      ),
    );
  }

  Widget _buildUnavailable(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.only(
          left: 28,
          right: 28,
          bottom: LayoutConstants.shellBottomContentPadding(context),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Could not load Movies & Shows. Check your connection and '
              'try again.',
              key: const ValueKey('browse-tmdb-unavailable'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: LayoutConstants.spacingMd),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  key: const ValueKey('browse-tmdb-retry'),
                  onPressed: _refreshAll,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(l10n.retry),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('browse-tmdb-addons-button'),
                  onPressed: widget.onOpenAddons,
                  icon: const Icon(Icons.dashboard_customize_rounded),
                  label: Text(l10n.browseOpenAddons),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(
    BuildContext context,
    AsyncValue<List<MultimediaItem>> asyncValue,
    String title,
    ViewAllCategory category,
  ) {
    return switch (asyncValue) {
      AsyncData(:final value) =>
        value.isEmpty
            ? const SizedBox.shrink()
            : MediaHorizontalList(
                title: title,
                mediaList: value,
                category: category,
                heroTagPrefix: 'explore',
              ),
      AsyncLoading() => _buildListShimmer(context),
      AsyncError() => const SizedBox.shrink(),
    };
  }

  Widget _buildCarouselShimmer(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final heroHeight = size.height * 0.60;
    final isDesktop =
        size.width > LayoutConstants.exploreCarouselDesktopBreakpoint;

    if (isDesktop) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LayoutConstants.dashboardContentPadding,
          vertical: LayoutConstants.spacingSm,
        ),
        child: SizedBox(
          height: heroHeight,
          width: double.infinity,
          child: ShimmerPlaceholder(borderRadius: 18),
        ),
      );
    } else {
      return SizedBox(
        height: heroHeight,
        width: double.infinity,
        child: ShimmerPlaceholder.rectangular(
          width: double.infinity,
          height: heroHeight,
          borderRadius: 0,
        ),
      );
    }
  }

  Widget _buildListShimmer(BuildContext context) {
    final isDesktop = context.isDesktop;
    final cardWidth = isDesktop ? 200.0 : 130.0;
    final imageHeight = cardWidth / (2 / 3);
    final listHeight = imageHeight + 40.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title Placeholder
        Padding(
          padding: EdgeInsets.fromLTRB(
            isDesktop
                ? LayoutConstants.dashboardContentPadding
                : LayoutConstants.spacingMd,
            LayoutConstants.spacingLg,
            isDesktop
                ? LayoutConstants.dashboardContentPadding
                : LayoutConstants.spacingMd,
            LayoutConstants.spacingSm,
          ),
          child: ShimmerPlaceholder.rectangular(
            width: 150,
            height: 24,
            borderRadius: 4,
          ),
        ),
        const SizedBox(height: LayoutConstants.spacingMd),
        // List Placeholder
        SizedBox(
          height: listHeight,
          child: ListView.separated(
            padding: EdgeInsets.symmetric(
              horizontal: isDesktop
                  ? LayoutConstants.dashboardContentPadding
                  : LayoutConstants.spacingMd,
            ),
            scrollDirection: Axis.horizontal,
            itemCount: 10,
            separatorBuilder: (_, _) => SizedBox(
              width: isDesktop
                  ? LayoutConstants.spacingLg
                  : LayoutConstants.spacingSm,
            ),
            itemBuilder: (context, index) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ShimmerPlaceholder.rectangular(
                    width: cardWidth,
                    height: imageHeight,
                    borderRadius: 12,
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
