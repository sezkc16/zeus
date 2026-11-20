import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/tmdb_details.dart';

import 'package:intl/intl.dart';

import '../../../../core/storage/history_repository.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../data/tmdb_details_provider.dart';

import 'package:zorox/l10n/generated/app_localizations.dart';

import '../../../../core/utils/layout_constants.dart';
import 'widgets/tmdb_details_desktop_hero.dart';
import 'widgets/provider_search_section.dart';
import 'widgets/nuvio_sources_card.dart';
import 'widgets/tmdb_details_stats_section.dart';
import 'widgets/hero_details_widgets.dart';
import 'widgets/movie_cast_list.dart';
import 'widgets/movie_more_like_this.dart';
import '../data/lightweight_details_provider.dart';
import 'widgets/movie_trailers_carousel.dart';
import 'widgets/movie_production_companies.dart';
import 'widgets/movie_seasons_list.dart';
import 'widgets/episode_picker_sheet.dart';
import '../../sources/presentation/plugin_sources_sheet.dart';
import '../../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../../../../shared/widgets/shimmer_placeholder.dart';

class TmdbMovieDetailsScreen extends ConsumerStatefulWidget {
  final int movieId;
  final String mediaType; // 'movie' or 'tv'
  final String? heroTag;
  final String? placeholderPoster;
  final String? source;

  const TmdbMovieDetailsScreen({
    super.key,
    required this.movieId,
    this.mediaType = 'movie',
    this.heroTag,
    this.placeholderPoster,
    this.source,
  });

  @override
  ConsumerState<TmdbMovieDetailsScreen> createState() =>
      _TmdbMovieDetailsScreenState();
}

