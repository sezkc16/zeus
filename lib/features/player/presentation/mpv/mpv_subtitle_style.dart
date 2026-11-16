/// The mpv player's subtitle look, shared by the player screen and its CC
/// sheet so the Style tab's preview and the on-video caption can never
/// disagree.
///
/// The mpv engine (media_kit) draws subtitles itself through
/// [SubtitleViewConfiguration], so — unlike libVLC — the style is a plain
/// Flutter [TextStyle] plus a bottom padding, and it applies at once while
/// the video plays: changing a setting rebuilds the configuration, no
/// re-open needed.
///
/// The numbers come from the stock [PlayerSettings] the VLC player already
/// persists, so the two players share one saved style:
///
///   * size — the stock `subtitleSize` (default 22). The Style tab offers
///     S/M/L/XL steps of it;
///   * text colour — the stock `subtitleColor`;
///   * background — the stock `subtitleBackgroundColor` + opacity. "None" is
///     opacity 0, "semi" 0.5, "solid" 1.0, all on black;
///   * edge — the stock `subtitleOutline` for none/outline, and the mpv-only
///     `subtitleShadow` flag for a drop shadow (the stock outline enum has
///     no shadow; libVLC ignores the flag);
///   * position — the stock `subtitleRaise`, a share of the picture's height
///     the lines are lifted from the bottom. The Style tab's Position
///     dropdown writes it, and so do the swipes on the video (horizontal:
///     right lifts, left drops; centre-third vertical: up lifts, down
///     drops), through `setSubtitleRaise`, which holds it to the stock
///     range [0, 0.2]. Auto-Adjust (+27) ignores the saved raise and
///     sits the caption just above the bottom controls while they are
///     visible, low when hidden (see [subtitleEffectiveRaise]).
library;

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../settings/presentation/player_settings_provider.dart';
import '../../domain/subtitle_style.dart';

/// The Style tab's size steps: S/M/L/XL, as stock font sizes.
const Map<String, double> kMpvSubtitleSizes = <String, double>{
  'S': 16,
  'M': 20,
  'L': 24,
  'XL': 28,
};

/// The Style tab's text colours, in order.
const List<(String label, int value)> kMpvSubtitleColors =
    <(String, int)>[
      ('White', 0xFFFFFFFF),
      ('Yellow', 0xFFFFFF00),
      ('Cyan', 0xFF00FFFF),
      ('Green', 0xFF00FF00),
    ];

/// The Style tab's background choices: label + the opacity written with
/// black. "None" is opacity 0 — no box at all.
const List<(String label, double opacity)> kMpvSubtitleBackgrounds =
    <(String, double)>[
      ('None', 0.0),
      ('Semi', 0.5),
      ('Solid', 1.0),
    ];

/// The Style tab's edge choices.
const List<String> kMpvSubtitleEdges = <String>['None', 'Outline', 'Shadow'];

/// The bottom padding the caption sits at, in every chrome state — one
/// fixed value (+25). It used to be 40px with the bars hidden and 116px
/// with them up, so the caption jumped up whenever the controls or the
/// lock pill appeared and dropped again when they left; and 40px plus a
/// saved raise was already ~140px up on a phone in landscape. 16px puts
/// it close to the bottom edge, the way a normal player does, and the
/// saved raise still lifts it from there. The PiP window keeps its own
/// smaller padding below.
const double kMpvSubtitlePaddingBottom = 16;

/// The bottom padding Auto-Adjust uses while the bottom controls are
/// visible (+27): the caption sits just above them. 116px is the pre-+25
/// chrome-up padding — the bars themselves measure ~110–131px (seekbar +
/// buttons + SafeArea) — so the caption clears them without floating far
/// above the picture. With the chrome hidden Auto-Adjust uses the same
/// 16px base as the manual position.
const double kMpvSubtitlePaddingBottomControlsVisible = 116;

/// The PiP window's subtitle scale: Android PiP is a tiny window (about a
/// third of the screen's width on a phone), and the caption is a Flutter
/// overlay whose font size is fixed logical pixels — the video texture
/// scales down with the window but the text does not, so a 22pt caption
/// overflows the window and is cut off at the right edge (user screenshot,
/// 2026-11-14, Flip 5). Halving the size keeps two-line dialogue inside
/// the window with room to read; the Text wraps, so nothing is ever cut
/// off. The same factor halves the side/bottom padding, which is also
/// sized for a full screen: 40px of bottom padding is a third of a ~140px
/// PiP window. Applies to Android PiP only — fullscreen playback is
/// untouched.
const double kMpvSubtitlePipFontScale = 0.5;
const double kMpvSubtitlePipPaddingSide = 8;
const double kMpvSubtitlePipPaddingBottom = 8;

/// The text style the on-video caption (and the Style tab's preview line)
/// are drawn in, from the saved settings.
///
/// [isPip] halves the font size for the Android PiP window (see
/// [kMpvSubtitlePipFontScale]): the caption must fit a window a third the
/// screen's width, and the overlay does not scale with it.
TextStyle mpvSubtitleTextStyle(PlayerSettings settings, {bool isPip = false}) {
  final background = Color(
    settings.subtitleBackgroundColor,
  ).withValues(alpha: settings.subtitleBackgroundOpacity.clamp(0.0, 1.0));
  final text = Color(
    settings.subtitleColor,
  ).withValues(alpha: settings.subtitleTextOpacity.clamp(0.0, 1.0));
  // Scale first, then clamp to a PiP floor of 6: the stock clamp's 10pt
  // floor would undo the halving for the S/M steps.
  final fontSize = (settings.subtitleSize.clamp(10.0, 80.0) *
          (isPip ? kMpvSubtitlePipFontScale : 1.0))
      .clamp(6.0, 80.0);
  return TextStyle(
    height: 1.4,
    fontSize: fontSize,
    // The Font setting (Default / Netflix / Serif / Monospace): the stock
    // VLC path applies it at creation, and mpv must too — otherwise the
    // setting silently does nothing on the mpv caption.
    fontFamily: subtitleFontFamily(settings.subtitleFont),
    color: text,
    fontWeight: settings.subtitleBold ? FontWeight.bold : FontWeight.w500,
    // Opacity 0 is no box at all, whatever the colour says — null, not a
    // transparent colour, is how the view is told to draw none.
    backgroundColor: background.a == 0 ? null : background,
    shadows: _mpvSubtitleShadows(settings),
  );
}

