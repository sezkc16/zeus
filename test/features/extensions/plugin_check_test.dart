import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/extensions/base_provider.dart';
import 'package:zorox/features/extensions/providers/plugin_check.dart';
import 'package:zorox/features/extensions/providers/plugin_check_provider.dart';

/// The plugin status check (v7): classification of one source's answer,
/// one-at-a-time order, cancel, and the notifier that keeps the results.

MultimediaItem _item(String t) =>
    MultimediaItem(title: t, url: 'https://t.test/$t', posterUrl: '');

class _Fake extends SkyStreamProvider {
  _Fake(
    this.name, {
    this.home,
    this.searchItems = 0,
    this.delay = Duration.zero,
    this.homeError,
    this.never = false,
    this.log,
    this.canSearch = true,
  });

  @override
  final String name;

  /// Rows the main page answers with; null = no main page (answers `{}`).
  final Map<String, int>? home;
  final int searchItems;
  final Duration delay;
  final Object? homeError;
  final bool never;
  final List<String>? log;
  final bool canSearch;
  int homeCalls = 0;
  int searchCalls = 0;
  String? lastQuery;

  @override
  String get packageName => 'fake.$name';
  @override
  String get mainUrl => 'https://t.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => const [];
  @override
  Set<ProviderType> get supportedTypes => {ProviderType.movie};
  @override
  bool get hasSearch => canSearch;

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async {
    homeCalls++;
    log?.add('start $name');
    if (never) return Completer<Map<String, List<MultimediaItem>>>().future;
    await Future<void>.delayed(delay);
    log?.add('end $name');
    if (homeError != null) throw homeError!;
    return {
      for (final e in (home ?? const <String, int>{}).entries)
        e.key: [for (var i = 0; i < e.value; i++) _item('${e.key}$i')],
    };
  }

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    searchCalls++;
    lastQuery = query;
    return [for (var i = 0; i < searchItems; i++) _item('s$i')];
  }

  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

const _fast = PluginCheckConfig(
  timeout: Duration(milliseconds: 300),
  slowAfter: Duration(milliseconds: 80),
  searchQuery: 'one',
);

