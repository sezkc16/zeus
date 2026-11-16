/// Two-finger pinch zoom: the gesture arena, and the Listener that
/// replaces it (+34).
///
/// +33 wired the pinch through the scale recognizer in the same
/// GestureDetector that holds the tap, double-tap and long-press
/// recognizers — and the pinch did NOTHING on the phone. The arena is
/// the failure (verified in the Flutter 3.47.7 SDK source, scale.dart):
/// the long-press 500 ms deadline accepts finger 1 if the viewer
/// places finger 2 and pauses before spreading, and the first finger
/// wins alone as a pan — the user's video showed the subtitle rail
/// while he was pinching, so his spread was read as a centre-third
/// vertical swipe.
///
/// +34 tracks the pinch in the Listener instead, bypassing the arena
/// entirely (see `_onPointerDown` / `_onPointerMove` in
/// `golden_player_controls.dart`). This file tests both sides, without
/// pumping the full controls tree (no test in the repo pumps
/// `GoldenPlayerControls`, and the full tree hangs the test isolate on
/// this VM — so these tests run anywhere, including here):
///
///   * the isolated arena test: the stock recognizer combination CAN
///     recognize a clean, immediate pinch — and a pause before
///     spreading lets the long-press win instead, which is the failure
///     the Listener patch exists for;
///   * the Listener mechanism test: two simulated pointers through a
///     Listener drive the real [rawPinchScale] — spread zooms in,
///     pinch-in zooms out, one finger changes nothing, and the zoom
///     sticks after the fingers lift.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/golden_player_controls.dart';

void main() {
  group('the stock recognizer combination (isolated)', () {
    Future<void> pumpDetector(
      WidgetTester tester, {
      required void Function(ScaleUpdateDetails) onScaleUpdate,
      required VoidCallback onLongPress,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              onDoubleTapDown: (_) {},
              onLongPressStart: (_) => onLongPress(),
              onLongPressEnd: (_) {},
              onScaleStart: (_) {},
              onScaleUpdate: onScaleUpdate,
              onScaleEnd: (_) {},
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
    }

    testWidgets('two-finger pinch works alongside tap, double-tap and hold', (
      tester,
    ) async {
      int pinchUpdates = 0;
      double largestScale = 1.0;
      await pumpDetector(
        tester,
        onScaleUpdate: (details) {
          if (details.pointerCount >= 2) {
            pinchUpdates++;
            if (details.scale > largestScale) {
              largestScale = details.scale;
            }
          }
        },
        onLongPress: () {},
      );
      final first = await tester.startGesture(
        const Offset(120, 200),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(200, 200),
        pointer: 2,
      );
      await tester.pump();
      await first.moveTo(const Offset(80, 200));
      await second.moveTo(const Offset(240, 200));
      await tester.pump();
      expect(pinchUpdates, greaterThan(0));
      expect(largestScale, greaterThan(1.0));
      await first.up();
      await second.up();
      // Let the double-tap recognizer's timeout expire, or the test
      // ends with its timer still pending.
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('a pause before spreading lets the long-press win the arena', (
      tester,
    ) async {
      // The +33 failure, reproduced: finger 1 down, finger 2 down,
      // then a pause past the long-press deadline BEFORE spreading.
      // The long-press accepts finger 1, the scale recognizer is
      // rejected for it, and the spread becomes a one-finger pan —
      // so no two-pointer scale update ever arrives. This is why
      // the pinch lives in the Listener now.
      int pinchUpdates = 0;
      var longPressed = false;
      await pumpDetector(
        tester,
        onScaleUpdate: (details) {
          if (details.pointerCount >= 2) pinchUpdates++;
        },
        onLongPress: () => longPressed = true,
      );
      final first = await tester.startGesture(
        const Offset(120, 200),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(200, 200),
        pointer: 2,
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(longPressed, isTrue);
      await first.moveTo(const Offset(80, 200));
      await second.moveTo(const Offset(240, 200));
      await tester.pump();
      expect(pinchUpdates, 0);
      await first.up();
      await second.up();
      await tester.pump(const Duration(milliseconds: 500));
    });
  });

  group('the Listener pinch (the +34 mechanism)', () {
    testWidgets('a spread zooms in and sticks after the lift', (tester) async {
      final scale = ValueNotifier<double>(1.0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: _RawPinchProbe(scale: scale)),
        ),
      );
      final first = await tester.startGesture(
        const Offset(120, 200),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(200, 200),
        pointer: 2,
      );
      await tester.pump();
      await first.moveTo(const Offset(80, 200));
      await second.moveTo(const Offset(240, 200));
      await tester.pump();
      // 80 px apart -> 160 px apart: the ratio is 2.0.
      expect(scale.value, 2.0);
      await first.up();
      await second.up();
      await tester.pump();
      expect(scale.value, 2.0);
    });

    testWidgets('a pinch-in zooms out', (tester) async {
      final scale = ValueNotifier<double>(1.0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: _RawPinchProbe(scale: scale)),
        ),
      );
      final first = await tester.startGesture(
        const Offset(80, 200),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(240, 200),
        pointer: 2,
      );
      await tester.pump();
      await first.moveTo(const Offset(120, 200));
      await second.moveTo(const Offset(200, 200));
      await tester.pump();
      // 160 px apart -> 80 px apart: the ratio is 0.5.
      expect(scale.value, 0.5);
      await first.up();
      await second.up();
    });

    testWidgets('a pause before spreading still zooms', (tester) async {
      // The arena-killer case, through the Listener: finger 1 down,
      // finger 2 down, a pause past the long-press deadline, then the
      // spread. The Listener never enters the arena, so the pause
      // changes nothing.
      final scale = ValueNotifier<double>(1.0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: _RawPinchProbe(scale: scale)),
        ),
      );
      final first = await tester.startGesture(
        const Offset(120, 200),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(200, 200),
        pointer: 2,
      );
      await tester.pump(const Duration(milliseconds: 600));
      await first.moveTo(const Offset(80, 200));
      await second.moveTo(const Offset(240, 200));
      await tester.pump();
      expect(scale.value, 2.0);
      await first.up();
      await second.up();
    });

    testWidgets('one finger moving changes nothing', (tester) async {
      final scale = ValueNotifier<double>(1.0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: _RawPinchProbe(scale: scale)),
        ),
      );
      final first = await tester.startGesture(
        const Offset(120, 200),
        pointer: 1,
      );
      await tester.pump();
      await first.moveTo(const Offset(200, 200));
      await tester.pump();
      expect(scale.value, 1.0);
      await first.up();
    });
  });
}