/// The edge, as Flutter shadows: none draws nothing, an outline is drawn as
/// shadows around each glyph, a drop shadow as one offset shadow.
List<Shadow>? _mpvSubtitleShadows(PlayerSettings settings) {
  if (settings.subtitleShadow) {
    return const <Shadow>[
      Shadow(
        offset: Offset(2, 2),
        blurRadius: 3,
        color: Color(0xcc000000),
      ),
    ];
  }
  switch (settings.subtitleOutline) {
    case SubtitleOutline.none:
      return null;
    case SubtitleOutline.thin:
    case SubtitleOutline.normal:
    case SubtitleOutline.thick:
      final spread = settings.subtitleOutline == SubtitleOutline.thick
          ? 2.0
          : 1.5;
      return <Shadow>[
        for (final dx in <double>[-spread, 0.0, spread])
          for (final dy in <double>[-spread, 0.0, spread])
            if (dx != 0 || dy != 0)
              Shadow(
                offset: Offset(dx, dy),
                blurRadius: 0,
                color: Colors.black,
              ),
      ];
  }
}

/// The whole subtitle configuration for the mpv video view: the text style
/// above, centred, lifted by the saved raise.
///
/// [screenHeight] is the landscape screen height, the frame the raise is a
/// share of. The lift is added on top of the fixed base padding.
///
/// [controlsVisible] no longer moves the caption (+25) — unless
/// Auto-Adjust is on (+27): then the caption sits just above the bottom
/// controls while they are visible and low when they are hidden, and the
/// saved raise is ignored. The parameter stays so call sites keep passing
/// the chrome state and tests can assert the independence in the manual
/// case and the dependence in the auto case.
///
/// [isPip] is the Android PiP window: the font is halved and the padding
/// shrunk to PiP proportions (see [kMpvSubtitlePipFontScale]) — the
/// overlay is fixed logical pixels and does not scale with the window.
/// The raise still applies, but it is a share of the PiP window's own
/// (small) height, so it shrinks with it. Auto-Adjust is ignored in PiP:
/// there is no chrome in the window, so the manual raise applies.
SubtitleViewConfiguration mpvSubtitleViewConfiguration(
  PlayerSettings settings, {
  required double screenHeight,
  required bool controlsVisible,
  bool isPip = false,
}) {
  // Auto-Adjust (+27): the automatic position, not the saved raise.
  // Off in PiP — no chrome there, the manual raise applies.
  final autoAdjust = settings.subtitleAutoAdjust && !isPip;
  final liftPx =
      (autoAdjust ? 0.0 : settings.subtitleRaise.clamp(0.0, 0.5)) *
      screenHeight;
  if (isPip) {
    return SubtitleViewConfiguration(
      style: mpvSubtitleTextStyle(settings, isPip: true),
      textAlign: TextAlign.center,
      textScaler: const TextScaler.linear(1.0),
      padding: EdgeInsets.fromLTRB(
        kMpvSubtitlePipPaddingSide,
        0,
        kMpvSubtitlePipPaddingSide,
        kMpvSubtitlePipPaddingBottom + liftPx,
      ),
    );
  }
  // One fixed base in every state (+25): the caption used to sit at 40px
  // with the chrome hidden and 116px with it up. Auto-Adjust (+27) puts
  // it just above the controls while they are visible, low when hidden.
  final base = autoAdjust && controlsVisible
      ? kMpvSubtitlePaddingBottomControlsVisible
      : kMpvSubtitlePaddingBottom;
  return SubtitleViewConfiguration(
    style: mpvSubtitleTextStyle(settings),
    textAlign: TextAlign.center,
    // media_kit's SubtitleView scales text down by sqrt(area / 1920x1080)
    // when no textScaler is given — on a phone in landscape that is ~0.44,
    // so a 22pt caption renders at ~10pt. 1.0 renders the configured size
    // as-is, matching the VLC player's look.
    textScaler: const TextScaler.linear(1.0),
    padding: EdgeInsets.fromLTRB(16, 0, 16, base + liftPx),
  );
}

/// Which size step [size] is nearest to, for the Style tab's selected chip.
String mpvSizeStepFor(double size) {
  var best = 'M';
  var bestDistance = double.infinity;
  for (final entry in kMpvSubtitleSizes.entries) {
    final distance = (entry.value - size).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      best = entry.key;
    }
  }
  return best;
}

/// Which background choice [opacity] is nearest to, for the Style tab.
String mpvBackgroundFor(double opacity) {
  var best = 'Semi';
  var bestDistance = double.infinity;
  for (final entry in kMpvSubtitleBackgrounds) {
    final distance = (entry.$2 - opacity).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      best = entry.$1;
    }
  }
  return best;
}

/// Which edge choice the settings describe, for the Style tab.
String mpvEdgeFor(PlayerSettings settings) {
  if (settings.subtitleShadow) return 'Shadow';
  if (settings.subtitleOutline == SubtitleOutline.none) return 'None';
  return 'Outline';
}
