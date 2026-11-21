/// Turning a `PlayerRouteExtra` into something an engine can actually open.
///
/// `PlayerRouteExtra.videoUrl` is not a URL. It is an opaque token handed to
/// the active plugin's `loadStreams()`, and plugins are free to put anything
/// in it — an episode page, a `tmdb:` id, or a JSON array of candidate
/// sources — so it must never be handed to `Uri.parse`.
///
/// Resolution is engine-agnostic: it ends at a [StreamResult] and nothing here
/// knows which engine opens it, so both players share this.
library;

import '../../../core/utils/source_language.dart';
import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart'
    show ProviderListenable;
import 'package:http/http.dart' as http;
import 'package:clock/clock.dart';

import '../../../core/addons/data/addon_own_links.dart';
import '../../../core/addons/data/addon_playback_launcher.dart';
import '../../../core/addons/data/addon_repository.dart';
import '../../../core/addons/data/addon_stream_service.dart';
import '../../../core/addons/models/addon_manifest.dart';
import '../../../core/addons/models/addon_meta.dart' show kAddonItemSource;
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers.dart';
import '../../../core/storage/history_repository.dart';
import '../../../core/storage/settings_repository.dart';
import '../../../core/network/http_defaults.dart';
import '../../../core/network/clearance/clearance.dart';
import '../../../core/network/probe_answer.dart';
import '../../../core/utils/app_utils.dart';
import '../../../core/utils/stream_quality_sorter.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../library/presentation/history_provider.dart';
import 'source_check.dart';
import '../../settings/presentation/player_settings_provider.dart';

/// Just enough of Riverpod to read providers. Both `Ref.read` and
/// `WidgetRef.read` satisfy this, so the resolver can be called from a
/// Notifier or straight from a widget without caring which it got.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// A resolved, ordered candidate list plus the one to open first.
class ResolvedPlayback {
  const ResolvedPlayback({
    required this.streams,
    required this.index,
    this.qualityFilteredFallback = false,
    this.lastUsedIndex = -1,
    this.dataSaver = false,
  });

  /// Quality-filtered and sorted, best first. Never empty.
  final List<StreamResult> streams;

  /// Index into [streams] of the stream to play. Later indices are the
  /// failover order.
  final int index;

  /// The quality filter matched nothing and was dropped, so [streams] is
  /// unfiltered. Callers may want to say so.
  final bool qualityFilteredFallback;

  /// Index into [streams] of the source this title last played on (v7), or
  /// -1 when none is remembered or it is not in this list. The Sources list
  /// tags it "Last used".
  final int lastUsedIndex;

  /// Whether the mobile-data limit shaped [streams] (v7): the device is on
  /// cellular with "Max quality on mobile data" set, so the sources at or
  /// below it come first. The Sources list says so.
  final bool dataSaver;

  StreamResult get selected => streams[index];
}

/// The identity a stream must present on the network.
///
/// Shared so that every request about one stream looks like the same client.
/// A CDN that ties a signed URL to the requesting agent will 403 if the probe,
/// the licence fetch and the engine disagree — and libVLC's own default
/// User-Agent is rejected outright by many of them.
///
/// A stream on a site holding a bot-check clearance carries it: the site's
/// cookies, and the agent they hold under unless the plugin set its own.
Map<String, String> playbackHeaders(StreamResult stream) {
  var headers = <String, String>{...?stream.headers};
  final uri = Uri.tryParse(stream.url);
  if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
    headers = Clearance.instance.withClearance(uri, headers);
  }
  final hasUserAgent = headers.keys.any((k) => k.toLowerCase() == 'user-agent');
  if (!hasUserAgent) headers['User-Agent'] = kDefaultBrowserUserAgent;
  return headers;
}

/// Turns a resolved candidate into a URL an engine can actually open.
///
/// Only torrents need work: the torrent service downloads and seeds a
/// `magnet:` link or a `.torrent`, then serves it over loopback HTTP, and the
/// engine plays that. The loopback hop means no headers are involved.
///
/// Returns null when the torrent could not be prepared, which the caller
/// should surface rather than pass to the engine.
Future<String?> playableUrlFor({
  required ProviderReader read,
  required StreamResult stream,
}) async {
  if (isTorrentSource(stream)) {
    return read(torrentServiceProvider).getStreamUrl(stream.url);
  }
  return AppUtils.normalizeUrl(stream.url);
}

/// Whether this candidate has to go through the torrent service first.
///
/// The path check is deliberately narrowed by [StreamResult.source]: a bare
/// absolute path is normally a local file, and only a torrent-sourced one is a
/// seeded file the service already knows about.
bool isTorrentSource(StreamResult stream) =>
    stream.url.startsWith('magnet:') ||
    stream.url.endsWith('.torrent') ||
    (stream.url.startsWith('/') && stream.source.contains('Torrent'));

