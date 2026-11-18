/// Coalesced ±10 s step seeks (build 86): several rapid taps become ONE
/// seek to the final target.
///
/// A ±10 s step used to send one seek per tap, immediately. Each seek
/// re-seeks the engine — mpv's exact seek decodes forward from the previous
/// keyframe (seconds on 4K with long GOPs, even inside the buffered band),
/// and libVLC's prefetch empties its window on a seek past the window's end
/// and re-reads from the host — so three quick taps cost three seeks and
/// three loads. Coalescing sends one seek, 150 ms after the last tap, to
/// the final target.
///
/// The chain: a step counts from the running target, not from the position
/// the engine last published (it lags the seek by a round trip, so counting
/// from it would send the chain backwards). The base survives the commit
/// for [baseLifetime], so a tap just after the commit still counts from the
/// committed target. An absolute seek — scrubber, swipe, rail, skip —
/// rebases the chain instead of fighting it: the pending step is cancelled
/// outright, and the absolute target becomes the base.
///
/// Pure apart from its two timers, so it is unit-tested with fakeAsync
/// (see `step_seek_test.dart`); a widget test pumping the real controls
/// does not exist in this repo (the full controls tree hangs the test
/// isolate — see `mpv_pinch_zoom_test.dart`), so the phone test is still
/// the proof the gesture reaches it on a real device.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// How long the taps may keep coming before the one seek is sent.
const Duration kStepSeekDebounce = Duration(milliseconds: 150);

/// How long the base survives after the last step: the controller's stall
/// delay (1000 ms on both engines) + 500 ms, the VLC chain's window — a
/// chain the engine is slow to honour gets its spinner before the base
/// falls back to the truth.
const Duration kStepSeekBaseLifetime = Duration(milliseconds: 1500);

/// One coalesced step-seek chain: the running target and the commit.
///
/// [onCommit] is the one seek, sent [kStepSeekDebounce] after the last
/// step. [onStep] fires at once on every step with the chain's cumulative
/// offset (target − origin), so the tap feels instant — the mpv badge
/// shows it; libVLC's burst is deliberately not shown (see
/// `VlcPlayerControls._showSeekBurst`), so it passes nothing there.
class StepSeekCoalescer {
  StepSeekCoalescer({
    required this.onCommit,
    this.onStep,
    this.debounce = kStepSeekDebounce,
    this.baseLifetime = kStepSeekBaseLifetime,
  });

  /// Called with the final target when the taps stop for [debounce].
  final ValueChanged<Duration> onCommit;

  /// Called at once on every step with the chain's cumulative offset.
  final ValueChanged<Duration>? onStep;

  /// How long the taps may keep coming before the one seek is sent.
  final Duration debounce;

  /// How long the base survives after the last step.
  final Duration baseLifetime;

  /// The running target, or null when no chain is in flight.
  Duration? get base => _base;
  Duration? _base;

  Duration? _origin;
  Duration? _pending;
  Timer? _timer;
  Timer? _baseTimer;

  /// One ±10 s step: accumulate it onto the chain and (re-)arm the
  /// commit. [position] is where the engine says playback is — only read
  /// when no chain is in flight. Clamped at both ends, because a seek
  /// past either end is rejected or trips the end-of-media handler.
  void step({
    required Duration position,
    required Duration delta,
    required Duration duration,
  }) {
    final here = _base ?? position;
    final origin = _origin ?? position;
    var target = here + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) {
      target = duration;
    }
    _base = target;
    _origin = origin;
    _pending = target;
    onStep?.call(target - origin);
    _armBaseTimer();
    _timer?.cancel();
    _timer = Timer(debounce, _commit);
  }

  /// Sends the coalesced seek: one seek to the final target. The base
  /// stays until [_baseTimer] fires, so a tap just after this one still
  /// counts from the target, not from the position the engine has not
  /// published yet.
  void _commit() {
    _timer = null;
    final target = _pending;
    _pending = null;
    if (target == null) return;
    onCommit(target);
  }

  /// Adopts [target] as the position the next step counts from, and
  /// cancels a pending debounced step outright: the absolute seek is the
  /// truth now, and sending the stale step after it would jump the film
  /// back.
  void rebase(Duration target) {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _base = target;
    _origin = target;
    _armBaseTimer();
  }

  /// One window for the whole chain, restarted by every step that feeds
  /// it. Longer than the controller's stall delay on purpose: a chain the
  /// engine is slow to honour gets its spinner before the base falls back
  /// to the truth.
  void _armBaseTimer() {
    _baseTimer?.cancel();
    _baseTimer = Timer(baseLifetime, () {
      _baseTimer = null;
      _base = null;
      _origin = null;
    });
  }

  /// A pending step seek must never fire after dispose.
  void dispose() {
    _timer?.cancel();
    _baseTimer?.cancel();
    _timer = null;
    _baseTimer = null;
    _pending = null;
  }
}
