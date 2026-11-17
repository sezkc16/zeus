/// A Stremio title's phone page in the "Hero" layout: the banner with the
/// add-on's tag, the title and the round Play button, the info strip, the
/// short synopsis and the episodes as a row - doing what the page did before.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/addons/models/addon_meta.dart';
import 'package:zorox/features/addons/presentation/addon_sources_sheet.dart';
import 'package:zorox/features/addons/presentation/widgets/addon_episode_card.dart';
import 'package:zorox/features/details/presentation/widgets/hero_details_widgets.dart';

import 'stremio_page_fakes.dart';

const Size _kPhone = Size(430, 932);

Finder get _fab => find.byKey(const ValueKey('details-play-fab'));
Finder get _strip => find.byKey(const ValueKey('details-info-strip'));
Finder get _row =>
    find.byKey(const ValueKey('details-episode-row'), skipOffstage: false);

Future<void> _reach(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await settle(tester);
}

AddonMeta _longShow(int count) => AddonMeta(
  id: 'cnc:long',
  type: 'other',
  name: 'One Piece',
  addonId: 'com.bridge',
  addonName: 'Bridge',
  description: List.filled(40, 'They sail on toward the Grand Line.').join(' '),
  releaseInfo: '1999-',
  runtime: '24 min',
  imdbRating: '8.9',
  genres: const ['Action', 'Adventure'],
  videos: [
    for (var n = 1; n <= count; n++)
      AddonVideo(id: 'cnc:l$n', title: 'Chapter $n', season: 1, episode: n),
  ],
);

