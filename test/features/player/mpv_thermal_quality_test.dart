/// The 4K thermal lag fix (+27, +33).
///
/// Two halves: the iOS mpv options (the VideoToolbox fallback Nuvio sets,
/// so a session invalidated under heat is recreated instead of dropping to
/// software decode for the rest of the file) and the thermal-aware quality
/// governor (drop a heavy stream for a lighter one while the phone is
/// serious or critical, restore it when it cools).
///
/// +33 adds the single-file answer: a direct link has no lighter stream
/// to drop to, so the governor lightens the render instead (`vf` scale to
/// 1080p plus the fast-decode options), and takes it off when the phone
/// cools. The governor also stays active during PiP for the lightening
/// only — the ladder logic still stands down there, because the PiP drop
/// owns quality while the window is up.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/providers/device_memory.dart';
import 'package:zorox/core/providers/thermal_state.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_ios_options.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_thermal_quality.dart';

void main() {
  group('thermalStateFromRaw', () {
    test('maps the iOS raw values', () {
      expect(thermalStateFromRaw(0), ThermalState.nominal);
      expect(thermalStateFromRaw(1), ThermalState.fair);
      expect(thermalStateFromRaw(2), ThermalState.serious);
      expect(thermalStateFromRaw(3), ThermalState.critical);
    });

    test('anything outside 0–3 is unknown, never a guess', () {
      expect(thermalStateFromRaw(4), ThermalState.unknown);
      expect(thermalStateFromRaw(-1), ThermalState.unknown);
      expect(thermalStateFromRaw(null), ThermalState.unknown);
      expect(thermalStateFromRaw('serious'), ThermalState.unknown);
    });

    test('a non-iOS, non-Android read is unknown without touching the '
        'channel', () async {
      // These tests run on the host (Linux), so the platform guard
      // answers before any channel call.
      expect(await readThermalState(), ThermalState.unknown);
    });

    test('an Android read goes through the channel', () async {
      // +33: Android answers the same 0–3 shape through the channel
      // (PowerManager status, mapped by the runner). The platform is
      // overridden for this test only.
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(deviceMemoryChannel, (call) async {
            if (call.method == 'thermalState') return 2;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance
            .defaultBinaryMessenger
            .setMockMethodCallHandler(deviceMemoryChannel, null),
      );
      expect(await readThermalState(), ThermalState.serious);
    });

    test('an Android read with no runner answers unknown', () async {
      // Below API 29 the runner does not implement the method, so the
      // call fails and the read is unknown, never a guess.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(await readThermalState(), ThermalState.unknown);
    });
  });

  group('kMpvIosOptions', () {
    test('falls back to software quickly if the session dies (+49)', () {
      // mpv's default is 3: fallback after 3 consecutive failed
      // frames (~125 ms). Nuvio's 300 tolerated ~12 s of failed
      // decoding and skipped the failed packets on fallback (the
      // user's +48 freeze + jump) — so +49 returns to the default.
      expect(kMpvIosOptions['hwdec-software-fallback'], '3');
    });

    test('drops frames instead of falling behind, like Android', () {
      // +34: mpv's manual calls `vo` "the recommended mode, and the
      // default" and says `decoder+vo` is "Not recommended".
      expect(kMpvIosOptions['framedrop'], 'vo');
    });

    test('carries the +34 cache and cheap-GPU-render layers', () {
      expect(kMpvIosOptions['demuxer-max-bytes'], '768MiB');
      expect(kMpvIosOptions['scale'], 'bilinear');
      expect(kMpvIosOptions['cscale'], 'bilinear');
      expect(kMpvIosOptions['dscale'], 'bilinear');
      expect(kMpvIosOptions['deband'], 'no');
      expect(kMpvIosOptions['dither-depth'], 'no');
      expect(kMpvIosOptions['correct-downscaling'], 'no');
      // `tone-mapping: clip` is the cheapest HDR mapping — and it is
      // NOT peak compute: `hdr-compute-peak` (the v20+1 black-screen
      // value) stays out, and media_kit forces it off.
      expect(kMpvIosOptions['tone-mapping'], 'clip');
    });

    test('pre-buffers without a time cap so a slow line does not stall '
        '(+54, +55)', () {
      // mpv's default cache-secs is 10: only ~10 s ahead of the
      // playhead, so a dip drains it in seconds and the player stalls
      // (user report 2026-11-16: "buffer bohot jaldi karey agey ka").
      // +54 raised it to 60 s; +55 removes the time cap altogether at
      // the user's ask ("60 sec nahi jitna sync karsakega jitne time
      // tak hota rehe"): 3600 s means time never limits the buffer —
      // mpv reads ahead until the byte cap stops it. The 768 MiB byte
      // cap (above) is the real limit and the jetsam safety valve: it
      // holds ~2 min at 50 Mbit/s peak 4K, ~4 min at 25 Mbit/s, and
      // ~10-13 min at 1080p.
      expect(kMpvIosOptions['cache-secs'], '3600');
    });

    test('reconnects a socket iOS killed while suspended (+49)', () {
      // The 5 s freeze + ~10 s catch-up jump on +48 (Home → return):
      // FFmpeg http-protocol options, so they apply to a direct HTTP
      // file link as well as HLS. A dead socket reconnects within the
      // 2 s cap instead of hanging on the OS TCP timeout, and a single
      // read fails fast at 5 s.
      expect(
        kMpvIosOptions['stream-lavf-o'],
        'reconnect=1,reconnect_streamed=1,reconnect_delay_max=2',
      );
      expect(kMpvIosOptions['network-timeout'], '5');
    });

    test('never carries the options that blank the video', () {
      expect(kMpvIosOptions.containsKey('hdr-compute-peak'), isFalse);
      expect(kMpvIosOptions.containsKey('video-sync'), isFalse);
      expect(kMpvIosOptions.containsKey('vo'), isFalse);
    });
  });

  group('ThermalQualityGovernor — the drop', () {
    const qualities = <int?>[2160, 1080, 720];

    test('a serious phone drops 4K to the best lighter stream', () {
      final governor = ThermalQualityGovernor();
      final decision = governor.evaluate(
        thermal: ThermalState.serious,
        qualities: qualities,
        currentIndex: 0,
      );
      expect(decision.kind, ThermalQualityKind.drop);
      expect(decision.targetIndex, 1);
    });

    test('a critical phone drops too', () {
      final governor = ThermalQualityGovernor();
      final decision = governor.evaluate(
        thermal: ThermalState.critical,
        qualities: qualities,
        currentIndex: 0,
      );
      expect(decision.kind, ThermalQualityKind.drop);
      expect(decision.targetIndex, 1);
    });

    test('prefers the tallest stream at or below 1080p', () {
      final governor = ThermalQualityGovernor();
      final decision = governor.evaluate(
        thermal: ThermalState.serious,
        qualities: const <int?>[2160, 720, 1080],
        currentIndex: 0,
      );
      expect(decision.targetIndex, 2);
    });

    test('falls to the next-lower stream when nothing is at 1080p', () {
      final governor = ThermalQualityGovernor();
      final decision = governor.evaluate(
        thermal: ThermalState.serious,
        qualities: const <int?>[2160, 1440],
        currentIndex: 0,
      );
      expect(decision.kind, ThermalQualityKind.drop);
      expect(decision.targetIndex, 1);
    });

    test('no drop when the stream is already light', () {
      final governor = ThermalQualityGovernor();
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: qualities,
              currentIndex: 1,
            )
            .isNone,
        isTrue,
      );
    });

    test('no drop when the phone is only fair, nominal or unreadable', () {
      for (final thermal in <ThermalState>[
        ThermalState.nominal,
        ThermalState.fair,
        ThermalState.unknown,
      ]) {
        final governor = ThermalQualityGovernor();
        expect(
          governor
              .evaluate(
                thermal: thermal,
                qualities: qualities,
                currentIndex: 0,
              )
              .isNone,
          isTrue,
          reason: '$thermal',
        );
      }
    });

    test('a single-file 4K source lightens the render instead of '
        'dropping', () {
      // +33: a direct link has no lighter stream, so the ladder drop is
      // a no-op there — the governor lightens the render instead. The
      // stream never changes, so the decision carries no target.
      final governor = ThermalQualityGovernor();
      final decision = governor.evaluate(
        thermal: ThermalState.serious,
        qualities: const <int?>[2160],
        currentIndex: 0,
      );
      expect(decision.kind, ThermalQualityKind.lighten);
      expect(decision.targetIndex, -1);
      expect(governor.isLightened, isTrue);
    });

    test('a critical phone lightens a single-file source too', () {
      final governor = ThermalQualityGovernor();
      expect(
        governor
            .evaluate(
              thermal: ThermalState.critical,
              qualities: const <int?>[2160],
              currentIndex: 0,
            )
            .kind,
        ThermalQualityKind.lighten,
      );
    });

    test('an adaptive master gets one hint, not a switch', () {
      final governor = ThermalQualityGovernor();
      // quality 0 is an HLS master (see StreamResult.quality).
      final hint = governor.evaluate(
        thermal: ThermalState.serious,
        qualities: const <int?>[0],
        currentIndex: 0,
      );
      expect(hint.kind, ThermalQualityKind.hint);
      expect(hint.targetIndex, -1);
      // The next hot tick does not hint again.
      expect(
        governor
            .evaluate(
              thermal: ThermalState.critical,
              qualities: const <int?>[0],
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
      // A cool tick re-arms the hint for the next episode.
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: const <int?>[0],
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: const <int?>[null],
              currentIndex: 0,
            )
            .kind,
        ThermalQualityKind.hint,
      );
    });
  });

  group('ThermalQualityGovernor — the restore', () {
    const qualities = <int?>[2160, 1080, 720];

    ThermalQualityGovernor dropped() {
      final governor = ThermalQualityGovernor();
      final decision = governor.evaluate(
        thermal: ThermalState.serious,
        qualities: qualities,
        currentIndex: 0,
      );
      expect(decision.kind, ThermalQualityKind.drop);
      return governor;
    }

    test('restores the original after two consecutive nominal ticks', () {
      final governor = dropped();
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: qualities,
              currentIndex: 1,
            )
            .isNone,
        isTrue,
        reason: 'one nominal tick is not enough',
      );
      final restore = governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: qualities,
        currentIndex: 1,
      );
      expect(restore.kind, ThermalQualityKind.restore);
      expect(restore.targetIndex, 0);
    });

    test('a hot tick resets the nominal streak', () {
      final governor = dropped();
      governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: qualities,
        currentIndex: 1,
      );
      governor.evaluate(
        thermal: ThermalState.serious,
        qualities: qualities,
        currentIndex: 1,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: qualities,
              currentIndex: 1,
            )
            .isNone,
        isTrue,
        reason: 'the streak restarted, one tick is not enough',
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: qualities,
              currentIndex: 1,
            )
            .kind,
        ThermalQualityKind.restore,
      );
    });

    test('an unreadable state does not count as cool', () {
      final governor = dropped();
      governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: qualities,
        currentIndex: 1,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.unknown,
              qualities: qualities,
              currentIndex: 1,
            )
            .isNone,
        isTrue,
      );
      // The unknown tick reset the streak: one nominal tick is not
      // enough anymore.
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: qualities,
              currentIndex: 1,
            )
            .isNone,
        isTrue,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: qualities,
              currentIndex: 1,
            )
            .kind,
        ThermalQualityKind.restore,
      );
    });

    test('once the restore lands, the episode is over', () {
      final governor = dropped();
      governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: qualities,
        currentIndex: 1,
      );
      governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: qualities,
        currentIndex: 1,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: qualities,
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
    });
  });

  group('ThermalQualityGovernor — a hand pick stands', () {
    const qualities = <int?>[2160, 1080, 1440];

    test('a manual 4K pick is never dropped while the episode lasts', () {
      final governor = ThermalQualityGovernor();
      governor.noteManualPick(0);
      expect(
        governor
            .evaluate(
              thermal: ThermalState.critical,
              qualities: qualities,
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
      // The phone cools: the latch clears, and the next hot episode
      // drops it like any other stream.
      governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: qualities,
        currentIndex: 0,
      );
      final decision = governor.evaluate(
        thermal: ThermalState.serious,
        qualities: qualities,
        currentIndex: 0,
      );
      expect(decision.kind, ThermalQualityKind.drop);
      expect(decision.targetIndex, 1);
    });

    test('re-picking the original mid-drop ends the episode by hand', () {
      final governor = ThermalQualityGovernor();
      governor.evaluate(
        thermal: ThermalState.serious,
        qualities: qualities,
        currentIndex: 0,
      );
      governor.noteManualPick(0);
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: qualities,
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
      // And the governor does not drop it again on the next hot tick:
      // the viewer chose 4K.
      expect(
        governor
            .evaluate(
              thermal: ThermalState.critical,
              qualities: qualities,
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
    });

    test('picking a third source mid-drop ends the drop, not the pick', () {
      final governor = ThermalQualityGovernor();
      governor.evaluate(
        thermal: ThermalState.serious,
        qualities: qualities,
        currentIndex: 0,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: qualities,
              currentIndex: 2,
            )
            .isNone,
        isTrue,
      );
      // The third pick (1440p) stands while hot.
      expect(
        governor
            .evaluate(
              thermal: ThermalState.critical,
              qualities: qualities,
              currentIndex: 2,
            )
            .isNone,
        isTrue,
      );
    });

    test('a bad index or an empty list is no change, never a throw', () {
      final governor = ThermalQualityGovernor();
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: qualities,
              currentIndex: 9,
            )
            .isNone,
        isTrue,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: const <int?>[],
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
    });
  });

  group('ThermalQualityGovernor — the single-file lighten (+33, +34)', () {
    test('the lighten properties scale the render to 1080p and the '
        'unlighten clears them', () {
      // +34: these properties are the ANDROID lighten actuation only.
      // On iOS the screen caps the render target through
      // `VideoController.setSize` instead — a `vf=scale` under
      // zero-copy videotoolbox forces a GPU→CPU download, a CPU scale
      // and a re-upload, and `vd-lavc-fast` is H.264/MPEG-1/2 only
      // (a no-op on the HEVC file).
      expect(kThermalLightenVf, 'scale=-2:1080');
      expect(kThermalLightenProperties['vf'], kThermalLightenVf);
      expect(kThermalLightenProperties['vd-lavc-skiploopfilter'], 'all');
      expect(kThermalLightenProperties['vd-lavc-fast'], 'yes');
      expect(kThermalUnlightenProperties['vf'], '');
      expect(kThermalUnlightenProperties['vd-lavc-skiploopfilter'], 'default');
      expect(kThermalUnlightenProperties['vd-lavc-fast'], 'no');
    });

    test('a second hot tick while lightened is no change', () {
      final governor = ThermalQualityGovernor();
      governor.evaluate(
        thermal: ThermalState.serious,
        qualities: const <int?>[2160],
        currentIndex: 0,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.critical,
              qualities: const <int?>[2160],
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
      expect(governor.isLightened, isTrue);
    });

    test('the lightening comes off after two consecutive nominal ticks', () {
      final governor = ThermalQualityGovernor();
      governor.evaluate(
        thermal: ThermalState.serious,
        qualities: const <int?>[2160],
        currentIndex: 0,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: const <int?>[2160],
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
      final unlighten = governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: const <int?>[2160],
        currentIndex: 0,
      );
      expect(unlighten.kind, ThermalQualityKind.unlighten);
      expect(governor.isLightened, isFalse);
    });

    test('a hot tick resets the lighten nominal streak', () {
      final governor = ThermalQualityGovernor();
      governor.evaluate(
        thermal: ThermalState.serious,
        qualities: const <int?>[2160],
        currentIndex: 0,
      );
      governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: const <int?>[2160],
        currentIndex: 0,
      );
      // Hot again: the one nominal tick is forgotten.
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: const <int?>[2160],
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: const <int?>[2160],
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: const <int?>[2160],
              currentIndex: 0,
            )
            .kind,
        ThermalQualityKind.unlighten,
      );
    });

    test('switching to a light stream takes the lightening off at once', () {
      final governor = ThermalQualityGovernor();
      governor.evaluate(
        thermal: ThermalState.serious,
        qualities: const <int?>[2160],
        currentIndex: 0,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: const <int?>[2160, 1080],
              currentIndex: 1,
            )
            .kind,
        ThermalQualityKind.unlighten,
      );
    });

    test('a light single-file stream never lightens', () {
      final governor = ThermalQualityGovernor();
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: const <int?>[1080],
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
    });

    test('a fair phone never lightens a single-file source', () {
      final governor = ThermalQualityGovernor();
      expect(
        governor
            .evaluate(
              thermal: ThermalState.fair,
              qualities: const <int?>[2160],
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
    });

    test('a manual 4K pick is never lightened while the episode lasts', () {
      final governor = ThermalQualityGovernor();
      governor.noteManualPick(0);
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: const <int?>[2160],
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
      expect(governor.isLightened, isFalse);
      // Cools: the latch clears, and the next hot tick lightens.
      governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: const <int?>[2160],
        currentIndex: 0,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: const <int?>[2160],
              currentIndex: 0,
            )
            .kind,
        ThermalQualityKind.lighten,
      );
    });
  });

  group('ThermalQualityGovernor — PiP mode (+33)', () {
    test('in PiP a single-file 4K source still lightens', () {
      final governor = ThermalQualityGovernor();
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: const <int?>[2160],
              currentIndex: 0,
              inPip: true,
            )
            .kind,
        ThermalQualityKind.lighten,
      );
    });

    test('in PiP a heavy ladder source is lightened, never dropped — '
        'PiP owns quality', () {
      final governor = ThermalQualityGovernor();
      // The PiP drop owns the stream switch, so the governor must never
      // drop here. But a heavy stream in PiP still gets the render
      // lightening — it changes no stream, so it cannot fight the PiP
      // drop. (In practice the PiP drop has already moved to the
      // lightest stream by the time a tick lands, and a light stream
      // lightens nothing.)
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: const <int?>[2160, 1080, 720],
              currentIndex: 0,
              inPip: true,
            )
            .kind,
        ThermalQualityKind.lighten,
      );
    });

    test('in PiP the lightening comes off after two nominal ticks', () {
      final governor = ThermalQualityGovernor();
      governor.evaluate(
        thermal: ThermalState.serious,
        qualities: const <int?>[2160],
        currentIndex: 0,
        inPip: true,
      );
      governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: const <int?>[2160],
        currentIndex: 0,
        inPip: true,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: const <int?>[2160],
              currentIndex: 0,
              inPip: true,
            )
            .kind,
        ThermalQualityKind.unlighten,
      );
    });

    test('in PiP an adaptive master gets no hint', () {
      final governor = ThermalQualityGovernor();
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: const <int?>[0],
              currentIndex: 0,
              inPip: true,
            )
            .isNone,
        isTrue,
      );
    });

    test('in PiP a drop episode survives untouched and resumes after', () {
      final governor = ThermalQualityGovernor();
      const qualities = <int?>[2160, 1080, 720];
      // Hot out of PiP: drops 4K → 1080p.
      final drop = governor.evaluate(
        thermal: ThermalState.serious,
        qualities: qualities,
        currentIndex: 0,
      );
      expect(drop.kind, ThermalQualityKind.drop);
      expect(drop.targetIndex, 1);
      // PiP opens and the PiP drop moves to 720p: the governor sees
      // neither a restore nor a cancellation — its episode survives.
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: qualities,
              currentIndex: 2,
              inPip: true,
            )
            .isNone,
        isTrue,
      );
      // PiP closes back on the governor's dropped-to stream: two
      // nominal ticks still restore the original.
      governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: qualities,
        currentIndex: 1,
      );
      final restore = governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: qualities,
        currentIndex: 1,
      );
      expect(restore.kind, ThermalQualityKind.restore);
      expect(restore.targetIndex, 0);
    });
  });
}
