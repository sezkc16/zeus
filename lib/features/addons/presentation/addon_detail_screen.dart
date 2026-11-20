import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart';
import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/addons/data/addon_client.dart';
import '../../../core/addons/data/builtin_addons.dart';
import '../../../core/addons/data/addon_repository.dart';
import '../../../core/addons/data/addon_stream_service.dart';
import '../../../core/network/clearance/clearance.dart';
import '../../../core/addons/models/addon_manifest.dart';
import '../../../core/addons/models/addon_meta.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/shimmer_placeholder.dart';
import '../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../../../core/models/tmdb_details.dart';
import '../../../core/storage/episode_watch_repository.dart';
import '../../../core/storage/history_repository.dart';
import '../../details/data/addon_tmdb_id_provider.dart';
import '../../details/data/tmdb_details_provider.dart';
import '../../details/presentation/widgets/hero_details_widgets.dart';
import '../../details/presentation/widgets/movie_cast_list.dart';
import '../../details/presentation/widgets/movie_more_like_this.dart';
import '../../details/presentation/widgets/movie_production_companies.dart';
import '../../details/presentation/widgets/movie_trailers_carousel.dart';
import '../../library/presentation/history_provider.dart';
import 'addon_direct_play.dart';
import 'addon_own_links.dart';
import 'addon_providers.dart';
import '../../../core/storage/settings_repository.dart';
import '../../sources/domain/last_used_source.dart';
import 'addon_resume_intent.dart';
import 'addon_sources_sheet.dart';
import 'widgets/addon_episode_card.dart';
import 'widgets/addon_play_button.dart';
import 'widgets/stremio_sources_card.dart';
import '../../../shared/focus/app_focus.dart';
import '../../../shared/widgets/check_line.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Detail page for an add-on catalog entry, styled to match the TMDB Details Screen.
/// Metadata comes from a `meta` add-on, playback from `stream` add-ons.
class AddonDetailScreen extends ConsumerStatefulWidget {
  final String type;
  final String id;
  final String? addonUrl;

  /// Set for a title opened from the Browse tab, whichever add-on listed
  /// it: see [_AddonDetailScreenState._mergedSources].
  final bool mergedSources;

  const AddonDetailScreen({
    super.key,
    required this.type,
    required this.id,
    this.addonUrl,
    this.mergedSources = false,
  });

  @override
  ConsumerState<AddonDetailScreen> createState() => _AddonDetailScreenState();
}

class _AddonDetailScreenState extends ConsumerState<AddonDetailScreen> {
  /// A title opened from Browse - a row of an installed catalog add-on, or
  /// a Cinemeta title - belongs to no plugin, so its sources come from
  /// everything installed: plugins, Nuvio providers and Stremio add-ons
  /// together. An add-on's title opened anywhere else keeps the add-on list
  /// it always had.
  bool get _mergedSources =>
      widget.mergedSources || widget.addonUrl == BuiltInAddons.cinemetaUrl;

