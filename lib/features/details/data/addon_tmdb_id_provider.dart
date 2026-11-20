import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/tmdb_config.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import 'metadata_resolution_service.dart';

/// The TMDB id for an add-on (plugin) title — the id Cast and
/// "More Like This" need on the plugin detail page (build 111, user
/// 2026-11-21 04:02: "cast or more like this nhi huwa" on Bull Run /
/// MoviesMod).
///
/// Most plugin titles carry no moviedbId, so the id is resolved the
/// same way the hero enrichment resolves one: TMDB search by title +
/// year, with the match threshold refusing a wrong film. A title TMDB
/// cannot match stays null and both rows stay hidden — never a fake id.
///
/// A plain [FutureProvider.family] (no codegen) so no build_runner run
/// is needed for one new provider.
class AddonTmdbIdParams {
  final int? moviedbId;
  final String title;
  final int? year;
  final bool isShow;

  const AddonTmdbIdParams({
    required this.moviedbId,
    required this.title,
    required this.year,
    required this.isShow,
  });

  @override
  bool operator ==(Object other) =>
      other is AddonTmdbIdParams &&
      other.moviedbId == moviedbId &&
      other.title == title &&
      other.year == year &&
      other.isShow == isShow;

  @override
  int get hashCode => Object.hash(moviedbId, title, year, isShow);
}

// autoDispose (build 112): a null or errored resolution used to stick for
// the whole app session — reopening the page reused the cached null and
// the rows never appeared until the app was killed. Leaving the page now
// drops the result, so reopening retries.
final addonTmdbIdProvider = FutureProvider.autoDispose
    .family<int?, AddonTmdbIdParams>((ref, params) async {
      // The add-on already knows: no search, no network.
      if (params.moviedbId != null) return params.moviedbId;
      if (TmdbConfig.apiKey.isEmpty) return null;
      final title = params.title.trim();
      if (title.isEmpty) return null;
      final enriched = await ref
          .watch(metadataResolutionServiceProvider)
          .enrichWithIds(
            MultimediaItem(
              title: title,
              url: '',
              posterUrl: '',
              year: params.year,
              contentType: params.isShow
                  ? MultimediaContentType.series
                  : MultimediaContentType.movie,
            ),
          );
      return enriched.tmdbId;
    });
