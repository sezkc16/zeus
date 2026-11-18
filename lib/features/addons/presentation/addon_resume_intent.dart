/// Build 74: "resume this Stremio title" handed from Continue Watching
/// to the add-on page it opens.
///
/// A plugin title's Continue Watching card opens its page with
/// `autoPlay` and the film continues; a Stremio title's card only
/// opened the page, and the viewer had to press Play and pick a source
/// again. The card now leaves this note, and the page — once the
/// title's details have loaded — opens the sources for the film (or
/// the episode to continue with) in resume mode.
///
/// One note at a time, good for a short while and for one page: a
/// page that never loads must not make a later visit start playing.
library;

class AddonResumeIntent {
  AddonResumeIntent._();

  static const Duration validFor = Duration(seconds: 45);

  static String? _id;
  static DateTime? _at;

  /// Continue Watching was tapped for the title [id].
  static void request(String id, {DateTime? now}) {
    _id = id;
    _at = now ?? DateTime.now();
  }

  /// Whether a resume was asked for [id] just now. True once.
  static bool consume(String id, {DateTime? now}) {
    final wanted = _id;
    final at = _at;
    if (wanted == null || at == null || wanted != id) return false;
    _id = null;
    _at = null;
    return (now ?? DateTime.now()).difference(at) <= validFor;
  }

  static void clear() {
    _id = null;
    _at = null;
  }
}

/// Whether a saved position is worth calling "Resume" (the same line
/// the add-on Play button draws at).
bool addonHasResume(int positionMs) => positionMs > 5000;

/// Build 75: the Sources card's label for a title with a saved
/// position — the word for "Resume" ([resume]), the episode for a
/// show, and where it continues: `Resume S1 E3 · 12:34`,
/// `Resume · 1:02:03`.
String addonResumeLabel({
  required String resume,
  required int positionMs,
  int? season,
  int? episode,
}) {
  final buffer = StringBuffer(resume);
  if (season != null && episode != null) {
    buffer.write(' S$season E$episode');
  }
  final total = positionMs ~/ 1000;
  if (total > 0) {
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    buffer.write(h > 0 ? ' · $h:${two(m)}:${two(s)}' : ' · $m:${two(s)}');
  }
  return buffer.toString();
}
