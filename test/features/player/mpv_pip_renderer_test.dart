import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_pip_renderer.dart';

void main() {
  group('renderer per phase', () {
    test('hardware phases use videotoolbox, software ones the copy', () {
      expect(rendererHwdec(MpvRendererPhase.hardware), 'videotoolbox');
      expect(rendererHwdec(MpvRendererPhase.toHardware), 'videotoolbox');
      expect(rendererHwdec(MpvRendererPhase.software), 'videotoolbox-copy');
      expect(rendererHwdec(MpvRendererPhase.toSoftware), 'videotoolbox-copy');
    });

    test('only the two moves count as switching', () {
      expect(rendererSwitching(MpvRendererPhase.hardware), isFalse);
      expect(rendererSwitching(MpvRendererPhase.software), isFalse);
      expect(rendererSwitching(MpvRendererPhase.toSoftware), isTrue);
      expect(rendererSwitching(MpvRendererPhase.toHardware), isTrue);
    });

    test('overlay line', () {
      expect(
        rendererOverlayLine(MpvRendererPhase.hardware, onDemand: true),
        'renderer: hw',
      );
      expect(
        rendererOverlayLine(MpvRendererPhase.software, onDemand: true),
        'renderer: sw(pip)',
      );
      expect(
        rendererOverlayLine(MpvRendererPhase.toSoftware, onDemand: true),
        contains('switching'),
      );
      expect(
        rendererOverlayLine(MpvRendererPhase.toHardware, onDemand: true),
        contains('switching'),
      );
      expect(
        rendererOverlayLine(MpvRendererPhase.software, onDemand: false),
        'renderer: hw',
      );
    });
  });

  group('Home-return logic gate', () {
    test('acts on a plain Home return, hardware or software', () {
      for (final phase in [
        MpvRendererPhase.hardware,
        MpvRendererPhase.software,
      ]) {
        expect(
          rendererReturnLogicAllowed(phase: phase, backgroundedWithPip: false),
          isTrue,
        );
      }
    });

    test('never on a return from the PiP window (the 00:00/LIVE bug)', () {
      for (final phase in MpvRendererPhase.values) {
        expect(
          rendererReturnLogicAllowed(phase: phase, backgroundedWithPip: true),
          isFalse,
        );
      }
    });

    test('never during a move', () {
      expect(
        rendererReturnLogicAllowed(
          phase: MpvRendererPhase.toHardware,
          backgroundedWithPip: false,
        ),
        isFalse,
      );
      expect(
        rendererReturnLogicAllowed(
          phase: MpvRendererPhase.toSoftware,
          backgroundedWithPip: false,
        ),
        isFalse,
      );
    });
  });

  group('PiP button', () {
    test('hardware moves first, software enters, a move ignores', () {
      expect(
        pipButtonPlan(MpvRendererPhase.hardware),
        PipButtonPlan.switchThenEnter,
      );
      expect(pipButtonPlan(MpvRendererPhase.software), PipButtonPlan.enter);
      expect(pipButtonPlan(MpvRendererPhase.toSoftware), PipButtonPlan.ignore);
      expect(pipButtonPlan(MpvRendererPhase.toHardware), PipButtonPlan.ignore);
    });
  });

  group('PiP end', () {
    PipEndPlan plan({
      MpvRendererPhase phase = MpvRendererPhase.software,
      bool windowUp = false,
      bool resumed = true,
      bool needsHardware = false,
    }) => pipEndPlan(
      phase: phase,
      pipWindowUp: windowUp,
      appResumed: resumed,
      needsHardware: needsHardware,
    );

    test('below 4K keeps playing on software: no re-open', () {
      expect(plan(), PipEndPlan.stayOnSoftware);
      expect(plan(resumed: false), PipEndPlan.stayOnSoftware);
    });

    test('4K moves back now in the foreground, deferred behind it', () {
      expect(plan(needsHardware: true), PipEndPlan.switchNow);
      expect(
        plan(needsHardware: true, resumed: false),
        PipEndPlan.pauseAndDefer,
      );
    });

    test('nothing while the window is up or off the software phase', () {
      expect(plan(windowUp: true, needsHardware: true), PipEndPlan.none);
      for (final phase in [
        MpvRendererPhase.hardware,
        MpvRendererPhase.toHardware,
        MpvRendererPhase.toSoftware,
      ]) {
        expect(plan(phase: phase, needsHardware: true), PipEndPlan.none);
      }
    });

    test('hardware is needed for 4K or an undone quality drop', () {
      expect(pipEndNeedsHardware(is4K: true, qualityDropped: false), isTrue);
      expect(pipEndNeedsHardware(is4K: false, qualityDropped: true), isTrue);
      expect(pipEndNeedsHardware(is4K: false, qualityDropped: false), isFalse);
    });
  });

  group('failure fallback', () {
    test('a failed move to software ends on hardware', () {
      expect(
        rendererPhaseAfterSwitch(toSoftware: true, succeeded: false),
        MpvRendererPhase.hardware,
      );
      expect(
        rendererPhaseAfterSwitch(toSoftware: true, succeeded: true),
        MpvRendererPhase.software,
      );
      expect(
        rendererPhaseAfterSwitch(toSoftware: false, succeeded: true),
        MpvRendererPhase.hardware,
      );
      expect(
        rendererPhaseAfterSwitch(toSoftware: false, succeeded: false),
        MpvRendererPhase.hardware,
      );
    });
  });

  group('carry-over', () {
    RendererCarryOver carry({
      Duration position = const Duration(minutes: 21, seconds: 49),
      bool wasPlaying = true,
      double rate = 1.0,
    }) => RendererCarryOver(
      position: position,
      duration: const Duration(hours: 3, minutes: 4, seconds: 50),
      wasPlaying: wasPlaying,
      rate: rate,
      volume: 100,
      streamIndex: 2,
    );

    test('opens at the position, never at a negative or zero start', () {
      expect(carry().start, const Duration(minutes: 21, seconds: 49));
      expect(carry(position: Duration.zero).start, isNull);
      expect(carry(position: const Duration(seconds: -3)).start, isNull);
    });

    test('a move to software always plays; a move back keeps the state', () {
      expect(carry(wasPlaying: false).autoPlay(toSoftware: true), isTrue);
      expect(carry(wasPlaying: false).autoPlay(toSoftware: false), isFalse);
      expect(carry(wasPlaying: true).autoPlay(toSoftware: false), isTrue);
    });

    test('speed is re-applied only when it is not 1x', () {
      expect(carry().rateToApply, isNull);
      expect(carry(rate: 1.5).rateToApply, 1.5);
    });

    test('the stream index and the length travel with it', () {
      expect(carry().streamIndex, 2);
      expect(
        carry().duration,
        const Duration(hours: 3, minutes: 4, seconds: 50),
      );
    });
  });
}