/// A URL that names itself as on-demand. Vetoes [_liveUrlShapes], because those
/// are guesses and this is the source saying what it is: Xtream Codes serves
/// VOD from `/movie/` and `/series/`, and Wowza's on-demand HLS lives under
/// `/vod/` while still being cut into `chunklist_*.m3u8` files.
final RegExp _vodMarkers = RegExp(r'/(vod|movies?|series)/');

/// URL shapes that in practice only IPTV and live packagers produce.
///
/// Deliberately narrower than "ends in .m3u8" — a VOD HLS ladder is also
/// `.m3u8`, and calling those live would kill seeking and resume across a large
/// slice of ordinary content. So: the path segments IPTV portals mount channels
/// under, the two live-edge playlist names (`stream.m3u8` from most origins,
/// `chunklist` from Wowza), and the Xtream Codes query that asks for a channel
/// list rather than a file.
final RegExp _liveUrlShapes = RegExp(
  r'/live/|/iptv/|stream\.m3u8|chunklist|(type|output)=m3u8',
);

/// Whether this source should be treated as live.
///
/// The item's own content type wins, then the URL scheme, then the URL's
/// shape. Torrents and local files are always VOD however they are labelled.
/// Decided from data both engines can see rather than from an engine report,
/// because liveness changes buffering, seeking, progress writing and what
/// end-of-media means.
///
/// The URL-shape pass matters because plugins routinely hand back an IPTV feed
/// typed as `movie`. Without it that stream gets VOD caching instead of
/// `:live-caching`, writes progress against a duration that means nothing, and
/// on a drop takes the end-of-media branch instead of reconnecting.
bool isLiveSource(MultimediaItem item, String url) {
  if (url.isEmpty) return item.contentType == MultimediaContentType.livestream;
  final lower = url.toLowerCase();
  if (lower.startsWith('magnet:') ||
      lower.endsWith('.torrent') ||
      lower.startsWith('/')) {
    return false;
  }
  if (item.contentType == MultimediaContentType.livestream) return true;
  if (lower.startsWith('rtmp://') ||
      lower.startsWith('rtsp://') ||
      lower.startsWith('mms://') ||
      lower.startsWith('udp://') ||
      lower.startsWith('rtp://')) {
    return true;
  }
  if (_vodMarkers.hasMatch(lower)) return false;
  return _liveUrlShapes.hasMatch(lower);
}

/// Why resolution gave up, as a code the UI can localize.
///
/// Resolution runs with no BuildContext, so it names the failure and
/// [describeStreamFailure] renders it.
enum StreamResolutionFailure {
  noProvider,
  nothingToPlay,
  loadFailed,
  cancelled,
  noStreams,

  /// An extension's own full-screen screen took the Play and left nothing to
  /// play: the player leaves quietly, with nothing to say.
  extensionScreen,
}

/// Resolution failed in a way worth showing the user.
class StreamResolutionException implements Exception {
  const StreamResolutionException(this.failure, {this.detail});

  final StreamResolutionFailure failure;

  /// The underlying error text, when there is one worth passing on.
  final String? detail;

  /// The developer-facing form, for logs and `toString()`. Derived from
  /// [failure] so a diagnostic can never describe a different failure from the
  /// one the viewer is shown. English on purpose; [describeStreamFailure] is
  /// what the viewer sees.
  String get message => switch (failure) {
    StreamResolutionFailure.noProvider => 'No provider selected.',
    StreamResolutionFailure.nothingToPlay => 'Nothing to play.',
    StreamResolutionFailure.loadFailed => 'Could not load sources: $detail',
    StreamResolutionFailure.cancelled => 'Cancelled.',
    StreamResolutionFailure.noStreams => 'No streams found.',
    StreamResolutionFailure.extensionScreen => 'The extension showed its own screen.',
  };

  @override
  String toString() => message;
}

/// The viewer-facing wording for a failed resolution.
String describeStreamFailure(
  AppLocalizations l10n,
  StreamResolutionException failure,
) => switch (failure.failure) {
  StreamResolutionFailure.noProvider => l10n.playerNoProviderSelected,
  StreamResolutionFailure.nothingToPlay => l10n.playerNothingToPlay,
  StreamResolutionFailure.loadFailed => l10n.playerCouldNotLoadSources(
    failure.detail ?? '',
  ),
  StreamResolutionFailure.cancelled => l10n.playerResolutionCancelled,
  StreamResolutionFailure.noStreams => l10n.playerNoStreamsFound,
  // Never shown: the player leaves.
  StreamResolutionFailure.extensionScreen => l10n.playerNothingToPlay,
};

/// Where one candidate's health probe has got to.
///
/// [trying] is reported when the probe is dispatched rather than when it
/// answers, because the probes run as a parallel race.
enum ProbeOutcome {
  trying,

  /// It answered with something to play, and nothing says it cannot be
  /// sought in.
  healthy,

