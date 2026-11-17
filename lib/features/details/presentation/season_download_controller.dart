/// Whole-season download: the part that touches the app.
///
/// [SeasonDownloadController] is a plain Riverpod notifier that outlives
/// the details page, so a batch keeps queuing when the page is closed;
/// the picker it may need opens on the app's root navigator for the same
/// reason. The rules it runs are the pure ones in
/// `domain/season_download.dart`; the links are loaded and the files
/// handed to the download manager exactly as the single-episode download
/// does it (see `download_launcher.dart`).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/logger/app_logger.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/download_service.dart';
import '../../../core/services/notification_service.dart';
import '../../player/domain/stream_resolver.dart' show readLastSourceMap;
import '../domain/season_download.dart';
import 'download_launcher.dart';
import 'downloaded_file_provider.dart';

/// One batch, as the page shows it.
class SeasonDownloadBatch {
  const SeasonDownloadBatch({
    required this.itemUrl,
    required this.progress,
    this.alreadyDownloaded = 0,
    this.alreadyQueued = 0,
    this.cancelRequested = false,
  });

  /// The title the batch belongs to (the details page's item URL).
  final String itemUrl;
  final SeasonDownloadProgress progress;

  /// Episodes left out because they were on disk / in the queue already.
  final int alreadyDownloaded;
  final int alreadyQueued;

  /// Stop was pressed; the batch ends after the step in flight.
  final bool cancelRequested;

  bool get isRunning => !progress.finished;

  SeasonDownloadBatch copyWith({
    SeasonDownloadProgress? progress,
    bool? cancelRequested,
  }) => SeasonDownloadBatch(
    itemUrl: itemUrl,
    progress: progress ?? this.progress,
    alreadyDownloaded: alreadyDownloaded,
    alreadyQueued: alreadyQueued,
    cancelRequested: cancelRequested ?? this.cancelRequested,
  );
}

/// The batch's final line: "Queued 10 · 1 already downloaded · 1 no
/// downloadable source". Only the parts that are not zero, except
/// "Queued", which is always said.
String seasonDownloadSummary(AppLocalizations l10n, SeasonDownloadBatch batch) {
  final p = batch.progress;
  final stopped = p.total - p.processed;
  return <String>[
    l10n.downloadSeasonSummaryQueued(p.queued),
    if (batch.alreadyDownloaded > 0)
      l10n.downloadSeasonSummaryAlreadyDownloaded(batch.alreadyDownloaded),
    if (batch.alreadyQueued > 0)
      l10n.downloadSeasonSummaryAlreadyQueued(batch.alreadyQueued),
    if (p.noSource > 0) l10n.downloadSeasonSummaryNoSource(p.noSource),
    if (p.failed > 0) l10n.downloadSeasonSummaryFailed(p.failed),
    if (p.finished && stopped > 0) l10n.downloadSeasonSummaryStopped(stopped),
  ].join(' · ');
}

/// Asks which source a batch should use; null when dismissed.
typedef SeasonSourceAsker =
    Future<StreamResult?> Function(
      Episode episode,
      List<StreamResult> downloadable,
    );

final seasonDownloadControllerProvider =
    NotifierProvider<SeasonDownloadController, SeasonDownloadBatch?>(
      SeasonDownloadController.new,
    );

class SeasonDownloadController extends Notifier<SeasonDownloadBatch?> {
  bool _cancel = false;

  @override
  SeasonDownloadBatch? build() => null;

  bool get _running => state?.isRunning ?? false;

  /// Which of [episodes] still need downloading (in episode order), and
  /// how many are on disk or in the queue already.
  Future<SeasonDownloadPlan> plan(
    MultimediaItem item,
    List<Episode> episodes,
  ) {
    final downloads = ref.read(downloadServiceProvider);
    final active = ref.read(activeDownloadsProvider);
    return planSeasonDownload(
      episodes: episodes,
      isQueued: (episode) => active.contains(episode.url),
      isDownloaded: (episode) async =>
          await downloads.getDownloadedFile(item, episode: episode) != null,
    );
  }

