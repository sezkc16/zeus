/// The mpv options iOS gets, on top of the stock `hwdec: videotoolbox`.
///
/// Evidence: Nuvio (public source, `NuvioMedia/NuvioMobile`,
/// `iosApp/iosApp/Player/MPVPlayerBridge.swift`, `setupMpv()`) sets
/// `hwdec-software-fallback: 300` on iOS, with the comment that iOS can
/// invalidate the VideoToolbox session — e.g. Notification Center during
/// PiP — and FFmpeg recreates it at the next frames; keep hardware
/// decoding meanwhile. ZoroX copied the 300 (+40), but mpv's manual
/// says the default is 3 and a higher number is harmful: the fallback
/// only triggers after N consecutive failed frames, so 300 tolerates
/// ~12 s of failed decoding before falling back to software — and when
/// it finally falls back, the failed packets are SKIPPED ("parts of the
/// file will be skipped, approximately by to the number of packets that
/// could not be decoded"). That matches the user's +48 symptom exactly
/// (timestamp frozen ~5 s, then a ~10 s jump). +49 returns to mpv's
/// default of 3: a dead session falls back to software after 3 failed
/// frames (~125 ms), and mpv retains the packets, so there is no skip.
/// The hwdec restore on resume (+40 P4) — and, when it fires, the
/// stall-fallback re-open (see [shouldResyncDecoderOnResume]) — brings
/// the hardware decoder back, so a software fallback is only ever a
/// brief bridge, never the rest of the file.
///
/// `framedrop: vo` is mpv's recommended mode (+34, was `decoder+vo`):
/// when a frame cannot be presented in time it is dropped instead of
/// stalling the clock, so a hot phone stutters briefly rather than
/// falling behind and never catching up. mpv's manual calls `vo` "the
/// recommended mode, and the default" and says `decoder+vo` is "Not
/// recommended" — the decoder side also skips frames, which costs
/// decode work for nothing when the bottleneck is the render.
///
/// `cache-secs: 3600` (+55, was 60 in +54) and `demuxer-max-bytes:
/// 768MiB` (+55, was 512MiB in +54): how far ahead the network cache
/// pre-buffers. mpv's default `cache-secs` is 10, so it only prefetched
/// ~10 s ahead of the playhead — on a slow or uneven line that cushion
/// drains in seconds and the player stalls (user report 2026-11-16:
/// "buffer bohot jaldi karey agey ka"). +54 raised it to 60 s, but the
/// user wants NO time cap at all (2026-11-16: "60 sec nahi jitna sync
/// karsakega jitne time tak hota rehe"): 3600 s (one hour) means time
/// never limits the buffer in practice — mpv reads ahead until the
/// byte cap stops it, i.e. as much as it can sync. The byte cap is the
/// real limit now, and it is also the safety valve: the cache lives in
/// RAM, and a cap so large that iOS jetsam-kills the app would be worse
/// than a stall. 768 MiB holds ~2 min at 50 Mbit/s peak 4K, ~4 min at
/// 25 Mbit/s, ~10-13 min at 8-10 Mbit/s 1080p — far beyond the 60 s the
/// user rejected — while keeping the app's total footprint well under
/// the jetsam limit even on 4 GB phones (his members), and comfortably
/// so on the user's 8 GB iPhone 15 Pro Max. It is also the size
/// media_kit already aspired to at player creation (`kMpvBufferSize`),
/// so it is not a new appetite, just the effective one. Costs only RAM
/// (a cap, not an allocation — mpv allocates what arrives). Note the
/// effective byte cap was 256 MiB, not the 768 MiB media_kit sets at
/// player creation: this file's setProperty runs after creation and
/// overwrites it. `demuxer-readahead-secs` is NOT set: under the cache
/// it is ignored (`cache-secs` overrides it when larger), so it would
/// be a no-op. `cache-pause-initial` is NOT set either: the Dart-side
/// pre-buffer hold already gates the start, and making mpv wait for a
/// full cache before the first frame would stall the open on a slow
/// source.
///
/// The scaler options (+34, the cheap GPU render layer): `scale` /
/// `cscale` / `dscale: bilinear` is the fastest scaler (the defaults
/// are lanczos / hermite), `deband: no` and `dither-depth: no` skip
/// two GPU passes, `correct-downscaling: no` skips the extra downscale
/// pass, and `tone-mapping: clip` is the cheapest HDR mapping. These
/// are gl_video options, so they apply only in the OpenGL render path
/// (normal playback, PiP OFF) — in the software render path (PiP ON)
/// they are no-ops, and the equivalent cheap knob there would be
/// `sws-scaler` / `sws-fast`. The cost is a little picture quality:
/// bilinear is visibly softer than lanczos on a 4K downscale, and
/// hard-clipped highlights lose rolloff.
///
/// Deliberately NOT here: `video-sync` (heat-irrelevant),
/// `hdr-compute-peak` (blacks the video with `vo=libmpv`, proven in
/// v20+1 — media_kit forces peak compute off), and Nuvio's `vo=gpu-next`
/// + MoltenVK native path (a redesign: ZoroX renders through media_kit's
/// Flutter texture). `tone-mapping` itself is NOT peak compute: it only
/// picks the mapping curve, and `clip` is the cheapest one; peak compute
/// stays off.
library;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../../../settings/presentation/player_settings_provider.dart';