  /// It answered with something to play, from a server that ignores byte
  /// ranges: it plays, but only from its start, so it cannot be sought in and
  /// a resume starts it over. Google's video-downloads host is one.
  unseekable,

  /// No answer, or a refusal.
  unhealthy,

  /// It answered with a web page - a link generator, a login, a missing-file
  /// page served with a 200 - rather than anything to play.
  notVideo,
}

extension ProbeOutcomeReach on ProbeOutcome {
  /// Whether the check got an answer a player can open, seekable or not.
  bool get reached =>
      this == ProbeOutcome.healthy || this == ProbeOutcome.unseekable;
}

/// Resolves [videoUrl] for [item] into playable streams.
///
/// [preloadedStreams] short-circuits the plugin call, for callers that have
/// already aggregated sources across plugins. It is taken as given — neither
/// re-sorted, re-filtered nor overridden by watch history — so its first entry
/// is what opens.
///
/// [probeCandidates] is how many candidates are health-checked at once, in
/// priority order, with a dead one's place going to the next in line until a
/// healthy one is known - so a dead link fails over before the engine spins on
/// a connect timeout. Pass 0 to skip probing. [probeBudget] caps how long that
/// may take before playback starts on the best found so far.
///
/// [onCandidates] fires as soon as the ordered list exists; indices in every
/// later report and in [ResolvedPlayback] are indices into that list.
/// [onProbe] fires for each candidate as it is dispatched and again as it
/// settles. Neither changes what is resolved.
///
/// Completing [pick] with an index into that list ends the race on exactly
/// that candidate: the viewer chose it from the source list while the check
/// was running, and the probes do not overrule them. Distinct from
/// [isCancelled], which abandons resolution altogether. Completing [abandon]
/// ends a check still running, for a caller that has stopped waiting - the
/// screen closing - so nothing it armed outlives it.
Future<ResolvedPlayback> resolvePlayback({
  required ProviderReader read,
  required MultimediaItem item,
  required String videoUrl,
  List<StreamResult>? preloadedStreams,
  int probeCandidates = 3,
  Duration probeBudget = kProbeBudget,
  bool Function()? isCancelled,
  void Function(List<StreamResult> streams)? onCandidates,
  void Function(int index, ProbeOutcome outcome)? onProbe,
  Future<int>? pick,
  Future<void>? abandon,
}) async {
  final direct = _directStream(item, videoUrl);
  if (direct != null) {
    final streams = [direct];
    onCandidates?.call(streams);
    return ResolvedPlayback(streams: streams, index: 0);
  }

  final preloaded = preloadedStreams ?? const <StreamResult>[];
  // A Stremio item's links come from the add-on it came from (Stremio direct
  // play) - for an episode after the first too - never from a plugin.
  final addon = _addonOf(read, item);
  final provider = _resolveProvider(read, item);
  if (provider == null && addon == null && preloaded.isEmpty) {
    throw const StreamResolutionException(StreamResolutionFailure.noProvider);
  }
  if (videoUrl.isEmpty && preloaded.isEmpty) {
    throw const StreamResolutionException(
      StreamResolutionFailure.nothingToPlay,
    );
  }

  // A list handed in is a choice the viewer already made: the sheets put the
  // tapped source first and have ranked the rest themselves. An add-on's
  // answer comes ranked too, best first, as its Play button would play it.
  final handPicked = preloaded.isNotEmpty;
  final ranked = handPicked || addon != null;

  List<StreamResult> raw;
  if (handPicked) {
    raw = preloaded;
  } else if (addon != null) {
    raw = await _addonStreams(read, addon, item, videoUrl);
  } else {
    try {
      raw = await provider!.loadStreams(videoUrl);
    } on ExtensionScreenEnded {
      throw const StreamResolutionException(StreamResolutionFailure.extensionScreen);
    } catch (e) {
      throw StreamResolutionException(
        StreamResolutionFailure.loadFailed,
        detail: '$e',
      );
    }
  }
  if (isCancelled?.call() ?? false) {
    throw const StreamResolutionException(StreamResolutionFailure.cancelled);
  }
  if (raw.isEmpty) {
    throw const StreamResolutionException(StreamResolutionFailure.noStreams);
  }

  // Ranking that list again opens a source nobody picked, and a filter can
  // drop the picked one out of it altogether.
  var didFallback = false;
  final settings = await _playerSettings(read);
  var streams = raw;
  var saved = 0;
  var lastUsedIndex = -1;
  var dataSaver = false;
  if (!ranked && settings != null) {
    final preference = await qualityPreferenceInForce(settings);
    final cap = await mobileDataCapInForce(settings);
    final plan = planSourceList(
      filterStreamsByQuality(
        raw,
        preference,
        settings.qualityFilterMode,
        onFallback: (v) => didFallback = v,
      ),
      preference: preference,
      cap: cap,
      lastUsed: (ordered) => _savedStreamIndex(read, item, ordered),
      language: settings.preferredSourceLanguage,
    );
    streams = plan.streams;
    saved = plan.start;
    lastUsedIndex = plan.lastUsedIndex;
    dataSaver = cap != QualityPreference.any;
  } else if (!ranked) {
    final found = _savedStreamIndex(read, item, streams);
    saved = found < 0 ? 0 : found;
    lastUsedIndex = found;
  }
  if (streams.isEmpty) {
    throw const StreamResolutionException(StreamResolutionFailure.noStreams);
  }
  onCandidates?.call(streams);
  final index = probeCandidates <= 1
      ? saved
      : await _firstHealthyStream(
          streams,
          startIndex: saved,
          limit: probeCandidates,
          budget: probeBudget,
          isCancelled: isCancelled,
          onProbe: onProbe,
          pick: pick,
          abandon: abandon,
        );

  return ResolvedPlayback(
    streams: streams,
    index: index,
    qualityFilteredFallback: didFallback,
    lastUsedIndex: lastUsedIndex,
    dataSaver: dataSaver,
  );
}

