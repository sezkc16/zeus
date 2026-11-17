/// Whole-season download: the pure rules.
///
/// Two things live here, both free of Flutter, Riverpod and the network
/// so they are unit-tested directly:
///
///   * source matching — given one episode's candidate streams, the
///     source last played for the title and the source the viewer picked
///     for this batch, which candidate to download ([rankSeasonSources] /
///     [chooseSeasonSource]);
///   * the batch itself — episodes handled one after another, in order,
///     with a cancel that stops queuing more but leaves what is already
///     queued ([runSeasonDownload]).
///
/// The real resolver, downloader and picker are handed in by
/// `season_download_controller.dart`.
library;

import '../../../core/domain/entity/multimedia_item.dart';
import '../../player/domain/stream_resolver.dart' show streamSourceKey;

/// Whether [stream] is something the app's downloader can fetch at all:
/// one plain HTTP(S) file. The downloader saves a URL's bytes to a file,
/// so an HLS / DASH playlist (it would save the playlist text, not the
/// video), a torrent / magnet, and a DRM-protected stream are out.
///
/// This is the cheap, offline half of the test. The single-episode
/// download's own rule — the server must report the file's size — is the
/// other half, and needs the network; the batch applies it when it
/// queues (see [SeasonEnqueueResult.notDownloadable]).
bool isDirectDownloadCandidate(StreamResult stream) {
  final url = stream.url.trim();
  if (url.isEmpty) return false;
  final lower = url.toLowerCase();
  if (lower.startsWith('magnet:')) return false;
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return false;
  }
  final path = uri.path.toLowerCase();
  if (path.endsWith('.m3u8') ||
      path.endsWith('.m3u') ||
      path.endsWith('.mpd') ||
      path.endsWith('.torrent') ||
      path.endsWith('.ism/manifest')) {
    return false;
  }
  // A playlist behind a query string ("?file=master.m3u8").
  if (lower.contains('.m3u8') || lower.contains('.mpd?')) return false;
  if (stream.drmKid != null ||
      stream.drmKey != null ||
      stream.licenseUrl != null) {
    return false;
  }
  return true;
}

/// Whether a response's content type says "this is not a video file":
/// the server answered with a playlist or a web page. Used by the batch
/// on top of the size check.
bool isNonFileMimeType(String? mimeType) {
  if (mimeType == null) return false;
  final mime = mimeType.toLowerCase();
  return mime.contains('mpegurl') ||
      mime.contains('dash+xml') ||
      mime.contains('text/html');
}

/// The source the viewer chose for a batch, kept for its later episodes.
class SeasonSourcePick {
  const SeasonSourcePick({
    required this.providerName,
    required this.source,
    required this.quality,
  });

  factory SeasonSourcePick.of(StreamResult stream) => SeasonSourcePick(
    providerName: stream.providerName,
    source: stream.source,
    quality: stream.quality,
  );

  final String providerName;
  final String source;

  /// Height in lines; null or 0 when the plugin gave none.
  final int? quality;

  /// The same identity the player's last-source memory uses.
  String get key => '$providerName\u0001$source\u0001${quality ?? 0}';
}

/// How far [quality] is from [wanted], for "closest quality". An unknown
/// quality (null / 0) on either side sorts after every known distance.
int _qualityDistance(int? quality, int? wanted) {
  final q = quality ?? 0;
  final w = wanted ?? 0;
  if (q == w) return 0;
  if (q <= 0 || w <= 0) return 1 << 30;
  return (q - w).abs();
}

/// The downloadable candidates of one episode, best match first, as
/// indexes into [candidates]:
///
///   1. the source last played for this title ([rememberedKey]), when a
///      downloadable candidate has the same key;
///   2. the batch's pick ([batchPick]) by exact key;
///   3. the pick's provider, closest quality first;
///   4. every other downloadable candidate, closest quality first.
///
/// Ties keep the plugin's own order. With no [batchPick] only step 1
/// applies: the list is empty when the remembered source is not there,
/// which is the batch's cue to ask the viewer (once). Candidates that
/// fail [isDirectDownloadCandidate] never appear.
List<int> rankSeasonSources({
  required List<StreamResult> candidates,
  String? rememberedKey,
  SeasonSourcePick? batchPick,
}) {
  final downloadable = <int>[
    for (var i = 0; i < candidates.length; i++)
      if (isDirectDownloadCandidate(candidates[i])) i,
  ];
  final ranked = <int>[];
  void add(int index) {
    if (!ranked.contains(index)) ranked.add(index);
  }

  if (rememberedKey != null) {
    for (final i in downloadable) {
      if (streamSourceKey(candidates[i]) == rememberedKey) {
        add(i);
        break;
      }
    }
  }
  if (batchPick == null) return ranked;

  final pickKey = batchPick.key;
  for (final i in downloadable) {
    if (streamSourceKey(candidates[i]) == pickKey) {
      add(i);
      break;
    }
  }

  List<int> byCloseness(Iterable<int> indexes) {
    final list = indexes.toList();
    // A stable sort by distance: List.sort is not guaranteed stable, so
    // the index breaks ties and keeps the plugin's order.
    list.sort((a, b) {
      final da = _qualityDistance(candidates[a].quality, batchPick.quality);
      final db = _qualityDistance(candidates[b].quality, batchPick.quality);
      return da != db ? da.compareTo(db) : a.compareTo(b);
    });
    return list;
  }

  byCloseness(
    downloadable.where(
      (i) => candidates[i].providerName == batchPick.providerName,
    ),
  ).forEach(add);
  byCloseness(downloadable).forEach(add);
  return ranked;
}

