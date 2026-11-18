// Build 76 (design A): with a saved position the Sources card shows
// Resume AND "Change source". Resume still plays the remembered source
// by itself; Change source opens the same list with nothing played,
// the remembered source first and marked "Last used", and the source
// picked there starts at the saved place and is the one remembered.
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

Finder _inCard(Finder what) =>
    find.descendant(of: find.byType(StremioSourcesCard), matching: what);

Future<void> _tapInCard(WidgetTester tester, Finder what) async {
  await tester.ensureVisible(find.byType(StremioSourcesCard));
  await tester.pump();
  await tester.tap(_inCard(what));
  await settle(tester);
}

void main() {
  useTestClearance();

  testWidgets('no saved position: one button, no Change source', (
    tester,
  ) async {
    await openStremioPage(
      tester,
      kBridgeShow,
      links: const [_nuvio, _stremio],
      opensPlayer: true,
      history: FakeHistory(),
      overrides: [settingsRepositoryProvider.overrideWithValue(_Settings())],
    );
    expect(_inCard(find.text('Change source')), findsNothing);
    expect(_inCard(find.textContaining('Resume')), findsNothing);
  });

  testWidgets('a saved position: Resume and Change source; Change source '
      'opens the list and plays nothing; the pick starts at the saved place '
      'and is remembered instead', (tester) async {
    final settings = _Settings();
    // The show last played on the Nuvio row.
    await rememberLastUsedSource(settings, 'cnc:show', addonSourceKey(_nuvio));
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

    expect(_inCard(find.text('Resume S1 E2 · 10:00')), findsOneWidget);
    expect(_inCard(find.text('Change source')), findsOneWidget);

    // Change source: the list, and nothing plays by itself.
    await _tapInCard(tester, find.text('Change source'));
    await settle(tester);
    expect(find.byType(AddonSourcesSheet), findsOneWidget);
    expect(page.launcher.played, isEmpty);
    expect(find.text('PLAYER'), findsNothing);
    // The remembered source leads, marked.
    expect(_inSheet(find.text('LAST USED')), findsOneWidget);

    // Pick the other one.
    await tester.ensureVisible(_inSheet(find.text(_stremio.name!)).first);
    await tester.tap(_inSheet(find.text(_stremio.name!)).first);
    await settle(tester);
    if (page.launcher.played.isEmpty) {
      await tester.tap(_inSheet(find.text('Play')).last);
      await settle(tester);
    }
    expect(page.launcher.played, hasLength(1));
    final played = page.launcher.played.last;
    expect(played.videoUrl, 'cnc:s1e2');

    // It starts at the saved place…
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AddonDetailScreen, skipOffstage: false)),
    );
    final point = resumePointFor(
      read: container.read,
      item: played.item,
      episode: played.episode,
      videoUrl: played.videoUrl,
    );
    expect(point?.position, const Duration(minutes: 10));
    // …and is the remembered source from now on.
    expect(readLastUsedSource(settings, 'cnc:show'), addonSourceKey(_stremio));

    // Resume now continues on it, by itself.
    Navigator.of(tester.element(find.text('PLAYER'))).pop();
    await settle(tester);
    await _tapInCard(tester, find.textContaining('Resume'));
    await settle(tester);
    expect(page.launcher.played, hasLength(2));
  });

  for (final width in [320.0, 360.0, 430.0]) {
    testWidgets('the two buttons at $width wide: nothing overflows, no label '
        'is cut', (tester) async {
      tester.view.physicalSize = Size(width * 3, 900 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await openStremioPage(
        tester,
        kBridgeShow,
        links: const [_nuvio, _stremio],
        opensPlayer: true,
        history: FakeHistory(
          positions: const {'cnc:s1e2': 3723000},
          lastEpisode: 'cnc:s1e2',
        ),
        overrides: [settingsRepositoryProvider.overrideWithValue(_Settings())],
      );
      expect(tester.takeException(), isNull);
      for (final label in ['Resume S1 E2 · 1:02:03', 'Change source']) {
        final text = tester.widget<Text>(_inCard(find.text(label)));
        expect(text.overflow, isNot(TextOverflow.ellipsis));
        final box = tester.getSize(_inCard(find.text(label)));
        // Drawn at (or near) full size: 14 pt text is about 17 tall.
        expect(box.height, greaterThan(12));
      }
    });
  }
}
