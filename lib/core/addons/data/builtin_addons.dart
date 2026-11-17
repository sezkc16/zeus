import '../models/addon_manifest.dart';

/// Add-ons ZoroX can fall back to without the user installing anything.
///
/// Catalog-only add-ons are extremely common — the Streaming Catalogs add-on
/// (Netflix/Disney+/Prime rows), Trakt lists, RPDB catalogs — and none of them
/// implement `meta`. In Stremio those work because Cinemeta is always
/// installed. ZoroX keeps the same guarantee by consulting Cinemeta as a
/// fallback: still pure add-on protocol, just not something the user had to
/// add, and only used when no installed add-on can answer.
class BuiltInAddons {
  const BuiltInAddons._();

  static const String cinemetaUrl =
      'https://v3-cinemeta.strem.io/manifest.json';

  /// Genres Cinemeta's `top` and `imdbRating` movie catalogs filter by, as
  /// its live manifest lists them.
  static const List<String> cinemetaMovieGenres = [
    'Action',
    'Adventure',
    'Animation',
    'Biography',
    'Comedy',
    'Crime',
    'Documentary',
    'Drama',
    'Family',
    'Fantasy',
    'History',
    'Horror',
    'Mystery',
    'Romance',
    'Sci-Fi',
    'Sport',
    'Thriller',
    'War',
    'Western',
  ];

  /// The series catalogs take the movie genres and three of their own.
  static const List<String> cinemetaSeriesGenres = [
    ...cinemetaMovieGenres,
    'Reality-TV',
    'Talk-Show',
    'Game-Show',
  ];

  /// Years the `year` catalog answers for, newest first. The live manifest
  /// goes back to 1920 for movies and 1960 for series.
  static List<String> _years(int oldest) => [
    for (var year = DateTime.now().year; year >= oldest; year--) '$year',
  ];

  /// A copy of the catalogs in Cinemeta's live manifest that ZoroX uses.
  ///
  /// Only `top` takes a `search`; `imdbRating` (Cinemeta names it
  /// "Featured" - it is not sorted by rating) and `year` ("New", whose
  /// `genre` extra is a required year) are browse-only, so search never
  /// asks them.
  static final ManagedAddon cinemeta = ManagedAddon(
    manifestUrl: cinemetaUrl,
    addedAt: DateTime.fromMillisecondsSinceEpoch(0),
    manifest: AddonManifest(
      id: 'com.linvo.cinemeta',
      name: 'Cinemeta',
      version: '3.0.14',
      description: 'Official movie & series metadata (built-in fallback)',
      types: const ['movie', 'series'],
      idPrefixes: const ['tt'],
      resources: const [
        AddonResource(name: 'catalog', types: ['movie', 'series']),
        AddonResource(name: 'meta', types: ['movie', 'series']),
      ],
      catalogs: [
        const AddonCatalog(
          type: 'movie',
          id: 'top',
          name: 'Popular movies',
          extra: [
            AddonExtraProperty(name: 'genre', options: cinemetaMovieGenres),
            AddonExtraProperty(name: 'search'),
            AddonExtraProperty(name: 'skip'),
          ],
        ),
        const AddonCatalog(
          type: 'series',
          id: 'top',
          name: 'Popular series',
          extra: [
            AddonExtraProperty(name: 'genre', options: cinemetaSeriesGenres),
            AddonExtraProperty(name: 'search'),
            AddonExtraProperty(name: 'skip'),
          ],
        ),
        const AddonCatalog(
          type: 'movie',
          id: 'imdbRating',
          name: 'Featured movies',
          extra: [
            AddonExtraProperty(name: 'genre', options: cinemetaMovieGenres),
            AddonExtraProperty(name: 'skip'),
          ],
        ),
        const AddonCatalog(
          type: 'series',
          id: 'imdbRating',
          name: 'Featured series',
          extra: [
            AddonExtraProperty(name: 'genre', options: cinemetaSeriesGenres),
            AddonExtraProperty(name: 'skip'),
          ],
        ),
        AddonCatalog(
          type: 'movie',
          id: 'year',
          name: 'New movies',
          extra: [
            AddonExtraProperty(
              name: 'genre',
              isRequired: true,
              options: _years(1920),
            ),
            const AddonExtraProperty(name: 'skip'),
          ],
        ),
        AddonCatalog(
          type: 'series',
          id: 'year',
          name: 'New series',
          extra: [
            AddonExtraProperty(
              name: 'genre',
              isRequired: true,
              options: _years(1960),
            ),
            const AddonExtraProperty(name: 'skip'),
          ],
        ),
      ],
    ),
  );
}
