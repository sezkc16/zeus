import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/domain/sleep_timer.dart';
import 'package:zorox/features/player/presentation/mpv/golden_sleep_timer.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// A clock and a ticker the test cranks by hand: no real minutes pass.
class _FakeTime {
  DateTime now = DateTime(2026, 11, 17, 22);
  final List<_FakeTicker> tickers = <_FakeTicker>[];

  Timer ticker(Duration period, void Function() onTick) {
    final t = _FakeTicker(onTick);
    tickers.add(t);
    return t;
  }

  /// Moves the clock on and fires every live ticker once.
  void advance(Duration by) {
    now = now.add(by);
    for (final t in List<_FakeTicker>.of(tickers)) {
      if (t.isActive) t.onTick();
    }
  }

  int get liveTickers => tickers.where((t) => t.isActive).length;
}

class _FakeTicker implements Timer {
  _FakeTicker(this.onTick);

  final void Function() onTick;
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

void main() {
  late _FakeTime time;
  late SleepTimer timer;
  late int fired;

  setUp(() {
    time = _FakeTime();
    fired = 0;
    timer = SleepTimer(now: () => time.now, ticker: time.ticker)
      ..onFire = () => fired++;
  });

  tearDown(() => timer.dispose());

  group('SleepTimer, timed', () {
    test('starts off, blocking nothing', () {
      expect(timer.mode, SleepTimerMode.off);
      expect(timer.isActive, isFalse);
      expect(timer.remaining, isNull);
      expect(timer.selectedDuration, isNull);
      expect(timer.blocksNextEpisode, isFalse);
      expect(timer.consumeEpisodeEnd(), isFalse);
    });

    test('fires once after its duration, not before', () {
      timer.start(const Duration(minutes: 15));
      expect(timer.mode, SleepTimerMode.timed);
      expect(timer.selectedDuration, const Duration(minutes: 15));

      time.advance(const Duration(minutes: 14, seconds: 59));
      expect(fired, 0);
      expect(timer.isActive, isTrue);

      time.advance(const Duration(seconds: 1));
      expect(fired, 1);
      expect(timer.mode, SleepTimerMode.off);
      expect(timer.remaining, isNull);
      expect(time.liveTickers, 0, reason: 'the tick is stopped once fired');

      time.advance(const Duration(hours: 1));
      expect(fired, 1, reason: 'one-shot');
    });

    test('reports the remaining time from the clock', () {
      timer.start(const Duration(minutes: 30));
      expect(timer.remaining, const Duration(minutes: 30));
      time.advance(const Duration(minutes: 10, seconds: 30));
      expect(timer.remaining, const Duration(minutes: 19, seconds: 30));
    });

    test('notifies listeners on every tick, so labels repaint', () {
      var notifications = 0;
      timer.addListener(() => notifications++);
      timer.start(const Duration(minutes: 15));
      final afterStart = notifications;
      time.advance(const Duration(seconds: 1));
      time.advance(const Duration(seconds: 1));
      expect(notifications, afterStart + 2);
    });

    test('a late tick (app was suspended) fires at once', () {
      timer.start(const Duration(minutes: 15));
      // No tick ran for two hours; the first one after sees the deadline
      // long gone.
      time.advance(const Duration(hours: 2));
      expect(fired, 1);
      expect(timer.remaining, isNull);
    });

    test('cancel (Off) stops it for good', () {
      timer.start(const Duration(minutes: 15));
      timer.cancel();
      expect(timer.mode, SleepTimerMode.off);
      expect(timer.remaining, isNull);
      expect(time.liveTickers, 0);
      time.advance(const Duration(hours: 1));
      expect(fired, 0);
      expect(timer.blocksNextEpisode, isFalse);
    });

    test('re-arming replaces the running timer', () {
      timer.start(const Duration(minutes: 15));
      time.advance(const Duration(minutes: 10));
      timer.start(const Duration(minutes: 60));
      expect(timer.selectedDuration, const Duration(minutes: 60));
      expect(timer.remaining, const Duration(minutes: 60));
      expect(time.liveTickers, 1, reason: 'the old tick is cancelled');

      time.advance(const Duration(minutes: 15));
      expect(fired, 0, reason: 'the first timer is gone');
      time.advance(const Duration(minutes: 45));
      expect(fired, 1);
    });

    test('can be armed again after it fired', () {
      timer.start(const Duration(minutes: 15));
      time.advance(const Duration(minutes: 15));
      expect(fired, 1);
      timer.start(const Duration(minutes: 30));
      expect(timer.blocksNextEpisode, isFalse);
      time.advance(const Duration(minutes: 30));
      expect(fired, 2);
    });

    test('survives an episode change: nothing about it is per-episode', () {
      timer.start(const Duration(minutes: 60));
      time.advance(const Duration(minutes: 25));
      // Episode 1 ends, the next one is offered as usual and plays.
      expect(timer.consumeEpisodeEnd(), isFalse);
      expect(timer.mode, SleepTimerMode.timed);
      expect(timer.remaining, const Duration(minutes: 35));
      timer.noteResumed(); // the next episode starts playing
      time.advance(const Duration(minutes: 35));
      expect(fired, 1);
    });

    test('a fired sleep blocks the next episode until playback resumes', () {
      timer.start(const Duration(minutes: 15));
      expect(timer.blocksNextEpisode, isFalse);
      time.advance(const Duration(minutes: 15));
      expect(timer.blocksNextEpisode, isTrue);
      expect(timer.consumeEpisodeEnd(), isTrue);
      expect(timer.consumeEpisodeEnd(), isTrue, reason: 'held, not spent');

      timer.noteResumed();
      expect(timer.blocksNextEpisode, isFalse);
      expect(timer.consumeEpisodeEnd(), isFalse);
    });

    test('a zero duration is Off', () {
      timer.start(Duration.zero);
      expect(timer.isActive, isFalse);
      expect(time.liveTickers, 0);
    });
  });

  group('SleepTimer, end of episode', () {
    test('blocks the next episode and is spent by the ending', () {
      timer.armEndOfEpisode();
      expect(timer.mode, SleepTimerMode.endOfEpisode);
      expect(timer.isActive, isTrue);
      expect(timer.remaining, isNull);
      expect(timer.blocksNextEpisode, isTrue);

      expect(timer.consumeEpisodeEnd(), isTrue);
      expect(timer.mode, SleepTimerMode.off, reason: 'one-shot');
      expect(fired, 0, reason: 'onFire is the timed sleep only');
      expect(timer.blocksNextEpisode, isTrue, reason: 'until the viewer plays');

      timer.noteResumed();
      expect(timer.blocksNextEpisode, isFalse);
      expect(timer.consumeEpisodeEnd(), isFalse);
    });

    test('stays armed across a manual episode change', () {
      timer.armEndOfEpisode();
      // The viewer jumps to another episode: playback starts again, no
      // ending was consumed.
      timer.noteResumed();
      expect(timer.mode, SleepTimerMode.endOfEpisode);
      expect(timer.blocksNextEpisode, isTrue);
    });

    test('replaces a timed sleep, and the other way round', () {
      timer.start(const Duration(minutes: 15));
      timer.armEndOfEpisode();
      expect(time.liveTickers, 0);
      time.advance(const Duration(hours: 1));
      expect(fired, 0);

      timer.start(const Duration(minutes: 15));
      expect(timer.mode, SleepTimerMode.timed);
      expect(timer.blocksNextEpisode, isFalse);
    });

    test('Off clears it', () {
      timer.armEndOfEpisode();
      timer.cancel();
      expect(timer.blocksNextEpisode, isFalse);
      expect(timer.consumeEpisodeEnd(), isFalse);
    });
  });

  test('dispose stops the tick and never fires', () {
    final t = SleepTimer(now: () => time.now, ticker: time.ticker)
      ..onFire = () => fired++;
    t.start(const Duration(minutes: 15));
    t.dispose();
    expect(time.liveTickers, 0);
    time.advance(const Duration(hours: 1));
    expect(fired, 0);
  });

  test('formatSleepRemaining', () {
    expect(formatSleepRemaining(const Duration(minutes: 15)), '15:00');
    expect(formatSleepRemaining(const Duration(minutes: 60)), '1:00:00');
    expect(
      formatSleepRemaining(const Duration(minutes: 14, seconds: 5)),
      '14:05',
    );
    expect(formatSleepRemaining(const Duration(milliseconds: 400)), '0:01');
    expect(formatSleepRemaining(Duration.zero), '0:00');
    expect(formatSleepRemaining(const Duration(seconds: -3)), '0:00');
  });

  group('golden sleep-timer chrome', () {
    Widget host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    );

    testWidgets('the section offers the five choices and arms them', (
      tester,
    ) async {
      await tester.pumpWidget(host(GoldenSleepTimerSection(timer: timer)));
      expect(find.text('SLEEP TIMER'), findsOneWidget);
      for (final label in <String>[
        'Off',
        '15 min',
        '30 min',
        '60 min',
        'End of episode',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.byKey(const Key('sleep-timer-status')), findsNothing);

      await tester.tap(find.text('30 min'));
      await tester.pump();
      expect(timer.selectedDuration, const Duration(minutes: 30));
      expect(find.text('30:00 left'), findsOneWidget);

      time.advance(const Duration(seconds: 61));
      await tester.pump();
      expect(find.text('28:59 left'), findsOneWidget);

      await tester.tap(find.text('End of episode'));
      await tester.pump();
      expect(timer.mode, SleepTimerMode.endOfEpisode);
      expect(find.text('Stops after this episode'), findsOneWidget);

      await tester.tap(find.text('Off'));
      await tester.pump();
      expect(timer.isActive, isFalse);
      expect(find.byKey(const Key('sleep-timer-status')), findsNothing);
    });

    testWidgets('the badge shows only while a timer is armed', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(GoldenSleepTimerBadge(timer: timer, onTap: () => taps++)),
      );
      expect(find.byKey(const Key('sleep-timer-badge-text')), findsNothing);

      timer.start(const Duration(minutes: 15));
      await tester.pump();
      expect(find.text('15:00'), findsOneWidget);

      time.advance(const Duration(minutes: 1));
      await tester.pump();
      expect(find.text('14:00'), findsOneWidget);
      await tester.tap(find.text('14:00'));
      expect(taps, 1);

      timer.armEndOfEpisode();
      await tester.pump();
      expect(find.text('End of episode'), findsOneWidget);

      time.advance(Duration.zero);
      timer.cancel();
      await tester.pump();
      expect(find.byKey(const Key('sleep-timer-badge-text')), findsNothing);
    });
  });
}
