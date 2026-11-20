import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/multimedia_card.dart';
import '../../data/tmdb_details_provider.dart';
import '../../data/tmdb_recommendations_provider.dart';

/// "More Like This" (build 110, user 2026-11-21 01:51): TMDB
/// recommendations for the title, after Cast and Trailers & Extras, like
/// SkyStream's detail page.
///
/// Shows only when recommendations arrive; hides while loading, on
/// error and when there are none — never a fake or empty row. Posters
/// are the new smaller home-row size (130x~150 on phones). Tap opens
/// that title's detail page.
class MovieMoreLikeThis extends ConsumerWidget {
  const MovieMoreLikeThis({
    required this.movieId,
    required this.mediaType,
    this.source,
    super.key,
  });

  final int movieId;
  final String mediaType;
  final String? source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recommendations = ref.watch(
      tmdbRecommendationsProvider(
        MovieDetailsParams(movieId, mediaType, source: source),
      ),
    );
    final items = recommendations.asData?.value;
    if (items == null || items.isEmpty) return const SizedBox.shrink();

    final isDesktop = context.isDesktop;
    final cardWidth = isDesktop ? 200.0 : LayoutConstants.homePosterCardWidth;
    final imageHeight = isDesktop
        ? cardWidth / (2 / 3)
        : LayoutConstants.homePosterImageHeight;
    final listHeight = imageHeight + 40.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'More Like This',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: isDesktop ? 24 : 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: isDesktop ? 20 : 16),
        SizedBox(
          height: listHeight,
          child: ListView.builder(
            clipBehavior: Clip.none,
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            itemExtent: cardWidth + LayoutConstants.spacingSm,
            itemBuilder: (context, index) {
              final item = items[index];
              final heroTag = 'mlt_${movieId}_${item.id}_$index';
              return Padding(
                padding: const EdgeInsets.only(
                  right: LayoutConstants.spacingSm,
                ),
                child: MultimediaCard(
                  imageUrl: item.posterUrl,
                  title: item.title,
                  heroTag: heroTag,
                  onTap: () => TmdbDetailsRoute(
                    movieId: item.id,
                    mediaType: item.tmdbMediaType,
                    heroTag: heroTag,
                    placeholderPoster: item.posterUrl,
                    source: item.source,
                  ).push<void>(context),
                ),
              );
            },
          ),
        ),
        SizedBox(height: isDesktop ? 50 : 24),
      ],
    );
  }
}
