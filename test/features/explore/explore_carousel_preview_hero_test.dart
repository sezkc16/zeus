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
import 'package:visibility_detector/visibility_detector.dart';

MultimediaItem _movie(int i) => MultimediaItem(
  title: 'Title $i',
  url: 'https://fake.test/$i',
  posterUrl: '',
  bannerUrl: '',
  contentType: MultimediaContentType.movie,
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
    void Function(MultimediaItem)? onTap,
    void Function(MultimediaItem)? onPlay,
  }) async {
    tester.view.physicalSize = const Size(1233, 2745);
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
          home: Scaffold(
            body: ExploreCarousel(
              movies: movies,
              showPreviewActions: showPreviewActions,
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
    testWidgets('big title, badge pill and all three actions render', (
      tester,
    ) async {
      await pumpCarousel(
        tester,
        movies: [_movie(0)],
        showPreviewActions: true,
      );

      expect(find.text('TITLE 0'), findsOneWidget);
      expect(find.text('MOVIE'), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      expect(find.text('My List'), findsOneWidget);
      expect(find.text('Info'), findsOneWidget);
      // The poster-only call to action is gone.
      expect(find.text('View Details'), findsNothing);
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
        onTap: tapped.add,
      );

      await tester.tap(find.text('Play'));
      await tester.pump();

      expect(tapped, [_movie(0)]);
    });

    testWidgets('tapping My List saves, tapping again removes', (
      tester,
    ) async {
      final movie = _movie(0);
      expect(fakeStorage.isInLibrary(movie.url), isFalse);

      await pumpCarousel(
        tester,
        movies: [movie],
        showPreviewActions: true,
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
