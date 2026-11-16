/// The subtitle's one fixed place (+25).
///
/// The caption used to sit at 40px with the chrome hidden and 116px with it
/// up, so it jumped whenever the controls or the lock pill appeared — and
/// 40px plus a saved raise was already ~140px up on a phone in landscape.
/// The base is now one fixed 16px in every state, the raise still lifts it
/// from there, and the centre-third slide moves the raise.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:skystream/features/player/presentation/mpv/golden_player_controls.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_subtitle_style.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';

void main() {
  const settings = PlayerSettings();

  SubtitleViewConfiguration configOf({
    PlayerSettings s = settings,
    double screenHeight = 360,
    required bool controlsVisible,
    bool isPip = false,
  }) =>
      mpvSubtitleViewConfiguration(
        s,
        screenHeight: screenHeight,
        controlsVisible: controlsVisible,
        isPip: isPip,
      );

  group('the caption stays in one fixed place', () {
    test('chrome down: 16px above the bottom edge', () {
      final config = configOf(controlsVisible: false);
      expect(config.padding.bottom, 16.0);
    });

    test('chrome up (controls or settings showing): the same 16px', () {
      final down = configOf(controlsVisible: false);
      final up = configOf(controlsVisible: true);
      expect(up.padding.bottom, 16.0);
      expect(up.padding, down.padding);
    });

    test('locked with the pill showing and locked with it faded: the '
        'same 16px', () {
      // The pill rides the chrome: showing is chrome up, faded is chrome
      // down. Both must leave the caption where it is.
      final faded = configOf(controlsVisible: false);
      final showing = configOf(controlsVisible: true);
      expect(showing.padding.bottom, 16.0);
      expect(faded.padding, showing.padding);
    });

    test('the raise still lifts from the low base', () {
      final middle = configOf(
        s: const PlayerSettings(subtitleRaise: 0.1),
        controlsVisible: false,
      );
      expect(middle.padding.bottom, 16.0 + 0.1 * 360);
      final top = configOf(
        s: const PlayerSettings(subtitleRaise: 0.2),
        controlsVisible: true,
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
