import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/utils/motion.dart';
import 'package:zorox/shared/widgets/branch_cross_fade.dart';

/// A tab with state of its own: a counter that must survive tab switches.
class _Tab extends StatefulWidget {
  const _Tab(this.name);
  final String name;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  int taps = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => setState(() => taps++),
    child: ColoredBox(
      color: Colors.black,
      child: Center(child: Text('${widget.name} $taps')),
    ),
  );
}

void main() {
  const tabs = [_Tab('home'), _Tab('search'), _Tab('settings')];

  Widget host(int index, {bool reduced = false}) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: BranchCrossFade(
        currentIndex: index,
        slideIndex: 2,
        children: tabs,
      ),
    ),
  );

  double opacityOf(WidgetTester tester, String text) => tester
      .widget<Opacity>(
        find.ancestor(of: find.textContaining(text), matching: find.byType(Opacity)),
      )
      .opacity;

  testWidgets('a tab switch cross-fades, keeps both on stage only for the '
      'transition, and keeps each tab\'s state', (tester) async {
    await tester.pumpWidget(host(0));
    await tester.tap(find.text('home 0'));
    await tester.pump();
    expect(find.text('home 1'), findsOneWidget);
    expect(find.textContaining('search'), findsNothing);

    await tester.pumpWidget(host(1));
    await tester.pump(kMotionTab ~/ 2);
    // Mid-way: both on stage; the upper one (search) is fading in.
    expect(find.text('home 1'), findsOneWidget);
    expect(find.text('search 0'), findsOneWidget);
    expect(opacityOf(tester, 'search'), inExclusiveRange(0.0, 1.0));
    expect(opacityOf(tester, 'home'), 1.0);

    await tester.pumpAndSettle();
    expect(find.textContaining('home'), findsNothing);
    expect(opacityOf(tester, 'search'), 1.0);

    // Back: the upper one (search) fades out over home; state survived.
    await tester.pumpWidget(host(0));
    await tester.pump(kMotionTab ~/ 2);
    expect(opacityOf(tester, 'search'), inExclusiveRange(0.0, 1.0));
    expect(opacityOf(tester, 'home'), 1.0);
    await tester.pumpAndSettle();
    expect(find.text('home 1'), findsOneWidget);
    expect(find.textContaining('search'), findsNothing);
  });

  testWidgets('Settings slides in from the right and back out', (tester) async {
    await tester.pumpWidget(host(0));
    await tester.pumpWidget(host(2));
    await tester.pump(kMotionPage ~/ 2);
    FractionalTranslation shift() => tester.widget<FractionalTranslation>(
      find
          .ancestor(
            of: find.textContaining('settings', skipOffstage: false),
            matching: find.byType(FractionalTranslation, skipOffstage: false),
          )
          .first,
    );
    expect(shift().translation.dx, inExclusiveRange(0.0, kMotionSettingsOffset));
    await tester.pumpAndSettle();
    expect(shift().translation.dx, 0);

    await tester.pumpWidget(host(0));
    await tester.pump(kMotionPage ~/ 2);
    expect(shift().translation.dx, inExclusiveRange(0.0, kMotionSettingsOffset));
    expect(find.text('home 0'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.textContaining('settings'), findsNothing);
  });

  testWidgets('reduced motion: the new tab just appears', (tester) async {
    await tester.pumpWidget(host(0, reduced: true));
    await tester.pumpWidget(host(1, reduced: true));
    await tester.pump();
    expect(find.textContaining('home'), findsNothing);
    expect(find.text('search 0'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
