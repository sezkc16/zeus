import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/shared/widgets/edge_swipe_back.dart';

void main() {
  Future<int Function()> pump(WidgetTester tester, {bool enabled = true}) async {
    var backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: EdgeSwipeBack(
          enabled: enabled,
          onBack: () => backs++,
          child: const Scaffold(body: Center(child: Text('settings'))),
        ),
      ),
    );
    return () => backs;
  }

  testWidgets('follows the finger, and a short drag slides back', (
    tester,
  ) async {
    final backs = await pump(tester);
    final rest = tester.getCenter(find.text('settings')).dx;
    final gesture = await tester.startGesture(const Offset(5, 300));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(70, 0));
    await tester.pump();
    expect(tester.getCenter(find.text('settings')).dx, greaterThan(rest + 50));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(backs(), 0);
    expect(tester.getCenter(find.text('settings')).dx, rest);
  });

  testWidgets('a drag past a third of the width goes back', (tester) async {
    final backs = await pump(tester);
    final gesture = await tester.startGesture(const Offset(5, 300));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(400, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(backs(), 1);
  });

  testWidgets('a drag that starts away from the edge does nothing', (
    tester,
  ) async {
    final backs = await pump(tester);
    await tester.dragFrom(const Offset(200, 300), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(backs(), 0);
  });

  testWidgets('off (Android): no strip at all', (tester) async {
    await pump(tester, enabled: false);
    expect(find.byKey(const ValueKey('edge-swipe-back-strip')), findsNothing);
  });
}
