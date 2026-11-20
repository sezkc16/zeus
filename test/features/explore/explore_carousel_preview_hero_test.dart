/// The restored preview hero (user decision 2026-11-16): big title, type
/// badge pill and Play / My List / Info actions on Home's carousel.
///
/// The poster-only hero (+42) is the default and stays that way for Explore,
/// AniList and Addons — these tests pin both sides: preview on renders the
/// full hero, preview off renders the white View Details pill and no title,
/// badge or action buttons.
///
/// The hero watches the library for the My List state, so the tests run the
/// real [Library] notifier against an in-memory [LibraryRepository]: the
/// real Hive round-trip lives in the plain container test
/// `test/features/library/library_storage_test.dart` instead — a real Hive
/// box never completes its writes inside a widget test's fake-async zone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/storage/library_repository.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/features/explore/presentation/widgets/explore_carousel.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';
import 'package:visibility_detector/visibility_detector.dart';

MultimediaItem _movie(int i) => MultimediaItem(
  title: 'Title $i',
  url: 'https://fake.test/$i',
  posterUrl: '',
  bannerUrl: '',
  contentType: MultimediaContentType.movie,
);

/// A movie with the metadata the preview hero's meta line renders:
/// score 8.7 → "★ 8.7", year 2024, 166 minutes → "2h 46m", genres,
/// and an HTML description (AniList ships them that way) for the synopsis.
MultimediaItem _richMovie() => MultimediaItem(
  title: 'Rich Title',
  url: 'https://fake.test/rich',
  posterUrl: '',
  bannerUrl: '',
  contentType: MultimediaContentType.movie,
  year: 2024,
  score: 8.7,
  duration: 166,
  tags: const ['Sci-Fi'],
  description: 'A <i>short</i> synopsis<br>across lines.',
);

/// In-memory stand-in for the library box: same keying (one entry per URL),
/// but its futures complete on microtasks, which `tester.pump()` delivers.
class _FakeLibraryStorage extends StorageService {
  final _items = <String, MultimediaItem>{};

  @override
  Future<void> addToLibrary(MultimediaItem item) async {
    _items[item.url] = item;
  }

  @override
  Future<void> removeFromLibrary(String url) async {
    _items.remove(url);
  }

  @override
  bool isInLibrary(String url) => _items.containsKey(url);

  @override
  List<MultimediaItem> getLibraryItems() => _items.values.toList();
}