/// The iOS-only mpv options, as `option → value`.
/// The reconnect options (+49): iOS kills the HTTP socket while the app
/// is suspended, so on return mpv sits in a read timeout before it can
/// serve data again — the 5 s freeze + ~10 s catch-up jump the user
/// reported on +48 (Other Mommy 1080p, PiP OFF, Home → return, timestamp
/// frozen at 07:13 then jumping to 07:23). The source is a direct HTTP
/// file link, not HLS, and these are FFmpeg http-protocol options, so
/// they apply to it: `reconnect=1` re-establishes a dead socket
/// automatically, `reconnect_streamed=1` covers streamed variants, and
/// `reconnect_delay_max=2` caps the retry delay at 2 s. `network-timeout:
/// 5` caps a single read at 5 s so a dead socket fails fast instead of
/// hanging on the OS TCP timeout. They are what makes the plain
/// pause/resume work (+55): on return mpv re-establishes the dead
/// socket itself, no re-open needed — the re-open survives only as the
/// stall fallback (see [shouldResyncDecoderOnResume]). They are also
/// the safety net if a socket dies mid-stream.
const Map<String, String> kMpvIosOptions = <String, String>{
  'hwdec-software-fallback': '3',
  'framedrop': 'vo',
  // Build 72: the read-ahead cache is on whatever mpv's own guess
  // about the stream is (`auto` enables it only for what it detects
  // as a network stream); the limits below then always apply.
  'cache': 'yes',
  'demuxer-max-bytes': '768MiB',
  'cache-secs': '3600',
  'scale': 'bilinear',
  'cscale': 'bilinear',
  'dscale': 'bilinear',
  'deband': 'no',
  'dither-depth': 'no',
  'correct-downscaling': 'no',
  'tone-mapping': 'clip',
  'stream-lavf-o': 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=2',
  'network-timeout': '5',
};

/// The `hwdec` value for the iOS VideoController.
///
/// PiP mode (+28) uses `'videotoolbox-copy'`: hardware decode with the
/// frames copied to system memory, so the software renderer — the only
/// renderer that can feed a PiP window, because GPU work is not allowed
/// in the background — can read them. Normal mode keeps `'videotoolbox'`.
/// Pure, so it is unit-tested (see `mpv_ios_pip_test.dart`).
String mpvIosHwdec({required bool pipEnabled}) =>
    pipEnabled ? 'videotoolbox-copy' : 'videotoolbox';

/// Whether the VideoToolbox session is lost, from the live
/// `hwdec-current` read-back (+40 P4).
///
/// `hwdec-current` is the decoder actually in use: `'videotoolbox'`
/// (or `'videotoolbox-copy'` in PiP mode) while the session is alive,
/// empty (or `'no'`) once iOS has invalidated it while the app was
/// backgrounded — the overlay then reads `hwdec:` with nothing after
/// it, and 4K falls back to software decode for the rest of the file
/// (user proof 2026-11-15: Home → return, `vo-drop: 18 (+18)`,
/// `vf-fps: 12`). Either VideoToolbox flavour counts as alive: a
/// `'videotoolbox'` session under a PiP-mode expectation is hardware
/// decode, just without the copy the SW renderer wants, and a
/// `'videotoolbox-copy'` session under a normal expectation is the same
/// hardware decoder. Pure, so it is unit-tested (see
/// `mpv_hwdec_resume_test.dart`).
///
/// Build 71 note: the bundled libmpv is mpv 0.36.0 (read from the
/// shipped Mpv.framework), and that version reports software decode as
/// an EMPTY `hwdec-current`, not `no` — so the empty overlay line means
/// "decoding in software", not "unreadable".
bool hwdecSessionLost({required String current}) {
  const alive = <String>{'videotoolbox', 'videotoolbox-copy'};
  return !alive.contains(current.trim());
}

