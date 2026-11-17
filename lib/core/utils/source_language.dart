/// "Preferred source language" (v9): which audio language a source says it
/// carries, read from the source's own text and nothing else.
///
/// A source matches a language only when its label, name or tags spell the
/// language out as a whole word — the name ("Hindi"), a three-letter code
/// ("HIN") or its own-script name ("हिन्दी"). "Dual Audio", "Multi", "Dub"
/// and "Sub" name no language, so they match nothing: the app never guesses.
/// Two-letter codes ("en", "te", "ta", "ko") are not read either — they are
/// ordinary syllables in release names.
enum SourceLanguage { off, hindi, english, japanese, korean, tamil, telugu }

/// The settings-box key the choice is stored under, by enum name.
const String kPreferredSourceLanguageKey = 'player_preferred_source_language';

extension SourceLanguageLabel on SourceLanguage {
  /// What the settings row and the row tag call it.
  String get label => switch (this) {
    SourceLanguage.off => 'Off',
    SourceLanguage.hindi => 'Hindi',
    SourceLanguage.english => 'English',
    SourceLanguage.japanese => 'Japanese',
    SourceLanguage.korean => 'Korean',
    SourceLanguage.tamil => 'Tamil',
    SourceLanguage.telugu => 'Telugu',
  };
}

/// The stored name back as a language; anything unknown is [SourceLanguage.off].
SourceLanguage sourceLanguageFromName(String? name) {
  for (final value in SourceLanguage.values) {
    if (value.name == name) return value;
  }
  return SourceLanguage.off;
}

RegExp _words(String alternatives) => RegExp(
  '(?<![\\p{L}\\p{N}])(?:$alternatives)(?![\\p{L}\\p{N}])',
  caseSensitive: false,
  unicode: true,
);

final Map<SourceLanguage, RegExp> _patterns = <SourceLanguage, RegExp>{
  SourceLanguage.hindi: _words('hindi|hin|हिन्दी|हिंदी'),
  SourceLanguage.english: _words('english|eng'),
  SourceLanguage.japanese: _words('japanese|jpn|jap|日本語'),
  SourceLanguage.korean: _words('korean|kor|한국어'),
  SourceLanguage.tamil: _words('tamil|tam|தமிழ்'),
  SourceLanguage.telugu: _words('telugu|tel|తెలుగు'),
};

/// Whether [text] says outright that it carries [language]. Always false for
/// [SourceLanguage.off] and for empty text.
bool textStatesLanguage(String? text, SourceLanguage language) {
  if (language == SourceLanguage.off || text == null || text.isEmpty) {
    return false;
  }
  return _patterns[language]!.hasMatch(text);
}

/// [items] with the ones [matches] accepts moved ahead of the rest, each
/// part keeping its own order (stable). Nothing is dropped. With [groupOf],
/// the move happens inside each group and the groups keep their order — the
/// mobile-data limit's "within the limit" and "above it" parts stay apart.
List<T> preferMatching<T>(
  List<T> items,
  bool Function(T item) matches, {
  int Function(T item)? groupOf,
}) {
  if (items.length <= 1) return items;
  if (!items.any(matches)) return items;
  if (groupOf == null) {
    return <T>[
      for (final item in items)
        if (matches(item)) item,
      for (final item in items)
        if (!matches(item)) item,
    ];
  }
  final groups = <int>[];
  for (final item in items) {
    final group = groupOf(item);
    if (!groups.contains(group)) groups.add(group);
  }
  return <T>[
    for (final group in groups) ...[
      for (final item in items)
        if (groupOf(item) == group && matches(item)) item,
      for (final item in items)
        if (groupOf(item) == group && !matches(item)) item,
    ],
  ];
}
