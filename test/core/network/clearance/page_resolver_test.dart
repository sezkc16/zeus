import 'dart:async';
import 'dart:io';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/network/clearance/clearance_solver.dart';
import 'package:zorox/core/network/clearance/clearance_store.dart';
import 'package:zorox/core/network/clearance/page_resolver.dart';
import 'package:zorox/core/network/clearance/resolve_diagnostic.dart';
import 'package:zorox/core/network/clearance/site_keys.dart';

import 'fakes.dart';

final _keys = SiteKeys.parse(
  File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
);

ClearanceSolver _solver(
  PageFactory pages, {
  int parallel = 3,
  Duration needsPersonAfter = const Duration(seconds: 20),
}) =>
    ClearanceSolver(
      store: ClearanceStore(),
      siteKeys: _keys,
      openPage: pages.call,
      parallel: parallel,
      needsPersonAfter: needsPersonAfter,
      callLimit: const Duration(milliseconds: 200),
    );

CapturedRequest _request(String url) =>
    CapturedRequest(Uri.parse(url), method: 'GET');

/// The probe script's answer, as a page would give it: Turnstile's
/// script loaded, no widget yet, the player elements as a CineCloud
/// watch page shows them before play() succeeds.
Future<String> _probeAnswer(String script) => Future.value(
  '{"ts":true,"widget":false,"tsBox":true,"tsBoxIframe":false,'
  '"csrf":true,"iframe":false,"iframeSrc":false,"vlc":true,'
  '"vlcHref":false,"cfMsg":false}',
);

/// Only the extension script's runs: the diagnostic probe evaluates
/// too, and it is not one of them.
List<String> _extensionRuns(FakePage page) =>
    page.evaluated.where((s) => s == 'document.title').toList();

