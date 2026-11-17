import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/shared/widgets/branch_cross_fade.dart';
import 'package:zorox/shared/widgets/edge_swipe_back.dart';

/// Build 67 on the phone: swiping Settings back from the left edge showed
/// pure black under the sliding screen, and Home only appeared after the
/// finger was lifted. The tab Settings was opened from must be painted
/// underneath for the whole drag.
class _Shell extends StatefulWidget {
  const _Shell();

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int index = 0;
  final List<int> swipedBackTo = <int>[];

  @override
  Widget build(BuildContext context) => BranchCrossFade(
    currentIndex: index,
    slideIndex: 2,
    onSwipeBack: (i) {
      swipedBackTo.add(i);
      setState(() => index = i);
    },
    children: [
      const ColoredBox(
        key: ValueKey('home'),
        color: Colors.blue,
        child: Center(child: Text('home')),
      ),
      const ColoredBox(
        key: ValueKey('search'),
        color: Colors.green,
        child: Center(child: Text('search')),
      ),
      EdgeSwipeBack(
        enabled: true,
        onBack: () => fail('inside the shell the container goes back'),
        child: const ColoredBox(
          key: ValueKey('settings'),
          color: Colors.red,
          child: Center(child: Text('settings')),
        ),
      ),
    ],
  );
}

void main() {
  Future<_ShellState> open(WidgetTester tester, {int from = 0}) async {
    await tester.pumpWidget(const MaterialApp(home: _Shell()));
    final state = tester.state<_ShellState>(find.byType(_Shell));
    if (from != 0) {
      // ignore: invalid_use_of_protected_member
      state.setState(() => state.index = from);
      await tester.pumpAndSettle();
    }
    // ignore: invalid_use_of_protected_member
    state.setState(() => state.index = 2);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsNothing);
    expect(find.text('search'), findsNothing);
    return state;
  }

  double left(WidgetTester tester, String key) =>
      tester.getTopLeft(find.byKey(ValueKey(key))).dx;

  double opacity(WidgetTester tester, String key) => tester
      .widget<Opacity>(
        find.ancestor(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(Opacity),
        ),
      )
      .opacity;

  testWidgets('during the drag the tab Settings came from is on stage, '
      'opaque, and under the sliding Settings', (tester) async {
    await open(tester);
    final width = tester.getSize(find.byType(_Shell)).width;

    final gesture = await tester.startGesture(const Offset(5, 300));
    await gesture.moveBy(const Offset(30, 0)); // past the touch slop
    await gesture.moveBy(const Offset(200, 0));
    await tester.pump();

    // Home is in the tree, on stage (findable = not Offstage) and opaque.
    expect(find.text('home'), findsOneWidget);
    expect(opacity(tester, 'home'), 1.0);
    expect(opacity(tester, 'settings'), 1.0);
    expect(find.text('search'), findsNothing);

    // Settings has followed the finger; everything it uncovered is Home.
    final settingsLeft = left(tester, 'settings');
    expect(settingsLeft, greaterThan(150));
    expect(left(tester, 'home'), lessThanOrEqualTo(0));
    expect(
      left(tester, 'home') + width,
      greaterThanOrEqualTo(settingsLeft),
      reason: 'no gap between Home and Settings',
    );

    // Home is painted first (below), Settings above it.
    final order = tester
        .widgetList<ColoredBox>(find.byType(ColoredBox))
        .map((b) => b.key)
        .toList();
    expect(
      order.indexOf(const ValueKey('home')),
      lessThan(order.indexOf(const ValueKey('settings'))),
    );
    final hit = tester.hitTestOnBinding(Offset(settingsLeft / 2, 300));
    expect(
      hit.path.any(
        (e) =>
            e.target is RenderObject &&
            (e.target as RenderObject).debugCreator.toString().contains(
              'ColoredBox-[<\'home\'>]',
            ),
      ),
      isFalse,
      reason: 'the tab underneath takes no touches during the drag',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('let go past a third: Settings slides off and Home is simply '
      'there, with no second transition', (tester) async {
    final state = await open(tester);
    final width = tester.getSize(find.byType(_Shell)).width;

    final gesture = await tester.startGesture(const Offset(5, 300));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(Offset(width * 0.5, 0));
    await tester.pump();
    await gesture.up();

    // While it finishes leaving: Home stays opaque underneath, every frame.
    var frames = 0;
    while (tester.binding.hasScheduledFrame && frames < 200) {
      await tester.pump(const Duration(milliseconds: 16));
      frames++;
      expect(find.text('home'), findsOneWidget);
      expect(opacity(tester, 'home'), 1.0);
      if (find.text('settings').evaluate().isNotEmpty) {
        expect(opacity(tester, 'settings'), 1.0);
      }
    }

    expect(state.swipedBackTo, [0]);
    expect(find.text('settings'), findsNothing);
    expect(left(tester, 'home'), 0);
  });

  testWidgets('it returns to the tab Settings was opened from', (tester) async {
    final state = await open(tester, from: 1);

    final gesture = await tester.startGesture(const Offset(5, 300));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(find.text('search'), findsOneWidget);
    expect(find.text('home'), findsNothing);
    await gesture.moveBy(const Offset(400, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(state.swipedBackTo, [1]);
    expect(find.text('search'), findsOneWidget);
  });

  testWidgets('let go early: Settings slides back and the tab leaves the '
      'stage again', (tester) async {
    final state = await open(tester);

    final gesture = await tester.startGesture(const Offset(5, 300));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(find.text('home'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(state.swipedBackTo, isEmpty);
    expect(left(tester, 'settings'), 0);
    expect(find.text('home'), findsNothing);
  });

  testWidgets('a drag that starts away from the edge does nothing', (
    tester,
  ) async {
    await open(tester);
    await tester.dragFrom(const Offset(200, 300), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(left(tester, 'settings'), 0);
    expect(find.text('home'), findsNothing);
  });
}
