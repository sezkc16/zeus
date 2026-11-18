// ignore_for_file: riverpod_lint/avoid_ref_inside_state_dispose
// The Android system-Back bug of 2026-11-19 (v2 APK): the film kept
// playing and the app stayed in landscape after a swipe back out of the
// mpv player. dispose() forced a last progress write through `ref.read`,
// which throws once the widget is being unmounted, so the engine stop and
// the portrait turn after it never ran.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _valueProvider = Provider<int>((ref) => 7);

class _Probe extends ConsumerStatefulWidget {
  const _Probe({required this.useContainer, required this.onResult});

  final bool useContainer;
  final void Function(Object? error, int? value, bool reachedEnd) onResult;

  @override
  ConsumerState<_Probe> createState() => _ProbeState();
}

class _ProbeState extends ConsumerState<_Probe> {
  late final ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    Object? error;
    int? value;
    try {
      value = widget.useContainer
          ? _container.read(_valueProvider)
          // The bug itself, kept here on purpose.
          : ref.read(_valueProvider);
    } catch (e) {
      error = e;
    }
    widget.onResult(error, value, true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  Future<(Object?, int?)> disposeWith(
    WidgetTester tester, {
    required bool useContainer,
  }) async {
    Object? error;
    int? value;
    await tester.pumpWidget(
      ProviderScope(
        child: _Probe(
          useContainer: useContainer,
          onResult: (e, v, _) {
            error = e;
            value = v;
          },
        ),
      ),
    );
    await tester.pumpWidget(const ProviderScope(child: SizedBox()));
    return (error, value);
  }

  testWidgets('ref.read inside dispose throws — the cause', (tester) async {
    final (error, value) = await disposeWith(tester, useContainer: false);
    expect(error, isStateError);
    expect(value, isNull);
  });

  testWidgets('the container read the player now uses works inside dispose', (
    tester,
  ) async {
    final (error, value) = await disposeWith(tester, useContainer: true);
    expect(error, isNull);
    expect(value, 7);
  });

  testWidgets('system Back on a canPop:false scope runs the exit routine '
      'once and does not pop by itself', (tester) async {
    var exits = 0;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('details')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (context) => PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            exits++;
            Navigator.of(context).pop();
          },
          child: const Scaffold(body: Text('player')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);

    // What Android's Back button and back swipe send.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(exits, 1);
    expect(find.text('player'), findsNothing);
    expect(find.text('details'), findsOneWidget);
  });
}
