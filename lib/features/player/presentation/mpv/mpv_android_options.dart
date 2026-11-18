/// Android-only mpv options, and the platform-dependent hardware decoder.
///
/// Why this file exists: the Golden player hardcodes `hwdec: 'videotoolbox'`
/// in its [VideoControllerConfiguration] — correct on iOS, where
/// VideoToolbox is the hardware decoder, but on Android VideoToolbox does
/// not exist. media_kit_video 2.0.1's Android controller uses the passed
/// `hwdec` verbatim (`android_video_controller/real.dart`: `hwdec:
/// configuration.hwdec ?? await getDefaultHwdec()`), so Android got
/// `hwdec=videotoolbox`, mpv could not use it, and fell back to SOFTWARE
/// decoding. 4K HEVC in software on a phone CPU is the continuous stutter
/// the viewer reported on Android (v20+6 release APK, Z Flip 5) — while
/// the same file is smooth on iOS, where VideoToolbox engages. Debug
/// overhead was ruled out: the lag persisted in the release build.
///
/// The fix has two parts, both Android-only (the iOS path is smooth and
/// is not touched):
///
///   1. [mpvHwdecForPlatform] — iOS/macOS keep `'videotoolbox'`; Android
///      gets `'auto-safe'`, media_kit's own Android default, which
///      resolves to mediacodec (see the `hwdec-codecs` list media_kit
///      sets: h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1).
///   2. [kMpvAndroidOptions] — the safe presentation options media_kit
///      does not set, applied via [NativePlayer.setProperty] before the
///      first open (the same escape hatch v20+1 used; the mechanism was
///      never the problem — the `hdr-compute-peak=yes` VALUE was, and it
///      is NOT in this map, never add it):
///        * `video-sync: display-resample` — retime the audio to the
///          display's clock, so 24 fps film stays locked to whatever rate
///          the panel is on. +9 used `display-vdrop` here; vdrop can only
///          drop/duplicate whole frames, and the Flip 5's adaptive 120 Hz
///          panel switches rates as the viewer watches, so vdrop juddered
///          on every switch. A presentation option; it cannot blank the
///          picture.
///        * `framedrop: vo` — mpv's recommended mode (+34, was
///          `decoder+vo`): when the video output cannot keep up, drop
///          frames instead of letting A/V drift grow. mpv's manual
///          calls `vo` "the recommended mode, and the default" and
///          says `decoder+vo` is "Not recommended".
///        * `hwdec-software-fallback: 300` — Nuvio's value (the safest
///          of its options): if the hardware decoder glitches
///          transiently, keep hardware decoding for 300 frames while
///          FFmpeg recreates the session, instead of dropping to
///          software decode for the rest of the file.
///        * `demuxer-max-bytes: 256MiB` (+34) — the network cache's
///          byte cap (default 150 MiB); a bigger headroom rides out
///          throughput dips without a cache stall. Costs only RAM.
///        * The cheap GPU render layer (+34): `scale` / `cscale` /
///          `dscale: bilinear` (fastest scaler; defaults lanczos /
///          hermite), `deband: no`, `dither-depth: no`,
///          `correct-downscaling: no`, `tone-mapping: clip` (cheapest
///          HDR mapping). gl_video options, so they apply to the GPU
///          render path; the cost is a little picture quality.
///
/// [logMpvDecodeInfo] is the lightweight diagnostic: one debugPrint of
/// the decoder actually engaged (`hwdec-current`) and the video codec,
/// read back once on first play. If it prints `mediacodec`, hardware
/// decode is engaged; if it prints nothing/`no`, the file is still on
/// software decode and the hwdec fix did not take.
library;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// The mpv hardware decoder for [platform].
///
/// Apple platforms use VideoToolbox; everything else uses media_kit's
/// Android default `'auto-safe'` (mediacodec on Android). Pure, so it is
/// unit-tested (see `mpv_android_options_test.dart`).
String mpvHwdecForPlatform(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return 'videotoolbox';
    case TargetPlatform.android:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
    case TargetPlatform.fuchsia:
      return 'auto-safe';
  }
}

/// Android-only mpv options, as `option → value`.
///
/// Deliberately NOT here (read before adding):
///
///   * `hdr-compute-peak: yes` — the v20+1 black-screen cause. media_kit
///     forces it to `no` with `vo=libmpv`; enabling it blanks the video
///     and stalls the player. NEVER retry. (`tone-mapping: clip` IS in
///     the map — it is not peak compute, it only picks the mapping
///     curve, and peak compute stays off.)
///   * `target-colorspace-hint` — Nuvio's HDR path; not needed for the
///     Android lag and out of scope here.
///   * `vo`, `gpu-api`, `gpu-context` — media_kit owns the video output
///     (`vo=gpu` + `gpu-context=android` on Android, `vo=libmpv` on
///     iOS); changing it breaks the Flutter texture.
const Map<String, String> kMpvAndroidOptions = <String, String>{
  // `display-resample`, not `display-vdrop` (+9's pick): the Flip 5's panel
  // is an adaptive 120 Hz display whose refresh rate switches as the
  // viewer watches, and vdrop judders on every rate switch — it can only
  // drop/duplicate whole frames to match a moving target. Resample instead
  // retimes the audio to the display's clock, so 24 fps film stays locked
  // to whatever rate the panel is on with no dropped frames and no drift.
  // The pitch shift is a fraction of a percent and inaudible. iOS is
  // untouched — its path is smooth as it is.
  'video-sync': 'display-resample',
  'framedrop': 'vo',
  'hwdec-software-fallback': '300',
  'demuxer-max-bytes': '256MiB',
  'scale': 'bilinear',
  'cscale': 'bilinear',
  'dscale': 'bilinear',
  'deband': 'no',
  'dither-depth': 'no',
  'correct-downscaling': 'no',
  'tone-mapping': 'clip',
};

