import '../../../core/domain/entity/multimedia_item.dart';

/// The category a search's results are filtered by — the design preview's
/// Search chips: All, Movies, TV Shows, Anime, K-Drama, 4K.
///
/// The chips filter the results already on screen; they do not re-run the
/// search, because extensions search by query text only and cannot be scoped
/// by category server-side.
enum SearchCategory { all, movies, tvShows, anime, kDrama, fourK }

/// The chip's label, as the design preview spells it.
String searchCategoryLabel(SearchCategory category) => switch (category) {
  SearchCategory.all => 'All',
  SearchCategory.movies => 'Movies',
  SearchCategory.tvShows => 'TV Shows',
  SearchCategory.anime => 'Anime',
  SearchCategory.kDrama => 'K-Drama',
  SearchCategory.fourK => '4K',
};

/// Whether [item] belongs under [category].
///
/// Movies, TV Shows and Anime read the item's content type, which every
/// result carries. The other two read fields only some results carry:
///
/// * K-Drama matches a series whose tags name it (`k-drama`, `korean`) —
///   extension results are rebuilt without tags (see `searchAllProviders`),
///   so they never match, and the chip is empty for them.
/// * 4K matches an item with a stream at 2160 lines or more — same caveat:
///   extension results carry no streams, so they never match.
///
/// Both are honest limits of what a search result knows, not of the filter:
/// results that do carry the field (TMDB, Stremio add-ons) filter correctly.
bool matchesSearchCategory(MultimediaItem item, SearchCategory category) {
  switch (category) {
    case SearchCategory.all:
      return true;
    case SearchCategory.movies:
      return item.contentType == MultimediaContentType.movie;
    case SearchCategory.tvShows:
      return item.contentType == MultimediaContentType.series;
    case SearchCategory.anime:
      return item.contentType == MultimediaContentType.anime;
    case SearchCategory.kDrama:
      if (item.contentType != MultimediaContentType.series) return false;
      final tags = item.tags;
      if (tags == null) return false;
      return tags.any((tag) {
        final folded = tag.toLowerCase();
        return folded.contains('k-drama') || folded.contains('korean');
      });
    case SearchCategory.fourK:
      final streams = item.streams;
      if (streams == null) return false;
      return streams.any((stream) => (stream.quality ?? 0) >= 2160);
  }
}
