import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../browse/presentation/browse_catalogue.dart';

part 'explore_mode_provider.g.dart';

const String _kExploreModeKey = 'explore_mode_type';

/// The source the Explore code (search, filters, genres) works against.
/// It follows Browse's catalogue switcher: [movies] (TMDB) while Browse
/// shows "Movies & Shows", [stremio] otherwise. AniList "Anime" is not
/// offered; the name stays so the code that branches on it compiles.
enum ExploreModeType { movies, anime, stremio }

/// Not a setting of its own any more: Browse's switcher is the one
/// place the source is chosen, so this only mirrors it. A preference an
/// older build saved under its own key is rewritten to Stremio add-ons.
@Riverpod(keepAlive: true)
class ExploreMode extends _$ExploreMode {
  @override
  ExploreModeType build() {
    _migrateSavedMode();
    return ref.watch(browseShowsTmdbProvider)
        ? ExploreModeType.movies
        : ExploreModeType.stremio;
  }

  Future<void> _migrateSavedMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_kExploreModeKey);
      if (saved != null && saved != ExploreModeType.stremio.name) {
        await prefs.setString(_kExploreModeKey, ExploreModeType.stremio.name);
      }
      // The older boolean key only ever meant "anime".
      if (prefs.containsKey('explore_mode_is_anime')) {
        await prefs.remove('explore_mode_is_anime');
      }
    } catch (_) {}
  }

  /// Kept for callers; the source is whatever Browse's switcher says.
  void setMode(ExploreModeType mode) {}

  void setAnimeMode(bool isAnime) {}
}
