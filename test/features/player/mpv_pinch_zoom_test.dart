/// Two-finger pinch zoom on the mpv (Golden) player (+33, +34).
///
/// The zoom plumbing has been in the v20 line since v18: a `Transform.scale`
/// over the `Video` widget driven by a `ValueNotifier<double>` the
/// controls' gesture layer writes (the screen's `_videoScale` in
/// `mpv_player_screen.dart`). The user phone report 2026-11-15 was "two
/// finger pinch video zoom in out nahi hein" — pinch out zooms in, pinch
/// in zooms out, 0.5x–3.0x, and the zoom sticks after the fingers lift.
///
/// +33 wired the pinch through the scale recognizer; it did NOTHING on
/// the phone. The arena is the failure (verified in the Flutter 3.47.7
/// SDK source): the long-press 500 ms deadline accepts finger 1 before
/// finger 2 spreads, and the first finger wins alone as a pan — the
/// user's video showed the subtitle rail while he was pinching, so his
/// spread was read as a centre-third vertical swipe. +34 moves the
/// pinch to the Listener (`_onPointerDown` / `_onPointerMove` in
/// `golden_player_controls.dart`), which bypasses the arena entirely:
/// two pointers are tracked by hand and their distance ratio is the
/// zoom ([rawPinchScale]). The scale recognizer keeps the single-finger
/// pan only, suppressed while a raw pinch is in flight.
///
/// The pinch math is pure ([videoScaleAfterPinch] / [clampVideoScale] /
/// [rawPinchScale]), so it is unit-tested here. The arena behaviour is
/// widget-tested in `pinch_gesture_arena_test.dart`: an isolated
/// recognizer test that runs anywhere, and a Listener-based mechanism
/// test driving the real [rawPinchScale] through two simulated
/// pointers. A widget test pumping the real controls class does not
/// exist — no test in the repo pumps `GoldenPlayerControls`, and the
/// full controls tree hangs the test isolate on this VM — so the phone
/// test is still the proof that the gesture reaches the notifier on a
/// real device.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/golden_player_controls.dart';

void main() {
  group('pinch zoom on the Golden player', () {
    test('the range is half size to 3x', () {
      expect(kVideoScaleMin, 0.5);
      expect(kVideoScaleMax, 3.0);
    });

    test('a two-finger spread zooms in', () {
      // Fingers 144 px apart -> 244 px apart: the gesture scale is ~1.7.
      expect(videoScaleAfterPinch(1.0, 244 / 144), closeTo(1.69, 0.01));
      expect(videoScaleAfterPinch(1.0, 1.5), 1.5);
    });

    test('a two-finger pinch-in zooms out', () {
      // Fingers 344 px apart -> 144 px apart: the gesture scale is ~0.42.
      expect(videoScaleAfterPinch(1.0, 144 / 344), closeTo(0.5, 0.01));
      expect(videoScaleAfterPinch(1.0, 0.6), 0.6);
    });

    test('a pinch from an already-zoomed picture keeps going', () {
      expect(videoScaleAfterPinch(2.0, 1.25), 2.5);
      expect(videoScaleAfterPinch(2.0, 0.5), 1.0);
    });

    test('no finger movement is no zoom change', () {
      expect(videoScaleAfterPinch(1.0, 1.0), 1.0);
      expect(videoScaleAfterPinch(2.0, 1.0), 2.0);
    });

    test('the zoom clamps at 3x', () {
      expect(videoScaleAfterPinch(1.0, 5.0), 3.0);
      expect(videoScaleAfterPinch(2.0, 2.0), 3.0);
    });

    test('the zoom clamps at 0.5x', () {
      expect(videoScaleAfterPinch(1.0, 0.1), 0.5);
      expect(videoScaleAfterPinch(0.6, 0.5), 0.5);
    });

    test('the settle clamp holds the zoom inside the range', () {
      expect(clampVideoScale(0.4), 0.5);
      expect(clampVideoScale(3.5), 3.0);
      expect(clampVideoScale(1.7), 1.7);
    });
  });

  group('rawPinchScale — the +34 Listener pinch (span ratio)', () {
    test('a spread from the start span zooms in by the ratio', () {
      // Fingers 144 px apart -> 244 px apart: the ratio is ~1.69.
      expect(rawPinchScale(1.0, 144, 244), closeTo(1.69, 0.01));
      expect(rawPinchScale(1.0, 100, 150), 1.5);
    });

    test('a pinch-in from the start span zooms out by the ratio', () {
      // Fingers 344 px apart -> 144 px apart: the ratio is ~0.42,
      // clamped to the 0.5 floor.
      expect(rawPinchScale(1.0, 344, 144), closeTo(0.5, 0.01));
      expect(rawPinchScale(1.0, 200, 120), 0.6);
    });

    test('a pinch from an already-zoomed picture keeps going', () {
      expect(rawPinchScale(2.0, 100, 125), 2.5);
      expect(rawPinchScale(2.0, 200, 100), 1.0);
    });

    test('no finger movement is no zoom change', () {
      expect(rawPinchScale(1.0, 144, 144), 1.0);
      expect(rawPinchScale(2.0, 200, 200), 2.0);
    });

    test('the zoom clamps at 3x and 0.5x', () {
      expect(rawPinchScale(1.0, 100, 500), 3.0);
      expect(rawPinchScale(1.0, 200, 10), 0.5);
    });

    test('a start span under 1 px never explodes the ratio', () {
      // Two fingers on the same point: the start span is treated as
      // 1 px, so a 100 px spread is a 100x ratio — clamped to 3x,
      // never infinity.
      expect(rawPinchScale(1.0, 0, 100), 3.0);
      expect(rawPinchScale(1.0, 0.5, 50), 3.0);
      expect(rawPinchScale(1.0, -10, 100), 3.0);
    });

    test('the raw ratio and the arena scale agree', () {
      // The same gesture through either path lands on the same zoom:
      // the Listener's span ratio is the recognizer's d.scale.
      expect(
        rawPinchScale(1.0, 144, 244),
        videoScaleAfterPinch(1.0, 244 / 144),
      );
    });
  });
}
