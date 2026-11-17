/// A title opened from Browse (a Cinemeta title) can always be played from
/// (v8): the round Play button and the sources card are there with nothing
/// asked yet and no Stremio stream add-on installed, and they open one list
/// that asks Nuvio too, says where each link came from and what each kind
/// answered.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/addons/data/builtin_addons.dart';
import 'package:zorox/core/addons/data/merged_source_service.dart';
import 'package:zorox/core/addons/models/addon_meta.dart';
import 'package:zorox/core/nuvio/data/nuvio_stream_service.dart';
import 'package:zorox/core/nuvio/models/nuvio_models.dart';
import 'package:zorox/features/addons/presentation/addon_sources_sheet.dart';

import 'stremio_page_fakes.dart';

const Size _kPhone = Size(430, 932);

Finder get _fab => find.byKey(const ValueKey('details-play-fab'));
Finder get _card => find.byKey(const ValueKey('merged-sources-card'));

const _odyssey = AddonMeta(
  id: 'tt33764258',
  type: 'movie',
  name: 'The Odyssey',
  addonId: 'com.linvo.cinemeta',
  addonName: 'Cinemeta',
  imdbIdField: 'tt33764258',
  moviedbId: 1368337,
  releaseInfo: '2026',
);

const _show = AddonMeta(
  id: 'tt0000001',
  type: 'series',
  name: 'The Body',
  addonId: 'com.linvo.cinemeta',
  addonName: 'Cinemeta',
  imdbIdField: 'tt0000001',
  moviedbId: 42,
  videos: [
    AddonVideo(id: 'tt0000001:1:1', title: 'One', season: 1, episode: 1),
    AddonVideo(id: 'tt0000001:1:2', title: 'Two', season: 1, episode: 2),
  ],
);

typedef _Ask = ({String id, String type, int? season, int? episode});

MergedSourceService _merged(
  List<_Ask> asked, {
  List<NuvioStreamResult> links = const [],
}) => MergedSourceService(
  plugins: () => const [],
  streamAddons: () => const [],
  askAddons: ({
    required addons,
    required request,
    required forceRefresh,
    required personWaiting,
  }) => const Stream.empty(),
  askNuvio:
      ({
        required id,
        required mediaType,
        season,
        episode,
        required personWaiting,
        required fresh,
      }) {
        asked.add((id: id, type: mediaType, season: season, episode: episode));
        return Stream.value(
          NuvioProgress(
            streams: links,
            statuses: [
              NuvioScraperStatus(
                scraperName: 'ShowBox',
                outcome: links.isEmpty
                    ? NuvioScraperOutcome.empty
                    : NuvioScraperOutcome.links,
                linkCount: links.length,
              ),
            ],
            completedCount: 1,
            totalCount: 1,
            isLoading: false,
          ),
        );
      },
);

void main() {
  useTestClearance();

  testWidgets('Play and the sources card are there for a Cinemeta movie '
      'with nothing installed and nothing asked', (tester) async {
    final asked = <_Ask>[];
    await openStremioPage(
      tester,
      _odyssey,
      size: _kPhone,
      addonUrl: BuiltInAddons.cinemetaUrl,
      noAddons: true,
      overrides: [
        mergedSourceServiceProvider.overrideWithValue(_merged(asked)),
      ],
    );
    expect(_fab, findsOneWidget);
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(_card, findsOneWidget);
    expect(find.text('Find sources'), findsOneWidget);
    // Nothing was asked to decide that.
    expect(asked, isEmpty);
  });

  testWidgets('Play opens the merged list: Nuvio is asked by TMDB id, a row '
      'says NUVIO, and each kind says what it answered', (tester) async {
    final asked = <_Ask>[];
    await openStremioPage(
      tester,
      _odyssey,
      size: _kPhone,
      addonUrl: BuiltInAddons.cinemetaUrl,
      noAddons: true,
      overrides: [
        mergedSourceServiceProvider.overrideWithValue(
          _merged(
            asked,
            links: const [
              NuvioStreamResult(
                scraperId: 'showbox',
                scraperName: 'ShowBox',
                title: 'The Odyssey 1080p',
                url: 'https://cdn.test/odyssey.1080p.mp4',
                quality: '1080p',
              ),
            ],
          ),
        ),
      ],
    );
    await tester.tap(_fab);
    await settle(tester);
    await settle(tester);

    expect(find.byType(AddonSourcesSheet), findsOneWidget);
    expect(asked.single.id, '1368337');
    expect(asked.single.type, 'movie');

    final tag = find.byKey(const ValueKey('source-origin-tag'));
    expect(tag, findsOneWidget);
    expect(
      find.descendant(of: tag, matching: find.text('NUVIO')),
      findsOneWidget,
    );
    expect(find.textContaining('ShowBox'), findsWidgets);

    expect(find.byKey(const ValueKey('sources-origin-status')), findsOneWidget);
    expect(find.text('Nuvio: 1 source'), findsOneWidget);
    expect(find.text('Plugins: none installed'), findsOneWidget);
    expect(find.text('Stremio: no stream add-on installed'), findsOneWidget);
  });

  testWidgets('an empty answer still says so per kind, with Open Plugins', (
    tester,
  ) async {
    final asked = <_Ask>[];
    await openStremioPage(
      tester,
      _odyssey,
      size: _kPhone,
      addonUrl: BuiltInAddons.cinemetaUrl,
      noAddons: true,
      overrides: [
        mergedSourceServiceProvider.overrideWithValue(_merged(asked)),
      ],
    );
    await tester.tap(find.text('Find sources'));
    await settle(tester);
    await settle(tester);
    expect(find.text('Nuvio: 0 sources'), findsOneWidget);
    expect(find.byKey(const ValueKey('sources-open-plugins')), findsOneWidget);
  });

  testWidgets('a Cinemeta show: Play names the first episode and asks for it', (
    tester,
  ) async {
    final asked = <_Ask>[];
    await openStremioPage(
      tester,
      _show,
      size: _kPhone,
      addonUrl: BuiltInAddons.cinemetaUrl,
      noAddons: true,
      overrides: [
        mergedSourceServiceProvider.overrideWithValue(_merged(asked)),
      ],
    );
    expect(find.byTooltip('Play E1'), findsOneWidget);
    await tester.tap(_fab);
    await settle(tester);
    await settle(tester);
    expect(asked.single, (id: '42', type: 'tv', season: 1, episode: 1));
  });
}