/// The one candidate to download, or null: [rankSeasonSources]' first.
///
/// Null means either the episode has no downloadable candidate at all,
/// or nothing is remembered / picked yet that matches — the caller tells
/// the two apart with [isDirectDownloadCandidate].
int? chooseSeasonSource({
  required List<StreamResult> candidates,
  String? rememberedKey,
  SeasonSourcePick? batchPick,
}) {
  final ranked = rankSeasonSources(
    candidates: candidates,
    rememberedKey: rememberedKey,
    batchPick: batchPick,
  );
  return ranked.isEmpty ? null : ranked.first;
}

/// The episodes a "Download season" would fetch: [episodes] in episode
/// order, minus those already on disk or already in the download queue.
class SeasonDownloadPlan {
  const SeasonDownloadPlan({
    required this.toDownload,
    required this.alreadyDownloaded,
    required this.alreadyQueued,
  });

  /// Not yet downloaded, in episode order.
  final List<Episode> toDownload;
  final int alreadyDownloaded;

  /// Already downloading / waiting in the queue.
  final int alreadyQueued;
}

/// Builds the plan for one season's (already Sub/Dub-filtered) episodes.
/// [isDownloaded] and [isQueued] are asked per episode.
Future<SeasonDownloadPlan> planSeasonDownload({
  required List<Episode> episodes,
  required Future<bool> Function(Episode episode) isDownloaded,
  required bool Function(Episode episode) isQueued,
}) async {
  final ordered = List<Episode>.of(episodes);
  // Episode order, whatever order the page shows them in. Stable: the
  // list position breaks ties (several entries sharing a number).
  final position = <Episode, int>{
    for (var i = 0; i < ordered.length; i++) ordered[i]: i,
  };
  ordered.sort((a, b) {
    if (a.season != b.season) return a.season.compareTo(b.season);
    if (a.episode != b.episode) return a.episode.compareTo(b.episode);
    return position[a]!.compareTo(position[b]!);
  });
  final toDownload = <Episode>[];
  var downloaded = 0;
  var queued = 0;
  for (final episode in ordered) {
    if (isQueued(episode)) {
      queued++;
    } else if (await isDownloaded(episode)) {
      downloaded++;
    } else {
      toDownload.add(episode);
    }
  }
  return SeasonDownloadPlan(
    toDownload: toDownload,
    alreadyDownloaded: downloaded,
    alreadyQueued: queued,
  );
}

/// What handing one episode's chosen source to the downloader came to.
enum SeasonEnqueueResult {
  /// In the download manager's queue.
  queued,

  /// The source turned out not to be a downloadable file (the server
  /// reports no size, or answers with a playlist / web page): the batch
  /// tries the episode's next-best source.
  notDownloadable,

  /// The download manager refused it (storage, permission): no other
  /// source would fare better, so the episode counts as failed.
  failed,
}

/// Where a batch stands. Immutable; a new one per step.
class SeasonDownloadProgress {
  const SeasonDownloadProgress({
    required this.total,
    this.processed = 0,
    this.queued = 0,
    this.noSource = 0,
    this.failed = 0,
    this.finished = false,
    this.cancelled = false,
  });

  /// Episodes the batch set out to queue.
  final int total;

  /// Episodes dealt with so far (queued, no source, or failed).
  final int processed;

  final int queued;

  /// Episodes with no downloadable source.
  final int noSource;

  /// Episodes the download manager refused, or whose links could not be
  /// loaded.
  final int failed;

  final bool finished;

  /// The batch was stopped before its last episode.
  final bool cancelled;

  /// Episodes never reached because the batch was cancelled.
  int get skipped => finished ? total - processed : 0;

