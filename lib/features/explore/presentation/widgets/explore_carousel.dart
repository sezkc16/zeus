import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:html_unescape/html_unescape.dart';

import '../../../../core/router/app_router.dart';
import '../../../../l10n/generated/app_localizations.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/theme/olympus.dart';
import '../../../../core/utils/image_utils.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/title_quality.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../home/data/hero_enrichment.dart';
import 'home_hero_meta.dart';

import '../../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../library/presentation/library_provider.dart';
import '../../../library/presentation/library_state.dart';

/// Lightweight controller for the hero carousel.
/// API-compatible with the old CarouselSliderController (nextPage/previousPage).
class HeroCarouselController {
  VoidCallback? onNextPage;
  VoidCallback? onPreviousPage;

  void nextPage({Duration? duration, Curve? curve}) => onNextPage?.call();
  void previousPage({Duration? duration, Curve? curve}) =>
      onPreviousPage?.call();
}

class ExploreCarousel extends ConsumerStatefulWidget {
  final List<MultimediaItem> movies;
  final ScrollController? scrollController;
  final void Function(MultimediaItem)? onTap;
  final VoidCallback? onNavigateUp;

  /// Called once after initState with the internal [HeroCarouselController]
  /// so the parent can drive prev/next from an external UI (e.g. header arrows).
  final void Function(HeroCarouselController controller)? onControllerReady;

  /// Restores the full preview hero (user decision 2026-11-16): big title,
  /// type badge pill and Play / My List / Info actions. Off by default —
  /// Explore, AniList and Addons keep the +42 poster-only hero.
  final bool showPreviewActions;

  /// Play handler for the preview hero. Home pushes the details screen with
  /// autoPlay, so Play resolves the item's streams and starts playback.
  /// Falls back to [onTap] / details when null.
  final void Function(MultimediaItem)? onPlay;

  /// Phone layout only: the hero runs edge to edge across the screen, with
  /// no side margin and square corners (user request 2026-11-17, Home).
  /// The text and buttons keep their own 24 px inset inside the slide. The
  /// wide (desktop / TV) layout ignores this and stays a padded card.
  final bool fullBleed;

  /// Phone layout only: render the Home hero (design A) — centred title
  /// logo, meta line, badge row, one View Details pill, dots inside the
  /// poster — with the same TMDB enrichment Home uses. Browse's TMDB
  /// hero sets this; Home sets [showPreviewActions] instead, which
  /// implies the same layout. Desktop keeps its own hero either way.
  final bool showHomeHero;

  const ExploreCarousel({
    super.key,
    required this.movies,
    this.scrollController,
    this.onTap,
    this.onNavigateUp,
    this.onControllerReady,
    this.showPreviewActions = false,
    this.showHomeHero = false,
    this.onPlay,
    this.fullBleed = false,
  });

  @override
  ConsumerState<ExploreCarousel> createState() => _ExploreCarouselState();
}

// Intents used by the carousel's keyboard shortcuts. Defined at file scope so
// they're const-constructible and stable across rebuilds.
class _CarouselUpIntent extends Intent {
  const _CarouselUpIntent();
}

class _CarouselPrevIntent extends Intent {
  const _CarouselPrevIntent();
}

class _CarouselNextIntent extends Intent {
  const _CarouselNextIntent();
}

