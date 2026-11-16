import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/providers/device_info_provider.dart';
import 'package:zorox/features/library/presentation/history_provider.dart';
import 'package:zorox/features/library/presentation/widgets/watch_status_tab.dart';
import 'package:zorox/features/settings/presentation/general_settings_provider.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

HistoryItem _entry(String url, int position, int duration) => HistoryItem(
  item: MultimediaItem(
    title: 'Title $url',
    url: url,
    posterUrl: '',
    contentType: MultimediaContentType.movie,
  ),
  position: position,
  duration: duration,
  timestamp: 1,
);

/// The history, without Hive underneath it.
class _FakeHistory extends WatchHistory {
  _FakeHistory(this._items);

  final List<HistoryItem> _items;

  @override
  List<HistoryItem> build() => _items;
}

Future<void> _pumpTab(
  WidgetTester tester, {
  required List<HistoryItem> items,
  required LibraryWatchFilter filter,
}) async {
  final container = ProviderContainer(
    overrides: [
      watchHistoryProvider.overrideWith(() => _FakeHistory(items)),
      generalSettingsProvider.overrideWithValue(const GeneralSettings()),
      deviceProfileProvider.overrideWithValue(
        const AsyncValue.data(DeviceProfile()),
      ),
    ],
  );
  addTearDown(container.dispose);

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(body: WatchStatusTab(filter: filter)),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  // Never pumpAndSettle here: the poster placeholders shimmer forever.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('filterWatchHistory', () {
    final items = [
      _entry('https://fake.test/not-started', 0, 3600),
      _entry('https://fake.test/barely', 10, 3600),
      _entry('https://fake.test/half', 1800, 3600),
      _entry('https://fake.test/done', 3300, 3600),
      _entry('https://fake.test/finished', 3600, 3600),
      _entry('https://fake.test/livestream', 0, 0),
    ];

    test('Watching is started but not finished', () {
      final watching = filterWatchHistory(items, LibraryWatchFilter.watching);
      expect(
        watching.map((e) => e.item.url).toList(),
        ['https://fake.test/half'],
        reason:
            'not-started (0%) and barely-started (<1%) are not watching; '
            'done (91%) is already completed',
      );
    });

    test('Completed is at or past the 90% mark', () {
      final completed = filterWatchHistory(
        items,
        LibraryWatchFilter.completed,
      );
      expect(
        completed.map((e) => e.item.url).toList(),
        ['https://fake.test/done', 'https://fake.test/finished'],
      );
    });

    test('a livestream entry is in neither', () {
      expect(
        filterWatchHistory(items, LibraryWatchFilter.watching),
        isNot(anyElement(predicate<HistoryItem>(
          (e) => e.item.url == 'https://fake.test/livestream',
        ))),
      );
      expect(
        filterWatchHistory(items, LibraryWatchFilter.completed),
        isNot(anyElement(predicate<HistoryItem>(
          (e) => e.item.url == 'https://fake.test/livestream',
        ))),
      );
    });
  });

  group('WatchStatusTab', () {
    testWidgets('Watching shows the in-progress titles with their status', (
      tester,
    ) async {
      await _pumpTab(
        tester,
        items: [
          _entry('https://fake.test/half', 1800, 3600),
          _entry('https://fake.test/done', 3300, 3600),
        ],
        filter: LibraryWatchFilter.watching,
      );

      expect(
        find.text('Title https://fake.test/half'),
        findsOneWidget,
      );
      expect(find.text('Watching · 50%'), findsOneWidget);
      expect(find.text('Title https://fake.test/done'), findsNothing);
    });

    testWidgets('Completed shows the finished titles', (tester) async {
      await _pumpTab(
        tester,
        items: [
          _entry('https://fake.test/half', 1800, 3600),
          _entry('https://fake.test/done', 3300, 3600),
        ],
        filter: LibraryWatchFilter.completed,
      );

      expect(find.text('Title https://fake.test/done'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Title https://fake.test/half'), findsNothing);
    });

    testWidgets('an empty filter says so', (tester) async {
      await _pumpTab(
        tester,
        items: [_entry('https://fake.test/half', 1800, 3600)],
        filter: LibraryWatchFilter.completed,
      );

      expect(find.text('Nothing completed yet'), findsOneWidget);
    });
  });
}
