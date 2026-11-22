import 'dart:convert';

/// What a WebView resolve's last look at its page found, for showing on
/// the "No streams found" screen so the user can screenshot it and send
/// it back: the resolve otherwise ends with no trace of where it stopped
/// (CineFreak's Turnstile resolve, b123: "Getting links" for the whole
/// timeout, then "No streams found", and no sheet ever opened — the v7
/// script never returned SHOW_SHEET, so nobody knew whether Turnstile
/// even rendered, or the page failed, or the script never ran).
///
/// Written by [resolvePage] when a resolve ends (and when it cannot even
/// borrow a page). The last resolve wins: resolves run one title at a
/// time on the phone, and the screen shows it only while it is fresh
/// (ended within a minute), so an older title's reading never explains
/// a newer failure. Never a token, a cookie, or a signed media URL:
/// only booleans about which elements exist, plus the stage and how
/// long the resolve ran.
class ResolveDiagnostic {
  const ResolveDiagnostic({
    required this.url,
    required this.startedAt,
    required this.endedAt,
    required this.stage,
    this.probe,
    this.probeFailed = false,
  });

  /// The last resolve's diagnostic, or null when no resolve has run.
  static ResolveDiagnostic? last;

  /// The page that was loaded, as given (a CineCloud `/f/<token>` URL,
  /// for one). Shown only in logs, never on screen.
  final String url;

  /// When the resolve started, and when it ended.
  final DateTime startedAt;
  final DateTime endedAt;

  /// How the resolve ended: `loading` (the page never loaded),
  /// `waiting` (loaded, the script ran, nothing came back),
  /// `sheet-shown` / `sheet-closed` (a person was asked / left),
  /// `page-failed` (the page failed by itself), `renderer-gone`,
  /// `cleared` (a URL was found), `timed-out` (the whole timeout
  /// burned with nothing), `no-page` (no page to borrow).
  final String stage;

  /// The last DOM probe's booleans, when one ran: `ts`
  /// (`window.turnstile` exists), `widget` (a `.cf-turnstile` element),
  /// `tsBox` (`#cfTsBox` exists), `tsBoxIframe` (an iframe inside it —
  /// the v7 script's SHOW_SHEET condition), `csrf`, `iframe`
  /// (`#cfPlayer` exists), `iframeSrc` (it has an http src), `vlc`
  /// (`#cfVlc` exists), `vlcHref` (it has an http href), `cfMsg`
  /// (`#cfMsg` exists). Null when no probe ran.
  final Map<String, bool>? probe;

  /// The probe itself could not run (JS evaluation failed).
  final bool probeFailed;

  /// How long the resolve ran.
  Duration get elapsed => endedAt.difference(startedAt);

  /// Whether this reading is fresh enough to explain a failure showing
  /// now: ended within [within] of [now].
  bool freshAt(DateTime now, {Duration within = const Duration(seconds: 60)}) =>
      now.difference(endedAt) < within;

  /// One line for the "No streams found" screen, e.g.
  /// `timed-out | turnstile: yes | widget: no | iframeSrc: no |
  /// vlcHref: no | 42s`, or `probe: FAILED | waiting | 42s` when the
  /// probe itself could not run. Short values only: it is read off a
  /// screenshot. The fields are the ones that decide anything:
  /// `iframeSrc` / `vlcHref` say whether play() actually set a link
  /// (the bare `iframe` / `vlc` existence flags do not — #cfVlc is in
  /// the iOS page template from load, with href="#" until play() runs,
  /// so `vlc: yes` on its own meant nothing, b124).
  String get summary {
    final seconds = elapsed.inSeconds;
    if (probeFailed) return 'probe: FAILED | $stage | ${seconds}s';
    final p = probe;
    if (p == null) return 'probe: none | $stage | ${seconds}s';
    String yes(String key) => p[key] == true ? 'yes' : 'no';
    return '$stage | turnstile: ${yes('ts')} | widget: ${yes('widget')} '
        '| iframeSrc: ${yes('iframeSrc')} | vlcHref: ${yes('vlcHref')} | ${seconds}s';
  }

  /// Parses a probe evaluation's result into its booleans, or null when
  /// it is not a probe answer. The probe returns `JSON.stringify(...)`,
  /// so evaluation hands back JSON text of a string; a plain object is
  /// accepted too.
  static Map<String, bool>? parseProbe(String result) {
    try {
      var value = jsonDecode(result);
      if (value is String) value = jsonDecode(value);
      if (value is! Map) return null;
      return {
        for (final e in value.entries)
          if (e.value is bool) e.key.toString(): e.value as bool,
      };
    } catch (_) {
      return null;
    }
  }
}
