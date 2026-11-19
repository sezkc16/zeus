import 'dart:async';
import 'dart:convert';

import 'package:challenge_browser/challenge_browser.dart';

import '../../logger/app_logger.dart';
import 'clearance_solver.dart';

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

/// Loads [url] in a hidden page and hands each request the page makes to
/// [onRequest], in order, until it answers true. The page comes from
/// [solver]'s page budget. It also ends when [timeout] passes (counted from
/// the call, waiting for room included) or the page's renderer ends.
///
/// With [script], the page runs it after each request, one run at a time,
/// and [onScript] gets the result.
///
/// When the script returns [showSheetMarker] — its page shows a check that
/// needs a person — the page is shown in the check sheet once the hidden
/// page has had [ClearanceSolver.needsPersonAfter] to solve it by itself.
/// While the sheet shows, the resolve waits on the person (the timeout
/// does not cut it off) and the script is polled, so a tick is seen
/// promptly; the sheet may show "Verified" once a token or a link is
/// observed, and the page is not closed until the sheet is.
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
  final CheckPage page;
  try {
    page = await solver.borrowPage();
  } catch (e) {
    talker.debug('[Clearance] no page to resolve $url: $e');
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

  // A script result that is a token or a link (not the marker): the check
  // is cleared.
  void noteCleared(String result) {
    final decoded = decodeScriptResult(result);
    if (decoded != null && decoded.isNotEmpty && decoded != showSheetMarker) {
      markCleared();
    }
  }

  // Showing the page to a person, once per resolve.
  var sheetRequested = false;
  var sheetShown = false;
  var sheetOpen = false;
  Future<ChallengeSheetResult?>? sheetDone;
  Timer? sheetTimer;

  // One script run at a time, shared by the re-runs below and the poll.
  var scripting = false;

  // The script, polled while the sheet shows: a tick is seen even when
  // the page makes no request after it.
  Future<void> pollScript() async {
    if (script == null || onScript == null) return;
    while (sheetOpen && !done.isCompleted) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!sheetOpen || done.isCompleted || scripting) continue;
      scripting = true;
      try {
        final result = await page.evaluate(script);
        if (done.isCompleted) return;
        await onScript(result);
        noteCleared(result);
      } catch (_) {
        // Between documents, or the page has closed.
      } finally {
        scripting = false;
      }
    }
  }

  Future<void> showSheet() async {
    if (sheetShown || done.isCompleted || cleared.isCompleted) return;
    sheetShown = true;
    sheetOpen = true;
    final site = solver.siteKeys.siteOf(url.host);
    final shown = solver.showSheet(
      page: page,
      site: site,
      cleared: cleared.future,
    );
    sheetDone = shown;
    unawaited(pollScript());
    final left = await shown;
    sheetOpen = false;
    if (left == null) {
      // No sheet could be shown (no presenter): the resolve runs on
      // hidden, and its own timeout ends it.
      return;
    }
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
    // The hidden page gets its chance first (needsPersonAfter); only
    // then is the page shown to the person.
    final wait = solver.needsPersonAfter - DateTime.now().difference(startedAt);
    if (wait <= Duration.zero) {
      unawaited(showSheet());
    } else {
      sheetTimer = Timer(wait, () {
        sheetTimer = null;
        if (sheetRequested &&
            !sheetShown &&
            !done.isCompleted &&
            !cleared.isCompleted) {
          unawaited(showSheet());
        }
      });
    }
  }

  void noteScriptResult(String result) {
    final decoded = decodeScriptResult(result);
    if (decoded == showSheetMarker) {
      askForSheet();
    } else if (decoded != null && decoded.isNotEmpty) {
      markCleared();
    }
  }

  // Each request is handed over once the one before has been answered.
  var reported = Future<void>.value();
  final events = page.events.listen((event) {
    if (event is RendererGone) {
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
    if (script == null || onScript == null || scripting) return;
    scripting = true;
    unawaited(() async {
      try {
        final result = await page.evaluate(script);
        if (!done.isCompleted) await onScript(result);
        noteScriptResult(result);
      } catch (_) {
        // Between documents, or the page has closed.
      } finally {
        scripting = false;
      }
    }());
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
    await done.future.timeout(
      deadline.difference(DateTime.now()),
      onTimeout: () {},
    );
    // A sheet still showing: wait for the person to close it before the
    // page goes (the page is what they are looking at).
    if (sheetDone != null) await sheetDone;
  } catch (e) {
    talker.debug('[Clearance] resolving $url failed: $e');
  } finally {
    finish();
    sheetTimer?.cancel();
    await events.cancel();
    await page.dispose();
  }
}