  SeasonDownloadProgress copyWith({
    int? processed,
    int? queued,
    int? noSource,
    int? failed,
    bool? finished,
    bool? cancelled,
  }) => SeasonDownloadProgress(
    total: total,
    processed: processed ?? this.processed,
    queued: queued ?? this.queued,
    noSource: noSource ?? this.noSource,
    failed: failed ?? this.failed,
    finished: finished ?? this.finished,
    cancelled: cancelled ?? this.cancelled,
  );
}

/// The most sources one episode tries before it is given up as having no
/// downloadable source: each try is a network round trip, and a season
/// of episodes multiplies it.
const int kSeasonMaxSourceAttempts = 4;

/// Queues [episodes] one after another, in the order given.
///
/// For each: [resolve] loads its candidate streams; the source is chosen
/// by [rankSeasonSources] from [rememberedKey] and the batch's pick; when
/// neither matches, [askPick] is called — ONCE for the whole batch, on
/// the first episode that needs it, with that episode's downloadable
/// candidates — and the answer is kept for the rest. A null answer (the
/// viewer dismissed the picker) cancels the batch. [enqueue] hands the
/// chosen stream to the download manager; on
/// [SeasonEnqueueResult.notDownloadable] the episode's next-best source
/// is tried, up to [kSeasonMaxSourceAttempts].
///
/// [isCancelled] is checked before every episode and after every await:
/// a cancel stops queuing further episodes and leaves the queued ones.
/// [onProgress] is called after every episode and once at the end.
Future<SeasonDownloadProgress> runSeasonDownload({
  required List<Episode> episodes,
  required Future<List<StreamResult>> Function(Episode episode) resolve,
  required Future<SeasonEnqueueResult> Function(
    Episode episode,
    StreamResult stream,
  )
  enqueue,
  required Future<StreamResult?> Function(
    Episode episode,
    List<StreamResult> downloadable,
  )
  askPick,
  required bool Function() isCancelled,
  String? rememberedKey,
  void Function(SeasonDownloadProgress progress)? onProgress,
}) async {
  var progress = SeasonDownloadProgress(total: episodes.length);
  SeasonSourcePick? batchPick;
  var cancelled = false;

  void step({int queued = 0, int noSource = 0, int failed = 0}) {
    progress = progress.copyWith(
      processed: progress.processed + 1,
      queued: progress.queued + queued,
      noSource: progress.noSource + noSource,
      failed: progress.failed + failed,
    );
    onProgress?.call(progress);
  }

  episodes:
  for (final episode in episodes) {
    if (isCancelled()) {
      cancelled = true;
      break;
    }
    List<StreamResult> candidates;
    try {
      candidates = await resolve(episode);
    } catch (_) {
      if (isCancelled()) {
        cancelled = true;
        break;
      }
      step(failed: 1);
      continue;
    }
    if (isCancelled()) {
      cancelled = true;
      break;
    }
    if (!candidates.any(isDirectDownloadCandidate)) {
      step(noSource: 1);
      continue;
    }

    final tried = <int>{};
    while (true) {
      final ranked = rankSeasonSources(
        candidates: candidates,
        rememberedKey: rememberedKey,
        batchPick: batchPick,
      ).where((i) => !tried.contains(i)).toList();

      if (ranked.isEmpty) {
        if (batchPick != null) {
          // Every downloadable source of this episode was tried.
          step(noSource: 1);
          continue episodes;
        }
        final choices = <StreamResult>[
          for (var i = 0; i < candidates.length; i++)
            if (!tried.contains(i) && isDirectDownloadCandidate(candidates[i]))
              candidates[i],
        ];
        if (choices.isEmpty) {
          step(noSource: 1);
          continue episodes;
        }
        final picked = await askPick(episode, choices);
        if (picked == null || isCancelled()) {
          cancelled = true;
          break episodes;
        }
        batchPick = SeasonSourcePick.of(picked);
        continue;
      }

      final index = ranked.first;
      tried.add(index);
      SeasonEnqueueResult result;
      try {
        result = await enqueue(episode, candidates[index]);
      } catch (_) {
        result = SeasonEnqueueResult.failed;
      }
      if (result == SeasonEnqueueResult.queued) {
        step(queued: 1);
        continue episodes;
      }
      if (result == SeasonEnqueueResult.failed) {
        step(failed: 1);
        continue episodes;
      }
      if (isCancelled()) {
        cancelled = true;
        break episodes;
      }
      if (tried.length >= kSeasonMaxSourceAttempts) {
        step(noSource: 1);
        continue episodes;
      }
    }
  }

  progress = progress.copyWith(finished: true, cancelled: cancelled);
  onProgress?.call(progress);
  return progress;
}
