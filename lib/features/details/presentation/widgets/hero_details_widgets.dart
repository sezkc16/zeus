import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The pieces of the phone details page ("Hero" layout): a full-bleed banner
/// with the source tag and title on it and a round Play button on its lower
/// edge, a one-card info strip, a three-line synopsis, and episodes as a
/// horizontal row of thumbnail cards. Shared by the plugin, add-on and
/// catalogue details screens so the three read as one page.

/// How tall the banner is on a screen of [screen]: a little under half of a
/// portrait phone's first view, and most of a landscape one's without
/// pushing everything else off it.
double detailsHeroBannerHeight(Size screen) {
  final landscape = screen.width > screen.height;
  return landscape
      ? (screen.height * 0.75).clamp(200.0, 400.0)
      : (screen.height * 0.46).clamp(280.0, 440.0);
}

/// How far the Play button hangs below the banner: half of it.
const double kDetailsPlayFabSize = 56;
const double kDetailsPlayFabOverhang = kDetailsPlayFabSize / 2;

/// The banner: [image] edge to edge, fading into the page at its foot, with
/// the source tag and the title over its lower left and [playFab] straddling
/// its lower right edge.
class DetailsHeroBanner extends StatelessWidget {
  const DetailsHeroBanner({
    super.key,
    required this.image,
    required this.title,
    required this.height,
    this.sourceTag,
    this.subtitle,
    this.playFab,
    this.onTitleLongPress,
  });

  /// The backdrop (or the poster standing in for it), already sized to cover.
  final Widget image;
  final String title;
  final double height;

  /// A [DetailsSourceTag], or whatever else names where the title is from.
  final Widget? sourceTag;

  /// A muted line under the title (genres), when the page has one.
  final String? subtitle;

  /// The round Play button, or null when there is nothing to play yet.
  final Widget? playFab;

  final VoidCallback? onTitleLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final page = theme.scaffoldBackgroundColor;
    final hasFab = playFab != null;
    final titleText = Text(
      title,
      key: const ValueKey('details-hero-title'),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w800,
        height: 1.1,
        color: theme.colorScheme.onSurface,
      ),
    );

    return SizedBox(
      key: const ValueKey('details-hero-banner'),
      height: height + (hasFab ? kDetailsPlayFabOverhang : 0),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                image,
                // The page's colour rising from the foot, so the title reads
                // in either theme and the art has no hard lower edge.
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          page.withValues(alpha: 0.0),
                          page.withValues(alpha: 0.35),
                          page.withValues(alpha: 0.82),
                          page,
                        ],
                        stops: const [0.35, 0.62, 0.86, 1.0],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: hasFab ? 16 + kDetailsPlayFabSize + 12 : 16,
                  bottom: 14,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (sourceTag != null) ...[
                        sourceTag!,
                        const SizedBox(height: 8),
                      ],
                      if (onTitleLongPress == null)
                        titleText
                      else
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onLongPress: onTitleLongPress,
                          child: titleText,
                        ),
                      if (subtitle != null && subtitle!.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.7,
                            ),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (hasFab) Positioned(right: 16, bottom: 0, child: playFab!),
        ],
      ),
    );
  }
}

/// Where a title is from, as a small outlined chip in the accent colour:
/// "ANIKOTO".
class DetailsSourceTag extends StatelessWidget {
  const DetailsSourceTag({super.key, required this.label, this.debug = false});

  final String label;

