import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/network/clearance/resolve_diagnostic.dart';

void main() {
  ResolveDiagnostic diagnostic({Map<String, bool>? probe, bool failed = false, String stage = 'timed-out', Duration ago = const Duration(seconds: 42)}) {
    final end = DateTime.now().subtract(ago);
    return ResolveDiagnostic(
      url: 'https://cinecloud.top/f/abc',
      startedAt: end.subtract(const Duration(seconds: 42)),
      endedAt: end,
      stage: stage,
      probe: probe,
      probeFailed: failed,
    );
  }

  group('parseProbe', () {
    test('a double-encoded probe answer parses', () {
      expect(
        ResolveDiagnostic.parseProbe(
          '"{\\"ts\\":true,\\"widget\\":false,\\"vlc\\":true}"',
        ),
        {'ts': true, 'widget': false, 'vlc': true},
      );
    });

    test('a plain object parses', () {
      expect(
        ResolveDiagnostic.parseProbe('{"ts":true,"widget":false}'),
        {'ts': true, 'widget': false},
      );
    });

    test('garbage is not a probe answer', () {
      expect(ResolveDiagnostic.parseProbe('not json'), isNull);
      expect(ResolveDiagnostic.parseProbe('"Player"'), isNull);
      expect(ResolveDiagnostic.parseProbe('null'), isNull);
    });

    test('non-boolean values are left out', () {
      expect(
        ResolveDiagnostic.parseProbe('{"ts":true,"page":"/f/abc"}'),
        {'ts': true},
      );
    });
  });

  group('summary', () {
    test('one line with the stage, the booleans and the seconds', () {
      final d = diagnostic(
        probe: {
          'ts': true,
          'widget': false,
          'iframeSrc': false,
          'vlcHref': true,
        },
      );
      expect(
        d.summary,
        'timed-out | turnstile: yes | widget: no | iframeSrc: no | vlcHref: yes | 42s',
      );
    });

    test('a probe that could not run says FAILED', () {
      expect(
        diagnostic(failed: true).summary,
        'probe: FAILED | timed-out | 42s',
      );
    });

    test('no probe at all says none', () {
      expect(
        diagnostic().summary,
        'probe: none | timed-out | 42s',
      );
    });
  });

  group('freshAt', () {
    test('ended within a minute is fresh, older is not', () {
      final now = DateTime.now();
      expect(diagnostic(ago: const Duration(seconds: 30)).freshAt(now), isTrue);
      expect(
        diagnostic(ago: const Duration(seconds: 61)).freshAt(now),
        isFalse,
      );
    });
  });
}
