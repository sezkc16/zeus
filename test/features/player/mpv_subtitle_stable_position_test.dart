/// The subtitle's one fixed place (+25, build 86).
///
/// The caption used to sit at 40px with the chrome hidden and 116px with it
/// up, so it jumped whenever the controls or the lock pill appeared — and
/// 40px plus a saved raise was already ~140px up on a phone in landscape.
/// The base is now one fixed 16px in every state, the raise still lifts it
/// from there, and the centre-third slide moves the raise.
///
/// Build 86: in MANUAL mode (Auto-Adjust off) the caption sticks to exactly
/// one place — 16px + the saved raise — in every chrome state. The old
/// `max(resting, 116)` forced a manual caption to at least 116px whenever
/// the chrome was up, so it jumped up with the controls and dropped when
/// they hid. The 116px lift is Auto-Adjust's alone now: with Auto-Adjust on
/// the caption still sits just above the controls while they are visible
/// and low when they hide.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:zorox/features/player/presentation/mpv/golden_drawer.dart';
import 'package:zorox/features/player/presentation/mpv/golden_player_controls.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_subtitle_style.dart';
import 'package:zorox/features/settings/presentation/player_settings_provider.dart';

void main() {
  const settings = PlayerSettings();

  SubtitleViewConfiguration configOf({
    PlayerSettings s = settings,
    double screenHeight = 360,
    required bool controlsVisible,
    bool isPip = false,
    double drawerWidth = 0,
  }) =>
      mpvSubtitleViewConfiguration(
        s,
        screenHeight: screenHeight,
        controlsVisible: controlsVisible,
        isPip: isPip,
        drawerWidth: drawerWidth,
      );

  group('the caption stays in one fixed place', () {
    test('chrome down: 16px above the bottom edge', () {
      final config = configOf(controlsVisible: false);
      expect(config.padding.bottom, 16.0);
    });

    test(
      'manual mode: controls showing does NOT move the caption (build 86)',
      () {
        // The viewer chose this raise; showing the controls must not lift
        // it. The old max(resting, 116) moved it to 116px whenever the
        // chrome was up.
        final down = configOf(controlsVisible: false);
        final up = configOf(controlsVisible: true);
        expect(up.padding.bottom, 16.0);
        expect(up.padding, down.padding);
      },
    );

    test('manual mode: a small raise stays put with the controls up', () {
      const raised = PlayerSettings(subtitleRaise: 0.1); // 16 + 36 px
      final down = configOf(s: raised, controlsVisible: false);
      final up = configOf(s: raised, controlsVisible: true);
      expect(down.padding.bottom, 16.0 + 0.1 * 360);
      expect(up.padding, down.padding);
    });

    test('auto-adjust still lifts clear of the controls while they show', () {
      const auto = PlayerSettings(subtitleAutoAdjust: true);
      final down = configOf(s: auto, controlsVisible: false);
      final up = configOf(s: auto, controlsVisible: true);
      expect(down.padding.bottom, 16.0);
      expect(up.padding.bottom, kMpvSubtitlePaddingBottomControlsVisible);
    });

    test('auto-adjust ignores the saved raise in both chrome states', () {
      const auto = PlayerSettings(
        subtitleAutoAdjust: true,
        subtitleRaise: 0.2,
      );
      expect(
        configOf(s: auto, controlsVisible: false).padding.bottom,
        16.0,
      );
      expect(
        configOf(s: auto, controlsVisible: true).padding.bottom,
        kMpvSubtitlePaddingBottomControlsVisible,
      );
    });

    test('the raise still lifts from the low base', () {
      final middle = configOf(
        s: const PlayerSettings(subtitleRaise: 0.1),
        controlsVisible: false,
      );
      expect(middle.padding.bottom, 16.0 + 0.1 * 360);
      final top = configOf(
        s: const PlayerSettings(subtitleRaise: 0.2),
        controlsVisible: false,
      );
      expect(top.padding.bottom, 16.0 + 0.2 * 360);
    });

    test('PiP keeps its own small padding, raise on top', () {
      final pip = configOf(controlsVisible: false, isPip: true);
      expect(pip.padding.bottom, 8.0);
      final pipRaised = configOf(
        s: const PlayerSettings(subtitleRaise: 0.2),
        controlsVisible: false,
        isPip: true,
      );
      expect(pipRaised.padding.bottom, 8.0 + 0.2 * 360);
    });
  });

  group('a drawer open over the video shifts the caption left (build 86)', () {
    test('no drawer: the right padding is the plain 16px', () {
      final config = configOf(controlsVisible: false);
      expect(config.padding.right, 16.0);
    });

    test('an open drawer adds its width to the right padding', () {
      final closed = configOf(controlsVisible: false);
      final open = configOf(controlsVisible: false, drawerWidth: 400);
      expect(open.padding.right, 16.0 + 400);
      // Only the right inset moves: the bottom stays the caption's own
      // place, so the drawer never lifts or drops it.
      expect(open.padding.bottom, closed.padding.bottom);
      expect(open.padding.left, closed.padding.left);
      expect(open.padding.top, closed.padding.top);
    });

    test('the shift applies in both chrome states', () {
      final down = configOf(controlsVisible: false, drawerWidth: 400);
      final up = configOf(controlsVisible: true, drawerWidth: 400);
      expect(down.padding.right, 416.0);
      expect(up.padding.right, 416.0);
      expect(up.padding.bottom, down.padding.bottom);
    });

    test('the drawer width is 85% of the screen, capped at 400px', () {
      expect(goldenDrawerWidth(800), 400.0);
      expect(goldenDrawerWidth(400), 340.0);
      expect(goldenDrawerWidth(470.59), closeTo(400.0, 0.01));
    });
  });

  group('the centre-third slide moves the raise', () {
    test('up a tenth of the screen adds a tenth of the range', () {
      // A tenth of the screen is a tenth of the 0.2 range: 0.02.
      expect(subtitleRaiseAfterSlide(0.1, 0.1), closeTo(0.12, 0.0001));
      expect(subtitleRaiseAfterSlide(0.0, 0.5), closeTo(0.1, 0.0001));
    });

    test('down a tenth lowers it', () {
      expect(subtitleRaiseAfterSlide(0.1, -0.1), closeTo(0.08, 0.0001));
    });

    test('a full screen up is the whole range', () {
      expect(subtitleRaiseAfterSlide(0.0, 1.0), 0.2);
    });

    test('a full screen down is the bottom', () {
      expect(subtitleRaiseAfterSlide(0.2, -1.0), 0.0);
    });

    test('it clamps at both ends', () {
      expect(subtitleRaiseAfterSlide(0.19, 0.1), 0.2);
      expect(subtitleRaiseAfterSlide(0.01, -0.1), 0.0);
    });
  });
}
