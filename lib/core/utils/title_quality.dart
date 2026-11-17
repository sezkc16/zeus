/// Quality badges a title really states about itself.
///
/// The Home hero used to print "4K · Dolby Vision" on every slide, with no
/// data behind it. A badge is shown only when the title (as the plugin or
/// feed wrote it) or one of its tags says so: a resolution such as `2160p`,
/// `4K`, `1080p`, `720p`, and HDR / Dolby Vision only where those words are
/// there. Nothing stated, no badge.
library;

final RegExp _uhd = RegExp(r'(?<![a-z0-9])(2160p|4k|uhd)(?![a-z0-9])', caseSensitive: false);
final RegExp _height = RegExp(r'(?<![a-z0-9])(1440|1080|720|480)\s?p(?![a-z0-9])', caseSensitive: false);
final RegExp _dolbyVision = RegExp(r'(?<![a-z0-9])(dolby\s*vision|dovi)(?![a-z0-9])', caseSensitive: false);
final RegExp _hdr = RegExp(r'(?<![a-z0-9])hdr(10\+?)?(?![a-z0-9])', caseSensitive: false);

/// The badges [title] and [tags] state, best resolution first: at most one
/// resolution ("4K", "1440p", "1080p", "720p", "480p"), then "Dolby Vision"
/// and/or "HDR". Empty when nothing is stated.
List<String> statedQualityBadges(String? title, {Iterable<String>? tags}) {
  final text = [?title, ...?tags].join(' \u0001 ');
  if (text.trim().isEmpty) return const <String>[];
  final badges = <String>[];
  if (_uhd.hasMatch(text)) {
    badges.add('4K');
  } else {
    var best = 0;
    for (final match in _height.allMatches(text)) {
      final height = int.parse(match.group(1)!);
      if (height > best) best = height;
    }
    if (best > 0) badges.add('${best}p');
  }
  if (_dolbyVision.hasMatch(text)) badges.add('Dolby Vision');
  if (_hdr.hasMatch(text)) badges.add('HDR');
  return badges;
}

/// A catalogue score out of 10 as the hero prints it ("8.7"), or null when
/// there is none. It is the feed's or plugin's own rating, so it is shown as
/// a rating, not as a "match".
String? ratingLabel(double? score) {
  if (score == null || !score.isFinite || score <= 0) return null;
  final clamped = score > 10 ? 10.0 : score;
  return clamped.toStringAsFixed(1);
}
