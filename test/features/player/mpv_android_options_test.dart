import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_android_options.dart';

/// Android 4K lag: the Golden player hardcoded `hwdec: 'videotoolbox'`
/// for every platform. VideoToolbox is Apple-only — on Android mpv
/// could not use it and fell back to software decoding, and 4K HEVC in
/// software is the continuous stutter the viewer reported (v20+6 release
/// APK, Z Flip 5), while the same file is smooth on iOS. These tests pin
/// the platform split and the Android option set, including the guard
/// that the v20+1 black-screen value never comes back.
void main() {
  group('mpvHwdecForPlatform', () {
    test('Apple platforms keep videotoolbox', () {
      expect(mpvHwdecForPlatform(TargetPlatform.iOS), 'videotoolbox');
      expect(mpvHwdecForPlatform(TargetPlatform.macOS), 'videotoolbox');
    });

    test('Android gets auto-safe (mediacodec), not videotoolbox', () {
      expect(mpvHwdecForPlatform(TargetPlatform.android), 'auto-safe');
    });

    test('every other platform gets auto-safe too', () {
      expect(mpvHwdecForPlatform(TargetPlatform.linux), 'auto-safe');
      expect(mpvHwdecForPlatform(TargetPlatform.windows), 'auto-safe');
      expect(mpvHwdecForPlatform(TargetPlatform.fuchsia), 'auto-safe');
    });
  });

  group('kMpvAndroidOptions', () {
    test('carries the safe presentation options', () {
      expect(kMpvAndroidOptions['video-sync'], 'display-resample');
      // +34: mpv's manual calls `vo` "the recommended mode, and the
      // default" and says `decoder+vo` is "Not recommended".
      expect(kMpvAndroidOptions['framedrop'], 'vo');
      expect(kMpvAndroidOptions['hwdec-software-fallback'], '300');
    });

    test('carries the +34 cache and cheap-GPU-render layers', () {
      expect(kMpvAndroidOptions['demuxer-max-bytes'], '256MiB');
      expect(kMpvAndroidOptions['scale'], 'bilinear');
      expect(kMpvAndroidOptions['cscale'], 'bilinear');
      expect(kMpvAndroidOptions['dscale'], 'bilinear');
      expect(kMpvAndroidOptions['deband'], 'no');
      expect(kMpvAndroidOptions['dither-depth'], 'no');
      expect(kMpvAndroidOptions['correct-downscaling'], 'no');
      // `tone-mapping: clip` is the cheapest HDR mapping — and it is
      // NOT peak compute: `hdr-compute-peak` (the v20+1 black-screen
      // value) stays out, and media_kit forces it off.
      expect(kMpvAndroidOptions['tone-mapping'], 'clip');
    });

    test('never carries the v20+1 black-screen value', () {
      expect(kMpvAndroidOptions.containsKey('hdr-compute-peak'), isFalse);
      expect(kMpvAndroidOptions.containsKey('target-colorspace-hint'), isFalse);
    });

    test('never touches the video output', () {
      expect(kMpvAndroidOptions.containsKey('vo'), isFalse);
      expect(kMpvAndroidOptions.containsKey('gpu-api'), isFalse);
      expect(kMpvAndroidOptions.containsKey('gpu-context'), isFalse);
    });
  });

  group('kMpvSubtitleOptions', () {
    test('turns the secondary subtitle track off, always', () {
      // +26: media_kit's subtitle state is [primary, secondary] and
      // its SubtitleView renders both, so an auto-picked secondary
      // track in the same language doubles the cue. The app has no
      // dual-subtitle feature, so the secondary slot stays off.
      expect(kMpvSubtitleOptions['secondary-sid'], 'no');
    });

    test('never touches the primary subtitle track', () {
      expect(kMpvSubtitleOptions.containsKey('sid'), isFalse);
      expect(kMpvSubtitleOptions.containsKey('sub-visibility'), isFalse);
      expect(kMpvSubtitleOptions.containsKey('sub-ass'), isFalse);
    });
  });

  test('v2: the Video drawer (HDR choice + PICTURE) is on iOS and Android only', () {
    expect(videoPanelSupportedOn(TargetPlatform.iOS), isTrue);
    expect(videoPanelSupportedOn(TargetPlatform.android), isTrue);
    expect(videoPanelSupportedOn(TargetPlatform.macOS), isFalse);
    expect(videoPanelSupportedOn(TargetPlatform.windows), isFalse);
    expect(videoPanelSupportedOn(TargetPlatform.linux), isFalse);
  });
}