/// Local files, remote casts and torrents are already playable and never go
/// through a plugin.
StreamResult? _directStream(MultimediaItem item, String videoUrl) {
  final isTorrent =
      item.provider == 'Torrent' ||
      videoUrl.startsWith('magnet:') ||
      videoUrl.endsWith('.torrent');
  final isDirect =
      item.provider == 'Remote' ||
      item.provider == 'Local' ||
      AppUtils.isLocalFile(videoUrl);

  if (!isTorrent && !isDirect) return null;
  return StreamResult(
    url: videoUrl,
    source: isTorrent ? 'Torrent' : 'Video',
    providerName: item.provider ?? 'Local',
    headers: const {},
  );
}

/// The plugin [resolvePlayback] would ask for [item]'s streams, or null when
/// it would ask none: a local file, a torrent or a direct link plays as it is.
///
/// For saying who is being waited on. Resolution itself does not go through
/// this, but it answers from the same two functions, so the two cannot name
/// different plugins.
SkyStreamProvider? pluginFor(
  ProviderReader read,
  MultimediaItem item,
  String videoUrl,
) {
  if (_directStream(item, videoUrl) != null) return null;
  return _resolveProvider(read, item);
}

SkyStreamProvider? _resolveProvider(ProviderReader read, MultimediaItem item) {
  // A Stremio item has no plugin behind it, and the active one knows nothing
  // of its ids: asked anyway, it answered with another title's links.
  if (item.source == kAddonItemSource) return null;
  final active = read(activeProviderProvider);
  final wanted = item.provider;
  if (wanted != null) {
    final match = read(extensionManagerProvider.notifier)
        .getAllProviders()
        .firstWhereOrNull((p) => p.packageName == wanted || p.name == wanted);
    if (match != null) return match;
  }
  return active;
}

/// The install a Stremio item's links come from - the one whose link is
/// playing, else the one that described it - while it is installed and on;
/// null for anything else.
ManagedAddon? _addonOf(ProviderReader read, MultimediaItem item) {
  final url = item.streamAddonUrl ?? item.addonUrl;
  if (item.source != kAddonItemSource || url == null) return null;
  return read(addonRepositoryProvider).enabled
      .firstWhereOrNull((a) => a.manifestUrl == url);
}

/// [videoUrl]'s links from [addon], best first: an episode by its own id and
/// numbers, a movie by the item's, asked as the type the add-on published and
/// the way the page's Play button asks; the top one through debrid when it is
/// a torrent and debrid is set up.
Future<List<StreamResult>> _addonStreams(
  ProviderReader read,
  ManagedAddon addon,
  MultimediaItem item,
  String videoUrl,
) async {
  final episode = item.episodes?.firstWhereOrNull((e) => e.url == videoUrl);
  final request = AddonStreamRequest(
    type:
        item.addonType ??
        (item.contentType == MultimediaContentType.movie ? 'movie' : 'series'),
    contentId: item.url,
    videoId: episode == null ? null : videoUrl,
    season: episode?.season,
    episode: episode?.episode,
    imdbId: item.imdbId,
    tmdbId: item.tmdbId,
    title: item.title,
    year: item.year,
  );
  // The player is open: someone is waiting, so a check that wants a click
  // may show its sheet.
  final links = await ownPlayableLinks(
    read(addonStreamServiceProvider),
    addon,
    request,
    personWaiting: true,
  );
  if (links.isEmpty) return const <StreamResult>[];
  final top = await viaDebrid(read, links.first);
  return read(addonStreamConverterProvider)
      .toStreamResults(links, selected: top);
}