class _TmdbMovieDetailsScreenState
    extends ConsumerState<TmdbMovieDetailsScreen> {
  AppLocalizations get l10n => AppLocalizations.of(context)!;
  late ScrollController _scrollController;
  final ValueNotifier<bool> _showAppBarTitle = ValueNotifier<bool>(false);
  final ValueNotifier<double> _titleOpacity = ValueNotifier<double>(0.0);
  final ValueNotifier<double> _contentOpacity = ValueNotifier<double>(1.0);
  final ValueNotifier<double> _scrollOffset = ValueNotifier<double>(0.0);

  late final ScrollController _castScrollController;
  late final ScrollController _trailerScrollController;

  late final ScrollController _episodeScrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _castScrollController = ScrollController();
    _trailerScrollController = ScrollController();

    _episodeScrollController = ScrollController();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _castScrollController.dispose();
    _trailerScrollController.dispose();

    _episodeScrollController.dispose();
    _showAppBarTitle.dispose();
    _titleOpacity.dispose();
    _contentOpacity.dispose();
    _scrollOffset.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final offset = _scrollController.offset;

    final show = offset > 450;
    if (show != _showAppBarTitle.value) {
      _showAppBarTitle.value = show;
    }

    final newTitleOpacity = ((offset - 300) / 100).clamp(0.0, 1.0);
    if (newTitleOpacity != _titleOpacity.value) {
      _titleOpacity.value = newTitleOpacity;
    }

    final newContentOpacity = (1.0 - (offset / 300)).clamp(0.0, 1.0);
    if (newContentOpacity != _contentOpacity.value) {
      _contentOpacity.value = newContentOpacity;
    }

    _scrollOffset.value = offset;
  }

  /// Movies open the sources sheet straight away; a series asks which episode
  /// first. The button used to be rendered only `if (isMovie)`, so every
  /// series poster looked like it had no plugin playback at all.
  void _openPluginSources(TmdbDetails data, bool isMovie) {
    if (isMovie) {
      PluginSourcesSheet.open(context, data);
      return;
    }
    final seasons = data.seasons;
    EpisodePickerSheet.open(
      context,
      movieId: widget.movieId,
      seasons: seasons,
      target: data,
      source: widget.source,
    );
  }

  @override
  Widget build(BuildContext context) {
    final params = MovieDetailsParams(
      widget.movieId,
      widget.mediaType,
      source: widget.source,
    );
    final detailsAsync = ref.watch(tmdbDetailsProvider(params));
    final fastDetailsAsync = ref.watch(lightweightDetailsProvider(params));

    // Prioritize full data, but use fast data if full is still loading
    final data = detailsAsync.asData?.value ?? fastDetailsAsync.asData?.value;
    final isHeavyLoading = detailsAsync.isLoading;
    final hasAnyData = data != null;

    final content = hasAnyData
        ? (context.isDesktop
              ? _buildDesktopLayout(data, isHeavyLoading)
              : _buildMobileLayout(data, isHeavyLoading))
        : detailsAsync.when(
            skipLoadingOnReload: false,
            skipLoadingOnRefresh: false,
            data: (data) => const SizedBox.shrink(), // Handled by hasAnyData
            loading: () {
              final isMovie = widget.mediaType == 'movie';
              return Scaffold(
                backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                appBar: AppBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  leading: const BackButton(),
                ),
                body: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ShimmerPlaceholder.rectangular(
                        height: 200,
                        width: double.infinity,
                        borderRadius: 12,
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          _buildTmdbLogo(),
                          const SizedBox(width: 12),
                          _buildTopBadge(
                            context,
                            isMovie
                                ? l10n.movie.toUpperCase()
                                : l10n.tvShow.toUpperCase(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      ShimmerPlaceholder.rectangular(
                        height: 30,
                        width: 250,
                        borderRadius: 6,
                      ),
                      const SizedBox(height: 16),
                      ShimmerPlaceholder.rectangular(
                        height: 100,
                        width: double.infinity,
                        borderRadius: 12,
                      ),
                    ],
                  ),
                ),
              );
            },
            error: (e, st) => Scaffold(
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                leading: const BackButton(),
              ),
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      l10n.failedToLoadContent,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () =>
                          ref.invalidate(tmdbDetailsProvider(params)),
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.retry),
                    ),
                  ],
                ),
              ),
            ),
          );

    final scaffold = Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: content,
    );

    return scaffold;
  }

  Widget _buildDesktopLayout(TmdbDetails data, bool isHeavyLoading) {
    final isMovie = widget.mediaType == 'movie';
    final seasons = data.seasons;
    final cast = data.tmdbCast;
    final trailers = data.tmdbTrailers;
    final productionCompanies = data.productionCompanies;

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final scaffoldColor = theme.scaffoldBackgroundColor;
    final textColor = theme.colorScheme.onSurface;
    final textSecondary = theme.colorScheme.onSurface.withValues(alpha: 0.7);

    return Scaffold(
      backgroundColor: scaffoldColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
          style: IconButton.styleFrom(
            backgroundColor: isDark ? Colors.black45 : Colors.white54,
            foregroundColor: textColor,
          ),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: TmdbDetailsDesktopHero(
        data: data,
        isMovie: isMovie,
        source: widget.source,
        nuvioCard: NuvioSourcesCard(
          isMovie: isMovie,
          compact: true,
          onOpen: () => _openPluginSources(data, isMovie),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The hero used to end on the overview, and 60 was the room that
            // needed. It ends on the Nuvio card's action now, so this is the
            // same gap that separates every other group on the page.
            const SizedBox(height: kDetailsGroupGap),
            // Cast, then Trailers & Extras, then Seasons (TV), then
            // More Like This, then Production (build 110, user
            // 2026-11-21 01:51: SkyStream's order).
            if (isHeavyLoading || cast.isNotEmpty) ...[
              MovieCastList(
                cast: cast,
                isLoading: isHeavyLoading,
                textColor: textColor,
                textSecondary: textSecondary,
              ),
            ],
            if (isHeavyLoading || trailers.isNotEmpty) ...[
              MovieTrailersCarousel(
                trailers: trailers,
                isLoading: isHeavyLoading,
                textColor: textColor,
              ),
            ],
            if (!isMovie) ...[
              MovieSeasonsList(
                movieId: widget.movieId,
                seasons: seasons,
                textColor: textColor,
                source: widget.source,
                title: data.title,
                posterUrl: data.posterUrl,
                bannerUrl: data.bannerUrl,
                overview: data.overview,
                releaseDateFull: data.releaseDateFull,
                imdbId: data.imdbId,
              ),
            ],
            MovieMoreLikeThis(
              movieId: widget.movieId,
              mediaType: widget.mediaType,
              source: widget.source,
            ),
            if (isHeavyLoading || productionCompanies.isNotEmpty) ...[
              MovieProductionCompanies(
                productionCompanies: productionCompanies,
                isLoading: isHeavyLoading,
                textColor: textColor,
                textSecondary: textSecondary,
              ),
            ],
            TmdbDetailsStatsSection(data: data, isMovie: isMovie),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }

  /// The phone page, in the "Hero" layout: a full-bleed banner with the
  /// catalogue's tag and the title on it, an info strip, the two source
  /// cards, a short synopsis, then everything else as before.
  ///
  /// No round Play button here: this page never had a Play. Its titles are
  /// played from the source cards, which are peers by design.
  Widget _buildMobileLayout(TmdbDetails data, bool isHeavyLoading) {
    final isMovie = widget.mediaType == 'movie';
    final theme = Theme.of(context);

    final backdropImageUrl = data.backdropImageUrl;
    final title = data.title;
    final overview = data.overview.trim();

    final tagline = data.tagline;
    final runtime = data.runtime;
    final releaseDate = data.releaseDateFull;
    final status = data.tmdbStatus;
    final budget = data.budget;
    final genres = data.genres;
    final cast = data.tmdbCast;
    final productionCompanies = data.productionCompanies;
    final trailers = data.tmdbTrailers;

    final hours = runtime ~/ 60;
    final minutes = runtime % 60;
    final durationText = hours > 0 ? '${hours}H ${minutes}M' : '${minutes}M';
    final year = releaseDate.isNotEmpty ? releaseDate.split('-')[0] : '';
    final rating = data.voteAverage.toStringAsFixed(1);

    final certification = data.certification;
    final director = data.director;

    final mq = MediaQuery.sizeOf(context);
    final bannerHeight = detailsHeroBannerHeight(mq);

    // What the title really has, in the order the strip shows it. The strip
    // takes the first four; the rest stays in the meta row under it.
    final facts = <({IconData icon, Color? color, DetailsInfoColumn column})>[
      if (year.isNotEmpty)
        (
          icon: Icons.calendar_today_rounded,
          color: null,
          column: DetailsInfoColumn(value: year, label: 'Year'),
        ),
      if (!isMovie && data.seasons.isNotEmpty)
        (
          icon: Icons.layers_rounded,
          color: null,
          column: DetailsInfoColumn(
            value: '${data.seasons.length}',
            label: l10n.seasons,
          ),
        ),
      if (runtime > 0)
        (
          icon: Icons.timer_outlined,
          color: null,
          column: DetailsInfoColumn(value: durationText, label: 'Runtime'),
        ),
      if (data.voteAverage > 0)
        (
          icon: Icons.star_rounded,
          color: theme.colorScheme.primary,
          column: DetailsInfoColumn(value: rating, label: 'Rating'),
        ),
      if (status.isNotEmpty)
        (
          icon: Icons.info_outline_rounded,
          color: null,
          column: DetailsInfoColumn(value: status, label: l10n.status),
        ),
    ];
    final inStrip = facts.take(DetailsInfoStrip.maxColumns).toList();
    final leftOver = facts.skip(DetailsInfoStrip.maxColumns).toList();

    return Stack(
      children: [
        CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverToBoxAdapter(
              child: DetailsHeroBanner(
                height: bannerHeight,
                title: title,
                subtitle: genres.isNotEmpty
                    ? genres.take(3).join(' • ')
                    : (isMovie ? 'Movie' : 'TV Show'),
                sourceTag: DetailsSourceTag(
                  label: widget.source == 'anilist' ? 'AniList' : 'TMDB',
                ),
                image: backdropImageUrl.isEmpty
                    ? ThumbnailErrorPlaceholder(label: title, isBackdrop: true)
                    : CachedNetworkImage(
                        imageUrl: backdropImageUrl,
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        // Bound the decoded bitmap to what cover paints:
                        // `original`-size backdrops decoded at source would
                        // cost ~33 MB each and starve the image cache.
                        memCacheWidth:
                            (math.max(mq.width, bannerHeight * 16 / 9) *
                                    MediaQuery.devicePixelRatioOf(context))
                                .round(),
                        placeholder: (context, url) => Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                        ),
                        errorWidget: (_, _, _) => ThumbnailErrorPlaceholder(
                          label: title,
                          isBackdrop: true,
                        ),
                      ),
              ),
            ),

            // Info strip, sources, metadata, synopsis, cast, production,
            // trailers, seasons, details
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (inStrip.isNotEmpty) ...[
                      DetailsInfoStrip(
                        columns: [for (final f in inStrip) f.column],
                      ),
                      const SizedBox(height: LayoutConstants.spacingMd),
                    ],
                    // The two source systems, as peers and in the same order
                    // the desktop hero uses: ZoroX providers, then Nuvio. One
                    // spacing unit above, between and below, so neither card
                    // reads as the page's primary action.
                    ProviderSearchSection(
                      query: title,
                      parentMediaType: isMovie ? 'movie' : 'tv',
                      tmdbId: data.tmdbId,
                      imdbId: data.imdbId,
                    ),
                    const SizedBox(height: LayoutConstants.spacingMd),
                    NuvioSourcesCard(
                      isMovie: isMovie,
                      onOpen: () => _openPluginSources(data, isMovie),
                    ),
                    // No spacer here: the card already carries a 16 dp foot
                    // inside its own padding, and the block below brings its
                    // own 8.
                    Consumer(
                      builder: (context, ref, _) {
                        final historyRepo = ref.watch(
                          historyRepositoryProvider,
                        );
                        final pos = historyRepo.getPosition(data.id.toString());
                        final dur = historyRepo.getDuration(data.id.toString());

                        if (pos > 0 && dur > 0) {
                          final progress = (pos / dur).clamp(0.0, 1.0);
                          final theme = Theme.of(context);
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 24.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: double.infinity,
                                  height: 6,
                                  clipBehavior: Clip.antiAlias,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: LinearProgressIndicator(
                                    value: progress,
                                    backgroundColor: Colors.transparent,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  l10n.percentWatched((progress * 100).toInt()),
                                  style: TextStyle(
                                    color: theme.colorScheme.primary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                    const SizedBox(height: 8),

                    // Meta row: MOVIE/TV, the age rating, and whatever the
                    // strip had no room for.
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _buildTopBadge(
                          context,
                          widget.source == 'anilist'
                              ? (isMovie ? "MOVIE" : "ANIME")
                              : (isMovie
                                    ? l10n.movie.toUpperCase()
                                    : l10n.tvShow.toUpperCase()),
                        ),
                        if (certification.isNotEmpty)
                          _buildBorderedInfo(context, certification),
                        for (final f in leftOver)
                          _buildIconInfo(
                            context,
                            f.icon,
                            f.column.value,
                            iconColor: f.color,
                          ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // Director / Creator
                    RichText(
                      text: TextSpan(
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontSize: 15,
                        ),
                        children: [
                          TextSpan(
                            text: isMovie
                                ? "${l10n.director}: "
                                : "${l10n.creator}: ",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.7,
                              ),
                            ),
                          ),
                          TextSpan(text: director),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    if (overview.isNotEmpty) ExpandableSynopsis(text: overview),

                    const SizedBox(height: 28),

                    // Cast, then Trailers & Extras, then Seasons (TV),
                    // then More Like This, then Production (build 110,
                    // user 2026-11-21 01:51: SkyStream's order).
                    if (isHeavyLoading || cast.isNotEmpty) ...[
                      MovieCastList(cast: cast, isLoading: isHeavyLoading),
                    ],

                    // Trailers Section
                    if (isHeavyLoading || trailers.isNotEmpty) ...[
                      MovieTrailersCarousel(
                        trailers: trailers,
                        isLoading: isHeavyLoading,
                      ),
                    ],

                    if (!isMovie &&
                        (isHeavyLoading || data.seasons.isNotEmpty)) ...[
                      MovieSeasonsList(
                        movieId: widget.movieId,
                        seasons: data.seasons,
                        source: widget.source,
                        title: data.title,
                        posterUrl: data.posterUrl,
                        bannerUrl: data.bannerUrl,
                        overview: data.overview,
                        releaseDateFull: data.releaseDateFull,
                        imdbId: data.imdbId,
                      ),
                    ],

                    // More Like This — TMDB recommendations; the widget
                    // hides itself when there are none.
                    MovieMoreLikeThis(
                      movieId: widget.movieId,
                      mediaType: widget.mediaType,
                      source: widget.source,
                    ),

                    // Production Section
                    if (isHeavyLoading || productionCompanies.isNotEmpty) ...[
                      MovieProductionCompanies(
                        productionCompanies: productionCompanies,
                        isLoading: isHeavyLoading,
                      ),
                    ],

                    // Movie Details Table
                    Text(
                      isMovie
                          ? l10n.movieDetails.toUpperCase()
                          : l10n.showDetails.toUpperCase(),
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (tagline.isNotEmpty)
                      _buildDetailRow(l10n.tagline, "\"$tagline\""),
                    _buildDetailRow(l10n.status, status),
                    _buildDetailRow(
                      isMovie ? l10n.releaseDate : l10n.firstAirDate,
                      () {
                        final parsed = DateTime.tryParse(releaseDate);
                        if (parsed != null) {
                          return DateFormat('MMMM d, yyyy').format(parsed);
                        }
                        return releaseDate.isNotEmpty
                            ? releaseDate
                            : l10n.unknown;
                      }(),
                    ),
                    if (budget > 0)
                      _buildDetailRow(
                        l10n.budgetLabel,
                        NumberFormat.currency(
                          symbol: '\$',
                          decimalDigits: 0,
                        ).format(budget),
                      ),
                    _buildDetailRow(l10n.originCountry, data.originCountry),
                    _buildDetailRow(
                      l10n.originalLanguage,
                      data.originalLanguage,
                    ),

                    // Safe Area padding
                    const SizedBox(height: 72),
                  ],
                ),
              ),
            ),
          ],
        ),
        DetailsHeroTopBar(
          scrollOffset: _scrollOffset,
          leading: DetailsHeroTopBar.button(
            key: const ValueKey('details-back'),
            icon: Icons.arrow_back,
            onPressed: () => context.pop(),
          ),
        ),
      ],
    );
  }

  Widget _buildTmdbLogo() {
    final isAnilist = widget.source == 'anilist';
    if (isAnilist) {
      return Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: const Color(0xFF02A9FF).withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        padding: const EdgeInsets.all(6),
        child: SvgPicture.asset(
          'assets/images/anilist_icon.svg',
          fit: BoxFit.contain,
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF01B4E4), // TMDB Blue
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        "TMDB",
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 10,
        ),
      ),
    );
  }

  Widget _buildTopBadge(BuildContext context, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildIconInfo(
    BuildContext context,
    IconData icon,
    String text, {
    Color? iconColor,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 14,
          color:
              iconColor ??
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: 0.8),
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildBorderedInfo(BuildContext context, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.5),
        border: Border.all(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.6),
              fontSize: 14,
            ),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