/// The waits between the hardware-decode checks that follow a Home →
/// return (build 70): each is counted from the previous check (or, for
/// the first, from the moment playback has actually resumed), so the
/// checks land about 1 s, 3 s and 6 s after the film is moving again.
///
/// The first wait is not zero on purpose: `hwdec-current` is empty
/// until the decoder has produced its first frame after a re-open, so
/// reading it at once would call a healthy decoder lost.
const List<Duration> kHwdecResumeCheckDelays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 3),
];

/// Whether the hardware-decode restore may act at all (build 70): only
/// when this film was seen decoding on VideoToolbox before. An empty
/// `hwdec-current` is the NORMAL state of a film that never had
/// hardware decode — the PiP renderer's session read empty while
/// playing normally on the phone (2026-11-18, 1080p, `pip: on`) — and
/// build 69 re-opened the source for it on every return from the PiP
/// window (black, 00:00/LIVE). Nothing was lost there, so nothing is
/// restored. Pure, so it is unit-tested.
bool hwdecRestoreAllowed({required bool seenAlive}) => seenAlive;

/// What one hardware-decode check after a Home → return does.
enum HwdecResumeStep {
  /// The decoder is VideoToolbox: stop checking, touch nothing.
  healthy,

  /// `hwdec-current` could not be read. Not evidence of loss: do
  /// nothing now, and look again at the next check if one is left.
  unreadable,

  /// Lost: switch `hwdec` off and back on in the live player. mpv
  /// re-creates the decoder and seeks in place — the film keeps its
  /// position, no fresh connection, no 00:00.
  cycle,

  /// Still lost on the last check: re-open the stream at the playhead
  /// (the last rung, a fresh decoder).
  reopen,

  /// Still lost on the last check, but the re-open may not run (the
  /// PiP window is up): stop, leave the film playing in software.
  giveUp,
}

/// Decides one hardware-decode check after a Home → return (build 70).
///
/// The phone proof (2026-11-18, 4K, PiP mode iOS): `hwdec: videotoolbox`
/// before Home, `hwdec:` empty after the return and for the rest of the
/// film. The 4K return re-opens the source, and nothing looked at the
/// decoder after that re-open — the only check ran while the film was
/// still paused and stood down. So the decoder is now checked after
/// playback has resumed, [kHwdecResumeCheckDelays].length times at
/// most, and never again once it is healthy.
///
/// [attempt] is the zero-based index of this check. [current] is the
/// live `hwdec-current`, null when the read failed. Every check but the
/// last cycles `hwdec`; the last one re-opens the stream instead, and
/// only when no PiP window is up ([inPip]) — a re-open would tear the
/// window's feed down. Either VideoToolbox flavour is healthy (see
/// [hwdecSessionLost]), so the PiP-mode expectation
/// (`videotoolbox-copy`, see [mpvIosHwdec]) is never "restored" away
/// from a working hardware decoder. Pure, so it is unit-tested (see
/// `mpv_hwdec_resume_test.dart`).
HwdecResumeStep hwdecResumeStep({
  required String? current,
  required int attempt,
  required bool inPip,
}) {
  if (current == null) return HwdecResumeStep.unreadable;
  if (!hwdecSessionLost(current: current)) return HwdecResumeStep.healthy;
  final isLast = attempt >= kHwdecResumeCheckDelays.length - 1;
  if (!isLast) return HwdecResumeStep.cycle;
  return inPip ? HwdecResumeStep.giveUp : HwdecResumeStep.reopen;
}