/// Settings can still be loading when playback starts. Silently skipping the
/// quality preference for that window would make the chosen source depend on
/// how warm the cache was, so wait for it instead.
Future<PlayerSettings?> _playerSettings(ProviderReader read) async {
  final snapshot = read(playerSettingsProvider);
  final data = snapshot.asData;
  if (data != null) return data.value;
  try {
    return await read(playerSettingsProvider.future);
  } catch (_) {
    return null;
  }
}

/// The source list as the player shows and walks it (v7), and where it
/// starts.
///
/// [streams] best quality first (see [sortStreamsBestFirst]); with a
/// mobile-data [cap] in force the sources at or below it lead. [lastUsed]
/// finds the source this title last played on in that list (-1 for none):
/// it moves to the top and playback starts on it — unless it is above the
/// [cap], in which case it keeps its place (still tagged) and playback
/// starts under the cap. With nothing remembered, playback starts on the
/// source the quality [preference] ranks first, as it did before v7, so a
/// 4K source at the top of the list is not opened just for being there.
///
/// Decided once, when playback is resolved, and not again on a handover:
/// the order is also what failover walks, and the walk records which
/// indices it has tried.
({List<StreamResult> streams, int start, int lastUsedIndex}) planSourceList(
  List<StreamResult> streams, {
  required QualityPreference preference,
  QualityPreference cap = QualityPreference.any,
  int Function(List<StreamResult> ordered)? lastUsed,
  SourceLanguage language = SourceLanguage.off,
}) {
  // v9: sources that say they carry the preferred language lead, inside
  // the mobile-data limit's two parts (within it, above it); the quality
  // order holds within each. Nothing is dropped.
  final ordered = preferMatching<StreamResult>(
    sortStreamsBestFirst(streams, cap: cap),
    (s) => streamStatesLanguage(s, language),
    groupOf: (s) => streamExceedsQuality(s, cap) ? 1 : 0,
  );
  if (ordered.isEmpty) return (streams: ordered, start: 0, lastUsedIndex: -1);
  final startPreference = lowerQualityPreference(preference, cap);
  // With nothing remembered, playback starts on the quality preference's
  // pick among the preferred-language sources when there are any.
  int preferredStart() {
    final inLanguage = <StreamResult>[
      for (final s in ordered)
        if (streamStatesLanguage(s, language)) s,
    ];
    if (inLanguage.isEmpty) {
      return preferredStartIndex(ordered, startPreference);
    }
    final pick = inLanguage[preferredStartIndex(inLanguage, startPreference)];
    final at = ordered.indexWhere((s) => identical(s, pick));
    return at < 0 ? 0 : at;
  }

  final found = lastUsed?.call(ordered) ?? -1;
  if (found < 0 || found >= ordered.length) {
    return (streams: ordered, start: preferredStart(), lastUsedIndex: -1);
  }
  if (streamExceedsQuality(ordered[found], cap)) {
    return (streams: ordered, start: preferredStart(), lastUsedIndex: found);
  }
  if (found == 0) return (streams: ordered, start: 0, lastUsedIndex: 0);
  final first = ordered[found];
  return (
    streams: <StreamResult>[
      first,
      for (var i = 0; i < ordered.length; i++)
        if (i != found) ordered[i],
    ],
    start: 0,
    lastUsedIndex: 0,
  );
}

/// Whether [stream] says it carries [language] (v9): its label or its
/// provider's name spells the language out. Never a guess.
bool streamStatesLanguage(StreamResult stream, SourceLanguage language) =>
    language != SourceLanguage.off &&
    textStatesLanguage('${stream.source} ${stream.providerName}', language);

/// Stable identity of one source, for remembering the last-played source
/// per title. The stream URL itself is NOT stable: signed links (DriveSeed
/// and friends) are re-issued on every load, so the exact-URL match in
/// [_savedStreamIndex] never hits for them and the title re-opens on
/// Source 1. The provider label + quality are re-scraped identically on
/// every load, so they identify the same row. A label that ever changes
/// just misses and the resolver falls back to Source 1, as before.
String streamSourceKey(StreamResult stream) =>
    '${stream.providerName}\u0001${stream.source}\u0001${stream.quality ?? 0}';

/// The [StreamResult] identity a [streamSourceKey] names, pointed at a
/// local file: the kept temp file that source downloaded, opened under
/// the source's own label. Remembering it writes back the same key, so
/// the next open finds the same file again, and the Sources panel names
/// the real source instead of a generic "Local" row. Null when [key]
/// is not a key this function wrote — the caller then falls back to the
/// normal resolve.
StreamResult? localStreamForSourceKey(String key, {required String localUrl}) {
  final parts = key.split('\u0001');
  if (parts.length != 3) return null;
  final provider = parts[0];
  final source = parts[1];
  final quality = int.tryParse(parts[2]);
  if (provider.isEmpty || source.isEmpty) return null;
  return StreamResult(
    url: localUrl,
    source: source,
    providerName: provider,
    quality: quality == null || quality <= 0 ? null : quality,
  );
}