/// The +34 Listener pinch, distilled: the same state machine as
/// `_GoldenPlayerControlsState`'s pointer handlers, driving the real
/// [rawPinchScale]. It proves the mechanism — two pointers through a
/// Listener, span ratio to zoom — without pumping the full controls
/// tree (which hangs the test isolate on this VM).
class _RawPinchProbe extends StatefulWidget {
  const _RawPinchProbe({required this.scale});

  final ValueNotifier<double> scale;

  @override
  State<_RawPinchProbe> createState() => _RawPinchProbeState();
}

class _RawPinchProbeState extends State<_RawPinchProbe> {
  final Map<int, Offset> _touches = <int, Offset>{};
  bool _pinching = false;
  double _startSpan = 1.0;
  double _startScale = 1.0;

  void _down(PointerDownEvent event) {
    _touches[event.pointer] = event.position;
    if (_touches.length == 2) {
      _pinching = true;
      _startScale = widget.scale.value;
      final points = _touches.values.toList();
      _startSpan = (points[0] - points[1]).distance;
      if (_startSpan < 1.0) _startSpan = 1.0;
    }
  }

  void _move(PointerMoveEvent event) {
    if (!_touches.containsKey(event.pointer)) return;
    _touches[event.pointer] = event.position;
    if (!_pinching || _touches.length != 2) return;
    final points = _touches.values.toList();
    widget.scale.value = rawPinchScale(
      _startScale,
      _startSpan,
      (points[0] - points[1]).distance,
    );
  }

  void _up(PointerEvent event) {
    _touches.remove(event.pointer);
    if (_touches.length < 2) _pinching = false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Opaque, or the empty child never hit-tests and no pointer
      // event reaches this Listener at all.
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: const SizedBox.expand(),
    );
  }
}
