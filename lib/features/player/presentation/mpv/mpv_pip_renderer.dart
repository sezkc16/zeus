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
    phase == MpvRendererPhase.toSoftware || phase == MpvRendererPhase.software;

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

// ---------------------------------------------------------------------------
// Build 74: the renderer is swapped under the SAME engine.
// ---------------------------------------------------------------------------
//
// Phone result on build 73 (2026-11-18, Avengers 4K, PiP mode mpv):
// the PiP window opened at once but stayed black for as long as it was
// up, and the return sat 10 s (once 25 s) on the held picture before
// the film played.
//
// Both are the same thing: every move was a second engine and a fresh
// open of the source, and on that host an open takes many seconds —
// the new engine's overlay read `cache: 0.000000s 1 KiB/s` with no
// decoded frame for the whole wait. Build 73 only hid that: the
// software engine's texture was pre-sized, so "it has a picture" was
// true 154 ms in, before a single frame existed, and the window opened
// on an empty layer.
//
// Build 74 does not open anything. The native side frees the current
// mpv render context and creates the other renderer's on the same core
// (libmpv allows one at a time, not one for ever); mpv answers the free
// by shutting its video chain down while audio, the demuxer and the
// connection keep running; the screen then sets `hwdec` for the new
// renderer and switches the video track back on, which mpv brings up
// on the new context with one seek in the stream it already has open.
// The re-open move of builds 72/73 stays as the fallback.

/// How a renderer move is carried out.
enum RendererMoveRoute {
  /// Same engine, the other renderer (build 74).
  inPlace,

  /// A second engine and a re-open of the source (builds 72/73).
  reopen,
}

/// The route a move tries first.
///
/// In place whenever the same stream stays: a PiP quality drop that is
/// already in force ([qualityDropped]) opened a different file, and
/// getting back to the original one is a re-open by definition.
RendererMoveRoute rendererMoveRoute({required bool qualityDropped}) =>
    qualityDropped ? RendererMoveRoute.reopen : RendererMoveRoute.inPlace;

/// The value `vid` is set back to after the swap: the track that was
/// selected (mpv reports its number), else `auto`.
///
/// mpv reads `no` once the render context is freed — that is the free
/// working, not a selection to keep.
String inPlaceVideoTrack(String? raw) {
  final value = (raw ?? '').trim();
  final id = int.tryParse(value);
  return id != null && id > 0 ? '$id' : 'auto';
}

/// Whether mpv's `vo-configured` says the video output has been set up
/// for a decoded frame — the one honest "there is a picture" signal.
/// A texture size is not: a fixed-size software texture has one before
/// any frame exists (build 73's black PiP window).
bool voConfigured(String? raw) {
  final value = (raw ?? '').trim().toLowerCase();
  return value == 'yes' || value == 'true';
}

/// Why a move is still waiting for its picture, for the QoE overlay:
/// the video output, the buffer ahead, whether mpv is paused for the
/// buffer and the download rate — together they say "no data" apart
/// from "data but no frame".
String switchWaitReason({
  required String? voConfiguredRaw,
  required String? cacheSeconds,
  required String? pausedForCache,
  required String? cacheSpeed,
}) {
  final cache = double.tryParse(cacheSeconds ?? '');
  final speed = double.tryParse(cacheSpeed ?? '');
  final parts = <String>[
    'vo=${voConfigured(voConfiguredRaw) ? 'yes' : 'no'}',
    'cache=${cache == null ? '?' : cache.toStringAsFixed(1)}s',
    'net=${speed == null ? '?' : (speed / 1024).toStringAsFixed(0)}K',
    'pfc=${voConfigured(pausedForCache) ? 'yes' : 'no'}',
  ];
  return parts.join(' ');
}

