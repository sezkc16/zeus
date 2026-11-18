/// Home's hero on a phone, design A (build 82): centred title, one small
/// meta line, one small badge row, a white View Details pill, round dots.
/// Every part shows only when the item carries it; nothing wraps.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:zorox/core/addons/models/addon_meta.dart' show kAddonItemSource;
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/features/explore/presentation/widgets/explore_carousel.dart';
import 'package:zorox/features/explore/presentation/widgets/home_hero_meta.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

MultimediaItem _bare(int i) => MultimediaItem(
  title: 'Title $i',
  url: 'https://fake.test/$i',
  posterUrl: '',
  bannerUrl: '',
  contentType: MultimediaContentType.other,
);

MultimediaItem _rich({
  String title = 'Godzilla Minus Zero',
  List<String> tags = const ['Science Fiction', 'Action', 'Adventure'],
  String? source,
}) => MultimediaItem(
  title: title,
  url: 'https://fake.test/rich',
  posterUrl: '',
  bannerUrl: '',
  contentType: MultimediaContentType.movie,
  year: 2026,
  score: 7.9,
  duration: 135,
  tags: tags,
  contentRating: 'r',
  status: ShowStatus.completed,
  source: source,
);

void main() {
  group('meta line rules', () {
    test('type, one genre, runtime, year - in that order', () {
      expect(heroMetaLine(_rich()), 'Movie • Science Fiction • 2h 15m • 2026');
    });

    test('a second genre only when asked for', () {
      expect(
        heroMetaLine(_rich(), maxGenres: 2),
        'Movie • Science Fiction • Action • 2h 15m • 2026',
      );
    });

    test('missing parts are left out; nothing at all gives null', () {
      expect(heroMetaLine(_bare(0)), isNull);
      expect(
        heroMetaLine(
          MultimediaItem(
            title: 't',
            url: 'u',
            posterUrl: '',
            contentType: MultimediaContentType.series,
            year: 2024,
          ),
        ),
        'TV Show • 2024',
      );
      expect(
        heroMetaLine(
          MultimediaItem(title: 't', url: 'u', posterUrl: '', duration: 24),
        ),
        'Movie • 24m',
      );
    });

    test('quality tags, blanks and repeats are not genres', () {
      final item = _rich(tags: const ['1080p', ' ', 'Drama', 'drama', '4K']);
      expect(heroGenres(item), ['Drama']);
    });

    test('runtime', () {
      expect(heroRuntimeLabel(null), isNull);
      expect(heroRuntimeLabel(0), isNull);
      expect(heroRuntimeLabel(45), '45m');
      expect(heroRuntimeLabel(120), '2h');
      expect(heroRuntimeLabel(135), '2h 15m');
    });
  });

  group('badge row rules', () {
    test('nothing carried: no row', () {
      final badges = heroBadges(_bare(0));
      expect(badges.isEmpty, isTrue);
      expect(badges.count, 0);
    });

    test('chip joins certification and status; either alone stands', () {
      expect(heroChipLabel(_rich()), 'R | ENDED');
      expect(
        heroChipLabel(
          MultimediaItem(
            title: 't',
            url: 'u',
            posterUrl: '',
            contentRating: 'TV-MA',
          ),
        ),
        'TV-MA',
      );
      expect(
        heroChipLabel(
          MultimediaItem(
            title: 't',
            url: 'u',
            posterUrl: '',
            status: ShowStatus.ongoing,
          ),
        ),
        'ONGOING',
      );
      expect(
        heroChipLabel(
          MultimediaItem(title: 't', url: 'u', posterUrl: '', comingSoon: true),
        ),
        'UPCOMING',
      );
      expect(heroChipLabel(_bare(0)), isNull);
    });

    test('a score is IMDb only for a Stremio add-on title', () {
      final plugin = heroBadges(_rich());
      expect(plugin.score, '7.9');
      expect(plugin.scoreIsImdb, isFalse);
      final addon = heroBadges(_rich(source: kAddonItemSource));
      expect(addon.score, '7.9');
      expect(addon.scoreIsImdb, isTrue);
      // No score: never an IMDb badge, whatever the source.
      final none = heroBadges(
        MultimediaItem(
          title: 't',
          url: 'u',
          posterUrl: '',
          source: kAddonItemSource,
        ),
      );
      expect(none.score, isNull);
      expect(none.scoreIsImdb, isFalse);
    });

    test('language: a plain code only, and it is the first to go', () {
      expect(heroLanguageLabel('ja'), 'JA');
      expect(heroLanguageLabel('Japanese'), isNull);
      expect(heroLanguageLabel(''), isNull);
      expect(heroLanguageLabel(null), isNull);
      final badges = heroBadges(_rich(), language: 'ja');
      expect(badges.count, 3);
      final narrow = badges.withoutLanguage();
      expect(narrow.language, isNull);
      expect(narrow.chip, 'R | ENDED');
      expect(narrow.score, '7.9');
    });
  });

  group('the hero on a phone', () {
    setUp(() {
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
    });
    tearDown(() {
      VisibilityDetectorController.instance.updateInterval = const Duration(
        milliseconds: 500,
      );
    });

    Future<void> pump(
      WidgetTester tester, {
      required List<MultimediaItem> movies,
      double width = 411,
      ThemeData? theme,
      void Function(MultimediaItem)? onTap,
      void Function(MultimediaItem)? onPlay,
    }) async {
      tester.view.physicalSize = Size(width * 3, 915 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: theme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ExploreCarousel(
                movies: movies,
                showPreviewActions: true,
                fullBleed: true,
                onTap: onTap,
                onPlay: onPlay,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      addTearDown(() => tester.pumpWidget(const SizedBox()));
    }

    testWidgets('title, meta, badges, one View Details; no Play / My List / '
        'Info, no badge pill, no synopsis', (tester) async {
      MultimediaItem? opened;
      var played = 0;
      await pump(
        tester,
        movies: [_rich(), _bare(1)],
        onTap: (m) => opened = m,
        onPlay: (_) => played++,
      );
      expect(find.text('Godzilla Minus Zero'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('home-hero-meta'))).data,
        'Movie • Science Fiction • 2h 15m • 2026',
      );
      expect(find.text('R | ENDED'), findsOneWidget);
      expect(find.text('7.9'), findsOneWidget);
      // A plugin's score: a plain star, never an IMDb badge.
      expect(find.text('IMDb'), findsNothing);
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
      expect(find.byKey(const ValueKey('home-hero-language')), findsNothing);

      expect(find.text('View Details'), findsOneWidget);
      expect(find.text('Play'), findsNothing);
      expect(find.text('My List'), findsNothing);
      expect(find.text('Info'), findsNothing);
      expect(find.text('#1 TRENDING TODAY'), findsNothing);
      expect(find.text('MOVIE'), findsNothing);

      // Everything is centred on the screen.
      for (final key in ['home-hero-meta', 'home-hero-badges']) {
        final rect = tester.getRect(find.byKey(ValueKey(key)));
        expect(rect.center.dx, closeTo(411 / 2, 1.0), reason: key);
      }
      final button = tester.getRect(
        find.byKey(const ValueKey('home-hero-view-details')),
      );
      expect(button.center.dx, closeTo(411 / 2, 1.0));
      final style = tester
          .widget<ElevatedButton>(
            find.byKey(const ValueKey('home-hero-view-details')),
          )
          .style!;
      expect(style.backgroundColor!.resolve({}), Colors.white);

      await tester.tap(find.text('View Details'));
      await tester.pump();
      expect(opened?.title, 'Godzilla Minus Zero');
      expect(played, 0);
    });

    testWidgets('an add-on title wears the IMDb badge', (tester) async {
      await pump(tester, movies: [_rich(source: kAddonItemSource)]);
      expect(find.text('IMDb'), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsNothing);
      expect(find.text('7.9'), findsOneWidget);
    });

    testWidgets('an item with nothing: title and button only, rows collapse', (
      tester,
    ) async {
      await pump(tester, movies: [_bare(0)]);
      expect(find.text('Title 0'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-hero-meta')), findsNothing);
      expect(find.byKey(const ValueKey('home-hero-badges')), findsNothing);
      expect(find.byKey(const ValueKey('home-hero-chip')), findsNothing);
      expect(find.text('View Details'), findsOneWidget);
      final title = tester.getRect(find.text('Title 0'));
      final button = tester.getRect(
        find.byKey(const ValueKey('home-hero-view-details')),
      );
      // No gap left where the two rows would have been.
      expect(button.top - title.bottom, lessThan(24));
    });

    for (final width in const [320.0, 360.0, 430.0]) {
      testWidgets('at $width px: meta and badges are small, on one line, '
          'inside the screen; the chip does not break', (tester) async {
        await pump(
          tester,
          width: width,
          movies: [
            _rich(
              title:
                  'A Very Long Title That Would Never Fit On One Line Of A '
                  'Phone Without Shrinking Or Wrapping',
              tags: const [
                'Science Fiction & Fantasy',
                'Action & Adventure',
                'Mystery',
              ],
            ),
            _bare(1),
          ],
        );
        expect(tester.takeException(), isNull);

        final meta = find.byKey(const ValueKey('home-hero-meta'));
        final metaText = tester.widget<Text>(meta);
        expect(metaText.maxLines, 1);
        expect(metaText.softWrap, isFalse);
        expect(metaText.overflow, isNull);
        expect(metaText.style!.fontSize, 13);
        // One line: no taller than a single 13 px line, and inside the
        // 24 px inset on both sides.
        final metaRect = tester.getRect(
          find.ancestor(of: meta, matching: find.byType(FittedBox)).first,
        );
        expect(metaRect.height, lessThanOrEqualTo(18));
        expect(metaRect.left, greaterThanOrEqualTo(24 - 0.5));
        expect(metaRect.right, lessThanOrEqualTo(width - 24 + 0.5));
        // The first genre is always there.
        expect(metaText.data, contains('Science Fiction & Fantasy'));

        final badges = find.byKey(const ValueKey('home-hero-badges'));
        final badgesRect = tester.getRect(
          find.ancestor(of: badges, matching: find.byType(FittedBox)).first,
        );
        expect(badgesRect.height, lessThanOrEqualTo(22));
        expect(badgesRect.left, greaterThanOrEqualTo(24 - 0.5));
        expect(badgesRect.right, lessThanOrEqualTo(width - 24 + 0.5));

        final chip = find.byKey(const ValueKey('home-hero-chip'));
        expect(tester.getSize(chip).height, lessThanOrEqualTo(20));
        final chipText = tester.widget<Text>(find.text('R | ENDED'));
        expect(chipText.maxLines, 1);
        expect(chipText.softWrap, isFalse);
        expect(chipText.style!.fontSize, 11.5);

        // The long title shrank inside its box instead of being cut.
        final title = tester.widget<Text>(
          find.textContaining('A Very Long Title'),
        );
        expect(title.overflow, isNull);
        final titleBox = tester.getRect(
          find.byKey(const ValueKey('home-hero-title')),
        );
        expect(titleBox.height, lessThanOrEqualTo(84 + 0.5));
        expect(titleBox.left, greaterThanOrEqualTo(24 - 0.5));
        expect(titleBox.right, lessThanOrEqualTo(width - 24 + 0.5));
      });
    }

    testWidgets('a second genre shows when the line still fits', (
      tester,
    ) async {
      // The test font is 13 px per letter: 29 letters fit in 430 - 48.
      await pump(
        tester,
        width: 430,
        movies: [
          _rich(tags: const ['A', 'B', 'C']),
        ],
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('home-hero-meta'))).data,
        'Movie • A • B • 2h 15m • 2026',
      );
    });

    testWidgets('on a narrow line the second genre is dropped first', (
      tester,
    ) async {
      await pump(
        tester,
        width: 320,
        movies: [
          _rich(
            tags: const ['Science Fiction & Fantasy', 'Action & Adventure'],
          ),
        ],
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('home-hero-meta'))).data,
        'Movie • Science Fiction & Fantasy • 2h 15m • 2026',
      );
    });

    testWidgets('dots: inside the poster under the button, the active one '
        'longer; one slide has none', (tester) async {
      await pump(tester, movies: [_rich(), _bare(1), _bare(2)]);
      final card = tester.getRect(find.byKey(const ValueKey('hero-card')));
      final button = tester.getRect(
        find.byKey(const ValueKey('home-hero-view-details')),
      );
      final active = tester.getRect(find.byKey(const ValueKey('hcd_0')));
      final other = tester.getRect(find.byKey(const ValueKey('hcd_1')));
      expect(active.top, greaterThan(button.bottom));
      expect(active.bottom, lessThan(card.bottom));
      expect(active.width, greaterThan(other.width * 2));
      expect(other.width, closeTo(6 + 6, 0.5)); // 6 px dot + 3 px margins
      // Centred as a group.
      final last = tester.getRect(find.byKey(const ValueKey('hcd_2')));
      expect((active.left + last.right) / 2, closeTo(411 / 2, 1.0));
      // The poster is tall: about two thirds of the screen.
      expect(card.height, closeTo(915 * 0.66, 1.0));
      expect(card.left, 0);
      expect(card.right, 411);

      await pump(tester, movies: [_rich()]);
      expect(find.byKey(const ValueKey('hcd_0')), findsNothing);
    });

    testWidgets('light theme: the text stays white over the darkened poster', (
      tester,
    ) async {
      await pump(
        tester,
        movies: [_rich()],
        theme: ThemeData.light(useMaterial3: true),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('home-hero-meta')))
            .style!
            .color,
        Colors.white,
      );
      expect(
        tester.widget<Text>(find.text('Godzilla Minus Zero')).style!.color,
        Colors.white,
      );
    });
  });
}
