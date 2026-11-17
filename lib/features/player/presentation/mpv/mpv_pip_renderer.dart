/// On-demand PiP renderer for the iOS mpv engine (build 72).
///
/// Until build 71, PiP mode "mpv" opened the whole session on the
/// software renderer (`enableHardwareAcceleration: false`,
/// `hwdec: videotoolbox-copy`), because the PiP window can only be fed
/// from software-rendered frames. A heavy 4K file then dropped about a
/// second of frames every second from the first frame, PiP or not
/// (phone proof 2026-11-18: `videotoolbox-copy`, `vo-drop +24` per
/// second at 24 fps).
///
/// Build 72: the player ALWAYS opens on the hardware renderer. Only a
/// tap on the PiP button moves it to the software renderer, and the end
/// of PiP moves it back. libmpv allows one render context per core and
/// the fork's `VideoOutput` picks its texture once, so a move is a new
/// `Player` + `VideoController` and a re-open of the same source at the
/// same position — never an in-place switch.
///
/// Everything here is pure, so the rules are unit-tested (see
/// `mpv_pip_renderer_test.dart`); the screen acts on them.
library;

import 'mpv_ios_options.dart';

/// Where the on-demand renderer is.
enum MpvRendererPhase {
  /// Normal playback: hardware renderer, `videotoolbox`.
  hardware,

  /// Moving to the software renderer for a PiP start.
  toSoftware,

  /// On the software renderer: the PiP window is up, or about to be.
  software,

  /// Moving back to the hardware renderer after PiP.
  toHardware,
}

/// Whether a move is in flight (the held frame is on screen).
bool rendererSwitching(MpvRendererPhase phase) =>
    phase == MpvRendererPhase.toSoftware ||
    phase == MpvRendererPhase.toHardware;

/// Whether the engine that exists (or is being created) in [phase] is
/// the software renderer.
bool rendererIsSoftware(MpvRendererPhase phase) =>
    phase == MpvRendererPhase.toSoftware ||
    phase == MpvRendererPhase.software;

/// The `hwdec` value the engine of [phase] is created with.
String rendererHwdec(MpvRendererPhase phase) =>
    mpvIosHwdec(pipEnabled: rendererIsSoftware(phase));

/// Whether the build-71 Home → return logic (the paused decoder
/// refresh, the hardware-decode watch, the +55/+56 resume and 4K
/// re-open) may act on a `resumed`.
///
/// Never during a move (the engine is being replaced), and never on a
/// return that had a PiP window up when the app went away: that return
/// is the PiP end, which either keeps the software session playing or
/// moves back to hardware itself. Phone proof 2026-11-18 (build 71,
/// PiP mode mpv, 4K): returning from the PiP window showed black +
/// 00:00/LIVE for ~3.5 s — the film was still playing under the
/// window, so the "was playing" snapshot read true for the first time
/// and the +56 4K re-open on return ran.
bool rendererReturnLogicAllowed({
  required MpvRendererPhase phase,
  required bool backgroundedWithPip,
}) {
  if (rendererSwitching(phase)) return false;
  return !backgroundedWithPip;
}

/// What a tap on the PiP button does.
enum PipButtonPlan {
  /// Nothing: a move is already in flight.
  ignore,

  /// Move to the software renderer, then start PiP.
  switchThenEnter,

  /// Already on the software renderer: start PiP.
  enter,
}

PipButtonPlan pipButtonPlan(MpvRendererPhase phase) => switch (phase) {
  MpvRendererPhase.hardware => PipButtonPlan.switchThenEnter,
  MpvRendererPhase.software => PipButtonPlan.enter,
  MpvRendererPhase.toSoftware ||
  MpvRendererPhase.toHardware => PipButtonPlan.ignore,
};

/// What to do when PiP is over (the window closed, the start failed, or
/// the app came back to the foreground on the software session).
enum PipEndPlan {
  /// Nothing to do: already on (or moving to) hardware, or the window
  /// is still up.
  none,

  /// Keep playing on the software session — no re-open at all, the
  /// window just grows back into the player (user 2026-11-18: "direct
  /// play ho, PiP bada hoke"). For everything below 4K: the software
  /// renderer carries it in fullscreen (build 71 and earlier ran whole
  /// sessions that way). The next player open starts on hardware.
  stayOnSoftware,

  /// Move back to the hardware renderer now (4K: the software renderer
  /// drops about a second of frames per second in fullscreen; or the
  /// PiP quality drop moved to a lighter stream and the original has
  /// to be re-opened anyway).
  switchNow,

  /// As [switchNow], but the app is not in the foreground: GPU work is
  /// not allowed there, so pause and move back on the next `resumed`.
  pauseAndDefer,
}

PipEndPlan pipEndPlan({
  required MpvRendererPhase phase,
  required bool pipWindowUp,
  required bool appResumed,
  required bool needsHardware,
}) {
  if (phase != MpvRendererPhase.software) return PipEndPlan.none;
  if (pipWindowUp) return PipEndPlan.none;
  if (!needsHardware) return PipEndPlan.stayOnSoftware;
  return appResumed ? PipEndPlan.switchNow : PipEndPlan.pauseAndDefer;
}

/// Whether the session has to go back to the hardware renderer after
/// PiP: a 4K picture, or a PiP quality drop that has to be undone.
bool pipEndNeedsHardware({required bool is4K, required bool qualityDropped}) =>
    is4K || qualityDropped;