/// Hive settings-box key for the per-title last-source map: title URL
/// (the same identity Continue Watching uses) -> [streamSourceKey].
const String kLastSourceByTitleKey = 'player_last_source_by_title';

/// The persisted last-source map, or empty when there is none or it is
/// unreadable. A corrupted box reads as no memory, and the resolver picks
/// fresh, which is where the viewer would have been anyway.
Map<String, String> readLastSourceMap(ProviderReader read) {
  try {
    final stored = read(
      settingsRepositoryProvider,
    ).getPlayerSetting<String>(kLastSourceByTitleKey);
    if (stored == null || stored.isEmpty) return <String, String>{};
    final decoded = jsonDecode(stored);
    if (decoded is! Map) return <String, String>{};
    return decoded.map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
  } catch (_) {
    return <String, String>{};
  }
}

/// The source the user last watched this title on, so switching episodes keeps
/// the working provider instead of re-picking from scratch. -1 when none is
/// remembered or it is not among [streams].
int _savedStreamIndex(
  ProviderReader read,
  MultimediaItem item,
  List<StreamResult> streams,
) {
  try {
    final isSeries =
        item.contentType == MultimediaContentType.series ||
        item.contentType == MultimediaContentType.anime;

    String? lastUrl;
    if (isSeries) {
      lastUrl = read(historyRepositoryProvider).getLastStreamUrl(item.url);
    }
    lastUrl ??= read(watchHistoryProvider)
        .firstWhereOrNull((h) => h.item.url == item.url)
        ?.lastStreamUrl;

    if (lastUrl != null) {
      final found = streams.indexWhere((s) => s.url == lastUrl);
      if (found != -1) return found;
    }
    // +46: the URL match above misses whenever the provider re-issues
    // signed links (DriveSeed): the last-played source is remembered by
    // its stable label instead — see [streamSourceKey]. A label that
    // changed just misses and the title opens on Source 1, as before.
    final lastKey = readLastSourceMap(read)[item.url];
    if (lastKey != null) {
      final found = streams.indexWhere(
        (s) => streamSourceKey(s) == lastKey,
      );
      if (found != -1) return found;
    }
  } catch (e) {
    if (kDebugMode) debugPrint('resolvePlayback: saved stream lookup: $e');
  }
  return -1;
}

/// How long the rolling check may run before playback starts regardless: on
/// the best candidate it has found, or the preferred one when it has found
/// none. Fifty dead links at up to six seconds a batch is minutes of spinner.
const Duration kProbeBudget = Duration(seconds: 10);

/// Checks candidates in priority order, [limit] at a time, and resolves as
/// soon as the highest-priority healthy one is known - with [0,1,2], a
/// healthy 0 returns immediately rather than waiting on 1 and 2.
///
/// Rolling: a candidate found dead hands its place to the next unchecked one
/// in line, so the check keeps [limit] going until something answers - and
/// carries on doing so after it has answered, in the background, for the ones
/// still out: the source list shows every slot filled rather than a dead one
/// left where it fell. It used to look at the top three and stop, which left
/// a dead one among them unreplaced and, with all three dead, opened the
/// first of them anyway. Completing the caller's `abandon` stops it.
///
/// Falls back to [startIndex] if every candidate fails, so a wrong probe never
/// blocks playback outright, and to the best found so far once [budget] runs
/// out.
Future<int> _firstHealthyStream(
  List<StreamResult> streams, {
  required int startIndex,
  required int limit,
  required Duration budget,
  bool Function()? isCancelled,
  void Function(int index, ProbeOutcome outcome)? onProbe,
  Future<int>? pick,
  Future<void>? abandon,
}) async {
  if (streams.isEmpty) return 0;
  final start = startIndex.clamp(0, streams.length - 1);

  // Every candidate, in priority order: the preferred one, then the rest of
  // the ring after it.
  final order = <int>[
    for (var i = 0; i < streams.length; i++) (start + i) % streams.length,
  ];
  if (order.length <= 1) return start;

  final completer = Completer<int>();
  final results = <int, bool>{};
  var dispatched = 0;
  var abandoned = false;
  Timer? deadline;

  /// Ends the check on [index]. The deadline goes in the same breath, not
  /// after the caller wakes: a probe answering as the screen closes would
  /// otherwise leave it armed for up to [budget] behind a dead screen.
  void finish(int index) {
    if (completer.isCompleted) return;
    deadline?.cancel();
    completer.complete(index);
  }

  /// The best answer the check has actually produced: the highest-priority
  /// healthy candidate, or [start] when there is none.
  int bestSoFar() {
    for (final c in order) {
      if (results[c] ?? false) return c;
    }
    return start;
  }

  void decide() {
    if (completer.isCompleted) return;
    // Dispatch follows priority, so nothing undispatched can outrank what is.
    for (final c in order.take(dispatched)) {
      final answer = results[c];
      if (answer == null) return; // a better one is still in flight
      if (answer) {
        finish(c);
        return;
      }
    }
    if (dispatched == order.length) finish(start); // all failed
  }

  late final void Function() dispatchNext;

  void record(int idx, ProbeOutcome outcome) {
    // Reported before the completion guard, so a candidate that answers after
    // the check is over still explains itself rather than staying "trying"
    // on screen forever.
    onProbe?.call(idx, outcome);
    results[idx] = outcome.reached;
    // Also once decided: the replacement is for the list, not the choice.
    if (!outcome.reached && !abandoned) dispatchNext();
    decide();
  }

  dispatchNext = () {
    if (dispatched >= order.length) return;
    final idx = order[dispatched++];
    onProbe?.call(idx, ProbeOutcome.trying);
    unawaited(
      probeSource(streams[idx])
          .then((outcome) => record(idx, outcome))
          .catchError((_) => record(idx, ProbeOutcome.unhealthy)),
    );
  };

  // Armed before the probes are dispatched: a pick that has already happened
  // must win the race rather than lose it by a microtask.
  if (pick != null) {
    unawaited(
      pick.then((index) {
        if (index < 0 || index >= streams.length) return;
        finish(index);
      }),
    );
  }

  if (abandon != null) {
    unawaited(
      abandon.then((_) {
        abandoned = true;
        finish(start);
      }),
    );
  }
  deadline = Timer(budget, () => finish(bestSoFar()));

  for (var i = 0; i < limit; i++) {
    dispatchNext();
  }

  final winner = await completer.future;
  if (isCancelled?.call() ?? false) return start;
  return winner;
}

