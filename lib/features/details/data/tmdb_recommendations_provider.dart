import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../explore/data/explore_language_provider.dart';
import '../../explore/data/explore_tmdb_provider.dart';
import 'tmdb_details_provider.dart';

/// TMDB recommendations for a title — the "More Like This" row on the
/// detail page (build 110, user 2026-11-21 01:51).
///
/// Empty list when there is no TMDB id, no key, no network, no
/// recommendations, or the title came from AniList (its ids are not
/// TMDB ids): the row hides itself, it never shows a fake or empty row.
///
/// A plain [FutureProvider.family] (no codegen) so no build_runner run
/// is needed for one new provider. Recommendations carry no `media_type`
/// in their JSON, so the row's own type is stamped in before mapping —
/// recommendations are always the same type as the title.
final tmdbRecommendationsProvider =
    FutureProvider.family<List<MultimediaItem>, MovieDetailsParams>((
      ref,
      params,
    ) async {
      if (params.source == 'anilist') return const <MultimediaItem>[];
      final service = ref.watch(tmdbServiceProvider);
      final language = ref.watch(languageProvider);
      final type = params.type.toLowerCase();
      final isTv = type == 'tv' || type == 'series' || type == 'tvseries';
      final results = isTv
          ? await service.getTvRecommendations(params.id, language: language)
          : await service.getMovieRecommendations(
              params.id,
              language: language,
            );
      if (results == null) return const <MultimediaItem>[];
      final mediaType = isTv ? 'tv' : 'movie';
      return results
          .map((json) {
            final withType = Map<String, dynamic>.of(json)
              ..['media_type'] = mediaType;
            return MultimediaItem.fromTmdbJson(withType);
          })
          .where((item) => item.tmdbId != null && item.posterUrl.isNotEmpty)
          .toList();
    });
