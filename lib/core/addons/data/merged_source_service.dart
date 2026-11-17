import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entity/multimedia_item.dart';
import '../../extensions/base_provider.dart';
import '../../extensions/extension_manager.dart';
import '../../nuvio/data/nuvio_stream_service.dart';
import '../../nuvio/models/nuvio_models.dart';
import '../models/addon_manifest.dart';
import '../models/addon_stream_source.dart';
import 'addon_repository.dart';
import 'addon_stream_service.dart';

/// Sources for a title opened from Browse (a Cinemeta title), from all three
/// kinds of thing a person can install: their plugins (.cs3 and the rest of
/// the extension system), their Nuvio providers and their Stremio add-ons.
final mergedSourceServiceProvider = Provider<MergedSourceService>((ref) {
  return MergedSourceService(
    plugins: () => ref.read(extensionManagerProvider),
    streamAddons: () => AddonStreamService.streamProvidersOf(
      ref.read(addonRepositoryProvider).enabled,
    ),
    askAddons:
        ({
          required addons,
          required request,
          required forceRefresh,
          required personWaiting,
        }) => ref
            .read(addonStreamServiceProvider)
            .resolve(
              addons: addons,
              request: request,
              forceRefresh: forceRefresh,
              personWaiting: personWaiting,
            ),
    askNuvio:
        ({
          required id,
          required mediaType,
          season,
          episode,
          required personWaiting,
          required fresh,
        }) => ref
            .read(nuvioStreamServiceProvider)
            .resolve(
              tmdbId: id,
              mediaType: mediaType,
              season: season,
              episode: episode,
              personWaiting: personWaiting,
              fresh: fresh,
            ),
  );
});

typedef AskAddons = Stream<AddonStreamProgress> Function({
  required List<ManagedAddon> addons,
  required AddonStreamRequest request,
  required bool forceRefresh,
  required bool personWaiting,
});

typedef AskNuvio = Stream<NuvioProgress> Function({
  required String id,
  required String mediaType,
  int? season,
  int? episode,
  required bool personWaiting,
  required bool fresh,
});

/// `addonId` prefixes that say which kind of source a link came from.
const String kPluginSourcePrefix = 'plugin:';
const String kNuvioSourcePrefix = 'nuvio:';

/// Asks plugins, Nuvio providers and Stremio add-ons for one title at once
/// and merges what they answer into the add-on sheet's own progress model,
/// so the sheet, its filters and playback work unchanged.
///
/// Every source is labelled with where it came from: `addonName` is the
/// plugin's, Nuvio provider's or add-on's own name.
class MergedSourceService {
  MergedSourceService({
    required List<SkyStreamProvider> Function() plugins,
    required List<ManagedAddon> Function() streamAddons,
    required AskAddons askAddons,
    required AskNuvio askNuvio,
    this.searchTimeout = const Duration(seconds: 25),
    this.detailsTimeout = const Duration(seconds: 30),
    this.streamsTimeout = const Duration(seconds: 45),
    this.maxConcurrentPlugins = 4,
  }) : _plugins = plugins,
       _streamAddons = streamAddons,
       _askAddons = askAddons,
       _askNuvio = askNuvio;

  final List<SkyStreamProvider> Function() _plugins;
  final List<ManagedAddon> Function() _streamAddons;
  final AskAddons _askAddons;
  final AskNuvio _askNuvio;

  final Duration searchTimeout;
  final Duration detailsTimeout;
  final Duration streamsTimeout;

  /// Plugins asked at once. Each runs a search, a details load and a links
  /// load in its engine; a handful at a time keeps the phone responsive.
  final int maxConcurrentPlugins;