/// Whether another check follows [step] at [attempt]: only a check that
/// left the decoder unproven ([HwdecResumeStep.unreadable]) or tried a
/// cycle ([HwdecResumeStep.cycle]) is followed up, and only while a
/// check is left. Healthy, re-open and give-up all end the watch — the
/// re-open is the last rung and is never itself followed by another
/// re-open, so the watch cannot loop.
bool hwdecResumeContinues({
  required HwdecResumeStep step,
  required int attempt,
}) {
  final hasNext = attempt + 1 < kHwdecResumeCheckDelays.length;
  switch (step) {
    case HwdecResumeStep.unreadable:
    case HwdecResumeStep.cycle:
      return hasNext;
    case HwdecResumeStep.healthy:
    case HwdecResumeStep.reopen:
    case HwdecResumeStep.giveUp:
      return false;
  }
}

/// What the hardware-decode restore does when the app comes back to
/// the foreground (build 71).
enum HwdecReturnPlan {
  /// Not a return from the background (Control Center, Notification
  /// Center, a call banner): nothing is done and the overlay keeps the
  /// last return's line.
  none,

  /// This film was never seen on VideoToolbox: nothing to restore.
  skipNoHardwareBefore,

  /// The film is already playing (a PiP window kept it running): the
  /// bounded watch starts at once.
  watchNow,

  /// The film is paused and its decoder may not be refreshed here (the
  /// PiP renderer's session, or an open still landing): the bounded
  /// watch starts when playback does.
  watchOnPlay,

  /// The film is paused on the hardware renderer — what every Home →
  /// return looks like on the phone: re-create the decoder now, while
  /// nothing is moving, then run the bounded watch when playback
  /// starts.
  refreshThenWatchOnPlay,
}

/// Decides the hardware-decode restore for one `resumed` (build 71).
///
/// Why this exists: build 70's watch never ran on the phone
/// (2026-11-18, 4K, PiP mode iOS: `hw-restore: -` after two returns,
/// `hwdec:` empty, `vo-drop` 0 → 164). Both recordings show the same
/// thing on return — the film comes back PAUSED with the play button
/// up, the viewer taps play, and no source re-open happens. Home
/// pauses the film, and nothing un-pauses it: Flutter replays
/// `hidden` → `inactive` → `resumed` on the way back in, the
/// `inactive` snapshot of "was it playing" is taken again while the
/// film is already paused, so the auto-resume / 4K re-open never run.
/// Build 70 armed the watch only inside that never-running path and in
/// a hook that stands down when the film is paused. So the watch is
/// now decided here, on every `resumed`, whatever the film is doing.
///
/// Why the decoder is refreshed while paused
/// ([HwdecReturnPlan.refreshThenWatchOnPlay]): iOS invalidates the
/// VideoToolbox session of a backgrounded app. With
/// `hwdec-software-fallback: 3` (see [kMpvIosOptions]) the first three
/// frames after play fail on the dead session and mpv drops to
/// software decode for the rest of the file. Re-creating the decoder
/// before play (mpv re-initialises it and seeks in place to the frame
/// on screen) gives it a fresh session and a clean keyframe start, so
/// there is nothing to fall back from. Whether that holds on the phone
/// is what the overlay line reports — the watch after play is the
/// safety net either way.
///
/// [wasBackgrounded] is the real-backgrounding flag (`paused`/`hidden`
/// seen since the last `resumed`). [seenAlive] is whether this film was
/// observed on VideoToolbox (see [hwdecRestoreAllowed]). [playing] is
/// the live playing state at `resumed`. [refreshAllowed] is false for
/// the PiP renderer's session, under a PiP window, and while an open
/// is still landing. Pure, so it is unit-tested (see
/// `mpv_hwdec_resume_test.dart`).
HwdecReturnPlan hwdecReturnPlan({
  required bool wasBackgrounded,
  required bool seenAlive,
  required bool playing,
  required bool refreshAllowed,
}) {
  if (!wasBackgrounded) return HwdecReturnPlan.none;
  if (!hwdecRestoreAllowed(seenAlive: seenAlive)) {
    return HwdecReturnPlan.skipNoHardwareBefore;
  }
  if (playing) return HwdecReturnPlan.watchNow;
  return refreshAllowed
      ? HwdecReturnPlan.refreshThenWatchOnPlay
      : HwdecReturnPlan.watchOnPlay;
}