void main() {
  late _FakeLibraryStorage fakeStorage;

  setUp(() {
    // The carousel is wrapped in a VisibilityDetector, which otherwise leaves
    // a 500 ms debounce Timer pending past the end of the test.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    fakeStorage = _FakeLibraryStorage();
  });

  tearDown(() {
    VisibilityDetectorController.instance.updateInterval = const Duration(
      milliseconds: 500,
    );
  });

  Future<void> pumpCarousel(
    WidgetTester tester, {
    required List<MultimediaItem> movies,
    bool showPreviewActions = false,
    bool fullBleed = false,
    Size physicalSize = const Size(1233, 2745),
    void Function(MultimediaItem)? onTap,
    void Function(MultimediaItem)? onPlay,
  }) async {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(
            LibraryRepository(fakeStorage),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ExploreCarousel(
              movies: movies,
              showPreviewActions: showPreviewActions,
              fullBleed: fullBleed,
              onTap: onTap,
              onPlay: onPlay,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // Dispose the carousel (its tickers and the VisibilityDetector timer)
    // even when the test fails, so the test process can exit.
    addTearDown(() => tester.pumpWidget(const SizedBox()));
  }

  group('preview hero on', () {
    testWidgets('the hero card has no outline (v8): rounded, no border', (
      tester,
    ) async {
      await pumpCarousel(tester, movies: [_movie(0)], showPreviewActions: true);
      final card = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('hero-card')),
      );
      final decoration = card.decoration! as BoxDecoration;
      expect(decoration.border, isNull);
      expect(decoration.borderRadius, BorderRadius.circular(20));
      // Without fullBleed the card keeps its 16 px side margin.
      final rect = tester.getRect(find.byKey(const ValueKey('hero-card')));
      expect(rect.left, 16);
      expect(rect.right, 411 - 16);
    });

    testWidgets('fullBleed on a phone: edge to edge, square corners, text '
        'still inset', (tester) async {
      await pumpCarousel(
        tester,
        movies: [_movie(0), _movie(1)],
        showPreviewActions: true,
        fullBleed: true,
      );
      final finder = find.byKey(const ValueKey('hero-card'));
      final rect = tester.getRect(finder);
      expect(rect.left, 0);
      expect(rect.right, 411);
      final decoration =
          tester.widget<AnimatedContainer>(finder).decoration! as BoxDecoration;
      expect(decoration.border, isNull);
      expect(decoration.borderRadius, BorderRadius.zero);
      // Title and button never touch the screen edge (Olympus Noir on a
      // phone: the uppercase title and the Explore Film button).
      for (final label in ['TITLE 0', 'EXPLORE FILM']) {
        final r = tester.getRect(find.text(label));
        expect(r.left, greaterThanOrEqualTo(24), reason: label);
        expect(r.right, lessThanOrEqualTo(411 - 24), reason: label);
      }
    });

    testWidgets(
      'fullBleed is ignored on the wide layout: padded rounded card',
      (tester) async {
        await pumpCarousel(
          tester,
          movies: [_movie(0)],
          showPreviewActions: true,
          fullBleed: true,
          physicalSize: const Size(3600, 2400),
        );
        final finder = find.byKey(const ValueKey('hero-card'));
        final decoration =
            tester.widget<AnimatedContainer>(finder).decoration!
                as BoxDecoration;
        expect(decoration.borderRadius, BorderRadius.circular(20));
        expect(tester.getRect(finder).left, greaterThan(0));
      },
    );

    testWidgets('big title, badge pill and all three actions render', (
      tester,
    ) async {
      await pumpCarousel(
        tester,
        movies: [_movie(0)],
        showPreviewActions: true,
        // The wide layout keeps this preview hero; a phone shows
        // design A (home_hero_design_a_test.dart).
        physicalSize: const Size(3600, 2400),
      );

      expect(find.text('TITLE 0'), findsOneWidget);
      // The first slide wears the "#1 TRENDING TODAY" badge, not the
      // type pill — the type pill is for the later slides.
      expect(find.text('#1 TRENDING TODAY'), findsOneWidget);
      expect(find.text('MOVIE'), findsNothing);
      expect(find.text('Play'), findsOneWidget);
      expect(find.text('My List'), findsOneWidget);
      expect(find.text('Info'), findsOneWidget);
      // The poster-only call to action is gone.
      expect(find.text('View Details'), findsNothing);
    });

    testWidgets('the second slide wears the type badge', (tester) async {
      await pumpCarousel(
        tester,
        movies: [_movie(0), _movie(1)],
        showPreviewActions: true,
        // The wide layout keeps this preview hero; a phone shows
        // design A (home_hero_design_a_test.dart).
        physicalSize: const Size(3600, 2400),
      );

      expect(find.text('#1 TRENDING TODAY'), findsOneWidget);
      expect(find.text('MOVIE'), findsNothing);

      // The 5 s auto-advance dwell, then the 400 ms slide transition. The
      // dwell fires on the frame after the clock passes 5 s, and the
      // crossfade keeps the old slide mounted until the transition
      // finishes, so the extra second settles both.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('#1 TRENDING TODAY'), findsNothing);
      expect(find.text('MOVIE'), findsOneWidget);
    });

    testWidgets('preview meta and synopsis read like the design', (
      tester,
    ) async {
      await pumpCarousel(
        tester,
        movies: [_richMovie()],
        showPreviewActions: true,
        // The wide layout keeps this preview hero; a phone shows
        // design A (home_hero_design_a_test.dart).
        physicalSize: const Size(3600, 2400),
      );

      // "★ 8.7 · 2024 · 2h 46m · Sci-Fi", as one clamped line — the
      // rating, year, runtime and genres come from the item. v7: no
      // quality badge, because this title states none (the 4K / Dolby
      // Vision badges used to be drawn on every slide).
      // The meta is a standalone RichText, which textContaining ignores
      // unless findRichText is passed.
      expect(find.textContaining('★ 8.7', findRichText: true), findsOneWidget);
      expect(find.textContaining('Match', findRichText: true), findsNothing);
      expect(find.textContaining('2024', findRichText: true), findsOneWidget);
      expect(find.textContaining('2h 46m', findRichText: true), findsOneWidget);
      expect(find.textContaining('4K', findRichText: true), findsNothing);
      expect(
        find.textContaining('Dolby Vision', findRichText: true),
        findsNothing,
      );
      expect(find.textContaining('Sci-Fi', findRichText: true), findsOneWidget);
      // The HTML in the description is stripped, not printed raw.
      expect(find.text('A short synopsis across lines.'), findsOneWidget);
      expect(find.textContaining('<i>'), findsNothing);
    });

    testWidgets('a quality badge shows only when the title states it', (
      tester,
    ) async {
      await pumpCarousel(
        tester,
        movies: [
          MultimediaItem(
            title: 'Blue Box (Season 1) Hindi Dubbed Blu-Ray 1080p & 720p',
            url: 'https://fake.test/bluebox',
            posterUrl: '',
            bannerUrl: '',
            contentType: MultimediaContentType.anime,
          ),
        ],
        showPreviewActions: true,
        // The wide layout keeps this preview hero; a phone shows
        // design A (home_hero_design_a_test.dart).
        physicalSize: const Size(3600, 2400),
      );
      expect(find.textContaining('1080p', findRichText: true), findsWidgets);
      expect(
        find.textContaining('Dolby Vision', findRichText: true),
        findsNothing,
      );
      expect(find.textContaining(' · 4K', findRichText: true), findsNothing);
    });

    testWidgets('Play calls onPlay once and does not fire the slide tap', (
      tester,
    ) async {
      final played = <MultimediaItem>[];
      final tapped = <MultimediaItem>[];
      await pumpCarousel(
        tester,
        movies: [_movie(0)],
        showPreviewActions: true,
        // The wide layout keeps this preview hero; a phone shows
        // design A (home_hero_design_a_test.dart).
        physicalSize: const Size(3600, 2400),
        onTap: tapped.add,
        onPlay: played.add,
      );

      await tester.tap(find.text('Play'));
      await tester.pump();

      expect(played, [_movie(0)]);
      expect(tapped, isEmpty);
    });

    testWidgets('Info opens details (same destination as tapping the poster)', (
      tester,
    ) async {
      final tapped = <MultimediaItem>[];
      await pumpCarousel(
        tester,
        movies: [_movie(0)],
        showPreviewActions: true,
        // The wide layout keeps this preview hero; a phone shows
        // design A (home_hero_design_a_test.dart).
        physicalSize: const Size(3600, 2400),
        onTap: tapped.add,
      );

      await tester.tap(find.text('Info'));
      await tester.pump();

      expect(tapped, [_movie(0)]);
    });

    testWidgets('Play without an onPlay handler falls back to details', (
      tester,
    ) async {
      final tapped = <MultimediaItem>[];
      await pumpCarousel(
        tester,
        movies: [_movie(0)],
        showPreviewActions: true,
        // The wide layout keeps this preview hero; a phone shows
        // design A (home_hero_design_a_test.dart).
        physicalSize: const Size(3600, 2400),
        onTap: tapped.add,
      );

      await tester.tap(find.text('Play'));
      await tester.pump();

      expect(tapped, [_movie(0)]);
    });

    testWidgets('tapping My List saves, tapping again removes', (tester) async {
      final movie = _movie(0);
      expect(fakeStorage.isInLibrary(movie.url), isFalse);

      await pumpCarousel(
        tester,
        movies: [movie],
        showPreviewActions: true,
        // The wide layout keeps this preview hero; a phone shows
        // design A (home_hero_design_a_test.dart).
        physicalSize: const Size(3600, 2400),
      );

      expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);

      await tester.tap(find.text('My List'));
      await tester.pump();
      await tester.pump();

      expect(fakeStorage.isInLibrary(movie.url), isTrue);
      expect(find.byIcon(Icons.bookmark_added_rounded), findsOneWidget);

      await tester.tap(find.text('My List'));
      await tester.pump();
      await tester.pump();

      expect(fakeStorage.isInLibrary(movie.url), isFalse);
      expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);
    });
  });

  group('preview hero off (poster-only, +42)', () {
    testWidgets('no title, no badge, no actions — just View Details', (
      tester,
    ) async {
      await pumpCarousel(tester, movies: [_movie(0)]);

      expect(find.text('TITLE 0'), findsNothing);
      expect(find.text('MOVIE'), findsNothing);
      expect(find.text('Play'), findsNothing);
      expect(find.text('My List'), findsNothing);
      expect(find.text('Info'), findsNothing);
      expect(find.text('View Details'), findsOneWidget);
    });
  });
}