/// Whether the health probe has no way to look at this candidate, and so
/// passes it without asking: a torrent is served by the local engine once it
/// is seeded, and a bare path is a file on this device.
///
/// A pass from the probe on one of these therefore says nothing, which the
/// source list has to know before it calls one reachable.
bool isUncheckableSource(StreamResult stream) =>
    stream.url.startsWith('magnet:') ||
    stream.url.endsWith('.torrent') ||
    stream.url.startsWith('/') ||
    _servedByTorrServer(stream.url);

/// A file the app's torrent server serves from a torrent it holds - a pack
/// file the viewer picked. Its loopback address answers only while that
/// torrent is loaded, so a check says nothing about the swarm.
bool _servedByTorrServer(String url) {
  final uri = Uri.tryParse(url);
  return uri != null &&
      uri.host == '127.0.0.1' &&
      uri.path == '/stream' &&
      uri.queryParameters.containsKey('link');
}

/// The health probe for one source, outside the race: the same ranged GET and
/// HEAD, for a source opened without having been checked - picked by the
/// viewer from past the top few, or reached by failover.
Future<bool> isReachable(StreamResult stream) async =>
    (await probeSource(stream)).reached;

/// What the health probe finds out about one source, outside the race.
Future<ProbeOutcome> probeSource(StreamResult stream) async =>
    (await checkSource(stream, headAfterError: true)).outcome;

/// How long a check waits for a server's headers (spec *Error handling*:
/// "checks have the probe's 3 s timeouts").
const Duration kCheckTimeout = Duration(seconds: 3);

