/// The player's sleep timer: pause after a while, or stop at the end of
/// the episode.
///
/// Pure Dart on purpose — no engine, no widgets — and driven by an
/// injectable clock and ticker, so every rule here is unit-tested without
/// waiting real minutes. The player screen holds ONE instance for the
/// life of the player: it is not tied to an episode, so a 60-minute timer
/// keeps counting into the next episode, and it is not persisted, so it
/// is gone when the player closes.
///
/// The countdown is measured against the wall clock (a deadline), not by
/// counting ticks: a tick that arrives late — the app was suspended in
/// the background, the isolate was busy — still sees the true remaining
/// time, and a deadline that passed while no tick could run fires on the
/// first tick after.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// What the timer is doing.
enum SleepTimerMode {
  /// Nothing armed.
  off,

  /// Counting down to a pause.
  timed,

  /// Playback stops when the current episode / film ends: the next
  /// episode is not offered.
  endOfEpisode,
}

/// The timed choices the player offers, in the order it shows them.
const List<Duration> kSleepTimerDurations = <Duration>[
  Duration(minutes: 15),
  Duration(minutes: 30),
  Duration(minutes: 60),
];

/// Starts a periodic tick; returns its handle. `Timer.periodic` in the
/// app, a hand-cranked fake in tests.
typedef SleepTicker =
    Timer Function(Duration period, void Function() onTick);

Timer _defaultTicker(Duration period, void Function() onTick) =>
    Timer.periodic(period, (_) => onTick());

class SleepTimer extends ChangeNotifier {
  SleepTimer({
    DateTime Function()? now,
    SleepTicker? ticker,
    this.tickPeriod = const Duration(seconds: 1),
  }) : _now = now ?? DateTime.now,
       _ticker = ticker ?? _defaultTicker;

  final DateTime Function() _now;
  final SleepTicker _ticker;

  /// How often the countdown is checked (and listeners repainted).
  final Duration tickPeriod;

  /// Called once when a TIMED sleep runs out. The screen pauses the
  /// player here. Not called for [SleepTimerMode.endOfEpisode] — that one
  /// is reported through [consumeEpisodeEnd], at the ending itself.
  VoidCallback? onFire;

  SleepTimerMode _mode = SleepTimerMode.off;
  Duration? _selected;
  DateTime? _deadline;
  Timer? _tick;
  bool _firedHold = false;
  bool _disposed = false;

  SleepTimerMode get mode => _mode;

  /// Whether anything is armed.
  bool get isActive => _mode != SleepTimerMode.off;

  /// The duration the viewer picked for the running timed sleep (15, 30
  /// or 60 minutes), or null when no timed sleep is running. The picker
  /// highlights this choice.
  Duration? get selectedDuration =>
      _mode == SleepTimerMode.timed ? _selected : null;

  /// Time left on a timed sleep, never negative; null when no timed
  /// sleep is running.
  Duration? get remaining {
    final deadline = _deadline;
    if (_mode != SleepTimerMode.timed || deadline == null) return null;
    final left = deadline.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Whether a natural ending must NOT offer or auto-play the next
  /// episode: end-of-episode is armed, or a sleep already fired and the
  /// viewer has not started playback again since (see [noteResumed]).
  bool get blocksNextEpisode =>
      _mode == SleepTimerMode.endOfEpisode || _firedHold;

  /// Arms (or re-arms) a timed sleep: [duration] from now. Replaces
  /// whatever was armed before.
  void start(Duration duration) {
    if (_disposed) return;
    if (duration <= Duration.zero) {
      cancel();
      return;
    }
    _stopTick();
    _mode = SleepTimerMode.timed;
    _selected = duration;
    _deadline = _now().add(duration);
    _firedHold = false;
    _tick = _ticker(tickPeriod, _onTick);
    notifyListeners();
  }

  /// Arms "end of episode": the current episode plays out, then playback
  /// stops instead of moving on. Replaces whatever was armed before.
  void armEndOfEpisode() {
    if (_disposed) return;
    _stopTick();
    _mode = SleepTimerMode.endOfEpisode;
    _selected = null;
    _deadline = null;
    _firedHold = false;
    notifyListeners();
  }

  /// Off: cancels whatever is armed, and forgets a sleep that already
  /// fired.
  void cancel() {
    if (_disposed) return;
    final changed = _mode != SleepTimerMode.off || _firedHold;
    _stopTick();
    _mode = SleepTimerMode.off;
    _selected = null;
    _deadline = null;
    _firedHold = false;
    if (changed) notifyListeners();
  }

  /// The current episode / film reached its natural end. Returns true
  /// when the sleep timer forbids offering the next episode for this
  /// ending — the caller then shows the ended card and stops.
  ///
  /// End-of-episode is one-shot: it is spent by the ending it stops, so
  /// the timer reads Off afterwards. The block itself stays up (see
  /// [blocksNextEpisode]) until the viewer plays again.
  bool consumeEpisodeEnd() {
    if (_disposed) return false;
    if (_mode == SleepTimerMode.endOfEpisode) {
      _mode = SleepTimerMode.off;
      _firedHold = true;
      notifyListeners();
      return true;
    }
    return _firedHold;
  }

  /// The viewer started playback again after a sleep fired: the sleep is
  /// over, so the next ending behaves normally again. A no-op otherwise.
  void noteResumed() {
    if (_disposed || !_firedHold) return;
    _firedHold = false;
    notifyListeners();
  }

  void _onTick() {
    if (_disposed || _mode != SleepTimerMode.timed) return;
    final deadline = _deadline;
    if (deadline == null) return;
    if (_now().isBefore(deadline)) {
      // Still counting: repaint the remaining-time labels.
      notifyListeners();
      return;
    }
    _stopTick();
    _mode = SleepTimerMode.off;
    _selected = null;
    _deadline = null;
    _firedHold = true;
    notifyListeners();
    onFire?.call();
  }

  void _stopTick() {
    _tick?.cancel();
    _tick = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTick();
    onFire = null;
    super.dispose();
  }
}

/// "14:05" / "1:02:09": the remaining time as the player's labels show
/// it. Rounded UP to the second, so a fresh 15-minute timer reads 15:00
/// and the label reaches 0:00 only when the timer fires.
String formatSleepRemaining(Duration remaining) {
  final totalSeconds = remaining.isNegative
      ? 0
      : (remaining.inMilliseconds / 1000).ceil();
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}
