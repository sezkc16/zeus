/// Stall-fallback re-open decision (+48, +49, +50, +55): +55 removed the
/// +49 re-open as the default return path (it showed 00:00/LIVE + black
/// + spinner for ~3-4 s on every return) — return is a plain pause/resume
/// now, and the re-open survives only as the fallback when the plain
/// resume is verifiably dead (no position progress 8 s after
/// resume-play). The fallback is only wanted when the player was
/// actually background-paused: PiP keeps decoding, an open landing
/// re-syncs on its own, and a film that never started has no position
/// to re-open at. +50: only after a REAL backgrounding
/// (`paused`/`hidden` → `resumed`) — a transient `inactive` (Control
/// Center, Notification Center, a call) returns to `resumed` without
/// ever backgrounding, and re-opening for one restarts the film for
/// nothing (user proof 2026-11-16, The Odyssey). +55: the old
/// `pipEnabled` gate is gone — with automatic PiP removed, the setting
/// no longer implies a live window; only an actually-open window
/// (`inPip`) skips the fallback.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_ios_options.dart';

void main() {
  group('shouldResyncDecoderOnResume', () {
    test('all gates pass => re-sync (the PiP-OFF Home → return case)', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          inPip: false,
          awaitingPrebuffer: false,
          startedPlaying: true,
          hasStream: true,
        ),
        isTrue,
      );
    });

    test('PiP setting ON but no window => re-sync (auto-PiP removed in +55: '
        'the setting no longer implies a live window)', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          inPip: false,
          awaitingPrebuffer: false,
          startedPlaying: true,
          hasStream: true,
        ),
        isTrue,
      );
    });

    test('PiP window was up => no re-sync (it kept decoding)', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          inPip: true,
          awaitingPrebuffer: false,
          startedPlaying: true,
          hasStream: true,
        ),
        isFalse,
      );
    });

    test('open landing => no re-sync (it re-syncs on its own)', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          inPip: false,
          awaitingPrebuffer: true,
          startedPlaying: true,
          hasStream: true,
        ),
        isFalse,
      );
    });

    test('film never started => no re-sync (no position to seek to)', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          inPip: false,
          awaitingPrebuffer: false,
          startedPlaying: false,
          hasStream: true,
        ),
        isFalse,
      );
    });

    test('no stream open => no re-sync', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          inPip: false,
          awaitingPrebuffer: false,
          startedPlaying: true,
          hasStream: false,
        ),
        isFalse,
      );
    });

    test(
      'never backgrounded (Control Center / Notification Center) => '
      'no re-open (+50)',
      () {
        expect(
          shouldResyncDecoderOnResume(
            wasBackgrounded: false,
            inPip: false,
            awaitingPrebuffer: false,
            startedPlaying: true,
            hasStream: true,
          ),
          isFalse,
        );
      },
    );

    test(
      'backgrounded then resumed, all gates pass => re-open '
      '(+50 keeps the +49 Home → return fix)',
      () {
        expect(
          shouldResyncDecoderOnResume(
            wasBackgrounded: true,
            inPip: false,
            awaitingPrebuffer: false,
            startedPlaying: true,
            hasStream: true,
          ),
          isTrue,
        );
      },
    );
  });

  group('is4KVideo (+56: the 4K-only reconnect gate)', () {
    test('3840x2160 is 4K', () {
      expect(is4KVideo(width: 3840, height: 2160), isTrue);
    });

    test('4096x2160 (DCI) is 4K', () {
      expect(is4KVideo(width: 4096, height: 2160), isTrue);
    });

    test('3840x1600 (ultrawide) is 4K', () {
      expect(is4KVideo(width: 3840, height: 1600), isTrue);
    });

    test('2560x1440 is not 4K', () {
      expect(is4KVideo(width: 2560, height: 1440), isFalse);
    });

    test('1920x1080 is not 4K', () {
      expect(is4KVideo(width: 1920, height: 1080), isFalse);
    });

    test('a lone width or height still decides', () {
      expect(is4KVideo(width: 3840, height: null), isTrue);
      expect(is4KVideo(width: null, height: 2160), isTrue);
      expect(is4KVideo(width: 1920, height: null), isFalse);
    });

    test('unreadable dimensions are not 4K (plain resume is the safe '
        'default)', () {
      expect(is4KVideo(width: null, height: null), isFalse);
    });
  });

  group('iosResumeAction (+56: 4K re-opens, everything else plain-resumes)',
      () {
    test('4K after a real backgrounding, playing => re-open', () {
      expect(
        iosResumeAction(
          wasBackgrounded: true,
          inPip: false,
          wasPlaying: true,
          is4K: true,
        ),
        IosResumeAction.reopen4K,
      );
    });

    test('1080p after a real backgrounding, playing => plain resume', () {
      expect(
        iosResumeAction(
          wasBackgrounded: true,
          inPip: false,
          wasPlaying: true,
          is4K: false,
        ),
        IosResumeAction.plainResume,
      );
    });

    test('not playing => nothing (a film paused by hand stays paused)', () {
      expect(
        iosResumeAction(
          wasBackgrounded: true,
          inPip: false,
          wasPlaying: false,
          is4K: true,
        ),
        IosResumeAction.none,
      );
    });

    test('PiP window up => nothing (it kept decoding)', () {
      expect(
        iosResumeAction(
          wasBackgrounded: true,
          inPip: true,
          wasPlaying: true,
          is4K: true,
        ),
        IosResumeAction.none,
      );
    });

    test('no real backgrounding (Control Center) => nothing', () {
      expect(
        iosResumeAction(
          wasBackgrounded: false,
          inPip: false,
          wasPlaying: true,
          is4K: true,
        ),
        IosResumeAction.none,
      );
    });
  });
}