/// A ranged GET for the first kilobyte, with the source's headers, and what it
/// answered (spec 2: "the check is the player's existing ranged GET, with the
/// source's headers, so it also yields the HTTP status").
///
/// The GET answers all the race asks in one request: whether the link
/// answers, whether its server serves byte ranges - the only way a player can
/// jump into a file over HTTP - and, from the first bytes, whether it is a
/// video at all. A HEAD proves only the first, so it is the fallback rather
/// than the lead: a server that refuses the ranged request but answers a
/// plain one still counts as reachable, with nothing said about seeking.
///
/// What recovery needs is the class (see [CheckResult]), and a dead host
/// must cost it no more than one timeout: a network error returns at once
/// with no HEAD - a refused GET means a refused HEAD - and so do the statuses
/// that settle a class. Only another 4xx, a server that may refuse ranged
/// GETs, is put to the HEAD. [headAfterError] keeps the race's HEAD after any
/// failure, which is how it finds slow hosts.
Future<CheckResult> checkSource(
  StreamResult stream, {
  bool headAfterError = false,
  Duration timeout = kCheckTimeout,
}) async {
  final watch = Stopwatch()..start();
  CheckResult done(
    CheckClass kind,
    ProbeOutcome outcome, {
    int? status,
    NetworkFault? fault,
    Duration? retryAfter,
  }) => CheckResult(
    kind: kind,
    outcome: outcome,
    status: status,
    fault: fault,
    retryAfter: retryAfter,
    elapsed: watch.elapsed,
  );

  if (isUncheckableSource(stream)) {
    return done(CheckClass.answers, ProbeOutcome.healthy);
  }
  final uri = Uri.tryParse(stream.url);
  if (uri == null || !uri.hasScheme) {
    return done(CheckClass.gone, ProbeOutcome.unhealthy);
  }
  final headers = playbackHeaders(stream);

  int? status;
  Duration? retryAfter;
  NetworkFault? fault;
  final client = http.Client();
  try {
    final request = http.Request('GET', uri);
    request.headers.addAll(headers);
    request.headers.putIfAbsent(
      'Range',
      () => 'bytes=0-${kProbeSniffBytes - 1}',
    );
    final resp = await client.send(request).timeout(timeout);
    // Nothing to range over: an empty file, which the old one-byte check
    // passed too.
    if (resp.statusCode == 416) {
      return done(CheckClass.answers, ProbeOutcome.healthy, status: 416);
    }
    if (resp.statusCode < 400) {
      final type = resp.headers['content-type'];
      // Only a page or a playlist is worth reading; a server that ignores the
      // range is sending the whole file behind these bytes.
      final head = mayBeWebPage(type)
          ? await _firstBytes(resp.stream)
                .timeout(timeout, onTimeout: () => const <int>[])
          : const <int>[];
      return done(
        CheckClass.answers,
        _outcomeOf(stream.url, uri, resp, head),
        status: resp.statusCode,
      );
    }
    status = resp.statusCode;
    retryAfter = retryAfterOf(resp.headers['retry-after'], now: clock.now());
  } catch (error) {
    fault = networkFaultOf(error);
  } finally {
    // Hangs up whatever of the body was not read.
    client.close();
  }

  final kind = status == null ? CheckClass.network : checkClassOfStatus(status);
  CheckResult refused() => done(
    kind,
    ProbeOutcome.unhealthy,
    status: status,
    fault: kind == CheckClass.network ? fault : null,
    retryAfter: kind == CheckClass.busy ? retryAfter : null,
  );
  final headDecides =
      status != null &&
      kind == CheckClass.gone &&
      !kGoneStatuses.contains(status);
  if (!headDecides && !headAfterError) return refused();

  try {
    final resp = await http.head(uri, headers: headers).timeout(timeout);
    if (resp.statusCode < 400) {
      return done(
        CheckClass.answers,
        ProbeOutcome.healthy,
        status: resp.statusCode,
      );
    }
  } catch (_) {
    // No answer to the HEAD either.
  }
  return refused();
}

/// What an answer to the ranged GET says about playing [url], which the
/// source names as [address].
ProbeOutcome _outcomeOf(
  String address,
  Uri url,
  http.BaseResponse resp,
  List<int> head,
) {
  final type = resp.headers['content-type'];
  if (isPlaylist(url, type, head)) return ProbeOutcome.healthy;
  if (isWebPage(type, head)) return ProbeOutcome.notVideo;
  // A media answer: its size is what the buffer rule sizes from.
  _rememberSize(address, resp);
  final ranged =
      resp.statusCode == 206 ||
      resp.headers.containsKey('content-range') ||
      (resp.headers['accept-ranges']?.toLowerCase().contains('bytes') ?? false);
  return ranged ? ProbeOutcome.healthy : ProbeOutcome.unseekable;
}

/// The file sizes the health probe read, by address: what the buffer rule
/// sizes from (spec 1.2), which a [ProbeOutcome] doesn't carry. The newest 64
/// are kept.
final Map<String, int> _probedSizes = <String, int>{};

/// The size the health probe read for [url], in bytes, or null when it read
/// none.
int? probedSizeOf(String url) => _probedSizes[url];

/// A media answer's file size: the total of its `Content-Range`, or the
/// `Content-Length` of a 200, which is a server ignoring the range and
/// sending the whole file.
@visibleForTesting
int? fileSizeFromHeaders(int status, Map<String, String> headers) {
  final range = headers['content-range'];
  if (range != null) {
    final total = int.tryParse(range.split('/').last.trim());
    return total != null && total > 0 ? total : null;
  }
  if (status != 200) return null;
  final length = int.tryParse(headers['content-length'] ?? '');
  return length != null && length > 0 ? length : null;
}

void _rememberSize(String url, http.BaseResponse resp) {
  final size = fileSizeFromHeaders(resp.statusCode, resp.headers);
  if (size == null) return;
  _probedSizes.remove(url);
  _probedSizes[url] = size;
  if (_probedSizes.length > 64) _probedSizes.remove(_probedSizes.keys.first);
}

/// Up to [kProbeSniffBytes] from the start of [body]. Leaving the loop early
/// cancels the subscription, so the rest is never read.
Future<List<int>> _firstBytes(Stream<List<int>> body) async {
  final bytes = <int>[];
  await for (final chunk in body) {
    final room = kProbeSniffBytes - bytes.length;
    bytes.addAll(chunk.length > room ? chunk.sublist(0, room) : chunk);
    if (bytes.length >= kProbeSniffBytes) break;
  }
  return bytes;
}
