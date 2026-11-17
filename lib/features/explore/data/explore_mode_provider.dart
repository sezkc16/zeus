import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'explore_mode_provider.g.dart';

const String _kExploreModeKey = 'explore_mode_type';

/// Explore's sources. Only [stremio] is offered (v5): the TMDB "Movies &
/// Shows" and AniList "Anime" sources were removed from Explore. The two
/// names stay so the code that still branches on them compiles; the mode
/// is never one of them.
enum ExploreModeType { movies, anime, stremio }

/// Explore's source: always Stremio add-ons (the built-in Cinemeta and any
/// add-on the person installed). There is nothing to pick any more, so a
/// preference saved by an older build for TMDB or AniList is rewritten to
/// Stremio add-ons rather than left pointing at a removed source.
@Riverpod(keepAlive: true)
class ExploreMode extends _$ExploreMode {
  @override
  ExploreModeType build() {
    _migrateSavedMode();
    return ExploreModeType.stremio;
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

  /// Kept for callers; whatever is asked for, the source is Stremio add-ons.
  void setMode(ExploreModeType mode) {
    state = ExploreModeType.stremio;
  }

  void setAnimeMode(bool isAnime) => setMode(ExploreModeType.stremio);
}
