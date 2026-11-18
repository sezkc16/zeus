/// The step-seek coalescer (build 86).
///
/// A widget test pumping the real controls does not exist in this repo —
/// the full controls tree hangs the test isolate (see
/// `mpv_pinch_zoom_test.dart`) — so the coalescing is tested here, on the
/// pure helper both engines drive, with fakeAsync: three rapid taps must
/// send ONE seek to the final target, and only after the taps stop.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/domain/step_seek.dart';

void main() {
  const position = Duration(seconds: 300);
  const duration = Duration(minutes: 90);
  const step = Duration(seconds: 10);

  group('StepSeekCoalescer', () {
    test('three rapid steps send one seek to the final target', () {
      fakeAsync((async) {
        final committed = <Duration>[];
        final offsets = <Duration>[];
        final coalescer = StepSeekCoalescer(
          onCommit: committed.add,
          onStep: offsets.add,
        );
        coalescer.step(position: position, delta: step, duration: duration);
        async.elapse(const Duration(milliseconds: 50));
        coalescer.step(position: position, delta: step, duration: duration);
        async.elapse(const Duration(milliseconds: 50));
        coalescer.step(position: position, delta: step, duration: duration);
        // No seek while the taps keep coming — only the badge offsets,
        // which fire at once per tap.
        expect(committed, isEmpty);
        expect(offsets, const [
          Duration(seconds: 10),
          Duration(seconds: 20),
          Duration(seconds: 30),
        ]);
        async.elapse(const Duration(milliseconds: 150));
        expect(committed, [const Duration(seconds: 330)]);
        coalescer.dispose();
      });
    });

    test('a step just after the commit counts from the committed target', () {
      fakeAsync((async) {
        final committed = <Duration>[];
        final coalescer = StepSeekCoalescer(onCommit: committed.add);
        coalescer.step(position: position, delta: step, duration: duration);
        async.elapse(const Duration(milliseconds: 150));
        expect(committed, [const Duration(seconds: 310)]);
        // The engine has not published the new position yet — the next
        // step still counts from the committed target, not from the stale
        // 300 s the engine would still report.
        coalescer.step(position: position, delta: step, duration: duration);
        async.elapse(const Duration(milliseconds: 150));
        expect(committed, [
          const Duration(seconds: 310),
          const Duration(seconds: 320),
        ]);
        coalescer.dispose();
      });
    });

    test('a step after the base window counts from the fresh position', () {
      fakeAsync((async) {
        final committed = <Duration>[];
        final coalescer = StepSeekCoalescer(onCommit: committed.add);
        coalescer.step(position: position, delta: step, duration: duration);
        async.elapse(const Duration(milliseconds: 150));
        expect(committed, [const Duration(seconds: 310)]);
        // The base window (1500 ms) has passed; the engine has published
        // the seek by now, so the next step counts from the fresh 310 s.
        async.elapse(const Duration(milliseconds: 1400));
        coalescer.step(
          position: const Duration(seconds: 310),
          delta: step,
          duration: duration,
        );
        async.elapse(const Duration(milliseconds: 150));
        expect(committed, [
          const Duration(seconds: 310),
          const Duration(seconds: 320),
        ]);
        coalescer.dispose();
      });
    });

    test('rebase cancels a pending step and adopts the absolute target', () {
      fakeAsync((async) {
        final committed = <Duration>[];
        final coalescer = StepSeekCoalescer(onCommit: committed.add);
        coalescer.step(position: position, delta: step, duration: duration);
        // An absolute seek (scrubber, swipe, rail) lands first: the
        // pending step must never fire after it.
        coalescer.rebase(const Duration(seconds: 400));
        async.elapse(const Duration(milliseconds: 300));
        expect(committed, isEmpty);
        // The next step counts from the rebased target.
        coalescer.step(
          position: const Duration(seconds: 400),
          delta: step,
          duration: duration,
        );
        async.elapse(const Duration(milliseconds: 150));
        expect(committed, [const Duration(seconds: 410)]);
        coalescer.dispose();
      });
    });

    test('steps clamp at both ends of the film', () {
      fakeAsync((async) {
        final committed = <Duration>[];
        final coalescer = StepSeekCoalescer(onCommit: committed.add);
        coalescer.step(
          position: const Duration(seconds: 5),
          delta: const Duration(seconds: -10),
          duration: duration,
        );
        async.elapse(const Duration(milliseconds: 150));
        expect(committed, [Duration.zero]);
        // Past the base window, so the next step counts from the fresh
        // position instead of the previous chain's base.
        async.elapse(const Duration(milliseconds: 1400));
        coalescer.step(
          position: const Duration(seconds: 5395),
          delta: step,
          duration: duration,
        );
        async.elapse(const Duration(milliseconds: 150));
        expect(committed, [Duration.zero, duration]);
        coalescer.dispose();
      });
    });

    test('dispose cancels a pending step', () {
      fakeAsync((async) {
        final committed = <Duration>[];
        final coalescer = StepSeekCoalescer(onCommit: committed.add);
        coalescer.step(position: position, delta: step, duration: duration);
        coalescer.dispose();
        async.elapse(const Duration(seconds: 1));
        expect(committed, isEmpty);
      });
    });
  });
}