/// The QoE overlay's line for the last PiP window's feed, read from
/// the native plugin's diagnostic string when the window closes:
/// frames the software renderer handed over (`in`), frames that
/// reached the window (`shown`), frames dropped on the way (`drop`),
/// how often the layer failed, and the last software render time.
///
/// `in 0` = the renderer drew nothing (no data, or no video chain);
/// `in` high with `shown 0` = the window's layer refused the frames.
String pipFeedLine(String? diag) {
  final text = diag ?? '';
  String field(String key) {
    final match = RegExp('(?:^|\\s)$key=(\\S+)').firstMatch(text);
    return match?.group(1) ?? '?';
  }

  if (text.trim().isEmpty) return 'pip-feed: -';
  return 'pip-feed: in ${field('ingest')} shown ${field('liveEnq')} '
      'drop ${field('liveDrop')} fail ${field('layerFail')} '
      'render ${field('rendMs')}ms';
}

// ---------------------------------------------------------------------------
// Build 75: the picture wait after an in-place swap is bounded and split.
// ---------------------------------------------------------------------------
//
// Phone result on build 74 (2026-11-18, Avengers 4K): the swap itself
// took 0.06–0.28 s, but the wait for the first picture after it took
// 2.6–9.5 s, with the buffer ahead reading ~0 s for the whole wait.
//
// Read from the mpv 0.36.0 source the app ships (not from memory):
//  * freeing the render context deselects the video track
//    (client.c `do_kill` → `error_on_track`), and a deselected track's
//    packets are thrown away (demux.c `update_stream_selection_state`);
//  * selecting it again runs `initiate_refresh_seek`, which clears the
//    queues of EVERY stream (the audio buffer ahead too) and seeks the
//    source itself to one second before the playhead — a new range
//    request, never served from the buffer;
//  * the new video chain then decodes and drops frames until it
//    reaches the playhead (video.c `video_output_image`).
// So one request to the host per swap cannot be avoided on this
// engine. What could: build 74 left the film playing, so the picture
// was chasing a playhead that kept moving while the data came in at
// about the speed it plays. Build 75 pauses for the move — the target
// stands still — and plays again the moment the picture is there.

/// Whether the film is paused for the length of an in-place move.
/// Only a playing film: one already paused has a still target.
bool pauseForInPlaceMove({required bool playing}) => playing;

/// What the picture wait of an in-place move was spent on.
class SwitchWaitSplit {
  const SwitchWaitSplit({
    required this.netMs,
    required this.decodeMs,
    required this.backBytes,
    required this.fetchedBytes,
  });

  /// From "video track on" to the first packet after the source seek
  /// (the host answering the range request). Null: never seen.
  final int? netMs;

  /// From that first packet to the first picture.
  final int? decodeMs;

  /// How far behind the reader the seek landed.
  final int? backBytes;

  /// Bytes read past the landing point until the picture.
  final int? fetchedBytes;
}

/// Splits the picture wait from the reader-position samples taken
/// while waiting. [samples] are (ms since the video track was switched
/// on, mpv `stream-pos`), oldest first; [beforePos] is `stream-pos`
/// just before it. The seek has landed at the first sample that lies
/// behind [beforePos]; [frameMs] is when the picture was there.
SwitchWaitSplit splitSwitchWait({
  required int? beforePos,
  required List<(int, int)> samples,
  required int frameMs,
}) {
  if (beforePos == null) {
    return const SwitchWaitSplit(
      netMs: null,
      decodeMs: null,
      backBytes: null,
      fetchedBytes: null,
    );
  }
  for (var i = 0; i < samples.length; i++) {
    final (ms, pos) = samples[i];
    if (pos < beforePos) {
      final last = samples.last.$2;
      return SwitchWaitSplit(
        netMs: ms,
        decodeMs: frameMs > ms ? frameMs - ms : 0,
        backBytes: beforePos - pos,
        fetchedBytes: last > pos ? last - pos : 0,
      );
    }
  }
  return const SwitchWaitSplit(
    netMs: null,
    decodeMs: null,
    backBytes: null,
    fetchedBytes: null,
  );
}

String _megabytes(int? bytes) =>
    bytes == null ? '?' : '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';

String _seconds(String? raw) {
  final value = double.tryParse((raw ?? '').trim());
  return value == null ? '?' : value.toStringAsFixed(1);
}