void main() {
  useTestClearance();

  testWidgets('the banner carries the title and the add-on tag, and the strip '
      'only what the title has', (tester) async {
    await openStremioPage(tester, _longShow(40), size: _kPhone);

    final banner = find.byType(DetailsHeroBanner);
    expect(banner, findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: banner,
              matching: find.byKey(const ValueKey('details-hero-title')),
            ),
          )
          .data,
      'One Piece',
    );
    expect(
      find.descendant(of: banner, matching: find.text('BRIDGE')),
      findsOneWidget,
    );
    expect(find.text('BRIDGE'), findsOneWidget);
    expect(find.byKey(const ValueKey('details-back')), findsOneWidget);

    Finder inStrip(String text) =>
        find.descendant(of: _strip, matching: find.text(text));
    expect(inStrip('1999-'), findsOneWidget);
    expect(inStrip('40'), findsOneWidget);
    expect(inStrip('Episodes'), findsOneWidget);
    expect(inStrip('24 min'), findsOneWidget);
    expect(inStrip('8.9'), findsOneWidget);
    // One season: no Seasons column.
    expect(inStrip('Seasons'), findsNothing);
    expect(find.text('SERIES', skipOffstage: false), findsOneWidget);
    // The search over every add-on is still on the page.
    expect(
      find.textContaining('Search add-ons', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('a title with nothing to put in the strip has no strip', (
    tester,
  ) async {
    await openStremioPage(tester, kBridgeMovie, size: _kPhone);
    expect(_strip, findsNothing);
    expect(find.text('MOVIE', skipOffstage: false), findsOneWidget);
  });

  testWidgets("the round Play plays the add-on's link, as the button did", (
    tester,
  ) async {
    final opened = await openStremioPage(tester, kBridgeMovie, size: _kPhone);
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(tester.getSize(_fab), const Size(56, 56));
    expect(find.text('Play'), findsNothing, reason: 'no full-width Play');

    await tester.tap(_fab);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final played = opened.launcher.played.single;
    expect(played.videoUrl, 'cnc:film');
    expect(played.item.addonUrl, kBridgeUrl);
  });

  testWidgets("a show's round Play names the next episode, or says Resume", (
    tester,
  ) async {
    final opened = await openStremioPage(
      tester,
      kBridgeShow,
      size: _kPhone,
      history: FakeHistory(lastEpisode: 'cnc:s1e1'),
      watched: const {'cnc:s1e1'},
    );
    expect(find.byTooltip('Play S1 E2'), findsOneWidget);
    await tester.tap(_fab);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(opened.launcher.played.single.videoUrl, 'cnc:s1e2');
  });

  testWidgets('Resume, with saved progress', (tester) async {
    await openStremioPage(
      tester,
      kBridgeMovie,
      size: _kPhone,
      history: FakeHistory(positions: const {'cnc:film': 600000}),
    );
    expect(find.byTooltip('Resume'), findsOneWidget);
  });

  testWidgets('no round Play while its links load', (tester) async {
    await openStremioPage(tester, kBridgeMovie, size: _kPhone, hold: true);
    expect(_fab, findsNothing);
  });

  testWidgets('no round Play for a title its add-on only describes', (
    tester,
  ) async {
    const described = AddonMeta(
      id: 'tt1',
      type: 'movie',
      name: 'Film',
      addonId: 'com.linvo.cinemeta',
      addonName: 'Cinemeta',
    );
    await openStremioPage(tester, described, size: _kPhone);
    expect(_fab, findsNothing);
  });

  testWidgets('the synopsis is three lines until "more"', (tester) async {
    final show = _longShow(3);
    await openStremioPage(tester, show, size: _kPhone);
    final toggle = find.byKey(
      const ValueKey('details-synopsis-more'),
      skipOffstage: false,
    );
    await _reach(tester, toggle);
    expect(find.text('more'), findsOneWidget);
    expect(tester.widget<Text>(find.text(show.description!)).maxLines, 3);
    await tester.tap(toggle);
    await settle(tester);
    expect(find.text('less', skipOffstage: false), findsOneWidget);
    expect(tester.widget<Text>(find.text(show.description!)).maxLines, isNull);
  });

  testWidgets('500 episodes are one lazy row; a tap plays, a long press '
      'searches every add-on', (tester) async {
    final opened = await openStremioPage(tester, _longShow(500), size: _kPhone);
    await _reach(tester, _row);

    expect(tester.widget<ListView>(_row).scrollDirection, Axis.horizontal);
    final built = find
        .byType(AddonEpisodeCard, skipOffstage: false)
        .evaluate()
        .length;
    expect(built, greaterThan(1));
    expect(built, lessThan(12));
    expect(find.text('1 · Chapter 1'), findsOneWidget);
    // The range picker and sort stay beside the header.
    expect(find.text('1-20'), findsOneWidget);
    expect(find.byIcon(Icons.swap_vert_rounded), findsOneWidget);

    await tester.tap(find.text('2 · Chapter 2'));
    await settle(tester);
    expect(opened.launcher.played.single.videoUrl, 'cnc:l2');
    expect(find.byType(AddonSourcesSheet), findsNothing);

    await tester.longPress(find.text('1 · Chapter 1'));
    await settle(tester);
    expect(find.byType(AddonSourcesSheet), findsOneWidget);
  });

  testWidgets('the range picker scrolls the row, and sort flips it', (
    tester,
  ) async {
    await openStremioPage(tester, _longShow(500), size: _kPhone);
    await _reach(tester, _row);

    await tester.tap(find.text('1-20'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('61-80').last);
    await tester.pumpAndSettle();
    expect(find.text('61 · Chapter 61'), findsOneWidget);
    expect(find.text('1 · Chapter 1'), findsNothing);

    await tester.tap(find.byIcon(Icons.swap_vert_rounded));
    await tester.pumpAndSettle();
    // Newest first now, still at the picker's range.
    expect(find.text('80 · Chapter 80'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('79 · Chapter 79')).dx,
      greaterThan(tester.getTopLeft(find.text('80 · Chapter 80')).dx),
    );
  });

  testWidgets('seasons stay, and progress shows on the cards', (tester) async {
    await openStremioPage(
      tester,
      kBridgeShow,
      size: _kPhone,
      history: FakeHistory(positions: const {'cnc:s1e1': 1800000}),
      watched: const {'cnc:s1e2'},
    );
    await _reach(tester, _row);
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('Season 2'), findsOneWidget);
    final bars = tester.widgetList<LinearProgressIndicator>(
      find.byKey(const ValueKey('episode-row-progress'), skipOffstage: false),
    );
    expect(bars.map((b) => b.value), containsAll(<double>[0.5, 1.0]));
    expect(find.text('WATCHING', skipOffstage: false), findsOneWidget);
    expect(find.text('WATCHED', skipOffstage: false), findsOneWidget);

    await tester.tap(find.text('Season 2'));
    await settle(tester);
    expect(find.text('1 · Three'), findsOneWidget);
    expect(find.text('1 · One'), findsNothing);
  });
}
