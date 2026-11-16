import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/providers/device_info_provider.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/utils/image_fallbacks.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/multimedia_card.dart';
import '../../../player/domain/playback_progress.dart';
import '../history_provider.dart';
import 'bookmarks_tab.dart' show GridFocusReturn;

/// Which slice of the watch history a Library tab shows.
///
/// Watching and Completed are the design preview's Library chips, next to
/// My List and Downloads. They are two views over the same history:
///
/// * Watching — started but not finished: the same rule Continue Watching
///   uses (a fraction of at least 1% and under [kCompletedFraction]).
/// * Completed — finished: a fraction at or above [kCompletedFraction].
///
/// A livestream's history entry carries no duration, so its fraction is 0
/// and it appears in neither: it was never "watching" in a resumable sense.
enum LibraryWatchFilter { watching, completed }

/// The history entries under [filter], newest first (the order the
/// repository already returns them in).
///
/// Pure so the rule is testable without a Hive box: the widget only renders
/// what this returns.
List<HistoryItem> filterWatchHistory(
  List<HistoryItem> items,
  LibraryWatchFilter filter,
) {
  return switch (filter) {
    LibraryWatchFilter.watching => [
      for (final item in items)
        if (item.progress >= 0.01 && item.progress < kCompletedFraction)
          item,
    ],
    LibraryWatchFilter.completed => [
      for (final item in items)
        if (item.progress >= kCompletedFraction) item,
    ],
  };
}

/// The Library's Watching or Completed tab: a poster grid over the watch
/// history, with the status under each title — "Watching · S1:E4" or
/// "Completed" — as the design preview shows them.
class WatchStatusTab extends ConsumerStatefulWidget {
  final LibraryWatchFilter filter;

  const WatchStatusTab({super.key, required this.filter});

  @override
  ConsumerState<WatchStatusTab> createState() => _WatchStatusTabState();
}

class _WatchStatusTabState extends ConsumerState<WatchStatusTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late final GridFocusReturn _focusReturn = GridFocusReturn(
    onTargetChanged: () {
      if (mounted) setState(() {});
    },
    debugLabel: 'watch status grid focus return',
  );

  @override
  void dispose() {
    _focusReturn.dispose();
    super.dispose();
  }

  /// Whether this device draws a focus highlight worth putting back.
  /// Same rule as the bookmarks grid: a touchscreen gets no ring back.
  bool get _restoresFocus {
    final platform = Theme.of(context).platform;
    final profile = ref.read(deviceProfileProvider).asData?.value;
    final isTouchDevice =
        (platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS) &&
        profile?.isTv != true;
    return !isTouchDevice;
  }

  /// Opens an entry and, on the way back, puts the highlight where the
  /// viewer left it.
  Future<void> _openDetails(MultimediaItem item) async {
    await DetailsRoute($extra: DetailsRouteExtra(item: item))
        .push<void>(context);
    if (!mounted) return;
    if (!_restoresFocus) return;
    _focusReturn.restoreTo(item.url);
  }

  String _statusLine(HistoryItem entry) {
    if (widget.filter == LibraryWatchFilter.completed) return 'Completed';
    final episode = entry.episode;
    final season = entry.season;
    if (episode != null && season != null) {
      return 'Watching · S$season:E$episode';
    }
    if (episode != null) return 'Watching · E$episode';
    return 'Watching · ${(entry.progress * 100).round()}%';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final history = ref.watch(watchHistoryProvider);
    final items = filterWatchHistory(history, widget.filter);
    final isLarge = context.isTabletOrLarger;
    final double totalHeight = isLarge ? 180.0 : 150.0;

    if (items.isEmpty) {
      return _buildEmpty(context);
    }

    // A taller cell than the bookmarks grid: the status line sits under
    // the card's own title.
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        LayoutConstants.spacingMd,
        LayoutConstants.spacingMd,
        LayoutConstants.spacingMd,
        0,
      ).copyWith(bottom: LayoutConstants.shellBottomContentPadding(context)),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: totalHeight,
        childAspectRatio: 2 / 3.9,
        crossAxisSpacing: LayoutConstants.spacingMd,
        mainAxisSpacing: LayoutConstants.spacingMd,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final entry = items[index];
        final item = entry.item;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: MultimediaCard(
                key: ValueKey(item.url),
                focusNode: _focusReturn.nodeFor(item.url),
                imageUrl:
                    AppImageFallbacks.poster(item.posterUrl, label: item.title) ??
                    '',
                title: item.title,
                heroTag: 'lib_watch_${item.url}_$index',
                onTap: () => _openDetails(item),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _statusLine(entry),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final isWatching = widget.filter == LibraryWatchFilter.watching;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isWatching
                ? Icons.play_circle_outline_rounded
                : Icons.check_circle_outline_rounded,
            size: 64,
            color: Theme.of(context).dividerColor,
          ),
          const SizedBox(height: 16),
          Text(
            isWatching ? 'Nothing watching yet' : 'Nothing completed yet',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}
