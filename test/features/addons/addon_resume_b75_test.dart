// Build 75: a Stremio / Browse title resumes for real — play it from
// the sources list, close the player, open it again: the page says
// Resume with the place, the source it played on plays by itself, and
// the player is handed the keys the saved position is stored under.
//
// Build 74 never remembered a pick made in the sources list: the
// memory was written after the player had closed, through the `ref`
// of a sheet that was disposed by then. These tests use a launcher
// that really opens a page and returns when it closes, as the app's
// does — with one that returns at once the bug does not show.
//
// A test's ProviderScope is its root scope; the rule only recognises
// one passed to runApp.
// ignore_for_file: riverpod_lint/scoped_providers_should_specify_dependencies
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/addons/models/addon_stream_source.dart';
import 'package:zorox/core/storage/settings_repository.dart';
import 'package:zorox/features/addons/presentation/addon_detail_screen.dart';
import 'package:zorox/features/addons/presentation/addon_resume_intent.dart';
import 'package:zorox/features/addons/presentation/addon_sources_sheet.dart';
import 'package:zorox/features/addons/presentation/widgets/stremio_sources_card.dart';
import 'package:zorox/features/player/domain/playback_progress.dart';
import 'package:zorox/features/sources/domain/last_used_source.dart';

import 'stremio_page_fakes.dart';

/// The settings store, in memory.
class _Settings implements SettingsRepository {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  Future<void> setPlayerSetting(String key, dynamic value) async {
    values[key] = value;
  }

  @override
  T? getPlayerSetting<T>(String key, {T? defaultValue}) =>
      (values[key] as T?) ?? defaultValue;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A row as a Nuvio provider's reads in the list, and an add-on's.
const _nuvio = AddonStreamSource(
  addonId: 'nuvio:4khdhub',
  addonName: 'Nuvio',
  name: '4KHDHub - FSL 2160p',
  url: 'https://cdn.test/nuvio-4k.mkv',
);
const _stremio = AddonStreamSource(
  addonId: 'com.bridge',
  addonName: 'Bridge',
  name: 'Bridge 1080p',
  url: 'https://cdn.test/bridge-1080.mkv',
);

Finder _inSheet(Finder what) =>
    find.descendant(of: find.byType(AddonSourcesSheet), matching: what);

Future<void> _openCard(WidgetTester tester) async {
  await tester.ensureVisible(find.byType(StremioSourcesCard));
  await tester.pump();
  await tester.tap(
    find.descendant(
      of: find.byType(StremioSourcesCard),
      matching: find.textContaining('Resume'),
    ),
  );
  await settle(tester);
}

void main() {
  useTestClearance();

  group('addonResumeLabel', () {
    test('an episode, with where it continues', () {
      expect(
        addonResumeLabel(
          resume: 'Resume',
          positionMs: 754000,
          season: 1,
          episode: 3,
        ),
        'Resume S1 E3 · 12:34',
      );
    });
    test('a film past the hour', () {
      expect(
        addonResumeLabel(resume: 'Resume', positionMs: 3723000),
        'Resume · 1:02:03',
      );
    });
    test('no place, no time', () {
      expect(addonResumeLabel(resume: 'Resume', positionMs: 0), 'Resume');
    });
  });

  for (final picked in [_nuvio, _stremio]) {
    testWidgets(
      'a series: play from the list (${picked.addonName} row), close, '
      'open again — Resume, the same source by itself, the saved place',
      (tester) async {
        final settings = _Settings();
        final history = FakeHistory(
          positions: const {'cnc:s1e2': 600000},
          lastEpisode: 'cnc:s1e2',
        );
        final page = await openStremioPage(
          tester,
          kBridgeShow,
          links: const [_nuvio, _stremio],
          opensPlayer: true,
          history: history,
          overrides: [settingsRepositoryProvider.overrideWithValue(settings)],
        );

        // The card names the episode to continue and where.
        expect(
          find.descendant(
            of: find.byType(StremioSourcesCard),
            matching: find.text('Resume S1 E2 · 10:00'),
          ),
          findsOneWidget,
        );

        // Nothing remembered yet: the list opens and waits for a pick.
        await _openCard(tester);
        expect(page.launcher.played, isEmpty);
        await tester.tap(_inSheet(find.text(picked.name!)).first);
        await settle(tester);
        if (page.launcher.played.isEmpty) {
          await tester.tap(_inSheet(find.text('Play')).first);
          await settle(tester);
        }
        expect(find.text('PLAYER'), findsOneWidget);
        expect(page.launcher.played, hasLength(1));

        // Remembered while the player is still up — not after it.
        expect(
          readLastUsedSource(settings, 'cnc:show'),
          addonSourceKey(picked),
        );

        // The player closes.
        Navigator.of(tester.element(find.text('PLAYER'))).pop();
        await settle(tester);
        expect(find.text('PLAYER'), findsNothing);
        expect(find.byType(AddonSourcesSheet), findsNothing);

        // Open again: the source plays by itself.
        await _openCard(tester);
        await settle(tester);
        expect(page.launcher.played, hasLength(2));
        final again = page.launcher.played.last;
        expect(again.videoUrl, 'cnc:s1e2');
        expect(again.episode?.url, 'cnc:s1e2');

        // And the player finds the saved place under what it was handed.
        final container = ProviderScope.containerOf(
          tester.element(find.byType(AddonDetailScreen, skipOffstage: false)),
        );
        final point = resumePointFor(
          read: container.read,
          item: again.item,
          episode: again.episode,
          videoUrl: again.videoUrl,
        );
        expect(point?.position, const Duration(minutes: 10));
      },
    );
  }

  testWidgets('a film: play from the list, close, open again — Resume, the '
      'same source by itself, the saved place', (tester) async {
    final settings = _Settings();
    final history = FakeHistory(positions: const {'cnc:film': 600000});
    final page = await openStremioPage(
      tester,
      kBridgeMovie,
      links: const [_nuvio, _stremio],
      opensPlayer: true,
      history: history,
      overrides: [settingsRepositoryProvider.overrideWithValue(settings)],
    );

    expect(
      find.descendant(
        of: find.byType(StremioSourcesCard),
        matching: find.text('Resume · 10:00'),
      ),
      findsOneWidget,
    );

    await _openCard(tester);
    expect(page.launcher.played, isEmpty);
    await tester.tap(_inSheet(find.text('Play')).first);
    await settle(tester);
    expect(find.text('PLAYER'), findsOneWidget);
    final remembered = readLastUsedSource(settings, 'cnc:film');
    expect(remembered, isNotNull);

    Navigator.of(tester.element(find.text('PLAYER'))).pop();
    await settle(tester);

    await _openCard(tester);
    await settle(tester);
    expect(page.launcher.played, hasLength(2));
    final again = page.launcher.played.last;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AddonDetailScreen, skipOffstage: false)),
    );
    expect(
      resumePointFor(
        read: container.read,
        item: again.item,
        episode: again.episode,
        videoUrl: again.videoUrl,
      )?.position,
      const Duration(minutes: 10),
    );
  });

  testWidgets('no saved position: the card reads as before', (tester) async {
    await openStremioPage(tester, kBridgeMovie, links: const [_stremio]);
    expect(
      find.descendant(
        of: find.byType(StremioSourcesCard),
        matching: find.textContaining('Resume'),
      ),
      findsNothing,
    );
  });
}
