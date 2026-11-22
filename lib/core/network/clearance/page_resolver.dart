import 'dart:async';
import 'dart:convert';

import 'package:challenge_browser/challenge_browser.dart';

import '../../logger/app_logger.dart';
import 'clearance_solver.dart';
import 'resolve_diagnostic.dart';

/// Headers a page load doesn't take from the caller: the browser sends its
/// own agent and cookies.
const _ownedByTheBrowser = {'user-agent', 'cookie', 'host', 'content-length'};

/// The script result an extension returns when its page shows a check that
/// needs a person (Turnstile's checkbox, for one): the app shows the page
/// in the check sheet so the person can finish it, instead of the resolve
/// timing out unseen. It is never a token or a link, and the extension's
/// own callback ignores it. (Cinefreak's Turnstile: the hidden page cannot
/// tick the checkbox, so its script returns this once the widget is
/// waiting.)
const showSheetMarker = 'SHOW_SHEET';

/// The script result an extension returns when its page has failed by
/// itself (its player showed an error, or it left for another document):
/// the resolve ends at once instead of burning its whole timeout.
/// Only CineFreak's Turnstile script returns it.
const pageFailedMarker = 'PAGE_FAILED';

/// The script result an extension returns when its check's script loaded
/// but its widget never rendered in the hidden page (CineFreak v8):
/// Turnstile's widget can only render once the page is visible, so the
/// hidden page waiting for it is a deadlock — the app shows the page in
/// the check sheet, exactly as for [showSheetMarker]. The extension
/// gives a silent auto-solve a few seconds first (it needs no widget),
/// so this only fires when a person is actually needed.
const needsWidgetMarker = 'NEEDS_WIDGET';

/// What the resolver's own look at the page reports, for the diagnostic
/// the "No streams found" screen shows (b124): whether Turnstile's
/// script loaded, whether its widget rendered, whether the player
/// elements exist. Read-only booleans — never a token, a cookie, or a
/// signed media URL. The v7 script's SHOW_SHEET condition is
/// `tsBoxIframe`: an iframe inside #cfTsBox.
const _probeScript = '''
(() => {
  const box = document.getElementById('cfTsBox');
  const iframe = document.getElementById('cfPlayer');
  const vlc = document.getElementById('cfVlc');
  return JSON.stringify({
    page: location.pathname,
    ready: document.readyState,
    ts: typeof window.turnstile !== 'undefined',
    widget: !!document.querySelector('.cf-turnstile'),
    tsBox: !!box,
    tsBoxIframe: !!(box && box.querySelector('iframe')),
    csrf: !!document.querySelector('meta[name="csrf-token"]'),
    iframe: !!iframe,
    iframeSrc: !!(iframe && (iframe.getAttribute('src') || '').indexOf('http') === 0),
    vlc: !!vlc,
    vlcHref: !!(vlc && (vlc.getAttribute('href') || '').indexOf('http') === 0),
    cfMsg: !!document.getElementById('cfMsg')
  });
})()''';