/// The phase a move ends in. A move to software that failed falls back
/// to hardware; a move to hardware always ends on hardware (there is
/// nothing else to fall back to — a failure there is a failed player).
MpvRendererPhase rendererPhaseAfterSwitch({
  required bool toSoftware,
  required bool succeeded,
}) => toSoftware && succeeded
    ? MpvRendererPhase.software
    : MpvRendererPhase.hardware;

/// What a move carries from the old engine to the new one.
class RendererCarryOver {
  const RendererCarryOver({
    required this.position,
    required this.duration,
    required this.wasPlaying,
    required this.rate,
    required this.volume,
    required this.streamIndex,
  });

  final Duration position;
  final Duration duration;
  final bool wasPlaying;
  final double rate;
  final double volume;
  final int streamIndex;

  /// Where the new engine opens. Never negative; an unknown or zero
  /// position opens from the start (null = no `start`).
  Duration? get start => position > Duration.zero ? position : null;

  /// Whether the new engine plays once its pre-buffer is in. A move to
  /// software always plays: the PiP window needs frames to start. A
  /// move back keeps what the film was doing.
  bool autoPlay({required bool toSoftware}) => toSoftware || wasPlaying;

  /// The rate to re-apply, or null when it is the default.
  double? get rateToApply => (rate - 1.0).abs() < 0.001 ? null : rate;
}

/// The QoE overlay's renderer line.
String rendererOverlayLine(MpvRendererPhase phase, {required bool onDemand}) {
  if (!onDemand) return 'renderer: hw';
  return switch (phase) {
    MpvRendererPhase.hardware => 'renderer: hw',
    MpvRendererPhase.software => 'renderer: sw(pip)',
    MpvRendererPhase.toSoftware => 'renderer: switching > sw(pip)',
    MpvRendererPhase.toHardware => 'renderer: switching > hw',
  };
}

// ---------------------------------------------------------------------------
// Build 73: the fast move, the small PiP render, no automatic PiP.
// ---------------------------------------------------------------------------
//
// Phone result on build 72 (2026-11-18, Avengers 4K, PiP mode mpv):
// the return from the PiP window sat ~14 s on a frozen picture with
// the play icon, flashed black once, and only then played on hardware;
// the PiP window itself stuttered (`vo-drop +48` per 2 s with a
// 3840x2160 software texture); and after that first round trip a plain
// Home swipe opened a PiP window by itself.
//
// Build 73: a move no longer waits on the outgoing engine at all (no
// awaited pause, no screenshot, no awaited dispose, no pre-buffer
// hold) — the old engine's own picture stays on screen until the new
// engine has drawn a frame; a 4K film is software-rendered small; and
// the native PiP controller only exists between the button and the end
// of that window.

/// A software render size: width x height in pixels.
class RenderSize {
  const RenderSize(this.width, this.height);
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is RenderSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// The width a 4K film is software-rendered at. The PiP feed is at
/// most 640 px wide (`maxPipWidth` in the native plugin); 960 leaves
/// the in-player moments either side of the window (before it opens,
/// after it closes, until the move back to hardware) watchable.
const int kSoftwareRenderWidth4K = 960;

/// The size the SOFTWARE renderer draws at, or null for the video's
/// own size.
///
/// Only a 4K picture ([is4K] — the same test that sends the session
/// back to hardware after PiP, see [pipEndNeedsHardware]) is shrunk:
/// the software renderer cannot keep up with it (phone proof: about a
/// second of frames dropped every second), and a 4K film is only on
/// the software renderer for the PiP window and the moments around
/// it. Everything below 4K keeps its own size, because below 4K the
/// session STAYS on the software renderer after PiP and is watched
/// full screen on it.
///
/// The aspect of the video is kept (a scope picture is not squeezed
/// into 16:9) and both sides are even.
RenderSize? softwareRenderSize({
  required int? videoWidth,
  required int? videoHeight,
  required bool is4K,
  int targetWidth = kSoftwareRenderWidth4K,
}) {
  if (!is4K) return null;
  final w = videoWidth ?? 0;
  final h = videoHeight ?? 0;
  if (w <= 0 || h <= 0) return null;
  if (w <= targetWidth) return null;
  var outH = (h * targetWidth / w).round();
  if (outH.isOdd) outH += 1;
  if (outH < 2) outH = 2;
  return RenderSize(targetWidth, outH);
}

/// Whether the native PiP bridge (controller, layer, frame tap) may
/// exist. Only while a window is being opened or is up: with no
/// controller iOS has nothing to bring back on a Home swipe, which is
/// what "PiP only from the button" needs.
bool pipBridgeWanted({required bool entering, required bool windowUp}) =>
    entering || windowUp;

/// Whether the film pauses when the PiP window goes away.
///
/// [restored] — the viewer tapped the window to come back into the
/// player: the film keeps going, whatever the lifecycle says at that
/// instant (iOS reports the stop a beat before the app is `resumed`,
/// and Flutter replays `hidden` on the way back in; build 72 paused
/// there — the play icon in the phone recording). Otherwise the window
/// was closed with X while the app is in the background: nothing is
/// showing the film, so it pauses.
bool pipEndPauses({required bool restored, required bool appForeground}) =>
    !restored && !appForeground;

/// The QoE overlay's line for the last move: how long each step took,
/// in milliseconds — the phone test's proof of where the time goes.
String switchTimingLine({
  required String direction,
  required Map<String, int> steps,
  required String outcome,
}) {
  if (direction.isEmpty) return 'switch: -';
  final parts = steps.entries.map((e) => '${e.key} ${e.value}').join(' ');
  final total = steps.values.fold<int>(0, (a, b) => a + b);
  return 'switch $direction: $parts = ${total}ms $outcome'.trimRight();
}
