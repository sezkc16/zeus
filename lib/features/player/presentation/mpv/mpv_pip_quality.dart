/// iOS mpv PiP quality (+31): while the PiP window is up, the app is
/// backgrounded and iOS throttles its CPU hard — the software renderer
/// writing full-res frames plus the tap's downscale cannot keep up, so
/// the window runs at ~1 frame per 5 s and the voice stutters too (the
/// same throttling starves mpv's audio decoder). The fix is to cut the
/// work at the source: drop to a light stream while PiP is up and
/// restore the original when it stops. The PiP window is small (the
/// feed is downscaled to ~640 px wide anyway), so 480p is plenty.
///
/// The decision is pure: given the stream ladder, the stream now
/// playing, and the ceiling, it returns the stream to drop to, or
/// null when no drop is wanted. The screen acts on it (see
/// `_dropQualityForPip` / `_restoreQualityAfterPip` in
/// `mpv_player_screen.dart`).
library;

import 'mpv_thermal_quality.dart';

/// The tallest stream PiP plays: 360p. A 1080p render+downscale is
/// ~9x the work of a 360p one; 480p would be ~1.8x. The window is
/// small, so the extra softness over 480p is invisible.
const int kPipMaxHeight = 360;

/// The stream to drop to while PiP is up, or null when no drop is
/// wanted: already at or below the ceiling, an adaptive (HLS) master
/// with no ladder (quality null/0 — mpv's ABR owns it), no lighter
/// stream, or a bad index. The target is the tallest stream at or
/// below the ceiling, else the tallest one below the current stream
/// (the same ladder the thermal governor walks, see
/// `bestLighterStreamIndex`).
int? pipQualityDropTarget({
  required List<int?> qualities,
  required int currentIndex,
  int maxHeight = kPipMaxHeight,
}) {
  if (currentIndex < 0 || currentIndex >= qualities.length) return null;
  final currentHeight = qualities[currentIndex];
  if (currentHeight == null || currentHeight <= 0) return null;
  if (currentHeight <= maxHeight) return null;
  final target = bestLighterStreamIndex(qualities, currentHeight, maxHeight);
  if (target == null || target == currentIndex) return null;
  return target;
}

/// The render-cap target the PiP and thermal caps agree on (+35 P1,
/// +47 PiP 540p).
///
/// The PiP cap and the thermal cap share one actuation (the fork's
/// `VideoController.setSize` — see `_setIosRenderCap` in
/// `mpv_player_screen.dart`), so the target is always the min of the
/// two: PiP up takes 960x540 (the 22GB 4K file still lagged in the PiP
/// window on the 1080p cap), thermal alone keeps 1080p; only both
/// clear restores full size.
enum PipRenderCap {
  /// Render at the source's native size.
  full,

  /// Cap the render target at 1920x1080.
  capped1080p,

  /// Cap the render target at 960x540 (+47): the PiP cap. A quarter
  /// of the 1080p cap's pixels (a sixteenth of 4K) — the feed is
  /// ~640 px wide, so nothing visible is lost, and the in-app texture
  /// is invisible while the app is backgrounded.
  capped540p,
}

/// The render-cap target for the current PiP/thermal state (+35 P1).
///
/// Pure: the screen acts on it (see `_applyPipRenderCap` /
/// `_restorePipRenderCap` in `mpv_player_screen.dart`). Sources at or
/// below 1080p never cap — there is nothing to shrink — and an unknown
/// height (`0`, e.g. an adaptive master) is treated the same way, the
/// same conservatism as the thermal governor.
PipRenderCap pipRenderCapTarget({
  required bool pipUp,
  required bool thermalLightened,
  required int sourceHeight,
}) {
  if (sourceHeight <= 1080) return PipRenderCap.full;
  // The min of the two caps: PiP takes 540p, thermal alone 1080p.
  if (pipUp) return PipRenderCap.capped540p;
  if (thermalLightened) return PipRenderCap.capped1080p;
  return PipRenderCap.full;
}