/// Loads [url] in a hidden page and hands each request the page makes to
/// [onRequest], in order, until it answers true. The page comes from
/// [solver]'s page budget. It also ends when [timeout] passes (counted from
/// the call, waiting for room included) or the page's renderer ends.
///
/// With [script], the page runs it after each request, one run at a time,
/// and [onScript] gets the result. A request that arrives while a run is
/// in flight is re-run once the run ends, instead of being dropped, and
/// the script is also polled every 2 s while the resolve runs — a check
/// whose single request is missed is still seen.
///
/// When the script returns [showSheetMarker] — its page shows a check that
/// needs a person — the page is shown in the check sheet at once. The
/// marker is the extension's own determination that a person is needed,
/// so the hidden page gets no [ClearanceSolver.needsPersonAfter] wait
/// first: it cannot finish the check by itself (a Turnstile checkbox
/// only appears when a person must tick it), and waiting would only
/// leave the person staring at a spinner. While the sheet shows, the
/// resolve waits on the person (the timeout does not cut it off) and the
/// script is polled, so a tick is seen promptly; the sheet may show
/// "Verified" once a token or a link is observed, and the page is not
/// closed until the sheet is. When the script returns [pageFailedMarker]
/// — its page failed by itself — the resolve ends at once instead of
/// burning its whole timeout.
///
/// Never throws, and the page always closes. Whoever asked going away (an
/// [onRequest] that throws) ends it too. This is how CloudStream's
/// `WebViewResolver` runs on the JVM; its engine matches the requests.
Future<void> resolvePage(
  ClearanceSolver solver, {
  required Uri url,
  Map<String, String> headers = const {},
  String? script,
  required Duration timeout,
  required Future<bool> Function(CapturedRequest request) onRequest,
  Future<void> Function(String result)? onScript,
}) async {
  final startedAt = DateTime.now();
  final deadline = startedAt.add(timeout);

  // Where the resolve got to, for the diagnostic the "No streams found"
  // screen shows (b124): the last resolve wins, and it is written when
  // the page closes, whatever ended it.
  var stage = 'loading';
  Map<String, bool>? lastProbe;
  var probeFailed = false;
  var timedOut = false;
  void recordDiagnostic() {
    ResolveDiagnostic.last = ResolveDiagnostic(
      url: url.toString(),
      startedAt: startedAt,
      endedAt: DateTime.now(),
      stage: timedOut && (stage == 'loading' || stage == 'waiting')
          ? 'timed-out'
          : stage,
      probe: lastProbe,
      probeFailed: probeFailed,
    );
  }

  final CheckPage page;
  try {
    page = await solver.borrowPage();
  } catch (e) {
    talker.debug('[Clearance] no page to resolve $url: $e');
    stage = 'no-page';
    recordDiagnostic();
    return;
  }
  final done = Completer<void>();
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  // The page produced what the extension needed (a token or a link): a
  // sheet showing the page may show "Verified" and close on this.
  final cleared = Completer<void>();
  void markCleared() {
    if (!cleared.isCompleted) cleared.complete();
  }

  // The script's result, decoded: the engine hands it back as JSON text
  // (a string comes back quoted), and a plain string is left as it is.
  String? decodeScriptResult(String result) {
    try {
      final value = jsonDecode(result);
      return value is String ? value : null;
    } catch (_) {
      return result.isEmpty ? null : result;
    }
  }

  // Showing the page to a person, once per resolve.
  var sheetRequested = false;
  var sheetShown = false;
  var sheetOpen = false;
  Future<ChallengeSheetResult?>? sheetDone;

  // One script run at a time, shared by the events below and the poll.
  var scripting = false;

  // A run was asked for while one was in flight: the latest DOM state
  // is read once the run finishes, instead of the ask being lost (a
  // Turnstile iframe, for one, reports exactly once).
  var scriptDirty = false;

  Future<void> showSheet() async {
    if (sheetShown || done.isCompleted || cleared.isCompleted) return;
    sheetShown = true;
    sheetOpen = true;
    stage = 'sheet-shown';
    final site = solver.siteKeys.siteOf(url.host);
    final shown = solver.showSheet(
      page: page,
      site: site,
      cleared: cleared.future,
    );
    sheetDone = shown;
    final left = await shown;
    sheetOpen = false;
    if (left == null) {
      // No sheet could be shown (no presenter): the resolve runs on
      // hidden, and its own timeout ends it.
      return;
    }
    stage = 'sheet-closed';
    // The person closed the sheet (or said done): a final read, in case
    // the tick landed after the last poll, then the resolve ends.
    if (script != null && onScript != null && !done.isCompleted) {
      try {
        final result = await page.evaluate(script);
        if (!done.isCompleted) await onScript(result);
      } catch (_) {
        // Between documents, or the page has closed.
      }
    }
    finish();
  }

  void askForSheet() {
    if (sheetRequested || sheetShown || done.isCompleted) return;
    sheetRequested = true;
    // At once: the marker is the extension's own determination that a
    // person is needed, and the hidden page cannot finish the check by
    // itself. (CineFreak's Turnstile only renders its checkbox when a
    // person must tick it, so waiting the old needsPersonAfter first
    // left the person staring at "Getting links" for 20 s, then a
    // sheet on a page they had already given up on.)
    unawaited(showSheet());
  }

  void noteScriptResult(String result) {
    final decoded = decodeScriptResult(result);
    if (decoded == showSheetMarker || decoded == needsWidgetMarker) {
      askForSheet();
    } else if (decoded == pageFailedMarker) {
      // The page failed by itself: nothing more will come from it.
      stage = 'page-failed';
      finish();
    } else if (decoded != null && decoded.isNotEmpty) {
      stage = 'cleared';
      markCleared();
    }
  }

  // One look at the page for the diagnostic (b124): what Turnstile and
  // the player elements are doing. Independent of the extension's
  // script — it runs whether or not the extension gave one — and never
  // disturbs it: a failed probe is recorded, not thrown.
  Future<void> runProbe() async {
    if (done.isCompleted) return;
    try {
      final parsed = ResolveDiagnostic.parseProbe(
        await page.evaluate(_probeScript),
      );
      if (parsed != null) {
        lastProbe = parsed;
      } else {
        probeFailed = true;
      }
    } catch (_) {
      probeFailed = true;
    }
  }

  // The probe, every 5 s while the resolve runs: the last reading is
  // what the diagnostic shows.
  Future<void> pollProbe() async {
    while (!done.isCompleted) {
      await Future<void>.delayed(const Duration(seconds: 5));
      if (done.isCompleted) return;
      await runProbe();
    }
  }

  // One script run, and a re-run for any ask that arrived mid-run.
  Future<void> runScript() async {
    if (script == null || onScript == null || scripting) return;
    scripting = true;
    try {
      while (!done.isCompleted) {
        try {
          final result = await page.evaluate(script);
          if (!done.isCompleted) await onScript(result);
          noteScriptResult(result);
        } catch (_) {
          // Between documents, or the page has closed.
        }
        if (!scriptDirty || done.isCompleted) break;
        scriptDirty = false;
      }
    } finally {
      scripting = false;
    }
  }

  // An ask to run the script, now or once the run in flight ends.
  void requestScriptRun() {
    if (script == null || onScript == null) return;
    if (scripting) {
      scriptDirty = true;
      return;
    }
    unawaited(runScript());
  }

  // The script, polled while the resolve runs: every 2 s until the sheet
  // shows, every 1 s while it does — a tick is seen even when the page
  // makes no request after it, and a check the events below missed is
  // still seen.
  Future<void> pollScript() async {
    if (script == null || onScript == null) return;
    while (!done.isCompleted) {
      await Future<void>.delayed(
        Duration(seconds: sheetOpen ? 1 : 2),
      );
      if (done.isCompleted) return;
      requestScriptRun();
    }
  }

  // Each request is handed over once the one before has been answered.
  var reported = Future<void>.value();
  final events = page.events.listen((event) {
    if (event is RendererGone) {
      stage = 'renderer-gone';
      finish();
      return;
    }
    if (event is! CapturedRequest) return;
    reported = reported.then((_) async {
      if (done.isCompleted) return;
      try {
        if (await onRequest(event)) finish();
      } catch (_) {
        finish();
      }
    });
    requestScriptRun();
  });
  try {
    // The budget had no room until the deadline had passed.
    if (!DateTime.now().isBefore(deadline)) return;
    await page.setCapture(true);
    await page.load(
      url.toString(),
      headers: {
        for (final e in headers.entries)
          if (!_ownedByTheBrowser.contains(e.key.toLowerCase())) e.key: e.value,
      },
    );
    // From here on, the script is polled too (see above): a check whose
    // single request the events above missed is still seen. The
    // diagnostic probe runs too, from the first reading on.
    stage = 'waiting';
    await runProbe();
    unawaited(pollScript());
    unawaited(pollProbe());
    await done.future.timeout(
      deadline.difference(DateTime.now()),
      onTimeout: () {
        timedOut = true;
      },
    );
    // A sheet still showing: wait for the person to close it before the
    // page goes (the page is what they are looking at).
    if (sheetDone != null) await sheetDone;
  } catch (e) {
    talker.debug('[Clearance] resolving $url failed: $e');
  } finally {
    finish();
    recordDiagnostic();
    await events.cancel();
    await page.dispose();
  }
}
