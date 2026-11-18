/// The Android PiP window's subtitle size: the caption is a Flutter
/// overlay in fixed logical pixels, so in the tiny PiP window it stays
/// 22pt and is cut off at the right edge (user screenshot, 2026-11-14,
/// Flip 5). PiP halves the font and shrinks the padding; leaving PiP
/// restores the exact fullscreen look.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_subtitle_style.dart';
import 'package:zorox/features/settings/presentation/player_settings_provider.dart';

void main() {
  const settings = PlayerSettings();

  group('mpvSubtitleViewConfiguration PiP', () {
    test('halves the font size in PiP (22 -> 11 at the default)', () {
      final config = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: 360,
        controlsVisible: false,
        isPip: true,
      );
      expect(config.style.fontSize, 11.0);
    });

    test('halves every size step, not just the default', () {
      for (final size in <double>[16, 20, 24, 28]) {
        final config = mpvSubtitleViewConfiguration(
          settings.copyWith(subtitleSize: size),
          screenHeight: 360,
          controlsVisible: false,
          isPip: true,
        );
        expect(config.style.fontSize, size / 2);
      }
    });

    test('PiP padding is small: 8px sides, 8px bottom', () {
      final config = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: 140,
        controlsVisible: false,
        isPip: true,
      );
      expect(config.padding.left, 8.0);
      expect(config.padding.right, 8.0);
      expect(config.padding.bottom, 8.0);
    });

    test('PiP bottom still lifts by the raise, on the small height', () {
      final config = mpvSubtitleViewConfiguration(
        settings.copyWith(subtitleRaise: 0.1),
        screenHeight: 140,
        controlsVisible: false,
        isPip: true,
      );
      // 8 base + 0.1 * 140 lift.
      expect(config.padding.bottom, closeTo(22.0, 0.001));
    });

    test('fullscreen is unchanged: 22pt, 16px sides, 16px bottom', () {
      final config = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: 360,
        controlsVisible: false,
      );
      expect(config.style.fontSize, 22.0);
      expect(config.padding.left, 16.0);
      expect(config.padding.right, 16.0);
      expect(config.padding.bottom, 16.0);
    });

    test('fullscreen: in manual mode the bars coming up do NOT move the '
        'caption (build 86), same text size', () {
      // The v9 lift is Auto-Adjust's alone now: with Auto-Adjust off
      // (the default) the caption sticks to 16px + the saved raise in
      // every chrome state — controls up, controls hidden — so it never
      // jumps when the player UI shows or hides (item 5). The lift to
      // 116px with the controls up lives in the Auto-Adjust tests in
      // mpv_subtitle_stable_position_test.dart.
      final down = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: 360,
        controlsVisible: false,
      );
      final up = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: 360,
        controlsVisible: true,
      );
      expect(down.style.fontSize, 22.0);
      expect(up.style.fontSize, 22.0);
      expect(down.padding.bottom, 16.0);
      expect(up.padding.bottom, 16.0);
    });

    test('fullscreen: with Auto-Adjust on, the bars coming up still lift '
        'the caption clear of the control row (build 86)', () {
      final auto = settings.copyWith(subtitleAutoAdjust: true);
      final down = mpvSubtitleViewConfiguration(
        auto,
        screenHeight: 360,
        controlsVisible: false,
      );
      final up = mpvSubtitleViewConfiguration(
        auto,
        screenHeight: 360,
        controlsVisible: true,
      );
      expect(down.padding.bottom, 16.0);
      expect(up.padding.bottom, kMpvSubtitlePaddingBottomControlsVisible);
    });

    test('the PiP window has no control row: nothing is lifted there', () {
      final pip = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: 140,
        controlsVisible: false,
        isPip: true,
      );
      expect(pip.padding.bottom, lessThan(16.0 + 1));
    });

    test('leaving PiP restores the exact fullscreen configuration', () {
      final pip = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: 140,
        controlsVisible: false,
        isPip: true,
      );
      final full = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: 360,
        controlsVisible: false,
      );
      expect(pip.style.fontSize, isNot(full.style.fontSize));
      expect(full.style.fontSize, 22.0);
      expect(full.padding, const EdgeInsets.fromLTRB(16, 0, 16, 16));
    });

    test('PiP font never drops below 6pt even for the S step', () {
      final config = mpvSubtitleViewConfiguration(
        settings.copyWith(subtitleSize: 10),
        screenHeight: 140,
        controlsVisible: false,
        isPip: true,
      );
      expect(config.style.fontSize, 6.0);
    });
  });
}