/// The overlay word for a film that was never on VideoToolbox.
const String kHwdecOutcomeSkipNoHardware = 'skip (no hw before)';

/// The overlay word while the watch waits for the viewer to press play.
const String kHwdecOutcomeWaitPlay = 'wait play';

/// The QoE overlay's `hw-restore:` line (build 70, reworked in 71):
/// what the hardware-decode restore did on the last return from the
/// background, so one screenshot says whether it ran and how it ended.
///
/// `hw-restore: -` only until the first return from the background.
/// After that it always starts with `#N`, the number of returns handled
/// in this player session — so a `-` after a Home → return now means
/// the return itself was not seen, and a number that does not grow
/// means the same.
///
/// [pre] is the decoder refresh done while the film was still paused:
/// `-` not attempted, `sent` issued but not read back yet, `ok` the
/// decoder read back as VideoToolbox, `lost` it did not, `fail` the
/// property could not be set. [checks] is how many times the decoder
/// was read after playback started, [cycles] how many times `hwdec` was
/// switched off and on by the watch, [reopened] whether the last rung
/// ran, [outcome] the short state word ([kHwdecOutcomeWaitPlay],
/// `waiting`, `ok`, `lost`, `unreadable`, `reopened`, `stopped`, or
/// [kHwdecOutcomeSkipNoHardware]).
String hwdecResumeOverlayLine({
  required int returns,
  required String pre,
  required int checks,
  required int cycles,
  required bool reopened,
  required String outcome,
}) {
  if (returns <= 0) return 'hw-restore: -';
  if (outcome == kHwdecOutcomeSkipNoHardware) {
    return 'hw-restore: #$returns $outcome';
  }
  final reopen = reopened ? ' reopen 1' : '';
  return 'hw-restore: #$returns pre:$pre chk $checks cyc $cycles'
      '$reopen $outcome';
}

/// Whether the stream needs a re-open as the +55 stall fallback
/// (+48, +49, +50, +55).
///
/// History: iOS suspends the VideoToolbox decoder while the app is
/// backgrounded, and its reference frames go stale — on resume the
/// player restarts mid-GOP without a valid I-frame reference, so the
/// picture is macroblocked (and sometimes frozen) until the next
/// keyframe, ~2-4 s later (user proof 2026-11-16, Other Mommy 1080p,
/// PiP OFF: full-frame macroblocking + wrong colours at 06:33-06:35,
/// clean by 06:36). +48 fixed the macroblocking with a seek to the
/// playhead, but the video stayed laggy and choppy (user proof
/// 2026-11-16, +48 installed: timestamp frozen at 07:13 for ~5 s,
/// then a ~10 s jump) — iOS also kills the HTTP socket while
/// suspended, so mpv sits in a read timeout before it can serve data
/// again, and the seek itself throws away the buffered cushion. +49
/// re-opened the stream at the playhead on every return instead (same
/// gates): a fresh connection, a fresh decoder, and the pre-buffer
/// refilled while still paused. But the re-open itself showed
/// 00:00/LIVE + black + spinner for ~3-4 s on every return (user
/// proof 2026-11-16, +54 installed), so +55 removed it as the
/// default: return is a plain pause/resume, and the re-open survives
/// only as this fallback, fired when the plain resume is verifiably
/// dead (no position progress 8 s after resume-play — see
/// `_maybeFallbackReopen` in `mpv_player_screen.dart`).
///
/// Only when the player was actually background-paused: PiP keeps
/// decoding (no pause, nothing stale), an open landing re-syncs on its
/// own, and a film that never started has no position to re-open at.
/// +50: `wasBackgrounded` — the fallback is only for a REAL
/// backgrounding (the app passed through `paused`/`hidden` before this
/// `resumed`). A transient `inactive` (Control Center, Notification
/// Center, a call banner) returns to `resumed` without ever
/// backgrounding — the decoder and the socket were never suspended,
/// so re-opening would restart the film for nothing (user proof
/// 2026-11-16, The Odyssey: Control Center pull-down → 00:00/LIVE
/// restart). +55: the old `pipEnabled` gate is gone — with automatic
/// PiP removed, the setting no longer implies a live window, so only
/// an actually-open window ([inPip]) skips the fallback. Pure, so it
/// is unit-tested (see `mpv_resume_resync_test.dart`).
bool shouldResyncDecoderOnResume({
  required bool wasBackgrounded,
  required bool inPip,
  required bool awaitingPrebuffer,
  required bool startedPlaying,
  required bool hasStream,
}) =>
    wasBackgrounded &&
    !inPip &&
    !awaitingPrebuffer &&
    startedPlaying &&
    hasStream;

