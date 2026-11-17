// v9: "Preferred source language". A source matches a language only when
// its own text spells it out; matching sources lead every sources list,
// ahead of the v7 quality order, and nothing is hidden. "Last used" still
// goes first and the mobile-data limit still splits the list.
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/addons/models/addon_stream_source.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/utils/source_language.dart';
import 'package:zorox/features/player/domain/stream_resolver.dart';
import 'package:zorox/features/settings/presentation/player_settings_provider.dart';

StreamResult s(String label) => StreamResult(
  url: 'https://a/${label.hashCode}.mkv',
  source: label,
  providerName: 'Plugin',
);

AddonStreamSource a(String addon, String title) => AddonStreamSource(
  addonId: addon,
  addonName: addon,
  title: title,
  url: 'https://x/$addon/${title.hashCode}.mkv',
);

List<String> labels(List<StreamResult> list) => [for (final x in list) x.source];

void main() {
  group('textStatesLanguage', () {
    test('the name, the three-letter code and the own-script name match', () {
      expect(textStatesLanguage('Movie 1080p Hindi', SourceLanguage.hindi), isTrue);
      expect(textStatesLanguage('Movie.1080p.HIN.x264', SourceLanguage.hindi), isTrue);
      expect(textStatesLanguage('फ़िल्म हिंदी', SourceLanguage.hindi), isTrue);
      expect(textStatesLanguage('[ENG] 720p', SourceLanguage.english), isTrue);
      expect(textStatesLanguage('1080p | Japanese', SourceLanguage.japanese), isTrue);
      expect(textStatesLanguage('KOR 1080p', SourceLanguage.korean), isTrue);
      expect(textStatesLanguage('Tamil + Telugu', SourceLanguage.tamil), isTrue);
      expect(textStatesLanguage('Tamil + Telugu', SourceLanguage.telugu), isTrue);
    });

    test('only whole words: a language inside another word is not one', () {
      expect(textStatesLanguage('Chinatown 1080p', SourceLanguage.hindi), isFalse);
      expect(textStatesLanguage('Shin Godzilla', SourceLanguage.hindi), isFalse);
      expect(textStatesLanguage('Engine 720p', SourceLanguage.english), isFalse);
      expect(textStatesLanguage('Hotel Telaviv', SourceLanguage.telugu), isFalse);
      expect(textStatesLanguage('Korra S01', SourceLanguage.korean), isFalse);
    });

    test('never a guess: Dual Audio, Multi, Dub, Sub name no language', () {
      for (final text in <String>[
        'Dual Audio 1080p',
        'Multi 2160p',
        'Dubbed',
        'Dub',
        'Sub',
        'Multi-Audio WEB-DL',
        '1080p WEB-DL x265',
      ]) {
        for (final language in SourceLanguage.values) {
          expect(textStatesLanguage(text, language), isFalse, reason: '$text / $language');
        }
      }
    });

    test('two-letter codes are not read', () {
      expect(textStatesLanguage('EN 1080p', SourceLanguage.english), isFalse);
      expect(textStatesLanguage('hi 720p', SourceLanguage.hindi), isFalse);
      expect(textStatesLanguage('ta te ko ja', SourceLanguage.tamil), isFalse);
    });

    test('Off, empty and null match nothing', () {
      expect(textStatesLanguage('Hindi', SourceLanguage.off), isFalse);
      expect(textStatesLanguage('', SourceLanguage.hindi), isFalse);
      expect(textStatesLanguage(null, SourceLanguage.hindi), isFalse);
    });

    test('the stored name reads back; junk is Off', () {
      for (final language in SourceLanguage.values) {
        expect(sourceLanguageFromName(language.name), language);
      }
      expect(sourceLanguageFromName(null), SourceLanguage.off);
      expect(sourceLanguageFromName('klingon'), SourceLanguage.off);
      expect(const PlayerSettings().preferredSourceLanguage, SourceLanguage.off);
    });
  });

  group('preferMatching', () {
    test('matches first, both parts in their own order, nothing dropped', () {
      expect(
        preferMatching<int>([1, 2, 3, 4, 5, 6], (n) => n.isEven),
        [2, 4, 6, 1, 3, 5],
      );
    });

    test('no match: the list itself', () {
      final list = [1, 3, 5];
      expect(preferMatching<int>(list, (n) => n.isEven), same(list));
    });

    test('with groups, the move stays inside each group', () {
      expect(
        preferMatching<int>(
          [1, 2, 3, 4, 11, 12, 13, 14],
          (n) => n.isEven,
          groupOf: (n) => n > 10 ? 1 : 0,
        ),
        [2, 4, 1, 3, 12, 14, 11, 13],
      );
    });
  });

  group('planSourceList with a preferred language', () {
    final raw = [
      s('720p English'),
      s('2160p English'),
      s('1080p Hindi'),
      s('480p Hindi'),
      s('1080p'),
    ];

    test('Off: exactly the v7 order', () {
      final plan = planSourceList(raw, preference: QualityPreference.q1080);
      expect(labels(plan.streams), [
        '2160p English',
        '1080p Hindi',
        '1080p',
        '720p English',
        '480p Hindi',
      ]);
    });

    test('Hindi sources lead, best quality first; nothing hidden', () {
      final plan = planSourceList(
        raw,
        preference: QualityPreference.q1080,
        language: SourceLanguage.hindi,
      );
      expect(labels(plan.streams), [
        '1080p Hindi',
        '480p Hindi',
        '2160p English',
        '1080p',
        '720p English',
      ]);
      expect(plan.streams, hasLength(raw.length));
      // Playback starts on a Hindi source.
      expect(plan.streams[plan.start].source, '1080p Hindi');
    });

    test('Last used stays on top, even when it is not in the language', () {
      final plan = planSourceList(
        raw,
        preference: QualityPreference.q1080,
        language: SourceLanguage.hindi,
        lastUsed: (ordered) =>
            ordered.indexWhere((x) => x.source == '720p English'),
      );
      expect(labels(plan.streams), [
        '720p English',
        '1080p Hindi',
        '480p Hindi',
        '2160p English',
        '1080p',
      ]);
      expect(plan.start, 0);
      expect(plan.lastUsedIndex, 0);
    });

    test('with the mobile-data limit: language first inside each part', () {
      final plan = planSourceList(
        raw,
        preference: QualityPreference.q1080,
        cap: QualityPreference.q720,
        language: SourceLanguage.hindi,
      );
      expect(labels(plan.streams), [
        // Within the limit.
        '480p Hindi',
        '720p English',
        // Above it.
        '1080p Hindi',
        '2160p English',
        '1080p',
      ]);
      expect(plan.streams[plan.start].source, '480p Hindi');
    });

    test('no source names the language: the v7 order, untouched', () {
      final plan = planSourceList(
        raw,
        preference: QualityPreference.q1080,
        language: SourceLanguage.korean,
      );
      expect(labels(plan.streams), [
        '2160p English',
        '1080p Hindi',
        '1080p',
        '720p English',
        '480p Hindi',
      ]);
    });
  });

  group('arrangeAddonSources with a preferred language', () {
    final ranked = [
      a('A', 'Film 2160p English'),
      a('B', 'Film 1080p Hindi'),
      a('C', 'Film 720p'),
      a('D', 'Film 480p HIN'),
    ];

    test('matching sources lead, order kept, nothing dropped', () {
      final out = arrangeAddonSources(ranked, language: SourceLanguage.hindi);
      expect([for (final x in out) x.addonName], ['B', 'D', 'A', 'C']);
    });

    test('Last used still goes first', () {
      final out = arrangeAddonSources(
        ranked,
        lastUsedKey: addonSourceKey(ranked[2]),
        language: SourceLanguage.hindi,
      );
      expect([for (final x in out) x.addonName], ['C', 'B', 'D', 'A']);
    });

    test('with the limit: what fits first, language first inside it', () {
      final out = arrangeAddonSources(
        ranked,
        capHeight: 720,
        language: SourceLanguage.hindi,
      );
      expect([for (final x in out) x.addonName], ['D', 'C', 'B', 'A']);
    });

    test('Off changes nothing', () {
      expect(arrangeAddonSources(ranked), ranked);
    });
  });
}
