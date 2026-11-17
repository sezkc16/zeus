/// Whole-season download: the Episodes header's button and the status
/// line under it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/services/notification_service.dart';
import '../../domain/season_download.dart';
import '../season_download_controller.dart';

/// "Download season": the square icon button beside the Episodes
/// header's range picker and sort button, in their style.
///
/// A tap counts the season's not-yet-downloaded episodes, asks
/// "Download 12 episodes?", and on Download hands them to
/// [SeasonDownloadController]. [episodes] is the selected season's list
/// as the page shows it (the Sub/Dub choice already applied).
class SeasonDownloadButton extends ConsumerStatefulWidget {
  const SeasonDownloadButton({
    required this.item,
    required this.episodes,
    super.key,
  });

  final MultimediaItem item;
  final List<Episode> episodes;

  @override
  ConsumerState<SeasonDownloadButton> createState() =>
      _SeasonDownloadButtonState();
}

class _SeasonDownloadButtonState extends ConsumerState<SeasonDownloadButton> {
  /// Counting the season's episodes on disk.
  bool _checking = false;

  Future<void> _onTap() async {
    if (_checking) return;
    final l10n = AppLocalizations.of(context)!;
    final controller = ref.read(seasonDownloadControllerProvider.notifier);
    if (ref.read(seasonDownloadControllerProvider)?.isRunning ?? false) {
      ref
          .read(notificationServiceProvider)
          .showInfo(l10n.downloadSeasonBusy, title: l10n.downloadSeason);
      return;
    }
    setState(() => _checking = true);
    SeasonDownloadPlan plan;
    try {
      plan = await controller.plan(widget.item, widget.episodes);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
    if (!mounted) return;

    final count = plan.toDownload.length;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.downloadSeason),
        content: Text(
          count > 0
              ? l10n.downloadSeasonConfirm(count)
              : plan.alreadyQueued > 0
              ? l10n.downloadSeasonAllQueued
              : l10n.downloadSeasonAllDownloaded,
        ),
        actions: count > 0
            ? <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(l10n.cancel),
                ),
                ElevatedButton(
                  key: const Key('season-download-confirm'),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(l10n.download),
                ),
              ]
            : <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(l10n.ok),
                ),
              ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Not awaited: the batch runs on its own and reports through the
    // controller's state, so the page stays usable.
    unawaited(
      ref
          .read(seasonDownloadControllerProvider.notifier)
          .start(item: widget.item, plan: plan, l10n: l10n),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final batch = ref.watch(seasonDownloadControllerProvider);
    final running =
        batch != null && batch.isRunning && batch.itemUrl == widget.item.url;
    final busy = _checking || running;
    return Tooltip(
      message: l10n.downloadSeason,
      child: Semantics(
        button: true,
        label: l10n.downloadSeason,
        child: SizedBox(
          height: 40,
          child: Material(
            color: Colors.transparent,
            child: Ink(
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: InkWell(
                key: const Key('season-download-button'),
                borderRadius: BorderRadius.circular(10),
                onTap: busy ? null : _onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Center(
                    widthFactor: 1,
                    child: busy
                        ? SizedBox(
                            width: 22,
                            height: 22,
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: scheme.primary,
                              ),
                            ),
                          )
                        : Icon(
                            Icons.download_for_offline_outlined,
                            size: 22,
                            color: scheme.onSurfaceVariant,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The line under the Episodes header while this title's season is being
/// queued — "Queuing 3/12…" with a bar and Stop — and, once it is done,
/// the summary with a dismiss button. Nothing at all otherwise.
class SeasonDownloadStatusBar extends ConsumerWidget {
  const SeasonDownloadStatusBar({
    required this.itemUrl,
    this.horizontalPadding = 16,
    super.key,
  });

  final String itemUrl;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batch = ref.watch(seasonDownloadControllerProvider);
    if (batch == null || batch.itemUrl != itemUrl) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = batch.progress;
    final controller = ref.read(seasonDownloadControllerProvider.notifier);
    final running = batch.isRunning;
    final shown = (progress.processed + 1).clamp(1, progress.total);

    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 0, horizontalPadding, 12),
      child: Container(
        key: const Key('season-download-status'),
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    running
                        ? l10n.downloadSeasonQueuing(shown, progress.total)
                        : seasonDownloadSummary(l10n, batch),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (running) ...<Widget>[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        minHeight: 3,
                        value: progress.total == 0
                            ? null
                            : progress.processed / progress.total,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            if (running)
              TextButton(
                key: const Key('season-download-stop'),
                onPressed: batch.cancelRequested ? null : controller.cancel,
                child: Text(l10n.downloadSeasonStop),
              )
            else
              IconButton(
                key: const Key('season-download-dismiss'),
                tooltip: l10n.dismiss,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 20),
                onPressed: controller.dismiss,
              ),
          ],
        ),
      ),
    );
  }
}