/// Whether the video track currently decoding is 4K (+56).
///
/// The gate for the 4K-only reconnect on Home → return (user
/// 2026-11-16: "only 4k videos hi ... source reconnect hojaye ...
/// baki sab ... reconnect naho"): a 4K track re-opens the source on
/// return, because the plain pause/resume lags at 4K bitrates on a
/// stale decoder/socket while 1080p recovers; 1440p and below stay on
/// the plain resume. Either dimension proves it: 3840 wide (UHD,
/// including ultrawide 3840x1600) or 2160 tall (DCI 4096x2160). Null
/// dimensions — an unreadable property — prove nothing, so they read
/// as not-4K; the caller falls back to the source row's label there
/// (see [_isCurrentVideo4K] in `mpv_player_screen.dart`). Pure, so it
/// is unit-tested (see `mpv_resume_resync_test.dart`).
bool is4KVideo({required int? width, required int? height}) =>
    (width != null && width >= 3840) || (height != null && height >= 2160);

/// What the iOS Home → return does after a real backgrounding (+56).
enum IosResumeAction {
  /// Re-open the source at the paused position and play once the
  /// pre-buffer refills (4K only).
  reopen4K,

  /// Plain play() from the paused position (everything below 4K).
  plainResume,

  /// Nothing: the film was not playing, a PiP window is up, or the
  /// return was a transient inactive (Control Center).
  none,
}

/// The iOS Home → return decision (+56): 4K re-opens, everything else
/// plain-resumes, and a film that was not playing, a live PiP window,
/// or a return without a real backgrounding does nothing. The player
/// implements this table in [_resumeIosAfterBackground] (its early
/// return is [IosResumeAction.none], its 4K branch
/// [IosResumeAction.reopen4K], its fall-through
/// [IosResumeAction.plainResume]). Pure, so it is unit-tested (see
/// `mpv_resume_resync_test.dart`).
IosResumeAction iosResumeAction({
  required bool wasBackgrounded,
  required bool inPip,
  required bool wasPlaying,
  required bool is4K,
}) {
  if (!wasBackgrounded || inPip || !wasPlaying) return IosResumeAction.none;
  return is4K ? IosResumeAction.reopen4K : IosResumeAction.plainResume;
}

/// Whether [iosResumeAction] does anything at all for this return —
/// i.e. whether the player's resume path will itself play or re-open
/// the film (build 71). When it will, that path starts the
/// hardware-decode watch; when it will not (the film comes back
/// paused), the return hook arms it instead (see [hwdecReturnPlan]).
bool iosResumePathActs({
  required bool wasBackgrounded,
  required bool wasInPip,
  required bool wasPlaying,
}) =>
    iosResumeAction(
      wasBackgrounded: wasBackgrounded,
      inPip: wasInPip,
      wasPlaying: wasPlaying,
      is4K: false,
    ) !=
    IosResumeAction.none;