  /// Queues [plan]'s episodes one after another. Returns false, and does
  /// nothing, while another batch is still running. The future completes
  /// when the batch has finished or was stopped; the caller need not
  /// wait for it.
  ///
  /// [askPick] defaults to the source sheet on the root navigator.
  Future<bool> start({
    required MultimediaItem item,
    required SeasonDownloadPlan plan,
    required AppLocalizations l10n,
    SeasonSourceAsker? askPick,
  }) async {
    if (_running || plan.toDownload.isEmpty) return false;
    _cancel = false;
    final batch = SeasonDownloadBatch(
      itemUrl: item.url,
      progress: SeasonDownloadProgress(total: plan.toDownload.length),
      alreadyDownloaded: plan.alreadyDownloaded,
      alreadyQueued: plan.alreadyQueued,
    );
    state = batch;

    final launcher = ref.read(downloadLauncherProvider);
    final downloads = ref.read(downloadServiceProvider);
    final rememberedKey = readLastSourceMap(ref.read)[item.url];

    try {
      await runSeasonDownload(
        episodes: plan.toDownload,
        rememberedKey: rememberedKey,
        isCancelled: () => _cancel,
        resolve: (episode) async {
          final provider = launcher.providerFor(item);
          if (provider == null) throw StateError('No active provider');
          return provider.loadStreams(episode.url);
        },
        askPick:
            askPick ??
            (episode, downloadable) =>
                showSeasonSourcePicker(episode, downloadable),
        enqueue: (episode, stream) async {
          // The single download's own rule: the server must say how big
          // the file is, or it is not a file this downloader can fetch.
          final metadata = await downloads
              .getMetadata(stream.url, headers: stream.headers)
              .timeout(const Duration(seconds: 15), onTimeout: () => null);
          if (metadata == null ||
              metadata.size == null ||
              isNonFileMimeType(metadata.mimeType)) {
            return SeasonEnqueueResult.notDownloadable;
          }
          try {
            final started = await launcher.queueDirect(
              stream: stream,
              item: item,
              resolveUrl: episode.url,
              metadata: metadata,
              episode: episode,
            );
            return started
                ? SeasonEnqueueResult.queued
                : SeasonEnqueueResult.failed;
          } catch (error, stackTrace) {
            talker.error(
              'SeasonDownload: could not queue "${item.title}" '
              'S${episode.season}E${episode.episode}',
              error,
              stackTrace,
            );
            return SeasonEnqueueResult.failed;
          }
        },
        onProgress: (progress) {
          final current = state;
          if (current == null) return;
          state = current.copyWith(progress: progress);
        },
      );
    } catch (error, stackTrace) {
      talker.error('SeasonDownload: batch failed', error, stackTrace);
      final current = state;
      if (current != null) {
        state = current.copyWith(
          progress: current.progress.copyWith(finished: true),
        );
      }
    }

    final done = state;
    if (done != null) {
      // Said app-wide, so it is seen even when the page was closed.
      ref
          .read(notificationServiceProvider)
          .showInfo(
            seasonDownloadSummary(l10n, done),
            title: l10n.downloadSeason,
            icon: Icons.download_done_rounded,
            duration: const Duration(seconds: 6),
          );
      // The episode cards' "downloaded" ticks read this cache.
      for (final episode in plan.toDownload) {
        unawaited(
          ref
              .read(downloadedFilesProvider.notifier)
              .checkFile(item, episode: episode),
        );
      }
    }
    return true;
  }

  /// Stops queuing further episodes. Those already queued stay in
  /// Downloads.
  void cancel() {
    final current = state;
    if (current == null || !current.isRunning) return;
    _cancel = true;
    state = current.copyWith(cancelRequested: true);
  }

  /// Clears a finished batch's summary.
  void dismiss() {
    if (_running) return;
    state = null;
  }
}

/// The batch's one question: which source to use for the season. A
/// bottom sheet on the root navigator (so it can open with the details
/// page closed) listing [downloadable] by name, quality and host.
Future<StreamResult?> showSeasonSourcePicker(
  Episode episode,
  List<StreamResult> downloadable,
) async {
  final context = rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return null;
  return showModalBottomSheet<StreamResult>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (ctx) {
      final l10n = AppLocalizations.of(ctx)!;
      final theme = Theme.of(ctx);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  l10n.downloadSeasonPickSource,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  l10n.downloadSeasonPickSourceHint,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: downloadable.length,
                  itemBuilder: (context, index) {
                    final stream = downloadable[index];
                    final label = stream.source != 'Auto'
                        ? stream.source
                        : 'Source ${index + 1}';
                    final quality = stream.quality;
                    final host = Uri.tryParse(stream.url)?.host ?? '';
                    final details = <String>[
                      if (stream.providerName.trim().isNotEmpty &&
                          stream.providerName != 'Unknown')
                        stream.providerName,
                      if (host.isNotEmpty) host,
                    ].join(' · ');
                    return ListTile(
                      key: Key('season-source-$index'),
                      leading: const Icon(Icons.file_download_outlined),
                      title: Text(label),
                      subtitle: details.isEmpty ? null : Text(details),
                      trailing: quality != null && quality > 0
                          ? Text(
                              '${quality}p',
                              style: theme.textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : null,
                      onTap: () => Navigator.pop(ctx, stream),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}
