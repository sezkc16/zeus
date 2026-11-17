import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorox/features/explore/data/explore_mode_provider.dart';

/// Explore has one source (v5): Stremio add-ons. The TMDB "Movies & Shows"
/// and AniList "Anime" sources were removed, so whatever an older build
/// saved, the mode is Stremio add-ons and the saved value is migrated.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer containerWith({Map<String, Object>? prefs}) {
    SharedPreferences.setMockInitialValues(prefs ?? <String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  test('nothing saved: Stremio add-ons', () {
    final container = containerWith();
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
  });

  for (final saved in ['movies', 'anime']) {
    test('a saved "$saved" source is migrated to Stremio add-ons', () async {
      final container = containerWith(prefs: {'explore_mode_type': saved});
      expect(container.read(exploreModeProvider), ExploreModeType.stremio);
      await settle();
      expect(container.read(exploreModeProvider), ExploreModeType.stremio);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('explore_mode_type'), 'stremio');
    });
  }

  test('the old anime flag is dropped', () async {
    final container = containerWith(prefs: {'explore_mode_is_anime': true});
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
    await settle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('explore_mode_is_anime'), isFalse);
  });

  test('no caller can switch to a removed source', () {
    final container = containerWith();
    container.read(exploreModeProvider.notifier).setMode(ExploreModeType.movies);
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
    container.read(exploreModeProvider.notifier).setAnimeMode(true);
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
  });
}