  /// Emits a snapshot whenever any plugin, Nuvio provider or add-on answers,
  /// so links show as they arrive rather than after the slowest one. A
  /// source that fails or finds nothing only shows in the statuses.
  Stream<AddonStreamProgress> resolve({
    required AddonStreamRequest request,
    bool forceRefresh = false,
    bool personWaiting = false,
  }) {
    final controller = StreamController<AddonStreamProgress>();
    var cancelled = false;
    final subs = <StreamSubscription<dynamic>>[];

    final title = request.title?.trim() ?? '';
    final plugins = title.isEmpty
        ? const <SkyStreamProvider>[]
        : [
            for (final p in _plugins())
              if (p.hasSearch) p,
          ];
    final addons = _streamAddons();

    // Nuvio providers are asked by TMDB/IMDb id; a title with neither has
    // nothing to ask them with.
    final nuvioId = nuvioIdFor(request);

    var addonProgress = const AddonStreamProgress();
    var addonsDone = addons.isEmpty;
    var nuvioProgress = const NuvioProgress();
    var nuvioDone = nuvioId == null;
    String? addonError;
    String? nuvioError;

    final pluginStreams = <AddonStreamSource>[];
    final pluginSeen = <String>{};
    final pluginStatuses = <String, AddonQueryStatus>{
      for (final p in plugins)
        p.packageName: AddonQueryStatus(
          addonName: p.name,
          outcome: AddonQueryOutcome.pending,
          origin: kOriginPlugin,
        ),
    };
    var pluginsCompleted = 0;

    AddonStreamProgress snapshot() {
      final nuvioStreams = [
        for (final r in nuvioProgress.streams) nuvioToSource(r, title: title),
      ];
      final loading =
          !addonsDone || !nuvioDone || pluginsCompleted < plugins.length;
      return AddonStreamProgress(
        streams: rankAddonStreams(
          [...pluginStreams, ...nuvioStreams, ...addonProgress.streams],
          title: request.title,
          year: request.year,
          // v7: the merged list is ordered by quality, best first.
          byQuality: true,
        ),
        statuses: [
          // v8: every kind says where it stands, also when there was
          // nothing to ask, so a kind is never silently missing.
          if (plugins.isEmpty)
            AddonQueryStatus(
              addonName: 'Plugins',
              outcome: AddonQueryOutcome.empty,
              message: title.isEmpty
                  ? 'this title has no name to search with'
                  : 'none installed',
              origin: kOriginPlugin,
              isNote: true,
            ),
          ...pluginStatuses.values,
          if (nuvioId == null)
            const AddonQueryStatus(
              addonName: 'Nuvio',
              outcome: AddonQueryOutcome.empty,
              message: 'this title has no TMDB or IMDb id',
              origin: kOriginNuvio,
              isNote: true,
            )
          else if (nuvioError != null)
            AddonQueryStatus(
              addonName: 'Nuvio',
              outcome: AddonQueryOutcome.failed,
              message: nuvioError,
              origin: kOriginNuvio,
              isNote: true,
            )
          else if (nuvioDone && nuvioProgress.statuses.isEmpty)
            AddonQueryStatus(
              addonName: 'Nuvio',
              outcome: AddonQueryOutcome.empty,
              message:
                  'no provider enabled for '
                  '${request.type == 'series' ? 'series' : 'movies'}',
              origin: kOriginNuvio,
              isNote: true,
            ),
          for (final s in nuvioProgress.statuses) _nuvioStatus(s),
          if (addons.isEmpty)
            const AddonQueryStatus(
              addonName: 'Stremio',
              outcome: AddonQueryOutcome.empty,
              message: 'no stream add-on installed',
              origin: kOriginStremio,
              isNote: true,
            )
          else if (addonError != null)
            AddonQueryStatus(
              addonName: 'Stremio',
              outcome: AddonQueryOutcome.failed,
              message: addonError,
              origin: kOriginStremio,
              isNote: true,
            ),
          for (final s in addonProgress.statuses)
            AddonQueryStatus(
              addonName: s.addonName,
              outcome: s.outcome,
              linkCount: s.linkCount,
              message: s.message,
              origin: kOriginStremio,
            ),
        ],
        completedCount:
            pluginsCompleted +
            nuvioProgress.completedCount +
            addonProgress.completedCount,
        totalCount:
            plugins.length +
            nuvioProgress.totalCount +
            addonProgress.totalCount,
        isLoading: loading,
      );
    }

    void emit() {
      if (cancelled || controller.isClosed) return;
      controller.add(snapshot());
      final done =
          addonsDone && nuvioDone && pluginsCompleted >= plugins.length;
      if (done) unawaited(controller.close());
    }

    Future<void> runPlugin(SkyStreamProvider plugin) async {
      var outcome = AddonQueryOutcome.empty;
      String? message = 'no match for this title';
      var added = 0;
      try {
        final found = await _pluginSources(plugin, request, () => cancelled);
        for (final source in found) {
          if (!pluginSeen.add(source.dedupeKey)) continue;
          pluginStreams.add(source);
          added++;
        }
        if (added > 0) {
          outcome = AddonQueryOutcome.links;
          message = null;
        }
      } catch (error) {
        // A plugin that fails is skipped; the details panel says why.
        outcome = AddonQueryOutcome.failed;
        message = error is TimeoutException
            ? 'took too long to answer'
            : error.toString();
        if (kDebugMode) {
          debugPrint('[MergedSources] ${plugin.name} failed: $error');
        }
      }
      pluginStatuses[plugin.packageName] = AddonQueryStatus(
        addonName: plugin.name,
        outcome: outcome,
        linkCount: added,
        message: message,
        origin: kOriginPlugin,
      );
      pluginsCompleted++;
      emit();
    }

    void start() {
      if (!addonsDone) {
        subs.add(
          _askAddons(
            addons: addons,
            request: request,
            forceRefresh: forceRefresh,
            personWaiting: personWaiting,
          ).listen(
            (progress) {
              addonProgress = progress;
              emit();
            },
            onError: (Object error) {
              addonError = error.toString();
              if (kDebugMode) debugPrint('[MergedSources] add-ons: $error');
              emit();
            },
            onDone: () {
              addonsDone = true;
              emit();
            },
          ),
        );
      }
      if (!nuvioDone) {
        subs.add(
          _askNuvio(
            id: nuvioId!,
            mediaType: request.type == 'series' ? 'tv' : 'movie',
            season: request.season,
            episode: request.episode,
            personWaiting: personWaiting,
            fresh: forceRefresh,
          ).listen(
            (progress) {
              nuvioProgress = progress;
              emit();
            },
            onError: (Object error) {
              nuvioError = error.toString();
              if (kDebugMode) debugPrint('[MergedSources] nuvio: $error');
              emit();
            },
            onDone: () {
              nuvioDone = true;
              emit();
            },
          ),
        );
      }

      final queue = List<SkyStreamProvider>.of(plugins);
      final workers = plugins.length < maxConcurrentPlugins
          ? plugins.length
          : maxConcurrentPlugins;
      for (var i = 0; i < workers; i++) {
        unawaited(() async {
          while (queue.isNotEmpty && !cancelled) {
            await runPlugin(queue.removeAt(0));
          }
        }());
      }

      // The first snapshot, so the sheet shows who is being asked; it also
      // closes the stream at once when nothing is installed at all.
      emit();
    }

    controller
      ..onListen = start
      ..onCancel = () async {
        cancelled = true;
        for (final sub in subs) {
          await sub.cancel();
        }
      };
    return controller.stream;
  }