  int? _selectedSeason;
  int _selectedRangeIndex = 0;
  bool _isAscending = true;

  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _showAppBarTitle = ValueNotifier<bool>(false);
  final ValueNotifier<double> _titleOpacity = ValueNotifier<double>(0.0);
  final ValueNotifier<double> _contentOpacity = ValueNotifier<double>(1.0);
  final ValueNotifier<double> _scrollOffset = ValueNotifier<double>(0.0);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    final clearance = Clearance.instance;
    _openedAt = clearance.isReady ? clearance.checks.now : DateTime.now();
  }

  /// When the page opened, on the checks' clock: the checks its add-ons meet
  /// from then on stand under its details.
  late final DateTime _openedAt;

  /// What the add-ons' bot checks are filed under.
  Set<String> get _addonSources => {
    for (final addon in ref.read(addonRepositoryProvider).enabled)
      AddonClient.sourceFor(addon),
  };

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
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

  @override
  Widget build(BuildContext context) {
    final metaAsync = ref.watch(
      addonMetaProvider(
        widget.type,
        widget.id,
        preferredAddonUrl: widget.addonUrl,
      ),
    );

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: metaAsync.when(
        loading: () => _buildLoadingState(context),
        error: (error, _) => _buildErrorState(context, error.toString()),
        data: (meta) {
          if (meta == null) {
            return _buildErrorState(
              context,
              'No installed add-on could describe this title. Install a '
              'metadata add-on such as Cinemeta.',
            );
          }
          _resumeIfAsked(meta);
          return _buildBody(context, meta);
        },
      ),
    );
  }

  Widget _buildLoadingState(BuildContext context) {
    final theme = Theme.of(context);
    final isMovie = widget.type.toLowerCase() == 'movie';

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(),
      ),
      // Scrollable only so that it fits: a phone held sideways is shorter
      // than the placeholder.
      body: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ShimmerPlaceholder.rectangular(
              height: 220,
              width: double.infinity,
              borderRadius: 12,
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                _buildTopBadge(context, 'ADD-ON'),
                const SizedBox(width: 12),
                _buildTopBadge(context, isMovie ? 'MOVIE' : 'SERIES'),
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
  }

  Widget _buildErrorState(BuildContext context, String text) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 56,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    text,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  // A bot check one of the add-ons met: Verify, then the
                  // details load again.
                  CheckLines(
                    sources: _addonSources,
                    since: _openedAt,
                    onCleared: (_) => ref.invalidate(
                      addonMetaProvider(
                        widget.type,
                        widget.id,
                        preferredAddonUrl: widget.addonUrl,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    autofocus: true,
                    onPressed: () => ref.invalidate(
                      addonMetaProvider(
                        widget.type,
                        widget.id,
                        preferredAddonUrl: widget.addonUrl,
                      ),
                    ),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 8,
            left: 8,
            child: CircleAvatar(
              backgroundColor: theme.colorScheme.onSurface.withValues(
                alpha: 0.1,
              ),
              child: IconButton(
                icon: Icon(
                  Icons.arrow_back,
                  color: theme.colorScheme.onSurface,
                  size: 20,
                ),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, AddonMeta meta) {
    final isDesktop = context.isDesktop || context.isTabletOrLarger;
    if (isDesktop) {
      return _buildDesktopLayout(context, meta);
    }
    return _buildMobileLayout(context, meta);
  }

  Widget _buildDesktopLayout(BuildContext context, AddonMeta meta) {
    final theme = Theme.of(context);
    final scaffoldColor = theme.scaffoldBackgroundColor;
    final textColor = theme.colorScheme.onSurface;
    final textSecondary = theme.colorScheme.onSurface.withValues(alpha: 0.7);

    // The TMDB id Cast and "More Like This" need (build 111): the
    // add-on's own when it has one, else resolved by title + year —
    // plugin titles like MoviesMod's Bull Run carry no moviedbId.
    // While it resolves, or when TMDB has no match, the id is null
    // and both rows hide.
    final tmdbId =
        meta.moviedbId ??
        ref
            .watch(
              addonTmdbIdProvider(
                AddonTmdbIdParams(
                  moviedbId: meta.moviedbId,
                  title: meta.name,
                  year: meta.year,
                  isShow: meta.isShow,
                ),
              ),
            )
            .asData
            ?.value;
    final tmdbAsync = tmdbId != null
        ? ref.watch(
            tmdbDetailsProvider(
              MovieDetailsParams(tmdbId, meta.isShow ? 'tv' : 'movie'),
            ),
          )
        : null;
    final tmdb = tmdbAsync?.value;

    final cast = (tmdb?.tmdbCast.isNotEmpty == true)
        ? tmdb!.tmdbCast
        : meta.castMembers;

    final productionCompanies = (tmdb?.productionCompanies.isNotEmpty == true)
        ? tmdb!.productionCompanies
        : meta.productionCompanies;

    final trailers = (tmdb?.tmdbTrailers.isNotEmpty == true)
        ? tmdb!.tmdbTrailers
        : meta.trailers;

    final title = meta.name;
    final overview = meta.description ?? '';
    final logoUrl = meta.logo;
    final backdropImageUrl = meta.background ?? meta.poster ?? '';
    final year = meta.releaseInfo ?? '';
    final rating = meta.imdbRating ?? '';
    final runtime = meta.runtime ?? '';
    final genreText = meta.genres.join(' • ');
    final hasEpisodes = meta.videos.isNotEmpty;
    final seasons = meta.seasons;

    return Scaffold(
      backgroundColor: scaffoldColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: CircleAvatar(
            backgroundColor: textColor.withValues(alpha: 0.1),
            child: IconButton(
              icon: Icon(Icons.arrow_back, color: textColor, size: 20),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (backdropImageUrl.isNotEmpty)
            Positioned.fill(
              child: ShaderMask(
                shaderCallback: (rect) {
                  return LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      scaffoldColor,
                      scaffoldColor.withValues(alpha: 0.85),
                      scaffoldColor.withValues(alpha: 0.55),
                      scaffoldColor.withValues(alpha: 0.25),
                      scaffoldColor.withValues(alpha: 0.08),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
                  ).createShader(rect);
                },
                blendMode: BlendMode.dstOut,
                child: CachedNetworkImage(
                  imageUrl: backdropImageUrl,
                  fit: BoxFit.cover,
                  alignment: Alignment.centerRight,
                  memCacheWidth:
                      (MediaQuery.sizeOf(context).width *
                              MediaQuery.devicePixelRatioOf(context))
                          .round(),
                  errorWidget: (_, _, _) =>
                      ThumbnailErrorPlaceholder(label: title, isBackdrop: true),
                ),
              ),
            ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    scaffoldColor,
                    scaffoldColor.withValues(alpha: 0.85),
                    scaffoldColor.withValues(alpha: 0.55),
                    scaffoldColor.withValues(alpha: 0.25),
                    scaffoldColor.withValues(alpha: 0.08),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    scaffoldColor,
                    scaffoldColor.withValues(alpha: 0.85),
                    scaffoldColor.withValues(alpha: 0.55),
                    scaffoldColor.withValues(alpha: 0.25),
                    scaffoldColor.withValues(alpha: 0.08),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.1, 0.2, 0.28, 0.35, 0.4],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 60),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: MediaQuery.sizeOf(context).width * 0.6,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (logoUrl != null && logoUrl.isNotEmpty)
                          _buildLogoWidget(
                            logoUrl,
                            title,
                            textColor,
                            isDesktop: true,
                          )
                        else
                          Text(
                            title.toUpperCase(),
                            style: TextStyle(
                              color: textColor,
                              fontSize: 48,
                              fontFamily: 'RobotoCondensed',
                              fontWeight: FontWeight.w900,
                              height: 1.1,
                            ),
                          ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _buildTopBadge(
                              context,
                              meta.addonName.isNotEmpty
                                  ? meta.addonName.toUpperCase()
                                  : 'ADD-ON',
                            ),
                            _buildTopBadge(
                              context,
                              meta.isShow ? 'SERIES' : 'MOVIE',
                            ),
                            if (year.isNotEmpty)
                              _buildIconInfo(
                                context,
                                Icons.calendar_today_rounded,
                                year,
                              ),
                            if (rating.isNotEmpty)
                              _buildIconInfo(
                                context,
                                Icons.star_rounded,
                                rating,
                                iconColor: Colors.amber,
                              ),
                            if (runtime.isNotEmpty)
                              _buildIconInfo(
                                context,
                                Icons.timer_outlined,
                                runtime,
                              ),
                            if (seasons.isNotEmpty && seasons.length > 1)
                              _buildIconInfo(
                                context,
                                Icons.layers_rounded,
                                '${seasons.length} Seasons',
                              ),
                          ],
                        ),
                        if (overview.isNotEmpty) ...[
                          const SizedBox(height: 20),
                          Text(
                            overview,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: textSecondary,
                              fontSize: 16,
                              height: 1.5,
                            ),
                          ),
                        ],
                        if (genreText.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            genreText,
                            style: TextStyle(
                              color: textSecondary.withValues(alpha: 0.6),
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        _buildPlayButton(context, meta, compact: true),
                        _buildSourcesCard(context, meta, compact: true),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                  if (hasEpisodes) ...[
                    _buildSeasonsAndEpisodesSection(context, meta),
                    const SizedBox(height: 32),
                  ],
                  if (cast.isNotEmpty) ...[
                    MovieCastList(
                      cast: cast,
                      textColor: textColor,
                      textSecondary: textSecondary,
                    ),
                    const SizedBox(height: 32),
                  ],
                  if (trailers.isNotEmpty) ...[
                    MovieTrailersCarousel(
                      trailers: trailers,
                      textColor: textColor,
                    ),
                    const SizedBox(height: 32),
                  ],
                  // "More Like This" (build 111): TMDB recommendations
                  // for the resolved id; the widget hides itself when
                  // there is no id or no recommendations.
                  if (tmdbId != null)
                    MovieMoreLikeThis(
                      movieId: tmdbId,
                      mediaType: meta.isShow ? 'tv' : 'movie',
                    ),
                  if (productionCompanies.isNotEmpty) ...[
                    MovieProductionCompanies(
                      productionCompanies: productionCompanies,
                      textColor: textColor,
                      textSecondary: textSecondary,
                    ),
                    const SizedBox(height: 32),
                  ],
                  _buildDetailsTable(context, meta, tmdb: tmdb),
                  const SizedBox(height: 100),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The phone page, in the "Hero" layout: a full-bleed banner with the
  /// add-on's tag, the title and the round Play button on it, an info strip,
  /// the sources card, a short synopsis and the episodes as a row.
  Widget _buildMobileLayout(BuildContext context, AddonMeta meta) {
    final theme = Theme.of(context);
    final backdropImageUrl = meta.background ?? meta.poster ?? '';
    final title = meta.name;
    final overview = (meta.description ?? '').trim();
    final year = meta.releaseInfo ?? '';
    final rating = meta.imdbRating ?? '';
    final runtime = meta.runtime ?? '';
    final hasEpisodes = meta.videos.isNotEmpty;
    final seasons = meta.seasons;
    final l10n = AppLocalizations.of(context)!;

    // The TMDB id Cast and "More Like This" need (build 111): the
    // add-on's own when it has one, else resolved by title + year —
    // plugin titles like MoviesMod's Bull Run carry no moviedbId.
    // While it resolves, or when TMDB has no match, the id is null
    // and both rows hide.
    final tmdbId =
        meta.moviedbId ??
        ref
            .watch(
              addonTmdbIdProvider(
                AddonTmdbIdParams(
                  moviedbId: meta.moviedbId,
                  title: meta.name,
                  year: meta.year,
                  isShow: meta.isShow,
                ),
              ),
            )
            .asData
            ?.value;
    final tmdbAsync = tmdbId != null
        ? ref.watch(
            tmdbDetailsProvider(
              MovieDetailsParams(tmdbId, meta.isShow ? 'tv' : 'movie'),
            ),
          )
        : null;
    final tmdb = tmdbAsync?.value;

    final cast = (tmdb?.tmdbCast.isNotEmpty == true)
        ? tmdb!.tmdbCast
        : meta.castMembers;

    final productionCompanies = (tmdb?.productionCompanies.isNotEmpty == true)
        ? tmdb!.productionCompanies
        : meta.productionCompanies;

    final trailers = (tmdb?.tmdbTrailers.isNotEmpty == true)
        ? tmdb!.tmdbTrailers
        : meta.trailers;

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
      if (seasons.length > 1)
        (
          icon: Icons.layers_rounded,
          color: null,
          column: DetailsInfoColumn(
            value: '${seasons.length}',
            label: l10n.seasons,
          ),
        ),
      if (meta.isShow && hasEpisodes)
        (
          icon: Icons.video_library_outlined,
          color: null,
          column: DetailsInfoColumn(
            value: '${meta.videos.length}',
            label: l10n.episodes,
          ),
        ),
      if (runtime.isNotEmpty)
        (
          icon: Icons.timer_outlined,
          color: null,
          column: DetailsInfoColumn(value: runtime, label: 'Runtime'),
        ),
      if (rating.isNotEmpty)
        (
          icon: Icons.star_rounded,
          color: Colors.amber,
          column: DetailsInfoColumn(value: rating, label: 'Rating'),
        ),
    ];
    final inStrip = facts.take(DetailsInfoStrip.maxColumns).toList();
    final leftOver = facts.skip(DetailsInfoStrip.maxColumns).toList();

    Widget padded(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: child,
    );

    return Stack(
      children: [
        CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverToBoxAdapter(
              child: DetailsHeroBanner(
                height: bannerHeight,
                title: title,
                subtitle: meta.genres.isNotEmpty
                    ? meta.genres.take(3).join(' • ')
                    : (meta.isShow ? 'TV Series' : 'Movie'),
                sourceTag: DetailsSourceTag(
                  label: meta.addonName.isNotEmpty ? meta.addonName : 'ADD-ON',
                ),
                playFab: _buildPlayFab(context, meta),
                image: backdropImageUrl.isEmpty
                    ? ThumbnailErrorPlaceholder(label: title, isBackdrop: true)
                    : CachedNetworkImage(
                        imageUrl: backdropImageUrl,
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
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
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  if (inStrip.isNotEmpty) ...[
                    padded(
                      DetailsInfoStrip(
                        columns: [for (final f in inStrip) f.column],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  padded(_buildSourcesCard(context, meta)),
                  const SizedBox(height: 12),

                  // Meta row: MOVIE/SERIES and whatever the strip had no
                  // room for.
                  padded(
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _buildTopBadge(
                          context,
                          meta.isShow ? 'SERIES' : 'MOVIE',
                        ),
                        for (final f in leftOver)
                          _buildIconInfo(
                            context,
                            f.icon,
                            f.column.label == l10n.seasons
                                ? '${f.column.value} Seasons'
                                : f.column.value,
                            iconColor: f.color,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  if (overview.isNotEmpty) ...[
                    padded(ExpandableSynopsis(text: overview)),
                    const SizedBox(height: 20),
                  ],

                  // Episodes (shown whenever episodes are available)
                  if (hasEpisodes) ...[
                    _buildEpisodeRowSection(context, meta),
                    const SizedBox(height: 24),
                  ],

                  if (cast.isNotEmpty) ...[
                    padded(MovieCastList(cast: cast, lookupPhotos: true)),
                    const SizedBox(height: 24),
                  ],

                  if (productionCompanies.isNotEmpty) ...[
                    padded(
                      MovieProductionCompanies(
                        productionCompanies: productionCompanies,
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  if (trailers.isNotEmpty) ...[
                    padded(MovieTrailersCarousel(trailers: trailers)),
                    const SizedBox(height: 24),
                  ],

                  // "More Like This" (build 111): TMDB recommendations
                  // for the resolved id; the widget hides itself when
                  // there is no id or no recommendations.
                  if (tmdbId != null)
                    padded(
                      MovieMoreLikeThis(
                        movieId: tmdbId,
                        mediaType: meta.isShow ? 'tv' : 'movie',
                      ),
                    ),

                  padded(_buildDetailsTable(context, meta, tmdb: tmdb)),
                  const SizedBox(height: 100),
                ],
              ),
            ),
          ],
        ),
        DetailsHeroTopBar(
          scrollOffset: _scrollOffset,
          leading: DetailsHeroTopBar.button(
            key: const ValueKey('details-back'),
            icon: Icons.arrow_back,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
      ],
    );
  }

  /// The round Play button on the phone page's banner: [AddonPlayButton] in
  /// its other shape, so it is there exactly when the full-width Play was -
  /// once the add-on that described the title has a link that plays here.
  Widget? _buildPlayFab(BuildContext context, AddonMeta meta) {
    if (_mergedSources) return _buildMergedPlayFab(context, meta);
    final addon = ownStreamAddon(
      enabled: ref.watch(addonRepositoryProvider).enabled,
      meta: meta,
      routeAddonUrl: widget.addonUrl,
    );
    if (addon == null) return null;
    final target = addonPlayTarget(
      meta,
      history: ref.watch(historyRepositoryProvider),
      watched: ref.watch(episodeWatchRepositoryProvider),
      lastWatched: ref
          .watch(watchHistoryProvider)
          .firstWhereOrNull((h) => h.item.url == meta.id),
    );
    if (meta.isShow && target == null) return null;
    return AddonPlayButton(meta: meta, addon: addon, target: target, fab: true);
  }

  /// A Browse title's Play (v8): always on the banner, whatever is
  /// installed and before anything was asked. A press opens the list of
  /// sources from plugins, Nuvio providers and Stremio add-ons; an empty
  /// list says so there. A show plays the episode to continue with, else
  /// the first one listed.
  Widget _buildMergedPlayFab(BuildContext context, AddonMeta meta) {
    final l10n = AppLocalizations.of(context)!;
    AddonVideo? target;
    if (meta.isShow) {
      target = addonPlayTarget(
        meta,
        history: ref.watch(historyRepositoryProvider),
        watched: ref.watch(episodeWatchRepositoryProvider),
        lastWatched: ref
            .watch(watchHistoryProvider)
            .firstWhereOrNull((h) => h.item.url == meta.id),
      );
      if (target == null) {
        final seasons = meta.seasons;
        final episodes = meta.episodesForSeason(
          _selectedSeason ?? (seasons.isEmpty ? 1 : seasons.first),
        );
        target = episodes.isNotEmpty ? episodes.first : null;
      }
    }
    // Build 74: a title with a saved position says Resume, and the
    // press continues on the source it last played on.
    final resume = _hasResume(meta, target);
    var label = resume ? l10n.resume : l10n.play;
    if (target != null) {
      label = meta.seasons.length <= 1
          ? l10n.playEpisodeOnly(label, target.episode ?? 1)
          : l10n.playEpisode(label, target.season ?? 1, target.episode ?? 1);
    }
    final video = target;
    return DetailsPlayFab(
      label: label,
      onPressed: () => _openSources(meta, video, resume: resume),
    );
  }

  /// Whether the film, or [video] of a show, has a position to resume.
  bool _hasResume(AddonMeta meta, AddonVideo? video) =>
      addonHasResume(_resumePositionMs(meta, video));

  /// The saved position of the film, or of [video] of a show, in ms.
  /// Read under the keys the player writes: the title's id for a film,
  /// the episode's own id for an episode.
  int _resumePositionMs(AddonMeta meta, AddonVideo? video) {
    try {
      // Rebuilt when a position is written (the player closing).
      ref.watch(watchHistoryProvider);
      final history = ref.watch(historyRepositoryProvider);
      return video == null
          ? history.getPosition(meta.id)
          : history.getEpisodePosition(
              video.id,
              mainUrl: meta.id,
              season: video.season,
              episode: video.episode,
            );
    } catch (_) {
      // No history store (not opened): nothing to resume.
      return 0;
    }
  }

  /// Build 74: Continue Watching asked for this title (see
  /// [AddonResumeIntent]) — the sources open in resume mode for the
  /// film, or for the episode to continue with.
  void _resumeIfAsked(AddonMeta meta) {
    if (!AddonResumeIntent.consume(meta.id)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AddonVideo? target;
      if (meta.isShow) {
        target = addonPlayTarget(
          meta,
          history: ref.read(historyRepositoryProvider),
          watched: ref.read(episodeWatchRepositoryProvider),
          lastWatched: ref
              .read(watchHistoryProvider)
              .firstWhereOrNull((h) => h.item.url == meta.id),
        );
        if (target == null) return;
      }
      // Continue Watching reopens the page by its add-on alone, so a
      // title that was played from Browse on a plugin's source would
      // be asked of the add-ons only and its source would never
      // answer. With a remembered source the list is the full one
      // (plugins, Nuvio providers and add-ons — the add-ons' own
      // sources are in it too).
      var remembered = false;
      try {
        remembered =
            readLastUsedSource(ref.read(settingsRepositoryProvider), meta.id) !=
            null;
      } catch (_) {}
      unawaited(
        _openSources(meta, target, resume: true, forceMerged: remembered),
      );
    });
  }

  /// Opens the sources list for the film, or for [video] of a show.
  Future<void> _openSources(
    AddonMeta meta,
    AddonVideo? video, {
    bool resume = false,
    bool forceMerged = false,
  }) {
    return AddonSourcesSheet.open(
      context,
      item: _itemOf(meta),
      request: AddonStreamRequest(
        type: meta.streamRequestType,
        contentId: meta.id,
        videoId: video?.id,
        season: video?.season,
        episode: video?.episode,
        imdbId: meta.imdbId,
        tmdbId: meta.moviedbId,
        title: meta.name,
        year: meta.year,
      ),
      episode: video?.toEpisode(),
      playlist: meta.videos,
      merged: _mergedSources || forceMerged,
      resume: resume,
    );
  }

  /// [meta] as the item this page hands on, naming the install that
  /// described it - Continue Watching reopens the title through it - or the
  /// route's add-on when none of the enabled ones is that add-on (Cinemeta is
  /// built in).
  MultimediaItem _itemOf(AddonMeta meta) => meta.toMultimediaItem(
    addonUrl:
        describingAddon(
          enabled: ref.watch(addonRepositoryProvider).enabled,
          meta: meta,
          routeAddonUrl: widget.addonUrl,
        )?.manifestUrl ??
        widget.addonUrl,
  );

  /// Play, when the add-on that described the title serves its links
  /// (Stremio direct play): [AddonPlayButton] stays out of sight until one
  /// came back. Nothing for a title its add-on only describes.
  Widget _buildPlayButton(
    BuildContext context,
    AddonMeta meta, {
    bool compact = false,
  }) {
    final addon = ownStreamAddon(
      enabled: ref.watch(addonRepositoryProvider).enabled,
      meta: meta,
      routeAddonUrl: widget.addonUrl,
    );
    if (addon == null) return const SizedBox.shrink();
    final target = addonPlayTarget(
      meta,
      history: ref.watch(historyRepositoryProvider),
      watched: ref.watch(episodeWatchRepositoryProvider),
      lastWatched: ref
          .watch(watchHistoryProvider)
          .firstWhereOrNull((h) => h.item.url == meta.id),
    );
    if (meta.isShow && target == null) return const SizedBox.shrink();
    return AddonPlayButton(
      meta: meta,
      addon: addon,
      target: target,
      compact: compact,
    );
  }

  /// The Stremio source card, in the same place the "Play from add-ons"
  /// button used to sit.
  ///
  /// [compact] follows the layout, not the device: the desktop hero draws it
  /// inside a padded column of its own, where the card's container would be a
  /// box inside a box.
  Widget _buildSourcesCard(
    BuildContext context,
    AddonMeta meta, {
    bool compact = false,
  }) {
    final item = _itemOf(meta);

    final seasons = meta.seasons;
    final activeSeason =
        _selectedSeason ?? (seasons.isEmpty ? 1 : seasons.first);
    final episodes = meta.episodesForSeason(activeSeason);
    var firstVideo = episodes.isNotEmpty ? episodes.first : null;

    // Build 75: a show with an episode to continue (the one last
    // watched while unfinished) resolves that episode, not the first
    // of the season — unless another season was picked by hand. Build
    // 74 taught only the banner's Play about resuming; this card, the
    // button the page actually offers on a phone, kept opening the
    // plain list for episode 1.
    if (meta.isShow) {
      AddonVideo? resumeTarget;
      try {
        resumeTarget = addonPlayTarget(
          meta,
          history: ref.watch(historyRepositoryProvider),
          watched: ref.watch(episodeWatchRepositoryProvider),
          lastWatched: ref
              .watch(watchHistoryProvider)
              .firstWhereOrNull((h) => h.item.url == meta.id),
        );
      } catch (_) {
        resumeTarget = null;
      }
      if (resumeTarget != null &&
          (_selectedSeason == null || resumeTarget.season == _selectedSeason) &&
          _hasResume(meta, resumeTarget)) {
        firstVideo = resumeTarget;
      }
    }
    final resumeMs = _resumePositionMs(meta, meta.isShow ? firstVideo : null);
    final resume =
        addonHasResume(resumeMs) && (!meta.isShow || firstVideo != null);

    // A series resolves one episode - the first of the selected season - and
    // the label says which. Anything else is reached from the episode list
    // further down, which opens the same sheet per episode.
    final isEpisode = meta.isShow && firstVideo != null;

    // Build 76: [resume] plays the remembered source by itself;
    // without it the same list opens and waits for a pick ("Change
    // source") — the remembered source is still first, marked "Last
    // used", and whichever is picked starts at the saved position and
    // is the one remembered from then on.
    void open({required bool resume}) => AddonSourcesSheet.open(
      context,
      item: item,
      request: AddonStreamRequest(
        // Preserve the meta's own type (other/tv/…) so bridges like
        // CNCVerse answer /stream on the type they published.
        type: meta.streamRequestType,
        contentId: meta.id,
        videoId: firstVideo?.id,
        season: firstVideo?.season,
        episode: firstVideo?.episode,
        imdbId: meta.imdbId,
        tmdbId: meta.moviedbId,
        title: meta.name,
        year: meta.year,
      ),
      episode: firstVideo?.toEpisode(),
      playlist: meta.videos,
      merged: _mergedSources,
      resume: resume,
    );

    return StremioSourcesCard(
      compact: compact,
      merged: _mergedSources,
      resumeLabel: resume
          ? addonResumeLabel(
              resume: AppLocalizations.of(context)!.resume,
              positionMs: resumeMs,
              season: isEpisode ? (firstVideo.season ?? activeSeason) : null,
              episode: isEpisode ? (firstVideo.episode ?? 1) : null,
            )
          : null,
      // The page's one way to its streams: a remote starts here.
      autofocus: true,
      episode: isEpisode
          ? (
              season: firstVideo.season ?? activeSeason,
              episode: firstVideo.episode ?? 1,
            )
          : null,
      onOpen: () => open(resume: resume),
      onChangeSource: resume ? () => open(resume: false) : null,
    );
  }

  Widget _buildLogoWidget(
    String logoUrl,
    String fallbackTitle,
    Color textColor, {
    required bool isDesktop,
  }) {
    if (logoUrl.toLowerCase().endsWith('.svg')) {
      return SvgPicture.network(
        logoUrl,
        width: isDesktop ? 280 : 220,
        height: isDesktop ? 140 : 100,
        fit: BoxFit.contain,
        placeholderBuilder: (_) => Text(
          fallbackTitle.toUpperCase(),
          style: TextStyle(
            color: textColor,
            fontSize: isDesktop ? 48 : 36,
            fontFamily: 'RobotoCondensed',
            fontWeight: FontWeight.w900,
          ),
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: logoUrl,
      width: isDesktop ? 280 : 220,
      height: isDesktop ? 140 : 100,
      fit: BoxFit.contain,
      alignment: isDesktop ? Alignment.centerLeft : Alignment.center,
      errorWidget: (_, _, _) => Text(
        fallbackTitle.toUpperCase(),
        style: TextStyle(
          color: textColor,
          fontSize: isDesktop ? 48 : 36,
          fontFamily: 'RobotoCondensed',
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _buildTopBadge(BuildContext context, String label) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: primary.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: primary,
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
    final theme = Theme.of(context);
    final color =
        iconColor ?? theme.colorScheme.onSurface.withValues(alpha: 0.7);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildSeasonsAndEpisodesSection(BuildContext context, AddonMeta meta) {
    final theme = Theme.of(context);
    final seasons = meta.seasons;
    final activeSeason =
        _selectedSeason ?? (seasons.isEmpty ? 1 : seasons.first);
    final episodes = meta.episodesForSeason(activeSeason);
    final item = _itemOf(meta);

    const int batchSize = 20;
    final int totalEpisodes = episodes.length;
    final int batchCount = (totalEpisodes / batchSize).ceil();

    if (_selectedRangeIndex >= batchCount) {
      _selectedRangeIndex = 0;
    }

    final int start = _selectedRangeIndex * batchSize;
    final int end = (start + batchSize).clamp(0, totalEpisodes);
    List<AddonVideo> displayedEpisodes = episodes.isNotEmpty
        ? episodes.sublist(start, end)
        : <AddonVideo>[];

    if (!_isAscending) {
      displayedEpisodes = displayedEpisodes.reversed.toList();
    }

    AddonStreamRequest requestFor(AddonVideo video) => AddonStreamRequest(
      type: meta.streamRequestType,
      contentId: meta.id,
      videoId: video.id,
      season: video.season,
      episode: video.episode,
      imdbId: meta.imdbId,
      tmdbId: meta.moviedbId,
      title: meta.name,
      year: meta.year,
    );

    // The add-on that described the title, when it serves its links: a tap
    // then plays the episode from it (Stremio direct play).
    final own = ownStreamAddon(
      enabled: ref.watch(addonRepositoryProvider).enabled,
      meta: meta,
      routeAddonUrl: widget.addonUrl,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Season selector (only shown if multiple seasons exist)
        if (seasons.length > 1) ...[
          Text(
            'SEASONS',
            style: TextStyle(
              color: theme.colorScheme.onSurface,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 12),
          _buildSeasonChips(theme, seasons, activeSeason),
          const SizedBox(height: 20),
        ],

        // Episodes Header + Range Dropdown (if episodes > 20) + Sort Order Toggle
        Row(
          children: [
            Text(
              'EPISODES',
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(width: 14),
            if (batchCount > 1) ...[
              _buildRangeDropdown(
                theme,
                batchCount: batchCount,
                batchSize: batchSize,
                totalEpisodes: totalEpisodes,
              ),
              const SizedBox(width: 8),
            ],
            _buildSortButton(theme),
          ],
        ),

        const SizedBox(height: 16),

        // TMDB-Style Horizontal Episode Cards List
        if (displayedEpisodes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0),
            child: Text(
              'No episodes listed for this title.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          // As a CloudStream title's (DetailsScreen): side by side as wide as
          // the page allows, one under another on a phone.
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.maxWidth / 480).ceil().clamp(1, 5);
              final rows = (displayedEpisodes.length / columns).ceil();
              return Column(
                children: [
                  for (var row = 0; row < rows; row++) ...[
                    if (row > 0) const SizedBox(height: 16),
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var column = 0; column < columns; column++)
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(
                                  left: column == 0 ? 0 : 8,
                                  right: column == columns - 1 ? 0 : 8,
                                ),
                                child:
                                    row * columns + column <
                                        displayedEpisodes.length
                                    ? _buildEpisodeCard(
                                        context,
                                        meta,
                                        displayedEpisodes[row * columns +
                                            column],
                                        own: own,
                                        item: item,
                                        request: requestFor(
                                          displayedEpisodes[row * columns +
                                              column],
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
      ],
    );
  }

  /// The season chips of a title with more than one season.
  Widget _buildSeasonChips(
    ThemeData theme,
    List<int> seasons,
    int activeSeason,
  ) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: seasons.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final season = seasons[index];
          final isSelected = season == activeSeason;
          return DpadFocusable(
            onSelect: () {
              setState(() {
                _selectedSeason = season;
                _selectedRangeIndex = 0;
              });
            },
            child: const SizedBox.shrink(),
            builder: (context, state, _) {
              final isFocused = showFocusIndicator(context, state.focused);
              return Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isFocused
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: ChoiceChip(
                  label: Text('Season $season'),
                  selected: isSelected,
                  onSelected: (_) {
                    setState(() {
                      _selectedSeason = season;
                      _selectedRangeIndex = 0;
                    });
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// The episode range picker ("1-20", "21-40"...). [onChanged] is told
  /// after the range is taken: the phone page's row scrolls to it.
  Widget _buildRangeDropdown(
    ThemeData theme, {
    required int batchCount,
    required int batchSize,
    required int totalEpisodes,
    ValueChanged<int>? onChanged,
  }) {
    return Focus(
      child: Builder(
        builder: (context) {
          final isFocused = showFocusIndicator(
            context,
            Focus.of(context).hasFocus,
          );
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isFocused ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
            child: Center(
              child: DropdownButton<int>(
                value: _selectedRangeIndex,
                dropdownColor: theme.colorScheme.surfaceContainerHigh,
                underline: const SizedBox(),
                elevation: 4,
                borderRadius: BorderRadius.circular(12),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                icon: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                items: List.generate(batchCount, (index) {
                  final rangeStart = index * batchSize + 1;
                  final rangeEnd = ((index + 1) * batchSize).clamp(
                    1,
                    totalEpisodes,
                  );
                  return DropdownMenuItem(
                    value: index,
                    child: Text('$rangeStart-$rangeEnd'),
                  );
                }),
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      _selectedRangeIndex = val;
                    });
                    onChanged?.call(val);
                  }
                },
              ),
            ),
          );
        },
      ),
    );
  }

  /// Flips the episodes' order.
  Widget _buildSortButton(ThemeData theme) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            setState(() {
              _isAscending = !_isAscending;
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Icon(
              Icons.swap_vert_rounded,
              size: 22,
              color: _isAscending
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// The phone page's episodes row: what it was last built for, and its key.
  Object? _episodeRowIdentity;
  GlobalKey<HorizontalEpisodeRowState> _episodeRowKey = GlobalKey();
  bool _openedAtTarget = false;

  /// The phone page's episodes: the season chips, the "Episodes" header with
  /// the range picker and the sort button, and the season's episodes as one
  /// horizontal row. The row holds the whole season and builds only what is
  /// on screen; it opens at the episode to resume, and the range picker
  /// scrolls it rather than cutting the list.
  Widget _buildEpisodeRowSection(BuildContext context, AddonMeta meta) {
    const double side = 20;
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final seasons = meta.seasons;
    final activeSeason =
        _selectedSeason ?? (seasons.isEmpty ? 1 : seasons.first);
    final episodes = meta.episodesForSeason(activeSeason);
    final item = _itemOf(meta);

    const int batchSize = 20;
    final int total = episodes.length;
    final int batchCount = (total / batchSize).ceil();
    if (_selectedRangeIndex >= batchCount) {
      _selectedRangeIndex = 0;
    }
    final ascending = _isAscending;

    AddonStreamRequest requestFor(AddonVideo video) => AddonStreamRequest(
      type: meta.streamRequestType,
      contentId: meta.id,
      videoId: video.id,
      season: video.season,
      episode: video.episode,
      imdbId: meta.imdbId,
      tmdbId: meta.moviedbId,
      title: meta.name,
      year: meta.year,
    );

    final own = ownStreamAddon(
      enabled: ref.watch(addonRepositoryProvider).enabled,
      meta: meta,
      routeAddonUrl: widget.addonUrl,
    );

    // Where the row shows the first card of a range.
    int positionOfRange(int range) {
      final first = (range * batchSize).clamp(0, total - 1);
      final last = (first + batchSize - 1).clamp(0, total - 1);
      return ascending ? first : total - 1 - last;
    }

    var initialPosition = 0;
    final identity = (activeSeason, ascending, total);
    if (identity != _episodeRowIdentity && total > 0) {
      _episodeRowIdentity = identity;
      _episodeRowKey = GlobalKey();
      final target = _openedAtTarget
          ? null
          : addonPlayTarget(
              meta,
              history: ref.read(historyRepositoryProvider),
              watched: ref.read(episodeWatchRepositoryProvider),
              lastWatched: ref
                  .read(watchHistoryProvider)
                  .firstWhereOrNull((h) => h.item.url == meta.id),
            );
      final targetIndex = target == null
          ? -1
          : episodes.indexWhere((e) => e.id == target.id);
      if (targetIndex >= 0) {
        _openedAtTarget = true;
        _selectedRangeIndex = targetIndex ~/ batchSize;
        initialPosition = ascending ? targetIndex : total - 1 - targetIndex;
      } else {
        initialPosition = positionOfRange(_selectedRangeIndex);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (seasons.length > 1) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: side),
            child: _buildSeasonChips(theme, seasons, activeSeason),
          ),
          const SizedBox(height: 16),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: side),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.episodes,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (batchCount > 1) ...[
                SizedBox(
                  height: 40,
                  child: _buildRangeDropdown(
                    theme,
                    batchCount: batchCount,
                    batchSize: batchSize,
                    totalEpisodes: total,
                    onChanged: (range) => _episodeRowKey.currentState
                        ?.scrollToIndex(positionOfRange(range)),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              _buildSortButton(theme),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (total == 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: side, vertical: 16),
            child: Text(
              'No episodes listed for this title.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          HorizontalEpisodeRow(
            key: _episodeRowKey,
            itemCount: total,
            initialIndex: initialPosition,
            padding: const EdgeInsets.symmetric(horizontal: side),
            onFirstVisibleChanged: (position) {
              final index = ascending ? position : total - 1 - position;
              final range = index ~/ batchSize;
              if (range != _selectedRangeIndex) {
                setState(() => _selectedRangeIndex = range);
              }
            },
            itemBuilder: (context, position) {
              final video =
                  episodes[ascending ? position : total - 1 - position];
              return _buildEpisodeCard(
                context,
                meta,
                video,
                own: own,
                item: item,
                request: requestFor(video),
                rowStyle: true,
              );
            },
          ),
      ],
    );
  }

  /// An episode's card: a tap plays it from [own] when the title's add-on
  /// serves its links, else opens every add-on's list for it, as a long
  /// press always does (Stremio direct play).
  Widget _buildEpisodeCard(
    BuildContext context,
    AddonMeta meta,
    AddonVideo video, {
    required ManagedAddon? own,
    required MultimediaItem item,
    required AddonStreamRequest request,
    bool rowStyle = false,
  }) {
    // Build 75: an episode with a saved position continues on the
    // source the show last played on, as the page's own buttons do.
    final resume = _hasResume(meta, video);
    void search() => AddonSourcesSheet.open(
      context,
      item: item,
      request: request,
      episode: video.toEpisode(),
      playlist: meta.videos,
      merged: _mergedSources,
      resume: resume,
    );
    return AddonEpisodeCard(
      key: ValueKey(video.id),
      video: video,
      showUrl: meta.id,
      loading: _askingFor == video.id,
      rowStyle: rowStyle,
      onTap: own == null
          ? search
          : () => _playEpisode(meta, video, own, request),
      onLongPress: search,
    );
  }

  /// The episode whose links are being asked for: its card shows a spinner.
  String? _askingFor;

  /// Plays [video] from [own]. Asked while someone waits, so a bot check that
  /// wants a click opens its sheet; with no link from it, every add-on's list
  /// opens for the episode instead.
  Future<void> _playEpisode(
    AddonMeta meta,
    AddonVideo video,
    ManagedAddon own,
    AddonStreamRequest request,
  ) async {
    if (_askingFor != null) return;
    setState(() => _askingFor = video.id);
    final links = await ownPlayableLinks(
      ref.read(addonStreamServiceProvider),
      own,
      request,
      personWaiting: true,
    );
    if (!mounted) return;
    setState(() => _askingFor = null);
    if (links.isEmpty) {
      await AddonSourcesSheet.open(
        context,
        item: meta.toMultimediaItem(addonUrl: own.manifestUrl),
        request: request,
        episode: video.toEpisode(),
        playlist: meta.videos,
        merged: _mergedSources,
      );
      return;
    }
    await playAddonLinks(
      context,
      ref,
      item: meta.toMultimediaItem(addonUrl: own.manifestUrl),
      request: request,
      links: links,
      episode: video.toEpisode(),
    );
  }

  Widget _buildDetailsTable(
    BuildContext context,
    AddonMeta meta, {
    TmdbDetails? tmdb,
  }) {
    final theme = Theme.of(context);
    final director = (tmdb?.director.isNotEmpty == true)
        ? tmdb!.director
        : (meta.directors.isNotEmpty ? meta.directors.join(', ') : null);
    final country = (tmdb?.originCountry.isNotEmpty == true)
        ? tmdb!.originCountry
        : meta.country;
    final status = (tmdb?.tmdbStatus.isNotEmpty == true)
        ? tmdb!.tmdbStatus
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          meta.isShow ? 'SHOW DETAILS' : 'MOVIE DETAILS',
          style: TextStyle(
            color: theme.colorScheme.onSurface,
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 16),
        _buildDetailRow('Type', meta.isShow ? 'Series' : 'Movie', theme),
        if (status != null && status.isNotEmpty)
          _buildDetailRow('Status', status, theme),
        if (director != null && director.isNotEmpty)
          _buildDetailRow('Director', director, theme),
        if (meta.writers.isNotEmpty)
          _buildDetailRow('Writer', meta.writers.join(', '), theme),
        if (country != null && country.isNotEmpty)
          _buildDetailRow('Country', country, theme),
        if (meta.awards != null && meta.awards!.isNotEmpty)
          _buildDetailRow('Awards', meta.awards!, theme),
        if (meta.releaseInfo != null && meta.releaseInfo!.isNotEmpty)
          _buildDetailRow('Release', meta.releaseInfo!, theme),
        if (meta.runtime != null && meta.runtime!.isNotEmpty)
          _buildDetailRow('Runtime', meta.runtime!, theme),
        if (meta.addonName.isNotEmpty)
          _buildDetailRow('Add-on Source', meta.addonName, theme),
        if (meta.imdbId != null && meta.imdbId!.isNotEmpty)
          _buildDetailRow('IMDb ID', meta.imdbId!, theme),
      ],
    );
  }

  Widget _buildDetailRow(String label, String value, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