void main() {
  setUp(() => ResolveDiagnostic.last = null);

  test('loads the page with its headers, and hands its requests over in order until one is the answer', () async {
    final page = FakePage(const [Step('Player')]);
    final pages = PageFactory([page]);
    final seen = <String>[];
    final resolving = resolvePage(
      _solver(pages),
      url: Uri.parse('https://host.example/embed/1'),
      headers: const {
        'Referer': 'https://site.example/',
        'User-Agent': 'Engine/9',
        'Cookie': 'a=1',
      },
      timeout: const Duration(seconds: 5),
      onRequest: (request) async {
        seen.add(request.url.path);
        return request.url.path.endsWith('.m3u8');
      },
    );
    await pumpEventQueue();
    expect(page.capturing, isTrue);
    expect(page.loaded, 'https://host.example/embed/1');
    // The browser sends its own agent and cookies.
    expect(page.loadedHeaders, {'Referer': 'https://site.example/'});
    page.emit(_request('https://host.example/player.js'));
    page.emit(_request('https://cdn.example/master.m3u8'));
    page.emit(_request('https://cdn.example/seg-1.ts'));
    await resolving;
    expect(seen, ['/player.js', '/master.m3u8']);
    expect(page.disposed, isTrue);
    expect(pages.open, 0);
  });

  test(
    'a page that never makes the request it waits for closes at the deadline',
    () async {
      final page = FakePage(const [Step('Player')]);
      final pages = PageFactory([page]);
      final watch = Stopwatch()..start();
      await resolvePage(
        _solver(pages),
        url: Uri.parse('https://host.example/'),
        timeout: const Duration(milliseconds: 150),
        onRequest: (_) async => false,
      );
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(140));
      expect(page.disposed, isTrue);
      expect(pages.open, 0);
    },
  );

  test('the script runs after a request, one run at a time, and its results are handed over', () async {
    final run = Completer<String>();
    var runs = 0;
    final page = FakePage(const [
      Step('Player'),
    ], onEvaluate: (script) {
      // The diagnostic probe answers for itself and is not a run.
      if (script.contains('cfTsBox')) return _probeAnswer(script);
      runs++;
      return runs == 1 ? run.future : Future.value('"Second"');
    });
    final results = <String>[];
    final resolving = resolvePage(
      _solver(PageFactory([page])),
      url: Uri.parse('https://host.example/'),
      script: 'document.title',
      timeout: const Duration(seconds: 5),
      onRequest: (request) async => request.url.path == '/done',
      onScript: (result) async => results.add(result),
    );
    await pumpEventQueue();
    page.emit(_request('https://host.example/a.js'));
    page.emit(_request('https://host.example/b.js'));
    await pumpEventQueue();
    expect(_extensionRuns(page), ['document.title']);
    // The probe ran once after the load, beside the script.
    expect(page.evaluated.any((s) => s.contains('cfTsBox')), isTrue);
    run.complete('"Player"');
    await pumpEventQueue();
    // The second request was not lost: it re-ran once the first run
    // finished, and its result was handed over too.
    expect(results, ['"Player"', '"Second"']);
    expect(_extensionRuns(page), hasLength(2));
    page.emit(_request('https://host.example/done'));
    await resolving;
    expect(_extensionRuns(page), hasLength(3));
  });

  test('a request dropped while a run is in flight is re-run, and SHOW_SHEET on the re-run opens the sheet at once', () async {
    // The first run is slow; the second request arrives while it is in
    // flight. The script answers '' first, then SHOW_SHEET — as a
    // Turnstile widget's iframe arriving mid-run would. The sheet opens
    // at once on the marker: the default needsPersonAfter (20 s) is
    // NOT waited first, so this 5 s resolve still sees the sheet.
    // (With the old wait, the resolve would end before the sheet
    // ever showed, and `shown` below would be 0.)
    final firstRun = Completer<String>();
    var runs = 0;
    final page = FakePage(const [
      Step('Player'),
    ], onEvaluate: (script) {
      // The diagnostic probe answers for itself and is not a run.
      if (script.contains('cfTsBox')) return _probeAnswer(script);
      runs++;
      return runs == 1 ? firstRun.future : Future.value('"SHOW_SHEET"');
    });
    var shown = 0;
    final solver = _solver(
      PageFactory([page]),
    )..presenter = ({required page, required site, required cleared}) async {
      shown++;
      return ChallengeSheetResult.closed;
    };
    final resolving = resolvePage(
      solver,
      url: Uri.parse('https://host.example/'),
      script: 'document.title',
      timeout: const Duration(seconds: 5),
      onRequest: (_) async => false,
      onScript: (_) async {},
    );
    await pumpEventQueue();
    page.emit(_request('https://host.example/a.js'));
    page.emit(_request('https://host.example/b.js'));
    await pumpEventQueue();
    // Only the first run started; the second request was queued, not lost.
    expect(_extensionRuns(page), ['document.title']);
    firstRun.complete('""');
    await pumpEventQueue();
    // The re-run read the marker, and the sheet was requested.
    expect(shown, 1);
    await resolving;
    expect(page.disposed, isTrue);
  });

  test('PAGE_FAILED ends the resolve at once, without burning the timeout', () async {
    // The page failed by itself (its player showed an error): the
    // script says so on the first poll, and the resolve ends then —
    // it does not sit on "Getting links" until the 5 s timeout.
    final page = FakePage(const [
      Step('Player'),
    ], onEvaluate: (script) {
      if (script.contains('cfTsBox')) return _probeAnswer(script);
      return Future.value('"PAGE_FAILED"');
    });
    final stopwatch = Stopwatch()..start();
    final resolving = resolvePage(
      _solver(PageFactory([page])),
      url: Uri.parse('https://host.example/'),
      script: 'document.title',
      timeout: const Duration(seconds: 5),
      onRequest: (_) async => false,
      onScript: (_) async {},
    );
    await resolving;
    stopwatch.stop();
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 4)));
    expect(page.disposed, isTrue);
    // And the diagnostic says the page failed, with the probe's reading.
    final diagnostic = ResolveDiagnostic.last;
    expect(diagnostic, isNotNull);
    expect(diagnostic!.stage, 'page-failed');
    expect(diagnostic.probe?['ts'], isTrue);
    expect(diagnostic.probe?['vlc'], isTrue);
  });

  test('NEEDS_WIDGET opens the sheet at once, like SHOW_SHEET', () async {
    // Turnstile's script loaded but its widget never rendered in the
    // hidden page (CineFreak v8): the script says so on the first poll,
    // and the sheet opens at once — the hidden page cannot render the
    // widget, so waiting the default needsPersonAfter (20 s) first
    // would only leave the person staring at "Getting links" for the
    // whole timeout, as b123/b124 proved on the phone.
    final page = FakePage(const [
      Step('Player'),
    ], onEvaluate: (script) {
      if (script.contains('cfTsBox')) return _probeAnswer(script);
      return Future.value('"NEEDS_WIDGET"');
    });
    var shown = 0;
    final solver = _solver(
      PageFactory([page]),
    )..presenter = ({required page, required site, required cleared}) async {
      shown++;
      return ChallengeSheetResult.closed;
    };
    final resolving = resolvePage(
      solver,
      url: Uri.parse('https://host.example/'),
      script: 'document.title',
      timeout: const Duration(seconds: 5),
      onRequest: (_) async => false,
      onScript: (_) async {},
    );
    await resolving;
    expect(shown, 1);
    expect(page.disposed, isTrue);
  });

  test('the probe runs during a resolve and its diagnostic records the page', () async {
    // No extension script at all: the probe still runs, and a resolve
    // that burns its whole timeout says so, with the page's reading.
    final page = FakePage(const [
      Step('Player'),
    ], onEvaluate: (script) {
      if (script.contains('cfTsBox')) return _probeAnswer(script);
      return Future.value('""');
    });
    await resolvePage(
      _solver(PageFactory([page])),
      url: Uri.parse('https://host.example/f/abc'),
      timeout: const Duration(milliseconds: 150),
      onRequest: (_) async => false,
    );
    final diagnostic = ResolveDiagnostic.last;
    expect(diagnostic, isNotNull);
    expect(diagnostic!.stage, 'timed-out');
    expect(diagnostic.probe?['ts'], isTrue);
    expect(diagnostic.probe?['widget'], isFalse);
    expect(diagnostic.probe?['tsBoxIframe'], isFalse);
    expect(diagnostic.probe?['vlc'], isTrue);
    expect(diagnostic.probe?['vlcHref'], isFalse);
    expect(diagnostic.probeFailed, isFalse);
    expect(diagnostic.summary, contains('timed-out'));
    expect(diagnostic.summary, contains('turnstile: yes'));
    expect(diagnostic.summary, contains('widget: no'));
  });

  test('a probe that cannot run records a failure', () async {
    final page = FakePage(const [
      Step('Player'),
    ], onEvaluate: (script) {
      if (script.contains('cfTsBox')) {
        throw StateError('the engine stopped');
      }
      return Future.value('""');
    });
    await resolvePage(
      _solver(PageFactory([page])),
      url: Uri.parse('https://host.example/f/abc'),
      timeout: const Duration(milliseconds: 150),
      onRequest: (_) async => false,
    );
    final diagnostic = ResolveDiagnostic.last;
    expect(diagnostic, isNotNull);
    expect(diagnostic!.probeFailed, isTrue);
    expect(diagnostic.summary, contains('probe: FAILED'));
  });

  test('a renderer that ends ends it', () async {
    final page = FakePage(const [Step('Player')]);
    final resolving = resolvePage(
      _solver(PageFactory([page])),
      url: Uri.parse('https://host.example/'),
      timeout: const Duration(seconds: 5),
      onRequest: (_) async => false,
    );
    await pumpEventQueue();
    page.emit(const RendererGone(crashed: true));
    await resolving;
    expect(page.disposed, isTrue);
  });

  test('whoever asked going away ends it', () async {
    final page = FakePage(const [Step('Player')]);
    final resolving = resolvePage(
      _solver(PageFactory([page])),
      url: Uri.parse('https://host.example/'),
      timeout: const Duration(seconds: 5),
      onRequest: (_) async => throw StateError('the engine stopped'),
    );
    await pumpEventQueue();
    page.emit(_request('https://host.example/a.js'));
    await resolving;
    expect(page.disposed, isTrue);
  });

  test('it waits for room in the page budget, and past its deadline gives the page straight back', () async {
    final pages = PageFactory([
      FakePage(const [Step('A')]),
      FakePage(const [Step('B')]),
    ]);
    final solver = _solver(pages, parallel: 1);
    final held = await solver.borrowPage();
    final resolving = resolvePage(
      solver,
      url: Uri.parse('https://host.example/'),
      timeout: const Duration(milliseconds: 100),
      onRequest: (_) async => false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await held.dispose();
    await resolving;
    expect(pages.opened, 2);
    expect(pages.pages[1].loaded, isNull);
    expect(pages.open, 0);
    expect(solver.openPages, 0);
  });
}
