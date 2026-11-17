import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/storage/settings_repository.dart';
import 'package:zorox/features/home/presentation/home_row_prefs.dart';
import 'package:zorox/features/home/presentation/home_row_prefs_provider.dart';

/// Home rows customise (v7): order, hide, unknown rows, reset, per source.

class _Repo implements SettingsRepository {
  String? saved;

  @override
  String? getHomeRowPrefsJson() => saved;

  @override
  Future<void> setHomeRowPrefsJson(String? json) async => saved = json;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _cw = kHomeRowContinueWatching;

void main() {
  const rows = [_cw, 'Latest', 'Popular', 'Movies'];

  group('applyHomeRowPrefs', () {
    test('nothing saved: the source order, every row', () {
      expect(applyHomeRowPrefs(rows, null), rows);
      expect(applyHomeRowPrefs(rows, const HomeRowPrefs()), rows);
    });

    test('saved order is applied', () {
      const prefs = HomeRowPrefs(order: ['Movies', _cw, 'Latest', 'Popular']);
      expect(applyHomeRowPrefs(rows, prefs), [
        'Movies',
        _cw,
        'Latest',
        'Popular',
      ]);
    });

    test('hidden rows are left out', () {
      const prefs = HomeRowPrefs(hidden: {'Popular', _cw});
      expect(applyHomeRowPrefs(rows, prefs), ['Latest', 'Movies']);
    });

    test('rows the saved order does not know go at the end, visible', () {
      const prefs = HomeRowPrefs(order: ['Popular', 'Latest'], hidden: {'Latest'});
      expect(applyHomeRowPrefs([...rows, 'Brand New'], prefs), [
        'Popular',
        _cw,
        'Movies',
        'Brand New',
      ]);
    });

    test('saved rows the source no longer sends are skipped', () {
      const prefs = HomeRowPrefs(order: ['Gone', 'Movies', 'Latest']);
      expect(applyHomeRowPrefs(rows, prefs), [
        'Movies',
        'Latest',
        _cw,
        'Popular',
      ]);
    });

    test('every row hidden: nothing to draw (Home keeps its hero)', () {
      final prefs = HomeRowPrefs(hidden: rows.toSet());
      expect(applyHomeRowPrefs(rows, prefs), isEmpty);
    });

    test('a duplicated saved id is used once', () {
      const prefs = HomeRowPrefs(order: ['Latest', 'Latest', 'Movies']);
      expect(applyHomeRowPrefs(rows, prefs), [
        'Latest',
        'Movies',
        _cw,
        'Popular',
      ]);
    });
  });

  group('knownHomeRows', () {
    test('Continue Watching is always listed, first by default', () {
      expect(knownHomeRows(const [], null), [_cw]);
      expect(knownHomeRows(const ['Latest'], null), [_cw, 'Latest']);
    });

    test('remembered rows are listed while the source is not loaded', () {
      const prefs = HomeRowPrefs(order: ['Latest', _cw, 'Movies']);
      expect(knownHomeRows(const [], prefs), ['Latest', _cw, 'Movies']);
    });

    test('hidden rows stay in the list', () {
      const prefs = HomeRowPrefs(hidden: {'Latest'});
      expect(knownHomeRows(const ['Latest', 'Movies'], prefs), [
        _cw,
        'Latest',
        'Movies',
      ]);
    });
  });

  test('source key: provider package name, or the key-free feed', () {
    expect(homeRowsSourceKey(null), kHomeRowsKeyFreeSource);
    expect(homeRowsSourceKey('cs3:abc/Site'), 'cs3:abc/Site');
    expect(
      homeRowsSourceKey('cs3:abc/Site', fellBack: true),
      kHomeRowsKeyFreeSource,
    );
  });

  test('encode/decode round trip; defaults are not stored; junk is empty', () {
    final encoded = encodeHomeRowPrefs({
      'a': const HomeRowPrefs(order: ['x', 'y'], hidden: {'y'}),
      'b': const HomeRowPrefs(),
    });
    final decoded = decodeHomeRowPrefs(encoded);
    expect(decoded.keys, ['a']);
    expect(decoded['a']!.order, ['x', 'y']);
    expect(decoded['a']!.hidden, {'y'});
    expect(encodeHomeRowPrefs({'b': const HomeRowPrefs()}), isNull);
    expect(decodeHomeRowPrefs(null), isEmpty);
    expect(decodeHomeRowPrefs('not json'), isEmpty);
    expect(decodeHomeRowPrefs('[1,2]'), isEmpty);
    expect(decodeHomeRowPrefs('{"a": 5}')['a']!.isDefault, isTrue);
  });

  group('HomeRowPrefsNotifier', () {
    late _Repo repo;
    late ProviderContainer c;

    setUp(() {
      repo = _Repo();
      c = ProviderContainer(
        overrides: [settingsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(c.dispose);
    });

    test('order and hidden are saved per source and survive a reload', () async {
      final n = c.read(homeRowPrefsProvider.notifier);
      await n.setOrder('p1', ['Movies', _cw, 'Latest']);
      await n.setHidden('p1', 'Latest', true);
      await n.setHidden('p2', _cw, true);

      expect(c.read(homeRowPrefsProvider)['p1']!.order, [
        'Movies',
        _cw,
        'Latest',
      ]);
      expect(c.read(homeRowPrefsProvider)['p1']!.hidden, {'Latest'});
      expect(c.read(homeRowPrefsProvider)['p2']!.hidden, {_cw});

      // A new container reading the same storage sees the same thing.
      final again = ProviderContainer(
        overrides: [settingsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(again.dispose);
      final loaded = again.read(homeRowPrefsProvider);
      expect(loaded['p1']!.order, ['Movies', _cw, 'Latest']);
      expect(loaded['p1']!.hidden, {'Latest'});
      expect(loaded['p2']!.hidden, {_cw});
    });

    test('showing a row again removes it from hidden', () async {
      final n = c.read(homeRowPrefsProvider.notifier);
      await n.setHidden('p1', 'Latest', true);
      await n.setHidden('p1', 'Latest', false);
      expect(c.read(homeRowPrefsProvider)['p1']!.hidden, isEmpty);
    });

    test('reset clears one source only', () async {
      final n = c.read(homeRowPrefsProvider.notifier);
      await n.setOrder('p1', ['Movies', 'Latest']);
      await n.setHidden('p2', 'Latest', true);
      await n.reset('p1');
      expect(c.read(homeRowPrefsProvider).containsKey('p1'), isFalse);
      expect(c.read(homeRowPrefsProvider)['p2']!.hidden, {'Latest'});
      expect(
        applyHomeRowPrefs(const [
          _cw,
          'Latest',
          'Movies',
        ], c.read(homeRowPrefsProvider)['p1']),
        [_cw, 'Latest', 'Movies'],
      );
      expect(decodeHomeRowPrefs(repo.saved).keys, ['p2']);
    });
  });
}