  /// A plugin loaded for debugging says so beside its name.
  final bool debug;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Container(
      key: const ValueKey('details-source-tag'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        // Enough of the page behind it that the outline reads over bright art.
        color: theme.scaffoldBackgroundColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accent, width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: accent,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
          ),
          if (debug) ...[
            const SizedBox(width: 6),
            Text(
              'DEBUG',
              style: TextStyle(
                color: theme.colorScheme.error,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The round Play button on the banner's edge. [label] is what a full-width
/// Play button would have read ("Play E1", "Resume E3"): here it is the
/// tooltip and what a screen reader says.
class DetailsPlayFab extends StatelessWidget {
  const DetailsPlayFab({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.focusNode,
  });

  final String label;

  /// Null while there is nothing to play yet: the button stays, dimmed.
  final VoidCallback? onPressed;

  /// Its links are being resolved: a spinner stands in for the play icon.
  final bool loading;

  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final fill = enabled
        ? colors.primary
        : Color.alphaBlend(
            colors.onSurface.withValues(alpha: 0.12),
            colors.surfaceContainerHighest,
          );
    final ink = enabled
        ? colors.onPrimary
        : colors.onSurface.withValues(alpha: 0.38);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: Material(
          key: const ValueKey('details-play-fab'),
          color: fill,
          shape: const CircleBorder(),
          elevation: enabled ? 6 : 0,
          shadowColor: Colors.black.withValues(alpha: 0.5),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            focusNode: focusNode,
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: kDetailsPlayFabSize,
              height: kDetailsPlayFabSize,
              child: Center(
                child: loading
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: ink,
                        ),
                      )
                    : Icon(Icons.play_arrow_rounded, size: 32, color: ink),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The back button and the page's other top actions, floating over the
/// banner and staying put as the page scrolls under them.
class DetailsHeroTopBar extends StatelessWidget {
  const DetailsHeroTopBar({
    super.key,
    this.leading,
    this.actions = const [],
    this.scrollOffset,
  });

  final Widget? leading;
  final List<Widget> actions;

  /// How far the page under the bar has scrolled. With it, the bar grows a
  /// backing in the page's colour as the page scrolls (v8), so content
  /// never shows through the clock and battery or under the back button.
  /// Nothing is drawn over the banner while the page is at the top.
  final ValueListenable<double>? scrollOffset;

  /// The scroll distance over which the backing fades in.
  static const double scrimFadeDistance = 140;

  /// A round, dark-backed icon button that reads over any artwork.
  static Widget button({
    Key? key,
    required IconData icon,
    required VoidCallback onPressed,
    String? tooltip,
    Color? iconColor,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      icon: Icon(icon, color: iconColor ?? Colors.white, size: 22),
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black45,
        foregroundColor: Colors.white,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bar = SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            ?leading,
            const Spacer(),
            for (final action in actions) ...[action, const SizedBox(width: 4)],
          ],
        ),
      ),
    );
    final offset = scrollOffset;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: offset == null
          ? bar
          : ValueListenableBuilder<double>(
              valueListenable: offset,
              child: bar,
              builder: (context, value, child) {
                final shown = (value / scrimFadeDistance).clamp(0.0, 1.0);
                return ColoredBox(
                  key: const ValueKey('details-top-scrim'),
                  color: Theme.of(context).scaffoldBackgroundColor
                      .withValues(alpha: shown),
                  child: child,
                );
              },
            ),
    );
  }
}

/// One column of the info strip: [value] in bold over a small muted [label].
class DetailsInfoColumn {
  const DetailsInfoColumn({required this.value, required this.label});

  final String value;
  final String label;
}

/// Year, episodes, runtime, status: one rounded card of up to four equal
/// columns. Only what the title really has is passed in; with nothing to
/// show there is no card.
class DetailsInfoStrip extends StatelessWidget {
  const DetailsInfoStrip({super.key, required this.columns});

  final List<DetailsInfoColumn> columns;

  static const int maxColumns = 4;

  @override
  Widget build(BuildContext context) {
    final shown = columns
        .where((c) => c.value.trim().isNotEmpty)
        .take(maxColumns)
        .toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      key: const ValueKey('details-info-strip'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0)
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  indent: 4,
                  endIndent: 4,
                  color: colors.outlineVariant.withValues(alpha: 0.4),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        shown[i].value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        shown[i].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The synopsis, three lines until "more" is tapped and all of it until
/// "less" is. A text that fits has no toggle.
class ExpandableSynopsis extends StatefulWidget {
  const ExpandableSynopsis({
    super.key,
    required this.text,
    this.maxLines = 3,
    this.moreLabel = 'more',
    this.lessLabel = 'less',
  });

  final String text;
  final int maxLines;
  final String moreLabel;
  final String lessLabel;

  @override
  State<ExpandableSynopsis> createState() => _ExpandableSynopsisState();
}

class _ExpandableSynopsisState extends State<ExpandableSynopsis> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
      height: 1.45,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: widget.maxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();

        return AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.text,
                maxLines: _expanded ? null : widget.maxLines,
                overflow: _expanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: style,
              ),
              if (overflows || _expanded)
                InkWell(
                  key: const ValueKey('details-synopsis-more'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.only(
                      top: 4,
                      bottom: 4,
                      right: 12,
                    ),
                    child: Text(
                      _expanded ? widget.lessLabel : widget.moreLabel,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// How wide an episode's card is in the row, and the gap after it.
const double kEpisodeRowCardWidth = 160;
const double kEpisodeRowCardGap = 12;

/// How tall the row has to be for a card at the current text size: the 16:9
/// thumbnail and the two lines under it.
double episodeRowHeight(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  return kEpisodeRowCardWidth * 9 / 16 +
      8 +
      scaler.scale(13) * 1.4 +
      2 +
      scaler.scale(11) * 1.4 +
      4;
}

/// One episode in the row: a 16:9 thumbnail with its state drawn on it, then
/// "1 · Episode 1" and a small muted line. What it does is its owner's.
class EpisodeRowCard extends StatelessWidget {
  const EpisodeRowCard({
    super.key,
    required this.title,
    required this.thumbnail,
    required this.onTap,
    this.number,
    this.meta,
    this.metaAccent = false,
    this.progress = 0,
    this.watched = false,
    this.badge,
    this.selectionMode = false,
    this.selected = false,
    this.upcoming = false,
    this.loading = false,
    this.focused = false,
    this.action,
    this.onLongPress,
    this.focusNode,
  });

  final int? number;
  final String title;

  /// Runtime and date ("24m · 1/4/2025"), or when it airs.
  final String? meta;

  /// [meta] in the accent colour: an episode not out yet.
  final bool metaAccent;

  /// The episode's still, or the placeholder standing in for it.
  final Widget thumbnail;

  /// 0..1, drawn as a bar along the thumbnail's foot.
  final double progress;
  final bool watched;

  /// "WATCHED", "WATCHING", "LAST WATCHED" and the like, top left.
  final String? badge;

  /// Episodes are being picked: the corner shows a tick box, not [action].
  final bool selectionMode;
  final bool selected;
  final bool upcoming;
  final bool loading;
  final bool focused;

  /// The thumbnail's top-right corner: the download button.
  final Widget? action;

  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final radius = BorderRadius.circular(10);
    final label = number == null ? title : '$number · $title';

    return SizedBox(
      width: kEpisodeRowCardWidth,
      child: InkWell(
        focusNode: focusNode,
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: radius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: radius,
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        thumbnail,
                        if (watched)
                          IgnorePointer(
                            child: ColoredBox(
                              color: Colors.black.withValues(alpha: 0.38),
                            ),
                          ),
                        if (selected)
                          IgnorePointer(
                            child: ColoredBox(
                              color: colors.primary.withValues(alpha: 0.30),
                            ),
                          ),
                        Center(
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              shape: BoxShape.circle,
                            ),
                            child: loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Icon(
                                    selectionMode
                                        ? (selected
                                              ? Icons.check_rounded
                                              : Icons.add_rounded)
                                        : watched
                                        ? Icons.check_rounded
                                        : upcoming
                                        ? Icons.schedule_rounded
                                        : Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                          ),
                        ),
                        if (progress > 0)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: LinearProgressIndicator(
                              key: const ValueKey('episode-row-progress'),
                              value: progress.clamp(0.0, 1.0),
                              minHeight: 3,
                              backgroundColor: Colors.black38,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                colors.primary,
                              ),
                            ),
                          ),
                        if (badge != null)
                          Positioned(
                            top: 6,
                            left: 6,
                            right: 40,
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: colors.primary.withValues(alpha: 0.9),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  badge!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: colors.onPrimary,
                                    fontSize: 8.5,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                // Focus / selection outline, over the clip so it is not cut.
                if (selected || focused)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: radius,
                          border: Border.all(
                            color: selected ? colors.primary : colors.onSurface,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: selectionMode
                      ? _corner(
                          Icon(
                            selected
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            key: const ValueKey('episode-row-select-mark'),
                            size: 20,
                            color: selected ? colors.primary : Colors.white,
                          ),
                        )
                      : (action ?? const SizedBox.shrink()),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                fontWeight: FontWeight.w700,
                color: watched
                    ? colors.onSurface.withValues(alpha: 0.65)
                    : colors.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              meta ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: metaAccent ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _corner(Widget child) => Container(
    width: 30,
    height: 30,
    decoration: const BoxDecoration(
      color: Colors.black54,
      shape: BoxShape.circle,
    ),
    alignment: Alignment.center,
    child: child,
  );

  /// A small round button for the thumbnail's top-right corner.
  static Widget cornerButton({
    Key? key,
    required Widget child,
    required VoidCallback onPressed,
    String? tooltip,
    FocusNode? focusNode,
  }) {
    final button = Material(
      key: key,
      color: Colors.black54,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        focusNode: focusNode,
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(width: 30, height: 30, child: Center(child: child)),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// Episodes side by side, built only as they scroll into view, so a series
/// of hundreds costs what a screenful does. Opens at [initialIndex] (the
/// episode to resume) and can be sent to any other with
/// [HorizontalEpisodeRowState.scrollToIndex], which is how a range picker
/// moves it.
class HorizontalEpisodeRow extends StatefulWidget {
  const HorizontalEpisodeRow({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.initialIndex = 0,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.onFirstVisibleChanged,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final int initialIndex;
  final EdgeInsets padding;

  /// Called when a scroll comes to rest with the index of the leftmost card.
  final ValueChanged<int>? onFirstVisibleChanged;

  static const double itemExtent = kEpisodeRowCardWidth + kEpisodeRowCardGap;

  @override
  State<HorizontalEpisodeRow> createState() => HorizontalEpisodeRowState();
}

class HorizontalEpisodeRowState extends State<HorizontalEpisodeRow> {
  late final ScrollController _controller = ScrollController(
    initialScrollOffset: math.max(
      0,
      widget.initialIndex * HorizontalEpisodeRow.itemExtent,
    ),
  );

  /// The index of the leftmost card.
  int get firstVisibleIndex {
    if (!_controller.hasClients || widget.itemCount == 0) return 0;
    return ((_controller.offset + HorizontalEpisodeRow.itemExtent / 2) ~/
            HorizontalEpisodeRow.itemExtent)
        .clamp(0, widget.itemCount - 1);
  }

  /// Brings the card at [index] to the row's left edge.
  void scrollToIndex(int index, {bool animate = true}) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target = (index * HorizontalEpisodeRow.itemExtent).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (animate) {
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    } else {
      _controller.jumpTo(target);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: episodeRowHeight(context),
      child: NotificationListener<ScrollEndNotification>(
        onNotification: (notification) {
          if (notification.metrics.axis == Axis.horizontal) {
            widget.onFirstVisibleChanged?.call(firstVisibleIndex);
          }
          return false;
        },
        child: ListView.builder(
          key: const ValueKey('details-episode-row'),
          controller: _controller,
          scrollDirection: Axis.horizontal,
          padding: widget.padding,
          itemExtent: HorizontalEpisodeRow.itemExtent,
          itemCount: widget.itemCount,
          itemBuilder: (context, index) => Align(
            alignment: Alignment.topLeft,
            child: widget.itemBuilder(context, index),
          ),
        ),
      ),
    );
  }
}
