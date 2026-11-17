import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/addons/models/addon_stream_source.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/utils/stream_quality_sorter.dart';
import 'package:zorox/features/player/domain/stream_resolver.dart';
import 'package:zorox/features/settings/presentation/player_settings_provider.dart';
import 'package:zorox/features/sources/domain/last_used_source.dart';

StreamResult s(String label, {int? quality, String url = 'https://a/b.mkv'}) =>
    StreamResult(url: url, source: label, providerName: 'Plugin', quality: quality);

AddonStreamSource a(String addon, String title, {String? name}) =>
    AddonStreamSource(
      addonId: addon,
      addonName: addon,
      name: name,
      title: title,
      url: 'https://x/$addon/${title.hashCode}.mkv',
    );

List<String> labels(List<StreamResult> list) => [for (final x in list) x.source];

void main() {
  group('sortStreamsBestFirst', () {
    test('quality descending, unknown last, nothing dropped', () {
      final sorted = sortStreamsBestFirst([
        s('Server A'),
        s('480p'),
        s('1080p'),
        s('2160p'),
        s('720p'),
        s('1440p'),
        s('360p'),
      ]);
      expect(labels(sorted), [
        '2160p',
        '1440p',
        '1080p',
        '720p',
        '480p',
        '360p',
        'Server A',
      ]);
    });

    test('bigger file first within one quality, unknown size after', () {
      final sorted = sortStreamsBestFirst([
        s('1080p · 900 MB'),
        s('1080p'),
        s('1080p · 2.1 GB'),
        s('1080p · 1,5 GB'),
      ]);
      expect(labels(sorted), [
        '1080p · 2.1 GB',
        '1080p · 1,5 GB',
        '1080p · 900 MB',
        '1080p',
      ]);
    });

    test('same quality and size keep the plugin\'s order', () {
      final sorted = sortStreamsBestFirst([
        s('1080p', url: 'https://a/1.mkv'),
        s('1080p', url: 'https://a/2.mkv'),
      ]);
      expect([for (final x in sorted) x.url], ['https://a/1.mkv', 'https://a/2.mkv']);
    });

    test('a mobile-data cap puts what fits first and keeps the rest', () {
      final sorted = sortStreamsBestFirst(
        [s('2160p'), s('480p'), s('1080p'), s('720p'), s('Mirror')],
        cap: QualityPreference.q720,
      );
      expect(labels(sorted), ['720p', '480p', '2160p', '1080p', 'Mirror']);
    });

    test('size parsing', () {
      expect(labelSizeMb('1080p · 2 GB'), 2048);
      expect(labelSizeMb('700 mb'), 700);
      expect(labelSizeMb('1,024 MB'), 1024);
      expect(labelSizeMb('1080p'), isNull);
    });
  });

  group('planSourceList', () {
    final raw = [s('720p'), s('2160p'), s('1080p'), s('480p')];

    test('nothing remembered: best-first list, start on the preference', () {
      final plan = planSourceList(raw, preference: QualityPreference.q1080);
      expect(labels(plan.streams), ['2160p', '1080p', '720p', '480p']);
      expect(plan.streams[plan.start].source, '1080p');
      expect(plan.lastUsedIndex, -1);
    });

    test('the last used source goes first and playback starts on it', () {
      final plan = planSourceList(
        raw,
        preference: QualityPreference.q1080,
        lastUsed: (ordered) => ordered.indexWhere((x) => x.source == '720p'),
      );
      expect(labels(plan.streams), ['720p', '2160p', '1080p', '480p']);
      expect(plan.start, 0);
      expect(plan.lastUsedIndex, 0);
    });

    test('a last used source above the cap stays put; start under the cap', () {
      final plan = planSourceList(
        raw,
        preference: QualityPreference.q1080,
        cap: QualityPreference.q720,
        lastUsed: (ordered) => ordered.indexWhere((x) => x.source == '2160p'),
      );
      expect(labels(plan.streams), ['720p', '480p', '2160p', '1080p']);
      expect(plan.streams[plan.start].source, '720p');
      expect(plan.streams[plan.lastUsedIndex].source, '2160p');
    });

    test('a last used source within the cap leads the capped list', () {
      final plan = planSourceList(
        raw,
        preference: QualityPreference.q1080,
        cap: QualityPreference.q720,
        lastUsed: (ordered) => ordered.indexWhere((x) => x.source == '480p'),
      );
      expect(labels(plan.streams), ['480p', '720p', '2160p', '1080p']);
      expect(plan.start, 0);
    });
  });

  group('merged list (rankAddonStreams byQuality)', () {
    test('quality first, then size; CAM last; nothing dropped', () {
      final ranked = rankAddonStreams([
        a('PluginA', 'Film 720p 900MB'),
        a('AddonB', 'Film 2160p 12 GB'),
        a('PluginC', 'Film 1080p 2 GB'),
        a('AddonD', 'Film 1080p 4 GB'),
        a('PluginE', 'Film 1080p CAM'),
        a('NuvioF', 'Film'),
      ], byQuality: true);
      expect([for (final x in ranked) x.addonName], [
        'AddonB',
        'AddonD',
        'PluginC',
        'PluginA',
        'NuvioF',
        'PluginE',
      ]);
    });
  });

  group('arrangeAddonSources', () {
    final ranked = [
      a('A', 'Film 2160p'),
      a('B', 'Film 1080p'),
      a('C', 'Film 720p'),
      a('D', 'Film'),
    ];

    test('last used goes first, the rest keep their order', () {
      final out = arrangeAddonSources(
        ranked,
        lastUsedKey: addonSourceKey(ranked[2]),
      );
      expect([for (final x in out) x.addonName], ['C', 'A', 'B', 'D']);
    });

    test('cap: what fits first, higher still listed', () {
      final out = arrangeAddonSources(ranked, capHeight: 720);
      expect([for (final x in out) x.addonName], ['C', 'D', 'A', 'B']);
    });

    test('last used above the cap is not promoted', () {
      final out = arrangeAddonSources(
        ranked,
        lastUsedKey: addonSourceKey(ranked[0]),
        capHeight: 1080,
      );
      expect([for (final x in out) x.addonName], ['B', 'C', 'D', 'A']);
    });

    test('an unknown key changes nothing', () {
      expect(arrangeAddonSources(ranked, lastUsedKey: 'nope'), ranked);
    });
  });

  group('last-used memory', () {
    test('one entry per title; newest kept; trimmed to the limit', () {
      var map = <String, String>{};
      map = withLastUsedSource(map, 'show-1', 'k1', limit: 2);
      map = withLastUsedSource(map, 'show-2', 'k2', limit: 2);
      map = withLastUsedSource(map, 'show-1', 'k1b', limit: 2);
      expect(map, {'show-2': 'k2', 'show-1': 'k1b'});
      map = withLastUsedSource(map, 'show-3', 'k3', limit: 2);
      expect(map.keys, ['show-1', 'show-3']);
    });

    test('unreadable storage reads as no memory', () {
      expect(decodeLastUsedSources(null), isEmpty);
      expect(decodeLastUsedSources('not json'), isEmpty);
      expect(decodeLastUsedSources('[1,2]'), isEmpty);
      expect(decodeLastUsedSources('{"a":"b"}'), {'a': 'b'});
    });

    test('the key ignores the address, which changes on every load', () {
      final one = const AddonStreamSource(
        addonId: 'x', addonName: 'HiCine', title: 'Ep 1 1080p', url: 'https://cdn/1?sig=a');
      final two = const AddonStreamSource(
        addonId: 'x', addonName: 'HiCine', title: 'Ep 2 1080p', url: 'https://cdn/2?sig=b');
      expect(addonSourceKey(one), addonSourceKey(two));
    });
  });
}
