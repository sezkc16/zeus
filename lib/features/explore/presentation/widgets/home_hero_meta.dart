/// What the Home hero (design A, build 82) prints under the title: one meta
/// line and one badge row. Pure, so the rules are tested without a widget.
///
/// Every part is the item's own data. A part the item does not carry is
/// left out - nothing is invented, and a score is called "IMDb" only when
/// it is one.
library;

import '../../../../core/addons/models/addon_meta.dart' show kAddonItemSource;
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/title_quality.dart';

/// The separator between parts of the meta line and the badge row.
const String kHeroDot = ' \u2022 ';

/// "Movie", "TV Show", "Anime", "Live Stream", or null for a type that says
/// nothing.
String? heroTypeLabel(MultimediaContentType type) => switch (type) {
  MultimediaContentType.movie => 'Movie',
  MultimediaContentType.series => 'TV Show',
  MultimediaContentType.anime => 'Anime',
  MultimediaContentType.livestream => 'Live Stream',
  MultimediaContentType.other => null,
};

/// Minutes as "2h 15m" / "24m", or null when there is no duration.
String? heroRuntimeLabel(int? minutes) {
  if (minutes == null || minutes <= 0) return null;
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '${hours}h' : '${hours}h ${rest}m';
}

/// The genres an item states, trimmed, without blanks, repeats, or tags
/// that are really a quality label ("1080p", "4K", "HDR").
List<String> heroGenres(MultimediaItem item) {
  final seen = <String>{};
  final out = <String>[];
  for (final raw in item.tags ?? const <String>[]) {
    final tag = raw.trim();
    if (tag.isEmpty) continue;
    if (statedQualityBadges(tag).isNotEmpty) continue;
    if (seen.add(tag.toLowerCase())) out.add(tag);
  }
  return out;
}

/// The meta line's parts, in order: type, up to [maxGenres] genres, runtime,
/// year. Only what the item has; empty when it has none of them.
List<String> heroMetaParts(MultimediaItem item, {int maxGenres = 1}) {
  final genres = heroGenres(item);
  final year = item.year;
  return <String>[
    ?heroTypeLabel(item.contentType),
    if (maxGenres > 0) ...genres.take(maxGenres),
    ?heroRuntimeLabel(item.duration),
    if (year != null && year > 1800 && year < 2200) '$year',
  ];
}

/// The meta line as text ("Movie • Science Fiction • 2h 15m • 2026"), or
/// null when there is nothing to say.
String? heroMetaLine(MultimediaItem item, {int maxGenres = 1}) {
  final parts = heroMetaParts(item, maxGenres: maxGenres);
  return parts.isEmpty ? null : parts.join(kHeroDot);
}

/// The outlined chip: the certification the item carries ("R", "TV-MA") and
/// the run its source described ("ENDED", "ONGOING", "UPCOMING"), joined by
/// a bar. Null when the item carries neither.
String? heroChipLabel(MultimediaItem item, {String? statusLabel}) {
  final cert = item.contentRating?.trim();
  // The item's own word first; [statusLabel] (looked up, e.g. RELEASED)
  // only when the item says nothing.
  final status = item.comingSoon
      ? 'UPCOMING'
      : switch (item.status) {
          ShowStatus.completed => 'ENDED',
          ShowStatus.ongoing => 'ONGOING',
          ShowStatus.upcoming => 'UPCOMING',
          ShowStatus.unknown => statusLabel,
        };
  final parts = <String>[
    if (cert != null && cert.isNotEmpty) cert.toUpperCase(),
    ?status,
  ];
  return parts.isEmpty ? null : parts.join(' | ');
}

/// The item's score out of 10 ("7.9"), or null when it has none.
String? heroScoreLabel(MultimediaItem item) => ratingLabel(item.score);

/// Whether the item's score is IMDb's. Only a Stremio add-on title's is:
/// add-ons publish it as `imdbRating`. A plugin's, TMDB's or AniList's
/// score is shown as a plain star rating instead.
bool heroScoreIsImdb(MultimediaItem item) => item.source == kAddonItemSource;

/// A language code for the badge row ("JA"), or null. Only a plain two- or
/// three-letter code is shown; anything else is ignored rather than guessed.
String? heroLanguageLabel(String? code) {
  final c = code?.trim() ?? '';
  return RegExp(r'^[A-Za-z]{2,3}$').hasMatch(c) ? c.toUpperCase() : null;
}

/// What the badge row holds. [isEmpty] rows are not drawn at all.
class HeroBadges {
  final String? chip;
  final String? score;
  final bool scoreIsImdb;
  final String? language;

  const HeroBadges({
    this.chip,
    this.score,
    this.scoreIsImdb = false,
    this.language,
  });

  bool get isEmpty => chip == null && score == null && language == null;

  /// How many of the three badges show.
  int get count =>
      (chip == null ? 0 : 1) +
      (score == null ? 0 : 1) +
      (language == null ? 0 : 1);

  /// The same row without the language - the first thing to go on a
  /// narrow screen.
  HeroBadges withoutLanguage() =>
      HeroBadges(chip: chip, score: score, scoreIsImdb: scoreIsImdb);
}

/// The badge row for [item]. [language] is the item's language code when
/// its source gave one.
///
/// [statusLabel] and [scoreIsImdb] come from the hero's TMDB lookup:
/// the status when the item has none of its own, and whether the score
/// now on the item was fetched from IMDb.
HeroBadges heroBadges(
  MultimediaItem item, {
  String? language,
  String? statusLabel,
  bool scoreIsImdb = false,
}) {
  final score = heroScoreLabel(item);
  return HeroBadges(
    chip: heroChipLabel(item, statusLabel: statusLabel),
    score: score,
    scoreIsImdb: score != null && (scoreIsImdb || heroScoreIsImdb(item)),
    language: heroLanguageLabel(language),
  );
}