/// The iOS HDR choice's render options (+57; two choices since v9).
///
/// The full render configuration, as `option → value`, applied on top of
/// [kMpvIosOptions]: the tone-mapping curve (Bright = `clip`, Balanced =
/// `bt.2390`), `target-peak: auto`, and the +34 cheap scalers — the same
/// scalers for both, so a pick only ever changes the curve.
///
/// Hardware path (PiP OFF, gl_video): real mpv options, applied live via
/// setProperty. Software path (PiP ON, TextureSW): the scaler options
/// are no-ops there (libswscale); the curve is honoured through the LUT,
/// which reads the live `tone-mapping` value (see
/// [swToneMapCurveForToneMapping] and TextureSW.swift) — so PiP ON
/// matches PiP OFF for both choices, the +50 principle.
///
/// The curve only does anything on an HDR (PQ / HLG) video: an SDR video
/// is never tone-mapped, which is why the panel shows the two choices on
/// HDR videos only. `hdr-compute-peak` is deliberately NOT set: it blacks
/// the video with vo=libmpv (media_kit forces it off). Bright is the
/// behaviour every install already had, so the default changes nothing
/// on upgrade. Pure, so it is unit-tested (see
/// `mpv_video_output_preset_test.dart`).
Map<String, String> videoOutputPresetOptions(
  VideoOutputPreset preset, {
  String? customToneMapping,
  String? customTargetPeak,
}) {
  // v9: two choices — Bright (clip) and Balanced (bt.2390) — and one
  // render set for both: the +34 cheap scalers (fastest scaler, no
  // deband, no dither, no extra downscale pass) and the peak from the
  // video. Compatibility's lanczos set and Custom's own target peak are
  // gone with those presets; [customTargetPeak] is accepted and ignored
  // so an old caller still compiles.
  return <String, String>{
    'tone-mapping': videoOutputPresetToneMapping(
      preset,
      customToneMapping: customToneMapping,
    ),
    'target-peak': 'auto',
    'scale': 'bilinear',
    'cscale': 'bilinear',
    'dscale': 'bilinear',
    'deband': 'no',
    'dither-depth': 'no',
    'correct-downscaling': 'no',
  };
}

/// The `tone-mapping` value a preset selects (+57, two values since v9).
///
/// The single value the software renderer reads to pick its LUT (see
/// [swToneMapCurveForToneMapping]): the hardware path gets the same value
/// through [videoOutputPresetOptions], so one setting drives both paths.
/// Bright is `clip`, Balanced is `bt.2390`; a legacy Compatibility or
/// Custom value is mapped through [migrateVideoOutputPreset] first, so it
/// can never select a third curve.
String videoOutputPresetToneMapping(
  VideoOutputPreset preset, {
  String? customToneMapping,
}) {
  final effective = migrateVideoOutputPreset(
    preset.name,
    customToneMapping: customToneMapping,
  );
  return effective == VideoOutputPreset.sdrToneMapped ? 'bt.2390' : 'clip';
}

/// The Video panel's PICTURE sliders as mpv properties (v9).
///
/// Each slider is −50…+50 and maps one-to-one onto mpv's own
/// `brightness` / `contrast` / `saturation` (−100…100, 0 = untouched),
/// held to the slider's range. Hardware path (PiP setting OFF): the
/// OpenGL renderer applies them itself. Software path (PiP setting ON):
/// mpv's software renderer ignores them, so TextureSW.swift reads the
/// same three properties every frame and applies the same maths to the
/// frame it hands Flutter and the PiP window. Pure, so it is unit-tested.
Map<String, String> pictureOptions({
  required int brightness,
  required int contrast,
  required int saturation,
}) => <String, String>{
  'brightness': '${clampPictureValue(brightness)}',
  'contrast': '${clampPictureValue(contrast)}',
  'saturation': '${clampPictureValue(saturation)}',
};

/// Applies the PICTURE sliders to a player's mpv instance (v9).
/// Best-effort, like the other option appliers.
Future<void> applyPictureOptions(
  NativePlayer platform, {
  required int brightness,
  required int contrast,
  required int saturation,
}) async {
  final options = pictureOptions(
    brightness: brightness,
    contrast: contrast,
    saturation: saturation,
  );
  for (final entry in options.entries) {
    try {
      await platform.setProperty(entry.key, entry.value);
    } catch (e) {
      debugPrint('[mpv] picture option ${entry.key} not applied: $e');
    }
  }
}

/// Whether an mpv `video-params/gamma` value is an HDR transfer (v9):
/// `pq` (HDR10, Dolby Vision's base layer) or `hlg`. The same two values
/// the software renderer's tone-mapping LUT keys on (TextureSW.swift).
/// Null — the property could not be read — is "unknown".
bool? videoGammaIsHdr(String? gamma) {
  final value = gamma?.trim().toLowerCase();
  if (value == null || value.isEmpty) return null;
  return value == 'pq' || value == 'hlg';
}