/// The QoE overlay's second line for the last in-place move: where the
/// picture wait went. `net` — the host answering; `dec` — reading and
/// decoding up to the playhead; `back` — how far back the source seek
/// went; `got` — how much was read for it; `cache a>b` — the buffer
/// ahead before the move and at the picture; `paused` — whether the
/// film was held for the move.
String switchDetailLine({
  required SwitchWaitSplit? split,
  required String? cacheBefore,
  required String? cacheAfter,
  required bool paused,
}) {
  if (split == null) return 'switch-wait: -';
  return 'switch-wait: net ${split.netMs ?? '?'} dec ${split.decodeMs ?? '?'} '
      'back ${_megabytes(split.backBytes)} got ${_megabytes(split.fetchedBytes)} '
      'cache ${_seconds(cacheBefore)}>${_seconds(cacheAfter)}s '
      'paused ${paused ? 'yes' : 'no'}';
}

// ---------------------------------------------------------------------------
// Build 76: the split of the picture wait, measured for real.
// ---------------------------------------------------------------------------
//
// Phone result on build 75: `switch-wait: net ? dec ? back ? got ?` on
// every move. Cause, read from the mpv 0.36.0 source: build 75 looked
// for mpv's `stream-pos` jumping BACK when the source seek landed. But
// `stream-pos` is `demuxer->filepos`, the file offset of the last
// packet HANDED TO A DECODER, and it is only ever raised
// (demux.c: `if (pkt->pos >= in->d_user->filepos) filepos = pkt->pos`);
// the refresh seek of a track switch does not reset it. It never goes
// back, so no sample was ever "behind" and nothing was measured.
//
// What does move is the reader's own state, `demuxer-cache-state`: the
// count of source seeks (`debug-low-level-seeks`), of requests at the
// byte level (`debug-byte-level-seeks`), and the bytes held ahead
// (`fw-bytes`), which the seek empties and the first data fills again.

/// One reading of mpv's `demuxer-cache-state` while a move waits.
class DemuxSample {
  const DemuxSample({
    required this.ms,
    required this.lowLevelSeeks,
    required this.byteLevelSeeks,
    required this.forwardBytes,
    required this.totalBytes,
  });

  /// Since the video track was switched back on.
  final int ms;
  final int? lowLevelSeeks;
  final int? byteLevelSeeks;
  final int? forwardBytes;
  final int? totalBytes;
}