void main() {
  group('probeProvider', () {
    test('working: main page answers with items, in time', () async {
      final p = _Fake('A', home: {'Latest': 2, 'Top': 1});
      final r = await probeProvider(p, config: _fast);
      expect(r.status, PluginCheckStatus.working);
      expect(r.itemCount, 3);
      expect(r.usedSearch, isFalse);
      expect(p.searchCalls, 0);
    });

    test('slow: items, but later than the slow limit', () async {
      final p = _Fake(
        'A',
        home: {'Latest': 1},
        delay: const Duration(milliseconds: 150),
      );
      final r = await probeProvider(p, config: _fast);
      expect(r.status, PluginCheckStatus.slow);
      expect(r.elapsed, greaterThan(_fast.slowAfter));
    });

    test('not responding: no answer before the time limit', () async {
      final r = await probeProvider(_Fake('A', never: true), config: _fast);
      expect(r.status, PluginCheckStatus.notResponding);
      expect(r.timedOut, isTrue);
      expect(r.error, isNull);
    });

    test('not responding: it threw, and the reason is kept short', () async {
      final r = await probeProvider(
        _Fake('A', homeError: Exception('HTTP 403 from site')),
        config: _fast,
      );
      expect(r.status, PluginCheckStatus.notResponding);
      expect(r.timedOut, isFalse);
      expect(r.error, 'HTTP 403 from site');
    });

    test('no main page: falls back to a neutral search', () async {
      final p = _Fake('A', searchItems: 4);
      final r = await probeProvider(p, config: _fast);
      expect(r.status, PluginCheckStatus.working);
      expect(r.usedSearch, isTrue);
      expect(r.itemCount, 4);
      expect(p.lastQuery, 'one');
    });

    test('empty: answered with nothing is not called Working', () async {
      final none = await probeProvider(_Fake('A'), config: _fast);
      expect(none.status, PluginCheckStatus.empty);
      expect(none.itemCount, 0);

      final emptyRows = await probeProvider(
        _Fake('B', home: {'Latest': 0}),
        config: _fast,
      );
      expect(emptyRows.status, PluginCheckStatus.empty);

      final noSearch = _Fake('C', canSearch: false);
      final r = await probeProvider(noSearch, config: _fast);
      expect(r.status, PluginCheckStatus.empty);
      expect(noSearch.searchCalls, 0);
    });
  });

  group('checkPlugin', () {
    test('a plugin that never loaded is reported without a call', () async {
      final p = _Fake('A', home: {'Latest': 1});
      final r = await checkPlugin(
        PluginCheckTarget(
          key: 'k',
          name: 'A',
          loadError: 'bad dex',
          providers: [p],
        ),
        config: _fast,
      );
      expect(r.status, PluginCheckStatus.couldNotLoad);
      expect(r.error, 'bad dex');
      expect(p.homeCalls, 0);
    });

    test('a plugin with no source says so', () async {
      final r = await checkPlugin(
        const PluginCheckTarget(key: 'k', name: 'Helper'),
        config: _fast,
      );
      expect(r.status, PluginCheckStatus.noSource);
    });

    test('several sources: the worst one is the status', () async {
      final r = await checkPlugin(
        PluginCheckTarget(
          key: 'k',
          name: 'Two',
          providers: [
            _Fake('Good', home: {'Latest': 1}),
            _Fake('Bad', homeError: Exception('down')),
          ],
        ),
        config: _fast,
      );
      expect(r.status, PluginCheckStatus.notResponding);
      expect(r.okCount, 1);
      expect(r.probes, hasLength(2));
      expect(r.error, 'down');
    });
  });

  group('runPluginChecks', () {
    test('one at a time, in order', () async {
      final log = <String>[];
      final targets = [
        for (final n in ['A', 'B', 'C'])
          PluginCheckTarget(
            key: n,
            name: n,
            providers: [
              _Fake(
                n,
                home: {'Latest': 1},
                delay: const Duration(milliseconds: 20),
                log: log,
              ),
            ],
          ),
      ];
      final started = <String>[];
      final done = <String>[];
      final finished = await runPluginChecks(
        targets,
        config: _fast,
        onStart: started.add,
        onResult: (k, _) => done.add(k),
      );
      expect(finished, isTrue);
      expect(started, ['A', 'B', 'C']);
      expect(done, ['A', 'B', 'C']);
      // No plugin starts before the one before it has answered.
      expect(log, ['start A', 'end A', 'start B', 'end B', 'start C', 'end C']);
    });

    test('cancel stops at once and starts nothing more', () async {
      final cancel = Completer<void>();
      final c = _Fake('C', home: {'Latest': 1});
      final targets = [
        PluginCheckTarget(
          key: 'A',
          name: 'A',
          providers: [
            _Fake('A', home: {'Latest': 1}),
          ],
        ),
        PluginCheckTarget(
          key: 'B',
          name: 'B',
          providers: [_Fake('B', never: true)],
        ),
        PluginCheckTarget(key: 'C', name: 'C', providers: [c]),
      ];
      final done = <String>[];
      final run = runPluginChecks(
        targets,
        // Long limits: only the cancel can end B.
        config: const PluginCheckConfig(timeout: Duration(seconds: 30)),
        cancelled: cancel.future,
        onStart: (k) {
          if (k == 'B') {
            Timer(const Duration(milliseconds: 30), cancel.complete);
          }
        },
        onResult: (k, _) => done.add(k),
      );
      final finished = await run.timeout(const Duration(seconds: 5));
      expect(finished, isFalse);
      expect(done, ['A']);
      expect(c.homeCalls, 0);
    });
  });

  group('PluginCheckNotifier', () {
    ProviderContainer container(List<PluginCheckTarget> targets) {
      final c = ProviderContainer(
        overrides: [
          pluginCheckTargetsProvider.overrideWithValue(targets),
          pluginCheckConfigProvider.overrideWithValue(_fast),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('keeps results by plugin key until the next check', () async {
      final c = container([
        PluginCheckTarget(
          key: 'A',
          name: 'A',
          providers: [
            _Fake('A', home: {'Latest': 1}),
          ],
        ),
        const PluginCheckTarget(key: 'B', name: 'B', loadError: 'nope'),
      ]);
      expect(c.read(pluginCheckProvider).results, isEmpty);
      expect(c.read(pluginCheckProvider).finishedAt, isNull);

      await c.read(pluginCheckProvider.notifier).start();
      final s = c.read(pluginCheckProvider);
      expect(s.running, isFalse);
      expect(s.runningKey, isNull);
      expect(s.wasCancelled, isFalse);
      expect(s.finishedAt, isNotNull);
      expect(s.total, 2);
      expect(s.results['A']!.status, PluginCheckStatus.working);
      expect(s.results['B']!.status, PluginCheckStatus.couldNotLoad);
    });

    test('cancel: running plugin gets no status, earlier results stay', () async {
      final c = container([
        PluginCheckTarget(
          key: 'A',
          name: 'A',
          providers: [
            _Fake('A', home: {'Latest': 1}),
          ],
        ),
        PluginCheckTarget(
          key: 'B',
          name: 'B',
          providers: [_Fake('B', never: true)],
        ),
      ]);
      final notifier = c.read(pluginCheckProvider.notifier);
      final run = notifier.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(c.read(pluginCheckProvider).running, isTrue);
      expect(c.read(pluginCheckProvider).runningKey, 'B');
      notifier.cancel();
      await run;
      final s = c.read(pluginCheckProvider);
      expect(s.running, isFalse);
      expect(s.wasCancelled, isTrue);
      expect(s.results.keys, ['A']);
      expect(s.results.containsKey('B'), isFalse);
    });
  });
}