/// Applies [kMpvAndroidOptions] to a player's mpv instance, then reads
/// the `hwdec` option back so the log shows what was set. A single
/// option failing must not break the open: each set is its own
/// try/catch, and the whole call is best-effort.
Future<void> applyMpvAndroidOptions(NativePlayer platform) async {
  for (final entry in kMpvAndroidOptions.entries) {
    try {
      await platform.setProperty(entry.key, entry.value);
    } catch (e) {
      debugPrint('[mpv] Android option ${entry.key} not applied: $e');
    }
  }
  try {
    final hwdec = await platform.getProperty('hwdec');
    debugPrint('[mpv] hwdec: $hwdec (Android options applied)');
  } catch (e) {
    debugPrint('[mpv] hwdec read-back failed: $e');
  }
}

/// Cross-platform subtitle options (iOS AND Android — unlike the
/// Android-only map above), as `option → value`.
///
/// The one entry is `secondary-sid: no` (+26). Why: media_kit's
/// subtitle state is a two-slot list — the primary `sub-text` and the
/// secondary `secondary-sub-text` — and its SubtitleView renders BOTH
/// (media_kit 1.2.6 `real.dart`: the `sub-text` and
/// `secondary-sub-text` observers each fill one slot, and
/// `SubtitleView` joins every non-empty line). mpv's `secondary-sid`
/// defaults to `auto`, which can pick a second same-language track
/// (e.g. English SDH next to English) as the secondary subtitle — and
/// then the same cue arrives in both slots and the caption shows
/// twice, four lines instead of two. The app has no dual-subtitle
/// feature and never selects a secondary track, so the secondary slot
/// is off, always. The primary track (`sid`, set through
/// `setSubtitleTrack`) is untouched by this option.
///
/// Deliberately NOT here: `sid` itself, and any `sub-*` presentation
/// option — the Flutter overlay owns the caption's style and position,
/// and mpv's native rendering stays off (`libass: false` in the
/// PlayerConfiguration, so `sub-visibility` is already `no`).
const Map<String, String> kMpvSubtitleOptions = <String, String>{
  'secondary-sid': 'no',
};

/// Applies [kMpvSubtitleOptions] to a player's mpv instance, then reads
/// `secondary-sid` back so the log shows what was set. Same best-effort
/// shape as [applyMpvAndroidOptions]: a single option failing must not
/// break the open.
Future<void> applyMpvSubtitleOptions(NativePlayer platform) async {
  for (final entry in kMpvSubtitleOptions.entries) {
    try {
      await platform.setProperty(entry.key, entry.value);
    } catch (e) {
      debugPrint('[mpv] subtitle option ${entry.key} not applied: $e');
    }
  }
  try {
    final secondarySid = await platform.getProperty('secondary-sid');
    debugPrint('[mpv] secondary-sid: $secondarySid (subtitle options '
        'applied)');
  } catch (e) {
    debugPrint('[mpv] secondary-sid read-back failed: $e');
  }
}

/// One-time diagnostic: reads the decoder actually engaged back from
/// mpv and prints it. Call once, on first play — before the first frame
/// `hwdec-current` is empty, so reading it earlier proves nothing.
///
/// Expected on Android: `hwdec-current: mediacodec`. If it prints
/// empty/`no`, the file is still on software decode.
Future<void> logMpvDecodeInfo(Player player) async {
  try {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    final hwdecCurrent = await platform.getProperty('hwdec-current');
    final codec = await platform.getProperty('video-codec');
    debugPrint('[mpv] decode: hwdec-current=$hwdecCurrent codec=$codec');
  } catch (e) {
    debugPrint('[mpv] decode read-back failed: $e');
  }
}

/// Whether the player's Video drawer offers the HDR choice and the
/// PICTURE sliders on [platform] (v2): iOS, and Android — both run mpv
/// with a renderer that honours `tone-mapping`, `brightness`, `contrast`
/// and `saturation` (Android: mpv's own `vo=gpu`). Pure, so it is
/// unit-tested.
bool videoPanelSupportedOn(TargetPlatform platform) =>
    platform == TargetPlatform.iOS || platform == TargetPlatform.android;
