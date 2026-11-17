// v9: the player's bottom option buttons sit flush right, under the seek
// bar's right edge — with or without a sleep timer armed. Before, an armed
// timer's badge shared the free width with the spacer and pulled the
// buttons toward the centre.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/domain/sleep_timer.dart';
import 'package:zorox/features/player/presentation/mpv/golden_player_controls.dart';
import 'package:zorox/features/player/presentation/mpv/golden_sleep_timer.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

void main() {
  const rowKey = ValueKey('row');
  const leftKey = ValueKey('left');
  const rightKey = ValueKey('right');

  Future<void> pumpRow(WidgetTester tester, {SleepTimer? timer}) async {
    tester.view.physicalSize = const Size(844, 390); // landscape phone
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              key: rowKey,
              children: <Widget>[
                const SizedBox(key: leftKey, width: 40, height: 40),
                GoldenBottomRowGap(sleepTimer: timer),
                const SizedBox(key: rightKey, width: 280, height: 40),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('no timer: the option buttons end at the row\'s right edge', (
    tester,
  ) async {
    await pumpRow(tester);
    expect(
      tester.getTopRight(find.byKey(rightKey)).dx,
      tester.getTopRight(find.byKey(rowKey)).dx,
    );
    expect(
      tester.getTopLeft(find.byKey(leftKey)).dx,
      tester.getTopLeft(find.byKey(rowKey)).dx,
    );
  });

  testWidgets('timer armed: still flush right, the badge rides on the left', (
    tester,
  ) async {
    final timer = SleepTimer()..start(const Duration(minutes: 30));
    addTearDown(timer.dispose);
    await pumpRow(tester, timer: timer);
    final rowRight = tester.getTopRight(find.byKey(rowKey)).dx;
    expect(tester.getTopRight(find.byKey(rightKey)).dx, rowRight);
    // The buttons keep their width: nothing was squeezed.
    expect(tester.getSize(find.byKey(rightKey)).width, 280);
    // The badge is drawn, and sits against the left group, not centred.
    final badge = find.byType(GoldenSleepTimerBadge);
    expect(badge, findsOneWidget);
    expect(
      tester.getTopLeft(badge).dx,
      tester.getTopRight(find.byKey(leftKey)).dx,
    );
    timer.cancel();
  });

  testWidgets('the gap owns all the free width', (tester) async {
    await pumpRow(tester);
    final row = tester.getSize(find.byKey(rowKey)).width;
    expect(tester.getSize(find.byType(GoldenBottomRowGap)).width, row - 40 - 280);
  });
}