  /// The id Nuvio providers are asked with. They are written against a
  /// numeric TMDB id, so the title's own TMDB id comes first (Cinemeta sends
  /// one): an IMDb id has to be converted through TMDB's API, which needs a
  /// key the app may not have, and a provider handed a bare `tt…` answers
  /// nothing.
  @visibleForTesting
  static String? nuvioIdFor(AddonStreamRequest request) {
    if (request.tmdbId != null) return '${request.tmdbId}';
    final imdb = request.imdbId?.trim();
    if (imdb != null && imdb.startsWith('tt')) return imdb;
    final base = request.contentId.split(':').first.trim();
    if (RegExp(r'^tt\d').hasMatch(base)) return base;
    if (request.contentId.startsWith('tmdb:')) {
      final id = request.contentId.split(':').elementAtOrNull(1);
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  static AddonQueryStatus _nuvioStatus(NuvioScraperStatus status) =>
      AddonQueryStatus(
        addonName: status.scraperName,
        outcome: switch (status.outcome) {
          NuvioScraperOutcome.pending ||
          NuvioScraperOutcome.running => AddonQueryOutcome.pending,
          NuvioScraperOutcome.links => AddonQueryOutcome.links,
          NuvioScraperOutcome.empty ||
          NuvioScraperOutcome.unsupported => AddonQueryOutcome.empty,
          NuvioScraperOutcome.failed => AddonQueryOutcome.failed,
        },
        linkCount: status.linkCount,
        message: status.message,
        origin: kOriginNuvio,
      );

  /// One plugin: search it for the title, open the best match, then load the
  /// links of the film — or of the wanted episode.
  Future<List<AddonStreamSource>> _pluginSources(
    SkyStreamProvider plugin,
    AddonStreamRequest request,
    bool Function() cancelled,
  ) async {
    final title = request.title!.trim();
    final results = await plugin.search(title).timeout(searchTimeout);
    if (cancelled()) return const [];
    final match = bestTitleMatch(
      results,
      title: title,
      year: request.year,
      isSeries: request.type == 'series',
      season: request.season,
    );
    if (match == null) return const [];

    final details = await plugin.getDetails(match.url).timeout(detailsTimeout);
    if (cancelled()) return const [];
    final dataUrl = playUrlFor(
      details,
      isSeries: request.type == 'series',
      season: request.season,
      episode: request.episode,
    );
    if (dataUrl == null || dataUrl.isEmpty) return const [];

    final streams = await plugin.loadStreams(dataUrl).timeout(streamsTimeout);
    return [
      for (var i = 0; i < streams.length; i++)
        if (streams[i].url.trim().isNotEmpty)
          pluginToSource(
            streams[i],
            plugin: plugin,
            matchedTitle: details.title.isNotEmpty
                ? details.title
                : match.title,
            index: i,
          ),
    ];
  }
}

final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final RegExp _yearToken = RegExp(r'\b(19|20)\d\d\b');
final RegExp _seasonToken = RegExp(
  r'\b(?:season|s)\s*0*(\d{1,2})\b',
  caseSensitive: false,
);

String _normalize(String text) =>
    text.toLowerCase().replaceAll(_nonWord, ' ').trim();

/// The search result of a plugin that is the wanted title, or null when none
/// is close enough to trust.
///
/// A result must be the title itself or start with it ("Inception (2010)
/// Hindi Dubbed"); a result that names a different year, or another season
/// of the show, is passed over.
@visibleForTesting
MultimediaItem? bestTitleMatch(
  List<MultimediaItem> results, {
  required String title,
  int? year,
  bool isSeries = false,
  int? season,
}) {
  final wanted = _normalize(title);
  if (wanted.isEmpty) return null;

  MultimediaItem? best;
  var bestScore = 0;
  for (final item in results) {
    final name = _normalize(item.title);
    if (name.isEmpty) continue;

    int score;
    if (name == wanted) {
      score = 100;
    } else if (name.startsWith('$wanted ')) {
      score = 70;
    } else if (' $name '.contains(' $wanted ') && wanted.length >= 6) {
      score = 50;
    } else {
      continue;
    }

    // The year, from the item or from its title ("Dune (2021)").
    final itemYear =
        item.year ??
        int.tryParse(_yearToken.firstMatch(item.title)?.group(0) ?? '');
    if (year != null && itemYear != null && !isSeries) {
      if ((itemYear - year).abs() > 1) continue;
      if (itemYear == year) score += 20;
    }

    final type = item.contentType;
    if (isSeries && type == MultimediaContentType.movie) score -= 30;
    if (!isSeries &&
        (type == MultimediaContentType.series ||
            type == MultimediaContentType.anime)) {
      score -= 30;
    }

    // Sites that list each season on its own page.
    if (isSeries && season != null) {
      final named = int.tryParse(
        _seasonToken.firstMatch(item.title)?.group(1) ?? '',
      );
      if (named != null) score += named == season ? 15 : -40;
    }

    if (score > bestScore) {
      bestScore = score;
      best = item;
    }
  }
  return bestScore >= 40 ? best : null;
}

/// What to hand a plugin's `loadStreams` for [details]: the film's own data
/// url, or the url of the wanted episode. Null when the plugin doesn't list
/// that episode.
@visibleForTesting
String? playUrlFor(
  MultimediaItem details, {
  required bool isSeries,
  int? season,
  int? episode,
}) {
  final episodes = details.episodes ?? const <Episode>[];
  if (!isSeries || season == null || episode == null) {
    return episodes.isNotEmpty ? episodes.first.url : details.url;
  }
  for (final e in episodes) {
    if (e.season == season && e.episode == episode) return e.url;
  }
  // A page that holds one season only, numbered however the site likes
  // (0, 1, or the real season): the episode number alone says which.
  final seasons = {for (final e in episodes) e.season};
  if (seasons.length == 1) {
    final named = int.tryParse(
      _seasonToken.firstMatch(details.title)?.group(1) ?? '',
    );
    if (named == season || (named == null && season == 1)) {
      for (final e in episodes) {
        if (e.episode == episode) return e.url;
      }
    }
  }
  return null;
}

String _qualityText(int? quality) {
  if (quality == null || quality <= 0) return '';
  return '${quality}p';
}

/// A plugin's link, as a row of the sources sheet. `addonName` is the
/// plugin's name: the row's "where it came from".
@visibleForTesting
AddonStreamSource pluginToSource(
  StreamResult stream, {
  required SkyStreamProvider plugin,
  required String matchedTitle,
  required int index,
}) {
  final quality = _qualityText(stream.quality);
  final server = stream.source.trim();
  final label = [
    if (server.isNotEmpty) server,
    if (quality.isNotEmpty && !server.contains(quality)) quality,
  ].join(' ');
  final subs = stream.subtitles ?? const <SubtitleFile>[];
  return AddonStreamSource(
    addonId: '$kPluginSourcePrefix${plugin.packageName}',
    addonName: plugin.name,
    url: stream.url,
    title: label.isEmpty ? null : label,
    description: matchedTitle,
    proxyHeaders: (stream.headers?.isEmpty ?? true) ? null : stream.headers,
    subtitles: [
      for (var i = 0; i < subs.length; i++)
        if (subs[i].url.startsWith('http'))
          AddonSubtitleTrack(
            id: '${plugin.packageName}-$index-$i',
            url: subs[i].url,
            lang: (subs[i].lang ?? subs[i].label).trim().isEmpty
                ? 'en'
                : (subs[i].lang ?? subs[i].label).trim(),
            addonName: plugin.name,
          ),
    ],
  );
}

/// A Nuvio provider's link, as a row of the sources sheet. `addonName` is
/// the Nuvio provider's name.
@visibleForTesting
AddonStreamSource nuvioToSource(NuvioStreamResult result, {String? title}) {
  final isMagnet = result.url.startsWith('magnet:');
  final quality = (result.quality ?? '').trim();
  final label = [
    (result.name ?? '').trim(),
    if (quality.isNotEmpty && !(result.name ?? '').contains(quality)) quality,
    if ((result.size ?? '').trim().isNotEmpty) result.size!.trim(),
  ].where((part) => part.isNotEmpty).join(' ');
  return AddonStreamSource(
    addonId: '$kNuvioSourcePrefix${result.scraperId}',
    addonName: result.scraperName,
    url: isMagnet ? null : result.url,
    infoHash: (result.infoHash ?? '').isEmpty
        ? null
        : result.infoHash!.toLowerCase(),
    title: label.isEmpty ? null : label,
    description: result.title.trim().isEmpty ? title : result.title,
    proxyHeaders: (result.headers?.isEmpty ?? true) ? null : result.headers,
    subtitles: [
      for (var i = 0; i < result.subtitles.length; i++)
        if (result.subtitles[i].url.startsWith('http'))
          AddonSubtitleTrack(
            id: 'nuvio-${result.scraperId}-$i',
            url: result.subtitles[i].url,
            lang:
                (result.subtitles[i].lang ?? result.subtitles[i].label)
                    .trim()
                    .isEmpty
                ? 'en'
                : (result.subtitles[i].lang ?? result.subtitles[i].label)
                      .trim(),
            addonName: result.scraperName,
          ),
    ],
  );
}

/// The kind of source a merged-list row came from, as its tag says it:
/// PLUGIN, NUVIO or STREMIO.
String sourceOriginTag(AddonStreamSource source) {
  if (source.addonId.startsWith(kPluginSourcePrefix)) return 'PLUGIN';
  if (source.addonId.startsWith(kNuvioSourcePrefix)) return 'NUVIO';
  return 'STREMIO';
}

/// One line of the merged sheet's per-kind summary.
class OriginSummary {
  const OriginSummary({
    required this.origin,
    required this.text,
    this.isError = false,
    this.isPending = false,
  });

  final String origin;

  /// E.g. "Nuvio: 0 sources", "Plugins: 6 sources (1 failed)",
  /// "Nuvio: error — …", "Stremio: no stream add-on installed".
  final String text;
  final bool isError;
  final bool isPending;
}

/// What each kind - plugins, Nuvio, Stremio - has answered so far, one line
/// per kind and always all three, so none of them is ever silently missing.
List<OriginSummary> originSummaries(List<AddonQueryStatus> statuses) {
  const labels = {
    kOriginPlugin: 'Plugins',
    kOriginNuvio: 'Nuvio',
    kOriginStremio: 'Stremio',
  };
  return [
    for (final entry in labels.entries)
      _originSummary(entry.key, entry.value, [
        for (final s in statuses)
          // A re-asked add-on's status carries no kind: it is an add-on.
          if ((s.origin ?? kOriginStremio) == entry.key) s,
      ]),
  ];
}

OriginSummary _originSummary(
  String origin,
  String label,
  List<AddonQueryStatus> all,
) {
  final asked = [
    for (final s in all)
      if (!s.isNote) s,
  ];
  if (asked.isEmpty) {
    final note = all.where((s) => s.isNote).firstOrNull;
    if (note == null) {
      return OriginSummary(
        origin: origin,
        text: '$label: asking…',
        isPending: true,
      );
    }
    final failed = note.outcome == AddonQueryOutcome.failed;
    return OriginSummary(
      origin: origin,
      text: failed
          ? '$label: error — ${note.message ?? 'unknown'}'
          : '$label: ${note.message ?? 'nothing to ask'}',
      isError: failed,
    );
  }
  final links = asked.fold<int>(0, (sum, s) => sum + s.linkCount);
  final pending = asked
      .where((s) => s.outcome == AddonQueryOutcome.pending)
      .length;
  final failed = [
    for (final s in asked)
      if (s.outcome == AddonQueryOutcome.failed) s,
  ];
  final sources = '$links source${links == 1 ? '' : 's'}';
  if (pending > 0) {
    return OriginSummary(
      origin: origin,
      text:
          '$label: asking ${asked.length - pending}/${asked.length}… '
          '$sources so far',
      isPending: true,
    );
  }
  if (failed.length == asked.length) {
    return OriginSummary(
      origin: origin,
      text: '$label: error — ${failed.first.message ?? 'did not answer'}',
      isError: true,
    );
  }
  return OriginSummary(
    origin: origin,
    text: failed.isEmpty
        ? '$label: $sources'
        : '$label: $sources (${failed.length} failed)',
  );
}
