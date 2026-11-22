import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/network/clearance/resolve_diagnostic.dart';
import 'package:zorox/features/player/presentation/widgets/resolve_diagnostic_text.dart';

void main() {
  setUp(() => ResolveDiagnostic.last = null);
  tearDown(() => ResolveDiagnostic.last = null);

  ResolveDiagnostic diagnostic({
    Map<String, bool>? probe,
    bool failed = false,
    Duration ago = Duration.zero,
  }) {
    final end = DateTime.now().subtract(ago);
    return ResolveDiagnostic(
      url: 'https://cinecloud.top/f/abc',
      startedAt: end.subtract(const Duration(seconds: 42)),
      endedAt: end,
      stage: 'timed-out',
      probe: probe,
      probeFailed: failed,
    );
  }

  Future<void> pumpText(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ResolveDiagnosticText())),
    );
    await tester.pump();
  }

  testWidgets('a fresh probe result renders on the no-streams screen', (
    tester,
  ) async {
    ResolveDiagnostic.last = diagnostic(
      probe: {
        'ts': false,
        'widget': false,
        'iframeSrc': false,
        'vlcHref': false,
      },
    );
    await pumpText(tester);
    expect(
      find.text(
        'timed-out | turnstile: no | widget: no | iframeSrc: no | vlcHref: no | 42s',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a probe that could not run renders as FAILED', (tester) async {
    ResolveDiagnostic.last = diagnostic(failed: true);
    await pumpText(tester);
    expect(find.textContaining('probe: FAILED'), findsOneWidget);
  });

  testWidgets('a stale reading renders nothing', (tester) async {
    ResolveDiagnostic.last = diagnostic(ago: const Duration(minutes: 2));
    await pumpText(tester);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('no resolve yet renders nothing', (tester) async {
    await pumpText(tester);
    expect(find.byType(Text), findsNothing);
  });
}