/// Which software LUT curve a `tone-mapping` value means (+57).
///
/// TextureSW.swift mirrors this table exactly: it reads the live
/// `tone-mapping` property once per video size and picks the LUT —
/// `clip` is the hard clip at the 100-nit SDR white (+50), `eetf` is the
/// BT.2390 roll-off re-added from +46/+47. `bt.2390` and `auto` both mean
/// the EETF (mpv's `auto` maps to bt.2390 on vo=gpu); every other value —
/// including an unreadable property — means the clip, the safe default
/// that matches the hardware path's `tone-mapping: clip`. Pure, so it is
/// unit-tested (see `mpv_video_output_preset_test.dart`).
enum SwToneMapCurve { clip, eetf }

SwToneMapCurve swToneMapCurveForToneMapping(String toneMapping) =>
    switch (toneMapping.trim().toLowerCase()) {
      'bt.2390' || 'auto' => SwToneMapCurve.eetf,
      _ => SwToneMapCurve.clip,
    };

/// The software renderer's LUT the live gamma + tone-mapping imply
/// (build 88, diagnostic only): the Dart-side mirror of TextureSW's
/// decision table, so the QoE overlay can show what the PiP path is
/// doing without a native bridge. `sdr-exact` is the build-87 exact
/// bt.1886 -> sRGB LUT; `none` means the SW path passes the frame
/// through (bt.709 / sRGB-like sources); `pq-<clip|eetf>` /
/// `hlg-<clip|eetf>` are the HDR tone-map LUTs. An unreadable gamma
/// is `?` — the native side defaults that to bt.1886, so a `?` next
/// to a visible PiP gap is itself the signal to check the native
/// read. Pure, so it is unit-tested (see
/// `mpv_video_output_preset_test.dart`).
String swLutOverlayLabel({
  required String? gamma,
  required String toneMapping,
}) {
  final g = gamma?.trim().toLowerCase() ?? '';
  final curve = swToneMapCurveForToneMapping(toneMapping).name;
  if (g == 'pq') return 'pq-$curve';
  if (g == 'hlg') return 'hlg-$curve';
  if (g == 'bt.1886' || g == 'gamma2.4' || g == 'gamma2.6' || g == 'gamma2.8') {
    return 'sdr-exact';
  }
  if (g.isEmpty) return '?';
  return 'none';
}

/// Applies a Video output preset's options to a player's mpv instance
/// (+57). Same best-effort shape as [applyMpvIosOptions]: a single
/// option failing must not break the open, and the tone-mapping
/// read-back shows what was set. Call after [applyMpvIosOptions] — the
/// preset overrides the base `tone-mapping: clip` and the +34 scalers
/// where the preset says otherwise.
Future<void> applyVideoOutputPresetOptions(
  NativePlayer platform,
  VideoOutputPreset preset, {
  String? customToneMapping,
  String? customTargetPeak,
}) async {
  final options = videoOutputPresetOptions(
    preset,
    customToneMapping: customToneMapping,
    customTargetPeak: customTargetPeak,
  );
  for (final entry in options.entries) {
    try {
      await platform.setProperty(entry.key, entry.value);
    } catch (e) {
      debugPrint('[mpv] video preset option ${entry.key} not applied: $e');
    }
  }
  try {
    final toneMapping = await platform.getProperty('tone-mapping');
    debugPrint('[mpv] video preset ${preset.name}: tone-mapping=$toneMapping');
  } catch (e) {
    debugPrint('[mpv] video preset tone-mapping read-back failed: $e');
  }
}

/// Applies [kMpvIosOptions] to a player's mpv instance, then reads the
/// fallback back so the log shows what was set. Same best-effort shape
/// as [applyMpvAndroidOptions] in `mpv_android_options.dart`: a single
/// option failing must not break the open.
Future<void> applyMpvIosOptions(NativePlayer platform) async {
  for (final entry in kMpvIosOptions.entries) {
    try {
      await platform.setProperty(entry.key, entry.value);
    } catch (e) {
      debugPrint('[mpv] iOS option ${entry.key} not applied: $e');
    }
  }
  try {
    final fallback = await platform.getProperty('hwdec-software-fallback');
    debugPrint(
      '[mpv] hwdec-software-fallback: $fallback (iOS options '
      'applied)',
    );
  } catch (e) {
    debugPrint('[mpv] hwdec-software-fallback read-back failed: $e');
  }
}
