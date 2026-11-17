import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/search/domain/search_plugin_filter.dart';

void main() {
  group('Search in plugins', () {
    test('everything is searched by default', () {
      expect(
        enabledSearchSources(['a', 'b', 'c'], const <String>{}, (s) => s),
        ['a', 'b', 'c'],
      );
    });

    test('a source switched off is not asked; order is kept', () {
      expect(
        enabledSearchSources(['a', 'b', 'c'], {'b'}, (s) => s),
        ['a', 'c'],
      );
    });

    test('a plugin installed later is on without being listed', () {
      final disabled = decodeSearchDisabledSources('["old"]');
      expect(enabledSearchSources(['old', 'new'], disabled, (s) => s), ['new']);
    });

    test('unreadable storage switches nothing off', () {
      expect(decodeSearchDisabledSources(null), isEmpty);
      expect(decodeSearchDisabledSources('{'), isEmpty);
      expect(decodeSearchDisabledSources('{"a":1}'), isEmpty);
    });
  });

  group('per-plugin search timeout', () {
    test('a search that answers in time is returned', () async {
      final result = await searchWithin(
        Future.value([1, 2]),
        limit: const Duration(milliseconds: 50),
      );
      expect(result, [1, 2]);
    });

    test('a slow search is dropped and its request cancelled', () async {
      var cancelled = false;
      final slow = Completer<List<int>>();
      await expectLater(
        searchWithin(
          slow.future,
          limit: const Duration(milliseconds: 20),
          onTimeout: () => cancelled = true,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(cancelled, isTrue);
    });

    test('the limit is 20 seconds', () {
      expect(kSearchSourceTimeout, const Duration(seconds: 20));
    });
  });

  group('the switches are no longer offered (1.0.1)', () {
    test('a stored switched-off source is searched again', () {
      expect(kSearchInPluginsOffered, isFalse);
      expect(effectiveSearchDisabledSources({'old.plugin'}), isEmpty);
      expect(
        enabledSearchSources(
          ['old.plugin', 'other'],
          effectiveSearchDisabledSources({'old.plugin'}),
          (id) => id,
        ),
        ['old.plugin', 'other'],
      );
    });

    test('the stored list would count again if the switches came back', () {
      expect(
        effectiveSearchDisabledSources({'old.plugin'}, offered: true),
        {'old.plugin'},
      );
    });
  });
}
