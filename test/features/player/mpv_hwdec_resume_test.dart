/// VideoToolbox session-loss decision (+40 P4): `hwdec-current` is the
/// decoder actually in use — empty (or `no`) once iOS has invalidated
/// the session while the app was backgrounded, `videotoolbox` /
/// `videotoolbox-copy` while it is alive. Either VideoToolbox flavour
/// counts as alive.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_ios_options.dart';

void main() {
  group('hwdecSessionLost', () {
    test('videotoolbox => alive', () {
      expect(hwdecSessionLost(current: 'videotoolbox'), isFalse);
    });

    test('videotoolbox-copy => alive', () {
      expect(hwdecSessionLost(current: 'videotoolbox-copy'), isFalse);
    });

    test('empty => lost (the phone-proof signal)', () {
      expect(hwdecSessionLost(current: ''), isTrue);
    });

    test('no => lost (software decode)', () {
      expect(hwdecSessionLost(current: 'no'), isTrue);
    });

    test('whitespace around a live value => alive', () {
      expect(hwdecSessionLost(current: '  videotoolbox  '), isFalse);
    });

    test('an unknown value => lost', () {
      expect(hwdecSessionLost(current: 'auto'), isTrue);
    });
  });

  // Build 70: the bounded watch that follows a Home → return. Phone
  // proof 2026-11-18 (4K, PiP mode iOS): `hwdec: videotoolbox` before
  // Home, empty after the 4K re-open for the rest of the film.
  group('hwdecResumeStep', () {
    final last = kHwdecResumeCheckDelays.length - 1;

    test('three checks, about 1 s, 3 s and 6 s after playback', () {
      expect(kHwdecResumeCheckDelays, hasLength(3));
      var total = Duration.zero;
      final marks = <int>[];
      for (final wait in kHwdecResumeCheckDelays) {
        total += wait;
        marks.add(total.inSeconds);
      }
      expect(marks, <int>[1, 3, 6]);
      // Never read at once: hwdec-current is empty before a frame.
      expect(kHwdecResumeCheckDelays.first, greaterThan(Duration.zero));
    });

    test('healthy decoder is never touched, on any check', () {
      for (var attempt = 0; attempt <= last; attempt++) {
        for (final value in <String>['videotoolbox', 'videotoolbox-copy']) {
          final step = hwdecResumeStep(
            current: value,
            attempt: attempt,
            inPip: false,
          );
          expect(step, HwdecResumeStep.healthy);
          expect(
            hwdecResumeContinues(step: step, attempt: attempt),
            isFalse,
            reason: 'a healthy decoder ends the watch',
          );
        }
      }
    });

    test('lost (the phone-proof empty value) cycles before any re-open', () {
      for (var attempt = 0; attempt < last; attempt++) {
        final step = hwdecResumeStep(
          current: '',
          attempt: attempt,
          inPip: false,
        );
        expect(step, HwdecResumeStep.cycle);
        expect(hwdecResumeContinues(step: step, attempt: attempt), isTrue);
      }
    });

    test('still lost on the last check re-opens once and stops', () {
      final step = hwdecResumeStep(
        current: 'no',
        attempt: last,
        inPip: false,
      );
      expect(step, HwdecResumeStep.reopen);
      expect(hwdecResumeContinues(step: step, attempt: last), isFalse);
    });

    test('never re-opens under a PiP window', () {
      final step = hwdecResumeStep(current: '', attempt: last, inPip: true);
      expect(step, HwdecResumeStep.giveUp);
      expect(hwdecResumeContinues(step: step, attempt: last), isFalse);
      // The in-place cycle is still allowed under the window.
      expect(
        hwdecResumeStep(current: '', attempt: 0, inPip: true),
        HwdecResumeStep.cycle,
      );
    });

    test('unreadable is not loss: no action, look again if a check is left',
        () {
      for (var attempt = 0; attempt <= last; attempt++) {
        final step = hwdecResumeStep(
          current: null,
          attempt: attempt,
          inPip: false,
        );
        expect(step, HwdecResumeStep.unreadable);
        expect(
          hwdecResumeContinues(step: step, attempt: attempt),
          attempt < last,
        );
      }
    });

    test('the watch cannot loop: a full run of lost reads ends in 3 steps',
        () {
      final steps = <HwdecResumeStep>[];
      var attempt = 0;
      while (true) {
        final step = hwdecResumeStep(
          current: '',
          attempt: attempt,
          inPip: false,
        );
        steps.add(step);
        if (!hwdecResumeContinues(step: step, attempt: attempt)) break;
        attempt++;
        expect(attempt, lessThan(10), reason: 'must terminate');
      }
      expect(steps, <HwdecResumeStep>[
        HwdecResumeStep.cycle,
        HwdecResumeStep.cycle,
        HwdecResumeStep.reopen,
      ]);
    });

    test('a past-the-end attempt is treated as the last', () {
      expect(
        hwdecResumeStep(current: '', attempt: 99, inPip: false),
        HwdecResumeStep.reopen,
      );
      expect(
        hwdecResumeContinues(step: HwdecResumeStep.cycle, attempt: 99),
        isFalse,
      );
    });
  });

  group('hwdecRestoreAllowed', () {
    test('a film never seen on VideoToolbox is left alone', () {
      // The PiP renderer's session: hwdec-current empty from frame one.
      expect(hwdecRestoreAllowed(seenAlive: false), isFalse);
    });

    test('a film that had hardware decode may be restored', () {
      expect(hwdecRestoreAllowed(seenAlive: true), isTrue);
    });
  });

  group('expected hwdec per PiP mode', () {
    test('PiP mode iOS (hardware renderer) expects videotoolbox', () {
      expect(mpvIosHwdec(pipEnabled: false), 'videotoolbox');
    });

    test('PiP mode mpv (software renderer) expects videotoolbox-copy', () {
      expect(mpvIosHwdec(pipEnabled: true), 'videotoolbox-copy');
    });

    test('both expectations read back as healthy', () {
      for (final pip in <bool>[true, false]) {
        expect(
          hwdecResumeStep(
            current: mpvIosHwdec(pipEnabled: pip),
            attempt: 0,
            inPip: false,
          ),
          HwdecResumeStep.healthy,
        );
      }
    });
  });

  // Build 71: build 70's watch never ran on the phone (2026-11-18:
  // `hw-restore: -` after two Home → returns). The film comes back
  // PAUSED and the viewer taps play, so the restore is decided on
  // every `resumed`, whatever the film is doing.
  group('hwdecReturnPlan', () {
    test('the phone case: paused on return, hardware renderer => '
        'refresh now, watch when play is pressed', () {
      expect(
        hwdecReturnPlan(
          wasBackgrounded: true,
          seenAlive: true,
          playing: false,
          refreshAllowed: true,
        ),
        HwdecReturnPlan.refreshThenWatchOnPlay,
      );
    });

    test('paused on return never leaves the watch un-armed', () {
      for (final refreshAllowed in <bool>[true, false]) {
        final plan = hwdecReturnPlan(
          wasBackgrounded: true,
          seenAlive: true,
          playing: false,
          refreshAllowed: refreshAllowed,
        );
        expect(
          plan,
          anyOf(
            HwdecReturnPlan.refreshThenWatchOnPlay,
            HwdecReturnPlan.watchOnPlay,
          ),
        );
      }
    });

    test('paused, refresh not allowed (PiP renderer / PiP window / open '
        'landing) => watch on play, decoder left alone', () {
      expect(
        hwdecReturnPlan(
          wasBackgrounded: true,
          seenAlive: true,
          playing: false,
          refreshAllowed: false,
        ),
        HwdecReturnPlan.watchOnPlay,
      );
    });

    test('already playing (PiP window kept it running) => watch now, '
        'never a refresh under a moving film', () {
      for (final refreshAllowed in <bool>[true, false]) {
        expect(
          hwdecReturnPlan(
            wasBackgrounded: true,
            seenAlive: true,
            playing: true,
            refreshAllowed: refreshAllowed,
          ),
          HwdecReturnPlan.watchNow,
        );
      }
    });

    test('never seen on VideoToolbox => skip, whatever else is true '
        '(the 1080p PiP-return misfire stays fixed)', () {
      for (final playing in <bool>[true, false]) {
        for (final refreshAllowed in <bool>[true, false]) {
          expect(
            hwdecReturnPlan(
              wasBackgrounded: true,
              seenAlive: false,
              playing: playing,
              refreshAllowed: refreshAllowed,
            ),
            HwdecReturnPlan.skipNoHardwareBefore,
          );
        }
      }
    });

    test('not a real backgrounding (Control Center) => nothing', () {
      for (final seenAlive in <bool>[true, false]) {
        for (final playing in <bool>[true, false]) {
          expect(
            hwdecReturnPlan(
              wasBackgrounded: false,
              seenAlive: seenAlive,
              playing: playing,
              refreshAllowed: true,
            ),
            HwdecReturnPlan.none,
          );
        }
      }
    });
  });

  group('iosResumePathActs', () {
    test('the phone case: film paused by Home reads "was not playing" '
        '=> the resume path does nothing, the return hook arms', () {
      expect(
        iosResumePathActs(
          wasBackgrounded: true,
          wasInPip: false,
          wasPlaying: false,
        ),
        isFalse,
      );
    });

    test('was playing, real backgrounding, no PiP => it acts', () {
      expect(
        iosResumePathActs(
          wasBackgrounded: true,
          wasInPip: false,
          wasPlaying: true,
        ),
        isTrue,
      );
    });

    test('PiP window or no backgrounding => it does not act', () {
      expect(
        iosResumePathActs(
          wasBackgrounded: true,
          wasInPip: true,
          wasPlaying: true,
        ),
        isFalse,
      );
      expect(
        iosResumePathActs(
          wasBackgrounded: false,
          wasInPip: false,
          wasPlaying: true,
        ),
        isFalse,
      );
    });
  });

  group('hwdecResumeOverlayLine', () {
    String line({
      int returns = 1,
      String pre = '-',
      int checks = 0,
      int cycles = 0,
      bool reopened = false,
      String outcome = 'waiting',
    }) =>
        hwdecResumeOverlayLine(
          returns: returns,
          pre: pre,
          checks: checks,
          cycles: cycles,
          reopened: reopened,
          outcome: outcome,
        );

    test('a dash only before the first return from the background', () {
      expect(line(returns: 0), 'hw-restore: -');
    });

    test('never a dash once a return was handled, in any state', () {
      for (final outcome in <String>[
        kHwdecOutcomeSkipNoHardware,
        kHwdecOutcomeWaitPlay,
        'waiting',
        'ok',
        'lost',
        'unreadable',
        'reopened',
        'stopped',
      ]) {
        final text = line(outcome: outcome);
        expect(text, isNot('hw-restore: -'));
        expect(text, startsWith('hw-restore: #1 '));
      }
    });

    test('the return counter grows with each return', () {
      expect(line(returns: 2, outcome: kHwdecOutcomeWaitPlay),
          'hw-restore: #2 pre:- chk 0 cyc 0 wait play');
    });

    test('skip names its reason', () {
      expect(line(outcome: kHwdecOutcomeSkipNoHardware),
          'hw-restore: #1 skip (no hw before)');
    });

    test('paused refresh worked, healthy on the first check', () {
      expect(line(pre: 'ok', checks: 1, outcome: 'ok'),
          'hw-restore: #1 pre:ok chk 1 cyc 0 ok');
    });

    test('restored by one cycle of the watch', () {
      expect(line(pre: 'lost', checks: 2, cycles: 1, outcome: 'ok'),
          'hw-restore: #1 pre:lost chk 2 cyc 1 ok');
    });

    test('the last rung is visible', () {
      expect(
        line(
          pre: 'sent',
          checks: 3,
          cycles: 2,
          reopened: true,
          outcome: 'reopened',
        ),
        'hw-restore: #1 pre:sent chk 3 cyc 2 reopen 1 reopened',
      );
    });
  });
}