class _ExploreCarouselState extends ConsumerState<ExploreCarousel>
    with TickerProviderStateMixin {
  final ValueNotifier<int> _currentIndexNotifier = ValueNotifier<int>(0);
  final HeroCarouselController _heroCarouselController =
      HeroCarouselController();
  final ValueNotifier<double> _scrollOffset = ValueNotifier(0.0);
  // Single anchor focus node so the carousel acts as ONE focus target on TV/
  // keyboard. Otherwise each slide is independently focusable and pages cause
  // focus to drop into the next row when slides unmount.
  final FocusNode _carouselFocusNode = FocusNode(debugLabel: 'carousel_anchor');
  bool _isFocusHighlighted = false;
  // True while the carousel occupies any visible viewport. Drives autoPlay
  // so the 5s slide loop pauses when the user scrolls past it — eliminates
  // off-screen frame work and the resulting battery / raster drain.
  bool _isVisibleOnScreen = true;

  // Crossfade + scale transition
  late final AnimationController _transitionController;
  late final Animation<double> _transitionAnimation;
  int _currentSlide = 0;
  int? _previousSlide;
  bool _isTransitioning = false;

  // Progress bar fill — also serves as the auto-advance timer (5s).
  late final AnimationController _fillController;

  @override
  void initState() {
    super.initState();

    _transitionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _transitionAnimation = CurvedAnimation(
      parent: _transitionController,
      curve: Curves.fastOutSlowIn,
    );
    _transitionController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() {
          _isTransitioning = false;
          _previousSlide = null;
        });
      }
    });

    _fillController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
      // A clock, not an animation. On the default behaviour Flutter runs a
      // controller at 5% of its duration while the platform asks for
      // animations to be removed - Android's "Animation off" transition scale,
      // and the fast animation modes some phones map onto it - and the
      // five-second dwell became a quarter of a second. The slide transition
      // above may still collapse under that setting; the dwell may not.
      animationBehavior: AnimationBehavior.preserve,
    );
    _fillController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        _goToNextSlide();
      }
    });

    _heroCarouselController.onNextPage = _goToNextSlide;
    _heroCarouselController.onPreviousPage = _goToPreviousSlide;

    widget.scrollController?.addListener(_onParentScroll);
    // Expose the internal controller to the parent so header arrows can
    // drive carousel navigation. Deferred to post-frame to avoid calling
    // setState on an ancestor while the widget tree is still building.
    if (widget.onControllerReady != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onControllerReady!(_heroCarouselController);
      });
    }

    _fillController.forward();
  }

  void _goToNextSlide() {
    if (widget.movies.length <= 1) return;
    final next = (_currentSlide + 1) % widget.movies.length;
    _startTransitionTo(next);
  }

  void _goToPreviousSlide() {
    if (widget.movies.length <= 1) return;
    final prev =
        (_currentSlide - 1 + widget.movies.length) % widget.movies.length;
    _startTransitionTo(prev);
  }

  void _startTransitionTo(int nextIndex) {
    if (_isTransitioning || nextIndex == _currentSlide || !mounted) return;
    setState(() {
      _previousSlide = _currentSlide;
      _currentSlide = nextIndex;
      _isTransitioning = true;
    });
    _currentIndexNotifier.value = nextIndex;
    _transitionController.forward(from: 0.0);
    _restartFill();
  }

  void _restartFill() {
    _fillController.reset();
    if (_isVisibleOnScreen) {
      _fillController.forward();
    }
  }

  void _onParentScroll() {
    // Always update — do NOT gate on _isVisibleOnScreen. Earlier we tried
    // to skip rebuilds while the carousel was off-screen, but that left
    // _scrollOffset frozen at a stale value; when the user scrolled back
    // up, syncing the offset on visibility-change caused a visible snap
    // (VisibilityDetector throttles, so the catch-up frame lands after
    // the user has already scrolled past it). The rebuild cost here is
    // negligible — Transform/RenderTransform reuses its RenderObject, the
    // CachedNetworkImage is cache-hit, and the whole carousel page is
    // wrapped in a RepaintBoundary so off-screen rebuilds don't ripple.
    if (widget.scrollController!.hasClients) {
      _scrollOffset.value = widget.scrollController!.offset;
    }
  }

  void _activateCurrent() {
    final movie = widget.movies[_currentSlide];
    if (widget.onTap != null) {
      widget.onTap!(movie);
    } else {
      _navigateToDetails(context, movie);
    }
  }

  @override
  void dispose() {
    _transitionController.dispose();
    _fillController.dispose();
    widget.scrollController?.removeListener(_onParentScroll);
    _scrollOffset.dispose();
    _currentIndexNotifier.dispose();
    _carouselFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.movies.isEmpty) return const SizedBox.shrink();

    final size = MediaQuery.sizeOf(context);
    // The wide hero layout is a size decision. A television reports 960 dp,
    // which is already past this 900 dp breakpoint, so the device clause that
    // used to be OR-ed in here could never change the answer for one.
    final isDesktop =
        size.width > LayoutConstants.exploreCarouselDesktopBreakpoint;
    // The Home hero on a phone (design A, build 82) is taller, and carries
    // its dots inside the poster, under the button.
    final homeHero = _isHomeHero(isDesktop);
    // Build 109: 0.66 -> 0.64 — the hero is a little shorter (bottom
    // ~1790 px on a 2796 px screen, preview v4). The cut is below the
    // button + dots (see _homeDotsBottom): the poster loses the empty
    // space under the dots, the content block is NOT recompressed.
    final heroHeight = size.height * (homeHero ? 0.64 : 0.60);

    return VisibilityDetector(
      key: const Key('explore-carousel-visibility'),
      // Visibility is still tracked — but only to gate the 5s auto-advance
      // timer (so we don't fire page transitions for an audience that
      // isn't watching). Parallax offset updates ignore this flag; see
      // [_onParentScroll] for the rationale.
      onVisibilityChanged: (info) {
        final visible = info.visibleFraction > 0.1;
        if (visible != _isVisibleOnScreen && mounted) {
          setState(() => _isVisibleOnScreen = visible);
          if (visible) {
            _fillController.forward();
          } else {
            _fillController.stop();
          }
        }
      },
      child: FocusableActionDetector(
        focusNode: _carouselFocusNode,
        // Only auto-focus on TV where D-pad is the primary input. On desktop
        // we skip autofocus so the focus ring doesn't appear on app launch
        // (Flutter defaults to 'traditional' highlight mode until a mouse
        // event arrives, which would show the ring immediately).
        autofocus: false,
        mouseCursor: SystemMouseCursors.click,
        // Arrow keys are wired as explicit Shortcuts/Actions at this level so
        // they fire when _carouselFocusNode has focus. Using a nested
        // Focus(onKeyEvent:) for arrows is unreliable here — that child Focus
        // is a descendant of _carouselFocusNode, and key events only propagate
        // UP from the focused node, so the child's handler never runs. Worse,
        // unhandled arrow keys fall through to Flutter's default ScrollAction
        // which then scrolls the outer vertical CustomScrollView — exactly the
        // "Right pages carousel AND scrolls page vertically" bug we saw.
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.arrowUp): _CarouselUpIntent(),
          SingleActivator(LogicalKeyboardKey.arrowLeft): _CarouselPrevIntent(),
          SingleActivator(LogicalKeyboardKey.arrowRight): _CarouselNextIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activateCurrent();
              return null;
            },
          ),
          _CarouselUpIntent: CallbackAction<_CarouselUpIntent>(
            onInvoke: (_) {
              widget.onNavigateUp?.call();
              return null;
            },
          ),
          _CarouselPrevIntent: CallbackAction<_CarouselPrevIntent>(
            onInvoke: (_) {
              _goToPreviousSlide();
              return null;
            },
          ),
          _CarouselNextIntent: CallbackAction<_CarouselNextIntent>(
            onInvoke: (_) {
              _goToNextSlide();
              return null;
            },
          ),
        },
        onShowFocusHighlight: (show) =>
            setState(() => _isFocusHighlighted = show),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: (details) {
            if (details.primaryVelocity == null) return;
            if (details.primaryVelocity! < -300) {
              _goToNextSlide();
            } else if (details.primaryVelocity! > 300) {
              _goToPreviousSlide();
            }
          },
          // The hero is a rounded CARD (v3; the border went in v8), except
          // with [ExploreCarousel.fullBleed] on a phone, where it runs edge
          // to edge. The dots sit BELOW it, not overlaid on the backdrop
          // the way v2 had them.
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeroCard(context, heroHeight, isDesktop: isDesktop),
              if (widget.movies.length > 1 && !homeHero) ...[
                const SizedBox(height: 12),
                _buildProgressIndicators(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Home's hero on a phone: the tall poster with the centred title, the
  /// meta line, the badge row, one View Details button and the dots
  /// (design A, build 82). The wide layout keeps the preview hero it had.
  /// Browse's TMDB hero is the same layout ([showHomeHero]); only the
  /// source of the items differs.
  bool _isHomeHero(bool isDesktop) =>
      (widget.showPreviewActions || widget.showHomeHero) && !isDesktop;

  /// Where the Home hero's dots sit, from the poster's bottom edge.
  /// Build 109: 26 -> 7 — the hero is shorter (0.64), so the dots sit
  /// just above the new bottom edge and the button + dots keep the
  /// screen rows they had (the cut is below them, the content is not
  /// recompressed and does not move).
  static const double _homeDotsBottom = 7;

  /// The hero as a card: rounded corners, the backdrop clipped inside and
  /// no outline (v8: the thin accent line around it was removed at the
  /// user's request). Only keyboard/TV focus draws a border, as the focus
  /// indicator; touch never does.
  Widget _buildHeroCard(
    BuildContext context,
    double heroHeight, {
    required bool isDesktop,
  }) {
    final border = _isFocusHighlighted
        ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2.5)
        : null;
    // Edge to edge on a phone: square corners, so no dark corner shows
    // against the screen edge. The clip stays either way — the slide
    // transition scales the outgoing backdrop past the card's bounds.
    final edgeToEdge = widget.fullBleed && !isDesktop;
    final radius = edgeToEdge ? BorderRadius.zero : BorderRadius.circular(20);
    final card = AnimatedContainer(
      key: const ValueKey('hero-card'),
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(borderRadius: radius, border: border),
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox(
          height: heroHeight,
          child: _buildCarouselStack(heroHeight, isDesktop: isDesktop),
        ),
      ),
    );
    if (isDesktop) {
      return RepaintBoundary(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            LayoutConstants.dashboardContentPadding,
            LayoutConstants.spacingSm,
            LayoutConstants.dashboardContentPadding,
            0,
          ),
          child: card,
        ),
      );
    }
    if (edgeToEdge) return card;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: card,
    );
  }

  // ---------------------------------------------------------------------------
  // Custom carousel with crossfade + scale transition
  // Entry: scale 0.8→1, opacity 0→1  |  Exit: scale 1→1.2, opacity 1→0  |  400ms
  // ---------------------------------------------------------------------------

  Widget _buildCarouselStack(double height, {required bool isDesktop}) {
    return Stack(
      children: [
        // Previous slide (exiting) — only during transition
        if (_isTransitioning && _previousSlide != null)
          AnimatedBuilder(
            animation: _transitionAnimation,
            builder: (context, _) {
              final t = _transitionAnimation.value;
              return Opacity(
                opacity: 1.0 - t,
                child: Transform.scale(
                  scale: 1.0 + 0.2 * t,
                  child: _buildSlideForIndex(
                    height,
                    _previousSlide!,
                    isDesktop: isDesktop,
                  ),
                ),
              );
            },
          ),

        // Current slide (entering or static)
        _isTransitioning
            ? AnimatedBuilder(
                animation: _transitionAnimation,
                builder: (context, _) {
                  final t = _transitionAnimation.value;
                  return Opacity(
                    opacity: t,
                    child: Transform.scale(
                      scale: 0.8 + 0.2 * t,
                      child: _buildSlideForIndex(
                        height,
                        _currentSlide,
                        isDesktop: isDesktop,
                      ),
                    ),
                  );
                },
              )
            : _buildSlideForIndex(height, _currentSlide, isDesktop: isDesktop),

        // The dots live below the card (see build), not overlaid on the
        // backdrop - except on Home's phone hero, where they sit inside the
        // poster under the button. They are outside the slides, so they do
        // not fade or scale with a slide change.
        if (_isHomeHero(isDesktop) && widget.movies.length > 1)
          Positioned(
            left: 0,
            right: 0,
            bottom: _homeDotsBottom,
            child: IgnorePointer(child: _buildProgressIndicators(round: true)),
          ),
      ],
    );
  }

  Widget _buildProgressIndicators({bool round = false}) {
    return ValueListenableBuilder<int>(
      valueListenable: _currentIndexNotifier,
      builder: (context, currentIndex, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final entry in widget.movies.asMap().entries)
              _ProgressDot(
                key: ValueKey('hcd_${entry.key}'),
                isActive: currentIndex == entry.key,
                fillController: _fillController,
                round: round,
              ),
          ],
        );
      },
    );
  }

  Widget _buildSlideForIndex(
    double height,
    int index, {
    required bool isDesktop,
  }) {
    final movie = widget.movies[index];
    if (widget.scrollController == null) {
      return _buildStaticItem(
        context,
        movie,
        height,
        isDesktop: isDesktop,
        isFirstSlide: index == 0,
      );
    }
    return _buildCarouselItem(
      context,
      movie,
      height,
      isDesktop: isDesktop,
      isFirstSlide: index == 0,
    );
  }

  void _navigateToDetails(BuildContext context, MultimediaItem movie) {
    // Standardize media type mapping (prevents TMDB ID collisions)
    final String mediaType = movie.tmdbMediaType;

    TmdbDetailsRoute(
      movieId: movie.id,
      mediaType: mediaType,
      heroTag: 'hero_${movie.id}',
      source: movie.source,
    ).push<void>(context);
  }

  Widget _buildCarouselItem(
    BuildContext context,
    MultimediaItem movie,
    double height, {
    bool isDesktop = false,
    bool isFirstSlide = false,
  }) {
    final theme = Theme.of(context);
    final scaffoldColor = theme.scaffoldBackgroundColor;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (widget.onTap != null) {
          widget.onTap!(movie);
        } else {
          _navigateToDetails(context, movie);
        }
      },
      child: RepaintBoundary(
        child: ValueListenableBuilder<double>(
          valueListenable: _scrollOffset,
          builder: (context, scrollOffset, child) {
            final parallaxOffset = scrollOffset * 0.1;
            final contentOffset = -scrollOffset * 0.2;
            final opacity = (1.0 - (scrollOffset / (height * 0.5))).clamp(
              0.0,
              1.0,
            );

            return _buildSlideBase(
              context: context,
              movie: movie,
              height: height,
              isDesktop: isDesktop,
              parallaxOffset: parallaxOffset,
              contentOffset: contentOffset,
              opacity: opacity,
              scaffoldColor: scaffoldColor,
              theme: theme,
              isFirstSlide: isFirstSlide,
            );
          },
        ),
      ),
    );
  }

  Widget _buildStaticItem(
    BuildContext context,
    MultimediaItem movie,
    double height, {
    bool isDesktop = false,
    bool isFirstSlide = false,
  }) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (widget.onTap != null) {
          widget.onTap!(movie);
        } else {
          _navigateToDetails(context, movie);
        }
      },
      child: _buildSlideBase(
        context: context,
        movie: movie,
        height: height,
        isDesktop: isDesktop,
        parallaxOffset: 0,
        contentOffset: 0,
        opacity: 1.0,
        scaffoldColor: theme.scaffoldBackgroundColor,
        theme: theme,
        isFirstSlide: isFirstSlide,
      ),
    );
  }

  Widget _buildSlideBase({
    required BuildContext context,
    required MultimediaItem movie,
    required double height,
    required bool isDesktop,
    required double parallaxOffset,
    required double contentOffset,
    required double opacity,
    required Color scaffoldColor,
    required ThemeData theme,
    required bool isFirstSlide,
  }) {
    final title = movie.title;

    const bleed = 60.0;
    final homeHero = _isHomeHero(isDesktop);
    // Home: art without the title printed on it, when the lookup found
    // some AND a logo to put on it; otherwise the plugin's own picture.
    final found = homeHero ? watchHeroEnrichment(ref, movie) : null;
    final cleanArt = found?.artUrl;
    final hasLogo =
        (movie.logoUrl?.isNotEmpty ?? false) ||
        (found?.logoUrl?.isNotEmpty ?? false);
    final imageUrl = cleanArt != null && hasLogo
        ? cleanArt
        : movie.backdropImageUrl;
    final topInset = MediaQuery.paddingOf(context).top;
    final lightPage = theme.brightness == Brightness.light;

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Background Image
          Positioned(
            top: -bleed + parallaxOffset,
            bottom: -bleed - parallaxOffset,
            left: 0,
            right: 0,
            // The box is the slide plus its parallax bleed, and it is not the
            // window: the wide layout pads the carousel, so only the
            // constraints know how big this backdrop is actually painted.
            // They are stable while a slide is up — parallax moves `top` and
            // `bottom` by the same amount, so the height does not change —
            // which matters because a decode bound that changed per frame
            // would be a new image-cache key per frame.
            child: LayoutBuilder(
              builder: (context, constraints) => CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                // TV and desktop fetch `original` backdrops (tmdb_config.dart
                // :78-80) — 1920x1080 at best, 3840x2160 for popular titles,
                // i.e. 8.3-33 MB decoded each, seven of them cycling every
                // 5 s against a 50 MB image cache. Bound to what is painted.
                memCacheWidth: ImageUtils.coverDecodeWidth(
                  context,
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  sourceAspectRatio: ImageUtils.backdropAspectRatio,
                ),
                placeholder: (context, url) =>
                    Container(color: theme.colorScheme.surfaceContainerHighest),
                errorWidget: (_, _, _) =>
                    ThumbnailErrorPlaceholder(label: title, isBackdrop: true),
              ),
            ),
          ),

          // 2. Parallax Gradients
          Positioned(
            top: -bleed + parallaxOffset,
            bottom: -bleed - parallaxOffset,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDesktop
                      ? [
                          Colors.black.withValues(alpha: 0.2),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.45),
                          Colors.black.withValues(alpha: 0.75),
                        ]
                      : homeHero
                      // Home: darker from the title down, so the white
                      // title, meta and badges read on any poster and in
                      // the light themes.
                      ? [
                          Colors.black.withValues(alpha: 0.35),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.6),
                          Colors.black.withValues(alpha: 0.9),
                        ]
                      : [
                          Colors.black.withValues(alpha: 0.3),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.4),
                          Colors.black.withValues(alpha: 0.8),
                        ],
                  stops: isDesktop
                      ? const [0.0, 0.35, 0.75, 1.0]
                      : homeHero
                      ? const [0.0, 0.3, 0.62, 1.0]
                      : const [0.0, 0.4, 0.6, 1.0],
                ),
              ),
            ),
          ),

          // 2.4. Home: a soft black scrim behind the header (logo,
          // buttons, provider line), which sits on top of the art —
          // DARK themes only (build 118). On light themes there is NO
          // top scrim at all (SkyStream): the poster stays fully vivid
          // top to bottom, full-bleed behind the status bar, with the
          // dark header text sitting straight on it. The old light
          // wash (scaffold colour 0.92 -> 0.7 -> 0) fogged the poster
          // top to white; a black scrim in its place hid the top
          // instead ("pura upar ka chupgaya"). Do not re-add either.
          if (homeHero && !lightPage)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: topInset + 150,
              child: IgnorePointer(
                child: DecoratedBox(
                  key: const ValueKey('home-hero-top-scrim'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.6),
                        Colors.black.withValues(alpha: 0.35),
                        Colors.black.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.6, 1.0],
                    ),
                  ),
                ),
              ),
            ),

          // 2.5. Fixed Bottom Feather (eased page transition scrim)
          Positioned(
            bottom: -1,
            left: 0,
            right: 0,
            // Home: a shorter fade, so the dots and the button stay on
            // the dark part of the poster.
            height: homeHero ? 84 : 120,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      scaffoldColor.withValues(alpha: 0.0),
                      scaffoldColor.withValues(alpha: 0.15),
                      scaffoldColor.withValues(alpha: 0.45),
                      scaffoldColor.withValues(alpha: 0.8),
                      scaffoldColor,
                    ],
                    stops: const [0.0, 0.5, 0.75, 0.9, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // 3. Content
          Positioned(
            left: 24,
            right: 24,
            // Home: the content ends above the dots.
            bottom: homeHero
                ? (widget.movies.length > 1 ? _homeDotsBottom + 20 : 44)
                : 48,
            child: Transform.translate(
              offset: Offset(0, contentOffset),
              child: opacity >= 0.999
                  ? _buildCarouselContent(
                      isDesktop: isDesktop,
                      movie: movie,
                      theme: theme,
                      context: context,
                      isFirstSlide: isFirstSlide,
                    )
                  : Opacity(
                      opacity: opacity,
                      child: _buildCarouselContent(
                        isDesktop: isDesktop,
                        movie: movie,
                        theme: theme,
                        context: context,
                        isFirstSlide: isFirstSlide,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCarouselContent({
    required bool isDesktop,
    required MultimediaItem movie,
    required ThemeData theme,
    required BuildContext context,
    required bool isFirstSlide,
  }) {
    if (_isHomeHero(isDesktop)) {
      // Olympus Noir (build 102): Home's phone hero is the cinematic
      // left-aligned layout. Browse (showHomeHero only) keeps design A,
      // so the redesign stays scoped to Home.
      if (widget.showPreviewActions) {
        return _buildOlympusHeroContent(context, movie);
      }
      return _buildHomeHeroContent(context, movie, theme);
    }
    final l10n = AppLocalizations.of(context)!;
    final logoUrl = movie.logoUrl;
    final year = movie.year?.toString() ?? '';
    final genres = movie.tags?.join(' • ') ?? '';

    String? type;
    final mType = movie.mediaType.toLowerCase();
    if (mType == 'movie') {
      type = 'Movie';
    } else if (mType == 'series' || mType == 'tv') {
      type = 'TV Show';
    } else if (mType == 'anime') {
      type = 'Anime';
    } else if (mType == 'livestream') {
      type = 'Live Stream';
    } else {
      type = mType.isNotEmpty
          ? mType[0].toUpperCase() + mType.substring(1)
          : null;
    }

    // +42: the poster-only hero shows no big overlaid title text and no
    // badge pills. The poster's own artwork (or its TMDB logo, when one
    // exists) is the title, and the type lives in the meta line.
    // The preview hero (showPreviewActions, Home only) restores the
    // pre-+42 layout instead: the type moves up into a gold badge pill,
    // the title comes back as big text when there is no logo, and Play /
    // My List / Info actions sit under the meta line.
    final showPreview = widget.showPreviewActions;
    // Preview hero meta: "★ 8.7 · 2024 · 2h 46m · 4K · Sci-Fi".
    // v7: every part is real. The star is the item's own score out of 10
    // (the feed's or the plugin's rating — it used to be printed as a
    // "% Match", which it never was). Quality badges show only when the
    // title or its tags state them (see [statedQualityBadges]); they used
    // to be drawn on every slide with no data behind them.
    final rating = ratingLabel(movie.score);
    final match = rating == null ? null : '★ $rating';
    final qualityBadges = showPreview
        ? statedQualityBadges(movie.title, tags: movie.tags)
        : const <String>[];
    final runtime = _formatRuntime(movie.duration);
    final synopsis = showPreview ? _plainSynopsis(movie.description) : null;
    // The first slide wears the trending badge; the rest wear the type as
    // a gold badge pill above the title.
    final badgeLabel = isFirstSlide
        ? l10n.trendingTodayBadge
        : type?.toUpperCase();
    final metaParts = <String>[
      if (!showPreview && type != null) type,
      if (genres.isNotEmpty) genres,
      if (year.isNotEmpty) year,
    ];
    final meta = metaParts.join(' • ');

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: isDesktop
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        // Preview hero only: the badge pill above the title.
        if (showPreview && badgeLabel != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                badgeLabel,
                style: TextStyle(
                  color: theme.colorScheme.onPrimary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
        // The item's own title logo, when TMDB has one. When there is
        // none, the preview hero falls back to the big title text; the
        // poster-only hero renders nothing here — the backdrop artwork
        // itself is the title (see the CLAYFACE reference: the red logo
        // is part of the poster).
        if (logoUrl != null)
          Padding(
            padding: const EdgeInsets.only(bottom: LayoutConstants.spacingLg),
            child: _buildLogo(logoUrl, isDesktop: isDesktop),
          )
        else if (showPreview)
          Padding(
            padding: const EdgeInsets.only(bottom: LayoutConstants.spacingLg),
            child: Text(
              movie.title.toUpperCase(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: isDesktop ? TextAlign.left : TextAlign.center,
              style:
                  (isDesktop
                          ? theme.textTheme.displaySmall
                          : theme.textTheme.headlineMedium)
                      ?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        height: 1.05,
                      ),
            ),
          ),
        if (showPreview)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: isDesktop ? TextAlign.left : TextAlign.center,
              text: TextSpan(
                style: theme.textTheme.labelLarge?.copyWith(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w600,
                ),
                children: _previewMetaSpans(
                  match: match,
                  year: year,
                  runtime: runtime,
                  qualityBadges: qualityBadges,
                  genres: genres,
                ),
              ),
            ),
          )
        else if (meta.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: isDesktop ? TextAlign.left : TextAlign.center,
              style: theme.textTheme.labelLarge?.copyWith(
                color: Colors.white.withValues(alpha: 0.9),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        // Preview hero only: the two-line synopsis under the meta.
        if (synopsis != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              synopsis,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: isDesktop ? TextAlign.left : TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.85),
                height: 1.35,
              ),
            ),
          ),
        if (showPreview)
          _buildPreviewActions(context, movie, theme, isDesktop)
        else
          // View Details — same destination as tapping the poster.
          ElevatedButton(
            onPressed: () => _openMovie(context, movie),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black87,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
              shape: const StadiumBorder(),
              textStyle: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            child: Text(l10n.viewDetails),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Home hero, design A (build 82): centred title logo, one small meta
  // line, one small badge row, a white View Details pill. The dots are
  // drawn by the card (see _buildCarouselStack).
  // ---------------------------------------------------------------------

  static const TextStyle _homeMetaStyle = TextStyle(
    color: Colors.white,
    fontSize: 13,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );

  Widget _buildHomeHeroContent(
    BuildContext context,
    MultimediaItem plain,
    ThemeData theme,
  ) {
    final l10n = AppLocalizations.of(context)!;
    // Build 85: what the plugin does not say is looked up on TMDB. Null
    // until it arrives, and for good on a miss - the hero then shows
    // only the plugin's own data, as before.
    final found = watchHeroEnrichment(ref, plain);
    final movie = found?.applyTo(plain) ?? plain;
    final logoUrl = movie.logoUrl;
    final badges = heroBadges(
      movie,
      language: found?.language,
      statusLabel: found?.status,
      scoreIsImdb:
          found != null && found.scoreIsImdb && movie.score == found.imdbScore,
    );
    final hasMeta = heroMetaParts(movie).isNotEmpty;

    return Column(
      key: const ValueKey('home-hero-content'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // The title: its own logo when the item has one, else its name.
        if (logoUrl != null && logoUrl.isNotEmpty)
          _buildHomeLogo(logoUrl, movie.title, theme)
        else
          _buildHomeTitleText(movie.title, theme),
        if (hasMeta) ...[const SizedBox(height: 10), _buildHomeMetaLine(movie)],
        if (!badges.isEmpty) ...[
          const SizedBox(height: 6),
          _buildHomeBadgeRow(badges),
        ],
        const SizedBox(height: 12),
        // View Details - same destination as tapping the poster.
        ElevatedButton(
          key: const ValueKey('home-hero-view-details'),
          onPressed: () => _openMovie(context, plain),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            elevation: 0,
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 10),
            shape: const StadiumBorder(),
            tapTargetSize: MaterialTapTargetSize.padded,
            textStyle: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          child: Text(l10n.viewDetails, maxLines: 1, softWrap: false),
        ),
      ],
    );
  }

  /// Olympus Noir hero (build 102) — the cinematic left-aligned layout
  /// that replaces design A on Home only: gold "NOW FEATURED" label,
  /// large title, one meta line, real-data badge row, metallic-gold
  /// "Explore Film" button + bookmark. Every part is the item's own
  /// data (plugin + TMDB enrichment, same as design A) — nothing is
  /// hardcoded, so any featured title renders in this language.
  Widget _buildOlympusHeroContent(BuildContext context, MultimediaItem plain) {
    final found = watchHeroEnrichment(ref, plain);
    final movie = found?.applyTo(plain) ?? plain;
    final logoUrl = movie.logoUrl;
    // My List state for the current slide, watched the same way the
    // details screen watches it (library match on the item URL).
    final isBookmarked = ref.watch(
      libraryProvider.select(
        (state) =>
            state is LibrarySuccess &&
            state.items.any((i) => i.url == movie.url),
      ),
    );
    // The score and whether it is IMDb's — the same rule design A used
    // (an add-on title's score is IMDb's, a plugin's is a plain star):
    // Olympus drops the certification chip and the language, but the
    // score keeps its IMDb badge when it is one.
    final badges = heroBadges(
      movie,
      language: found?.language,
      statusLabel: found?.status,
      scoreIsImdb:
          found != null && found.scoreIsImdb && movie.score == found.imdbScore,
    );
    final qualityBadges = statedQualityBadges(movie.title, tags: movie.tags);

    return Column(
      key: const ValueKey('olympus-hero-content'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Gold "NOW FEATURED" label alone (build 111, user 2026-11-21
        // 04:03: the hairline next to it stretched across the whole
        // hero and read as a stray line cutting the poster — removed).
        const Text(
          'NOW FEATURED',
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            color: kOlympusGold,
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 2.0,
          ),
        ),
        const SizedBox(height: 10),
        // The title: its own logo when the item has one, else its name
        // in large uppercase text.
        if (logoUrl != null && logoUrl.isNotEmpty)
          _buildOlympusLogo(logoUrl, movie.title)
        else
          _buildOlympusTitleText(movie.title),
        if (_olympusMetaParts(movie).isNotEmpty) ...[
          const SizedBox(height: 8),
          _buildOlympusMetaLine(movie),
        ],
        if (badges.score != null || qualityBadges.isNotEmpty) ...[
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              key: const ValueKey('olympus-hero-badges'),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (badges.score != null)
                  Container(
                    height: 22,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (badges.scoreIsImdb)
                          Container(
                            height: 16,
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5C518),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: const Text(
                              'IMDb',
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(
                                color: Colors.black,
                                fontSize: 10,
                                height: 1.0,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          )
                        else
                          const Icon(
                            Icons.star_rounded,
                            size: 14,
                            color: Color(0xFFF5C518),
                          ),
                        const SizedBox(width: 3),
                        Text(
                          badges.score!,
                          maxLines: 1,
                          softWrap: false,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                for (final badge in qualityBadges) ...[
                  const SizedBox(width: 6),
                  Container(
                    height: 22,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                    child: Text(
                      // "Dolby Vision" reads as "Dolby" on the badge.
                      badge == 'Dolby Vision' ? 'Dolby' : badge,
                      maxLines: 1,
                      softWrap: false,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            // Explore Film — metallic gold, same destination as tapping
            // the poster. Flexible with a scale-down label: on a narrow
            // phone the button shrinks instead of overflowing the row.
            Flexible(
              child: FilledButton.icon(
                key: const ValueKey('olympus-hero-explore-film'),
                onPressed: () => _openMovie(context, plain),
                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('EXPLORE FILM', maxLines: 1, softWrap: false),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: kOlympusGold,
                  foregroundColor: Colors.black,
                  elevation: 0,
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  tapTargetSize: MaterialTapTargetSize.padded,
                  textStyle: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Bookmark — filled gold once the item is saved.
            SizedBox(
              width: 48,
              height: 48,
              child: OutlinedButton(
                key: const ValueKey('olympus-hero-bookmark'),
                onPressed: () => _toggleLibrary(movie),
                style: OutlinedButton.styleFrom(
                  foregroundColor: isBookmarked ? kOlympusGold : Colors.white,
                  backgroundColor: isBookmarked
                      ? kOlympusGold.withValues(alpha: 0.20)
                      : Colors.black.withValues(alpha: 0.25),
                  elevation: 0,
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  side: BorderSide(
                    color: isBookmarked
                        ? kOlympusGold
                        : Colors.white.withValues(alpha: 0.4),
                  ),
                ),
                child: Icon(
                  isBookmarked
                      ? Icons.bookmark_added_rounded
                      : Icons.bookmark_add_outlined,
                  size: 22,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// The Olympus meta line's parts, in order: year, up to [maxGenres]
  /// genres (uppercased), runtime. Only what the item has; empty when
  /// it has none of them.
  List<String> _olympusMetaParts(MultimediaItem movie, {int maxGenres = 1}) {
    final year = movie.year;
    return <String>[
      if (year != null && year > 1800 && year < 2200) '$year',
      ...heroGenres(movie).take(maxGenres).map((g) => g.toUpperCase()),
      ?heroRuntimeLabel(movie.duration),
    ];
  }

  /// The Olympus meta line as text ("2026 • Science Fiction • 2h 15m"),
  /// or null when there is nothing to say.
  String? _olympusMetaLine(MultimediaItem movie, {int maxGenres = 1}) {
    final parts = _olympusMetaParts(movie, maxGenres: maxGenres);
    return parts.isEmpty ? null : parts.join(kHeroDot);
  }

  /// "2026 • Action, Adventure • 2h 53m" on ONE small line. A second
  /// genre is shown only when the line still fits; if even one genre is
  /// too wide the line scales down. It never wraps — the same rule
  /// design A used, so long genre names stay legible instead of
  /// shrinking to nothing.
  Widget _buildOlympusMetaLine(MultimediaItem movie) {
    const style = TextStyle(
      color: Colors.white,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      shadows: [Shadow(color: Color(0x99000000), blurRadius: 8)],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        var line = _olympusMetaLine(movie)!;
        final wider = _olympusMetaLine(movie, maxGenres: 2)!;
        if (wider != line) {
          final painter = TextPainter(
            text: TextSpan(text: wider, style: style),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          if (painter.width <= constraints.maxWidth) line = wider;
          painter.dispose();
        }
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            line,
            key: const ValueKey('olympus-hero-meta'),
            maxLines: 1,
            softWrap: false,
            style: style,
          ),
        );
      },
    );
  }

  /// The Olympus title as text: uppercase, left-aligned, it wraps then
  /// shrinks to fit the box — it is never cut off with an ellipsis.
  Widget _buildOlympusTitleText(String title) {
    return LayoutBuilder(
      builder: (context, constraints) => ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 100),
        child: FittedBox(
          key: const ValueKey('olympus-hero-title'),
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: Text(
              title.toUpperCase(),
              textAlign: TextAlign.left,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 38,
                fontWeight: FontWeight.w900,
                height: 1.02,
                letterSpacing: 0.5,
                shadows: [Shadow(color: Color(0x99000000), blurRadius: 12)],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The Olympus title's logo, left-aligned. While it loads the space is
  /// kept; if it fails the title's name stands in, so a slide is never
  /// left without a title.
  Widget _buildOlympusLogo(String logoUrl, String title) {
    const height = 72.0;
    const width = 240.0;
    if (logoUrl.toLowerCase().endsWith('.svg')) {
      return SvgPicture.network(
        logoUrl,
        height: height,
        width: width,
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        placeholderBuilder: (context) =>
            const SizedBox(height: height, width: width),
        errorBuilder: (context, error, stackTrace) =>
            _buildOlympusTitleText(title),
      );
    }
    return CachedNetworkImage(
      imageUrl: logoUrl,
      height: height,
      width: width,
      fit: BoxFit.contain,
      alignment: Alignment.centerLeft,
      placeholder: (context, url) =>
          const SizedBox(height: height, width: width),
      errorWidget: (context, url, error) => _buildOlympusTitleText(title),
    );
  }

  /// The title as text: it wraps, then shrinks to fit the box - it is
  /// never cut off with an ellipsis.
  Widget _buildHomeTitleText(String title, ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) => ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 84),
        child: FittedBox(
          key: const ValueKey('home-hero-title'),
          fit: BoxFit.scaleDown,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium?.copyWith(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.w800,
                height: 1.05,
                shadows: const [
                  Shadow(color: Color(0x99000000), blurRadius: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The title's logo. While it loads the space is kept; if it fails the
  /// title's name stands in, so a slide is never left without a title.
  Widget _buildHomeLogo(String logoUrl, String title, ThemeData theme) {
    const height = 96.0;
    const width = 260.0;
    if (logoUrl.toLowerCase().endsWith('.svg')) {
      return SvgPicture.network(
        logoUrl,
        height: height,
        width: width,
        fit: BoxFit.contain,
        placeholderBuilder: (context) =>
            const SizedBox(height: height, width: width),
        errorBuilder: (context, error, stackTrace) =>
            _buildHomeTitleText(title, theme),
      );
    }
    return CachedNetworkImage(
      imageUrl: logoUrl,
      height: height,
      width: width,
      fit: BoxFit.contain,
      alignment: Alignment.bottomCenter,
      placeholder: (context, url) =>
          const SizedBox(height: height, width: width),
      errorWidget: (context, url, error) => _buildHomeTitleText(title, theme),
    );
  }

  /// "Type • Genre • Runtime • Year" on ONE small line. A second genre is
  /// shown only when the line still fits; if even one genre is too wide
  /// the line scales down. It never wraps.
  Widget _buildHomeMetaLine(MultimediaItem movie) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        var line = heroMetaLine(movie)!;
        final wider = heroMetaLine(movie, maxGenres: 2)!;
        if (wider != line) {
          final painter = TextPainter(
            text: TextSpan(text: wider, style: _homeMetaStyle),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          if (painter.width <= constraints.maxWidth) line = wider;
          painter.dispose();
        }
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            line,
            key: const ValueKey('home-hero-meta'),
            maxLines: 1,
            softWrap: false,
            style: _homeMetaStyle,
          ),
        );
      },
    );
  }

  /// The badge row on ONE small line: outlined chip, rating, language -
  /// each only when the item carries it. On a narrow screen the language
  /// goes first; after that the row scales down. It never wraps.
  Widget _buildHomeBadgeRow(HeroBadges all) {
    const text = TextStyle(
      color: Colors.white,
      fontSize: 11.5,
      height: 1.0,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
    );
    const gold = Color(0xFFF5C518);
    return LayoutBuilder(
      builder: (context, constraints) {
        final badges = constraints.maxWidth < 240 && all.count > 1
            ? all.withoutLanguage()
            : all;
        final items = <Widget>[
          if (badges.chip != null)
            Container(
              key: const ValueKey('home-hero-chip'),
              height: 20,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: Colors.white.withValues(alpha: 0.6)),
              ),
              child: Text(
                badges.chip!,
                maxLines: 1,
                softWrap: false,
                style: text.copyWith(letterSpacing: 0.8),
              ),
            ),
          if (badges.score != null)
            Row(
              key: const ValueKey('home-hero-score'),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (badges.scoreIsImdb)
                  Container(
                    key: const ValueKey('home-hero-imdb'),
                    height: 16,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: gold,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const Text(
                      'IMDb',
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 10,
                        height: 1.0,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  )
                else
                  const Icon(Icons.star_rounded, size: 15, color: gold),
                const SizedBox(width: 4),
                Text(
                  badges.score!,
                  maxLines: 1,
                  softWrap: false,
                  style: text.copyWith(color: gold, fontSize: 12),
                ),
              ],
            ),
          if (badges.language != null)
            Text(
              badges.language!,
              key: const ValueKey('home-hero-language'),
              maxLines: 1,
              softWrap: false,
              style: text,
            ),
        ];
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            key: const ValueKey('home-hero-badges'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text('\u2022', style: text),
                  ),
                items[i],
              ],
            ],
          ),
        );
      },
    );
  }

  /// The preview hero's meta line, as one ellipsis-clamped line:
  /// "[rating] · [year] · [runtime] · [stated quality] · [genres]".
  /// Segments that have nothing to say are skipped, so a bare item still
  /// reads as one line instead of a row of stray separators.
  List<InlineSpan> _previewMetaSpans({
    required String? match,
    required String year,
    required String? runtime,
    required List<String> qualityBadges,
    required String genres,
  }) {
    final spans = <InlineSpan>[];
    void add(String text, {TextStyle? style}) {
      if (spans.isNotEmpty) {
        spans.add(const TextSpan(text: ' · '));
      }
      spans.add(TextSpan(text: text, style: style));
    }

    if (match != null) {
      add(
        match,
        style: const TextStyle(
          color: Color(0xFF46D369),
          fontWeight: FontWeight.w800,
        ),
      );
    }
    if (year.isNotEmpty) add(year);
    if (runtime != null) add(runtime);
    // Only what the title itself states (v7) — nothing stated, no badge.
    for (final badge in qualityBadges) {
      add(
        badge,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      );
    }
    if (genres.isNotEmpty) add(genres);
    return spans;
  }

  /// Minutes as the preview's runtime ("2h 46m", "24m"), or null when the
  /// item carries no duration.
  String? _formatRuntime(int? minutes) {
    if (minutes == null || minutes <= 0) return null;
    if (minutes < 60) return '${minutes}m';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '${hours}h' : '${hours}h ${rest}m';
  }

  /// A description as plain text for the hero synopsis: AniList ships
  /// descriptions as HTML (`<br>`, `<i>`, …), which a Text widget would
  /// print raw. Tags become spaces, entities are unescaped, and runs of
  /// whitespace collapse, so the two-line clamp counts real words.
  String? _plainSynopsis(String? raw) {
    if (raw == null) return null;
    final text = HtmlUnescape()
        .convert(raw.replaceAll(RegExp('<[^>]*>'), ' '))
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.isEmpty ? null : text;
  }

  /// Play / My List / Info for the preview hero (Home only).
  ///
  /// Play is the primary gold button; My List and Info are dark glass
  /// pills. All four labels come from l10n.
  Widget _buildPreviewActions(
    BuildContext context,
    MultimediaItem movie,
    ThemeData theme,
    bool isDesktop,
  ) {
    final l10n = AppLocalizations.of(context)!;
    // My List state for the current slide, watched the same way the
    // details screen watches it (library match on the item URL).
    final isBookmarked = ref.watch(
      libraryProvider.select(
        (state) =>
            state is LibrarySuccess &&
            state.items.any((i) => i.url == movie.url),
      ),
    );

    const buttonPadding = EdgeInsets.symmetric(horizontal: 20, vertical: 12);
    const buttonText = TextStyle(fontSize: 15, fontWeight: FontWeight.w700);
    final glassStyle = FilledButton.styleFrom(
      backgroundColor: Colors.white.withValues(alpha: 0.16),
      foregroundColor: Colors.white,
      elevation: 0,
      padding: buttonPadding,
      shape: const StadiumBorder(),
      textStyle: buttonText,
    );

    return Wrap(
      alignment: isDesktop ? WrapAlignment.start : WrapAlignment.center,
      spacing: 10,
      runSpacing: 10,
      children: [
        // Play — primary gold button; Home wires it to details + autoPlay.
        FilledButton.icon(
          onPressed: () => _playMovie(context, movie),
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(l10n.play),
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            elevation: 0,
            padding: buttonPadding,
            shape: const StadiumBorder(),
            textStyle: buttonText,
          ),
        ),
        // My List — filled bookmark once the item is saved.
        FilledButton.icon(
          onPressed: () => _toggleLibrary(movie),
          icon: Icon(
            isBookmarked
                ? Icons.bookmark_added_rounded
                : Icons.bookmark_add_outlined,
          ),
          label: Text(l10n.myList),
          style: glassStyle,
        ),
        // Info — same destination as tapping the poster.
        FilledButton.icon(
          onPressed: () => _openMovie(context, movie),
          icon: const Icon(Icons.info_outline_rounded),
          label: Text(l10n.info),
          style: glassStyle,
        ),
      ],
    );
  }

  /// Opens an item's details — the same destination as tapping the hero
  /// poster itself (+42: the View Details button reuses it).
  void _openMovie(BuildContext context, MultimediaItem movie) {
    if (widget.onTap != null) {
      widget.onTap!(movie);
    } else {
      _navigateToDetails(context, movie);
    }
  }

  /// Play for the preview hero: the caller's handler when one is set (Home
  /// pushes details with autoPlay), otherwise the same destination as
  /// tapping the poster.
  void _playMovie(BuildContext context, MultimediaItem movie) {
    if (widget.onPlay != null) {
      widget.onPlay!(movie);
    } else {
      _openMovie(context, movie);
    }
  }

  /// My List toggle for the preview hero: the same library the details
  /// screen and the Library tab read, matched on the item URL.
  void _toggleLibrary(MultimediaItem movie) {
    final notifier = ref.read(libraryProvider.notifier);
    if (notifier.isBookmarked(movie.url)) {
      unawaited(notifier.removeItem(movie.url));
    } else {
      unawaited(notifier.addItem(movie));
    }
  }

  /// The item's own title logo (TMDB), when one exists. A failed load
  /// renders nothing — never the giant fallback title (+42).
  Widget _buildLogo(String logoUrl, {bool isDesktop = false}) {
    if (logoUrl.toLowerCase().endsWith('.svg')) {
      return SvgPicture.network(
        logoUrl,
        height: 140,
        width: 300,
        fit: BoxFit.contain,
        placeholderBuilder: (context) =>
            const SizedBox(height: 140, width: 300),
        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
      );
    }
    return CachedNetworkImage(
      imageUrl: logoUrl,
      height: 140,
      width: 300,
      fit: BoxFit.contain,
      alignment: Alignment.bottomCenter,
      placeholder: (context, url) => const SizedBox(height: 140, width: 300),
      errorWidget: (context, url, error) => const SizedBox.shrink(),
    );
  }
}

/// A single progress dot whose width animates with spring physics.
///
/// When [isActive] toggles the dot springs between inactive (11 px) and active
/// (35 px) width. The active dot also renders a fill bar driven by
/// [fillController] that grows from 0 % → 100 % over the auto-advance interval.
///
/// Each dot manages its own [AnimationController] for the spring width
/// transition — only two dots tick per toggle. The fill bar is a separate
/// [AnimatedBuilder] that exists only on the active dot, so per-frame fill
/// rebuilds are limited to exactly one dot.
class _ProgressDot extends StatefulWidget {
  final bool isActive;
  final AnimationController fillController;

  /// Home's hero (build 82): round 6 px dots, the active one a 22 px pill.
  final bool round;

  const _ProgressDot({
    super.key,
    required this.isActive,
    required this.fillController,
    this.round = false,
  });

  @override
  State<_ProgressDot> createState() => _ProgressDotState();
}

class _ProgressDotState extends State<_ProgressDot>
    with SingleTickerProviderStateMixin {
  static const double _activeWidth = 35.0;
  static const double _inactiveWidth = 11.0;
  static const double _height = 4.0;

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _controller.value = widget.isActive ? 1.0 : 0.0;
  }

  @override
  void didUpdateWidget(_ProgressDot old) {
    super.didUpdateWidget(old);
    if (widget.isActive != old.isActive) {
      _animateToTarget();
    }
  }

  void _animateToTarget() {
    _controller.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 300, damping: 30),
        _controller.value,
        widget.isActive ? 1.0 : 0.0,
        0,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final round = widget.round;
        final activeWidth = round ? 22.0 : _activeWidth;
        final inactiveWidth = round ? 6.0 : _inactiveWidth;
        final height = round ? 6.0 : _height;
        final radius = round ? 3.0 : 2.0;
        final width = inactiveWidth + (activeWidth - inactiveWidth) * t;

        return Container(
          width: width,
          height: height,
          margin: const EdgeInsets.symmetric(horizontal: 3.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            // Olympus Noir (build 102): the home hero's round dots wear
            // the design gold; the other (rectangular) indicators keep
            // their white.
            color: round
                ? (widget.isActive
                      ? kOlympusGold.withValues(alpha: 0.30)
                      : Colors.white.withValues(alpha: 0.35))
                : Colors.white.withValues(alpha: widget.isActive ? 0.3 : 0.2),
          ),
          child: widget.isActive
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
                  child: AnimatedBuilder(
                    animation: widget.fillController,
                    builder: (context, _) {
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: activeWidth * widget.fillController.value,
                          height: height,
                          color: round
                              ? kOlympusGold
                              : Colors.white.withValues(alpha: 0.9),
                        ),
                      );
                    },
                  ),
                )
              : null,
        );
      },
    );
  }
}
