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

    test('controls showing: lifted clear of the bottom control row (v9)', () {
      // The caption was drawn under the icon row (user screenshot,
      // 2026-11-17). While the row is up the caption sits above it, and
      // it returns to its own place when the row hides.
      final down = configOf(controlsVisible: false);
      final up = configOf(controlsVisible: true);
      expect(up.padding.bottom, kMpvSubtitlePaddingBottomControlsVisible);
      expect(up.padding.bottom, greaterThan(down.padding.bottom));
      expect(configOf(controlsVisible: false).padding, down.padding);
      // Only the bottom inset moves.
      expect(up.padding.left, down.padding.left);
      expect(up.padding.right, down.padding.right);
      expect(up.padding.top, down.padding.top);
    });

    test('a caption already raised clear of the row does not move', () {
      const raised = PlayerSettings(subtitleRaise: 0.4); // 16 + 144 px
      final down = configOf(s: raised, controlsVisible: false);
      final up = configOf(s: raised, controlsVisible: true);
      expect(down.padding.bottom, 16.0 + 0.4 * 360);
      expect(up.padding, down.padding);
    });

    test('a small raise is lifted only as far as the row needs', () {
      const raised = PlayerSettings(subtitleRaise: 0.1); // 16 + 36 px
      final up = configOf(s: raised, controlsVisible: true);
      expect(up.padding.bottom, kMpvSubtitlePaddingBottomControlsVisible);
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