int? _jsonInt(String json, String key) {
  final match = RegExp('"${RegExp.escape(key)}"\\s*:\\s*(-?\\d+)')
      .firstMatch(json);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Reads [raw] — `demuxer-cache-state` as mpv prints it (JSON) — into
/// a sample taken [ms] into the wait. Null when it is not that.
DemuxSample? parseDemuxState(String? raw, {required int ms}) {
  final json = (raw ?? '').trim();
  if (!json.startsWith('{')) return null;
  final sample = DemuxSample(
    ms: ms,
    lowLevelSeeks: _jsonInt(json, 'debug-low-level-seeks'),
    byteLevelSeeks: _jsonInt(json, 'debug-byte-level-seeks'),
    forwardBytes: _jsonInt(json, 'fw-bytes'),
    totalBytes: _jsonInt(json, 'total-bytes'),
  );
  if (sample.forwardBytes == null && sample.totalBytes == null) return null;
  return sample;
}

/// Where the picture wait of a move went, from the reader's state.
class SwitchWait {
  const SwitchWait({
    required this.netMs,
    required this.decodeMs,
    required this.gotBytes,
    required this.seeks,
    required this.requests,
  });

  /// From "video track on" until the first data after the source seek
  /// is in the buffer — the host answering. Null: not seen.
  final int? netMs;

  /// From that first data to the first picture.
  final int? decodeMs;

  /// What the reader held at the picture (all of it read for the move:
  /// the seek emptied the buffer).
  final int? gotBytes;

  /// Source seeks the move cost, and requests at the byte level.
  final int? seeks;
  final int? requests;
}

/// Splits the wait. [before] is the reading just before the video
/// track was switched back on, [samples] those taken while waiting
/// (oldest first), [frameMs] when the picture was there.
///
/// The data "after the seek" is the first sample that holds bytes
/// ahead once the seek has been seen — the seek counter above
/// [before]'s, or the buffer seen empty.
SwitchWait splitSwitchWaitByDemux({
  required DemuxSample? before,
  required List<DemuxSample> samples,
  required int frameMs,
}) {
  if (samples.isEmpty) {
    return const SwitchWait(
      netMs: null,
      decodeMs: null,
      gotBytes: null,
      seeks: null,
      requests: null,
    );
  }
  final seeksBefore = before?.lowLevelSeeks;
  var seekSeen = false;
  int? netMs;
  for (final sample in samples) {
    final seeks = sample.lowLevelSeeks;
    if (!seekSeen) {
      if ((seeksBefore != null && seeks != null && seeks > seeksBefore) ||
          (sample.forwardBytes ?? -1) == 0) {
        seekSeen = true;
      }
    }
    if (seekSeen && (sample.forwardBytes ?? 0) > 0) {
      netMs = sample.ms;
      break;
    }
  }
  final last = samples.last;
  int? delta(int? now, int? then) =>
      now == null || then == null ? null : now - then;
  return SwitchWait(
    netMs: netMs,
    decodeMs: netMs == null ? null : (frameMs > netMs ? frameMs - netMs : 0),
    gotBytes: last.totalBytes ?? last.forwardBytes,
    seeks: delta(last.lowLevelSeeks, before?.lowLevelSeeks),
    requests: delta(last.byteLevelSeeks, before?.byteLevelSeeks),
  );
}

/// The QoE overlay's second line for the last in-place move (build
/// 76): `net` — ms until the host's first data after the seek; `dec` —
/// ms from there to the picture; `got` — what was read for it; `seek
/// a/b` — source seeks / byte-level requests the move cost; `cache
/// a>b` — the buffer ahead before the move and at the picture;
/// `paused` — whether the film was held for the move. [extra] is
/// appended as is (build 76's keyframe landing).
String switchWaitLine({
  required SwitchWait? wait,
  required String? cacheBefore,
  required String? cacheAfter,
  required bool paused,
  String extra = '',
}) {
  if (wait == null) return 'switch-wait: -';
  return 'switch-wait: net ${wait.netMs ?? '?'} dec ${wait.decodeMs ?? '?'} '
      'got ${_megabytes(wait.gotBytes)} '
      'seek ${wait.seeks ?? '?'}/${wait.requests ?? '?'} '
      'cache ${_seconds(cacheBefore)}>${_seconds(cacheAfter)}s '
      'paused ${paused ? 'yes' : 'no'}$extra';
}

// ---------------------------------------------------------------------------
// Build 76: the picture comes back on a keyframe.
// ---------------------------------------------------------------------------
//
// Phone result on build 75 (Avengers 4K): the picture wait was still
// 11.6 s / 4.9 s / 1.8 s — holding the film did not shorten it.
//
// Read from the mpv 0.36.0 source: a video track switched on in a
// running film is brought in by a refresh seek to one second BEFORE
// the playhead (demux.c `initiate_refresh_seek`: `start_ts -= 1.0`),
// which the demuxer rounds down to the keyframe before that; the new
// video chain then decodes every frame from that keyframe and throws
// each away until it reaches the playhead (video.c
// `video_output_image`: "video was just enabled via track switching -
// skip to current time"). All of that data has to arrive, and all of
// those frames have to be decoded, before one picture is shown.
//
// A keyframe seek (`seek <t> absolute+keyframes`, playloop.c `mp_seek`
// with no SEEK_FORWARD) lands on the keyframe at or before the
// playhead and shows THAT frame: the first picture is the first
// keyframe that arrives. The film then continues from the keyframe —
// a jump back of at most one keyframe interval, never forward. The
// viewer accepted that trade (2026-11-18). What it cannot remove: the
// track switch has already emptied the buffer, so the host still has
// to answer one request.

/// Whether the move lands on a keyframe: a film with a known place
/// that can be seeked. A live stream is left to mpv's own refresh.
bool keyframeLandingForMove({
  required bool seekable,
  required Duration? position,
}) => seekable && position != null && position > Duration.zero;

/// The mpv command that lands on the keyframe at or before [position].
List<String> keyframeSeekCommand(Duration position) => <String>[
  'seek',
  (position.inMilliseconds / 1000).toStringAsFixed(3),
  'absolute+keyframes',
];

/// mpv's `time-pos` as a place in the film, or null.
Duration? mpvTimePos(String? raw) {
  final seconds = double.tryParse((raw ?? '').trim());
  if (seconds == null || !seconds.isFinite || seconds < 0) return null;
  return Duration(milliseconds: (seconds * 1000).round());
}

/// The overlay's note on the keyframe landing, appended to the
/// `switch-wait` line: ` key -1.8s` — the film continued 1.8 s before
/// where it was; ` key ?` — landed, place not read; ` key off` — not
/// used (mpv's own refresh brought the picture).
String keyframeLandingNote({
  required bool used,
  required Duration? before,
  required Duration? after,
}) {
  if (!used) return ' key off';
  if (before == null || after == null) return ' key ?';
  final delta = (after - before).inMilliseconds / 1000;
  final sign = delta > 0 ? '+' : '';
  return ' key $sign${delta.toStringAsFixed(1)}s';
}

// ---------------------------------------------------------------------------
// Build 79: the film continues from exactly where it was.
// ---------------------------------------------------------------------------
//
// Build 76's keyframe landing made the film continue from the keyframe
// before the playhead — 1.3–1.4 s earlier on the phone. It was there to
// keep the host's answer short. Since build 77/78 the bytes around the
// playhead are still on the phone (the stream cache proxy), so the
// request after the move costs no host round trip, and the film can
// land on the very frame it stopped on.
//
// Read from the mpv 0.36.0 source, the two ways to get there:
//  * leave it to mpv's own refresh (build 75): the source is seeked to
//    one second BEFORE the playhead (demux.c `initiate_refresh_seek`),
//    and video.c skips to the playhead without telling the decoder
//    (no `mp_decoder_wrapper_set_start_pts`): every frame of that
//    second and of the keyframe interval before it is fully decoded.
//  * `seek <t> absolute+exact` (playloop.c `mp_seek`, hr-seek): the
//    source is seeked to the keyframe at or before the playhead itself
//    (`hr-seek-demuxer-offset` is 0) — the same request the keyframe
//    landing makes, one request measured on the phone — and the
//    decoder is told the target (`hr-seek-framedrop`, on by default),
//    so it may skip frames nothing depends on. Frames before the
//    target never reach the screen (video.c drops them before the
//    output is configured), so the held picture stays until the exact
//    frame is drawn.
// The second is the shorter one, and is what is sent.

/// Whether the move may land exactly on the playhead: the film is on
/// the proxy, and what the phone holds reaches back past the playhead.
///
/// [behind] is what the proxy holds before the player's reading point
/// (bytes); [forwardBytes] what the player had read ahead of the
/// playhead. The playhead's own bytes are that far behind the reading
/// point, plus a margin for what sits in between unseen (socket and
/// stream buffers, container overhead). Anything unknown: no.
bool exactLandingForMove({
  required bool proxyServing,
  required int? behind,
  required int? forwardBytes,
}) {
  if (!proxyServing || behind == null || forwardBytes == null) return false;
  if (behind <= 0 || forwardBytes < 0) return false;
  const margin = 8 * 1024 * 1024;
  return behind >= forwardBytes + forwardBytes ~/ 32 + margin;
}

/// The mpv command that lands exactly on [position].
List<String> exactSeekCommand(Duration position) => <String>[
  'seek',
  (position.inMilliseconds / 1000).toStringAsFixed(3),
  'absolute+exact',
];

/// The overlay's note on an exact landing, appended to the
/// `switch-wait` line: ` exact +0.00s` — how far from where the film
/// was it continued (0 = the same frame); ` exact ?` — place not read.
String exactLandingNote({
  required Duration? before,
  required Duration? after,
}) {
  if (before == null || after == null) return ' exact ?';
  final delta = (after - before).inMilliseconds / 1000;
  final sign = delta < 0 ? '' : '+';
  return ' exact $sign${delta.toStringAsFixed(2)}s';
}
