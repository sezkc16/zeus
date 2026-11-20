/// Olympus Noir theme cards (build 102) — the "APP THEME" section of
/// Settings: Obsidian / Aurora / Imperial, each with a miniature
/// preview. The selected card wears a gold outline, a gold checkmark
/// and a soft glow.
///
/// Build 104: the previews are real miniature scenes (a golden
/// horizon under stars, aurora bands, a golden sun — drawn in
/// Flutter, not glyph icons), and each card carries its signature
/// accent, so tapping one visibly changes the app: the theme AND
/// its accent apply together (Obsidian and Imperial are gold,
/// Aurora is sky-blue — build 109 turned it from jade-green).
/// Before this the three cards mapped onto three dark variants that
/// differed only in surface shades while the accent stayed put, so a
/// tap looked like nothing happened.
/// The accent row below still overrides the accent on its own.
///
/// The three cards map onto the existing theme system, so no saved
/// setting is ever lost:
///
/// * Obsidian → [ZoroxThemeVariant.obsidian] (the new Olympus Noir
///   palette, #090B10 / #E7BE63).
/// * Aurora → [ZoroxThemeVariant.liquidGlass] (the cool blue dark
///   theme, closest in spirit to the mockup's aurora card).
/// * Imperial → [ZoroxThemeVariant.arenaGold] (the warm gold dark
///   theme, closest to the mockup's imperial card).
///
/// Midnight and Frost are not in the mockup, so they live one line
/// below as "More themes" chips — still selectable, never removed.
library;

import 'package:flutter/material.dart';
import 'package:zorox/core/theme/accent_color.dart';
import 'package:zorox/core/theme/olympus.dart';
import 'package:zorox/core/theme/theme_variant.dart';

class OlympusThemeCards extends StatelessWidget {
  const OlympusThemeCards({
    super.key,
    required this.current,
    required this.onChanged,
  });

  final ZoroxThemeVariant current;

  /// A card tap applies the theme and its signature accent together
  /// (so the tap visibly changes the app); a "More themes" chip
  /// passes a null accent and leaves the accent alone.
  final void Function(ZoroxThemeVariant variant, ZoroxAccent? accent)
  onChanged;

  @override
  Widget build(BuildContext context) {
    const cards = <_OlympusThemeCard>[
      _OlympusThemeCard(
        label: 'Obsidian',
        variant: ZoroxThemeVariant.obsidian,
        preview: _PreviewKind.obsidian,
        signatureAccent: ZoroxAccent.gold,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A1D26), Color(0xFF090B10)],
        ),
      ),
      _OlympusThemeCard(
        label: 'Aurora',
        variant: ZoroxThemeVariant.liquidGlass,
        preview: _PreviewKind.aurora,
        signatureAccent: ZoroxAccent.green,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF123B33), Color(0xFF081210)],
        ),
      ),
      _OlympusThemeCard(
        label: 'Imperial',
        variant: ZoroxThemeVariant.arenaGold,
        preview: _PreviewKind.imperial,
        signatureAccent: ZoroxAccent.gold,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3A2A12), Color(0xFF0D0A07)],
        ),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final card in cards) ...[
                Expanded(
                  child: _ThemeCard(
                    card: card,
                    selected: current == card.variant,
                    onTap: () =>
                        onChanged(card.variant, card.signatureAccent),
                  ),
                ),
                if (card != cards.last) const SizedBox(width: 10),
              ],
            ],
          ),
          const SizedBox(height: 10),
          // Midnight and Frost are not in the mockup, but they are
          // existing themes — they stay selectable here, one line down.
          // A Wrap, not a Row: on a narrow phone (or a long locale
          // label) the chips drop to the next line instead of
          // overflowing.
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'More themes',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.6),
                ),
              ),
              for (final variant in [
                ZoroxThemeVariant.midnight,
                ZoroxThemeVariant.frost,
              ])
                _MoreThemeChip(
                  variant: variant,
                  selected: current == variant,
                  onTap: () => onChanged(variant, null),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OlympusThemeCard {
  const _OlympusThemeCard({
    required this.label,
    required this.variant,
    required this.preview,
    required this.signatureAccent,
    required this.gradient,
  });

  final String label;
  final ZoroxThemeVariant variant;

  /// Which miniature scene the card shows.
  final _PreviewKind preview;

  /// The accent that applies with this theme, so the tap visibly
  /// changes the app (gold for Obsidian and Imperial, jade-green
  /// for Aurora).
  final ZoroxAccent signatureAccent;
  final Gradient gradient;
}

/// What the card's miniature preview draws: a golden horizon under
/// stars (Obsidian), aurora bands (Aurora), a golden sun over a warm
/// horizon (Imperial). Pure widgets — no assets, no glyph icons.
enum _PreviewKind { obsidian, aurora, imperial }

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.card,
    required this.selected,
    required this.onTap,
  });

  final _OlympusThemeCard card;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              // The miniature scene, clipped to the card's shape.
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  height: 64,
                  width: double.infinity,
                  child: _ThemePreview(
                    kind: card.preview,
                    gradient: card.gradient,
                  ),
                ),
              ),
              // The border and glow, drawn above the scene so the
              // scene never covers them.
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: selected
                        ? kOlympusGold
                        : Colors.white.withValues(alpha: 0.08),
                    width: selected ? 2 : 1,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: kOlympusGold.withValues(alpha: 0.25),
                            blurRadius: 12,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
              ),
              if (selected)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: const BoxDecoration(
                      color: kOlympusGold,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: Colors.black,
                      size: 13,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            card.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: selected
                  ? kOlympusGold
                  : Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }
}

/// The card's miniature scene: a golden horizon under stars
/// (Obsidian), aurora bands (Aurora), a golden sun over a warm
/// horizon (Imperial). Pure widgets — no assets, no glyph icons —
/// so each card looks like its name at a glance.
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.kind, required this.gradient});

  final _PreviewKind kind;
  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(gradient: gradient),
      child: Stack(children: _motif()),
    );
  }

  List<Widget> _motif() {
    switch (kind) {
      case _PreviewKind.obsidian:
        return [
          // Stars.
          const Positioned(top: 8, left: 14, child: _Star()),
          const Positioned(top: 14, left: 44, child: _Star(size: 2)),
          const Positioned(top: 7, right: 20, child: _Star()),
          // Golden horizon glow.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 18,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x00E7BE63),
                    Color(0x80E7BE63),
                  ],
                ),
              ),
            ),
          ),
          // A small golden dome on the horizon.
          Positioned(
            bottom: 10,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: 20,
                height: 10,
                decoration: const BoxDecoration(
                  color: kOlympusGold,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(10),
                    topRight: Radius.circular(10),
                  ),
                ),
              ),
            ),
          ),
        ];
      case _PreviewKind.aurora:
        return [
          // Soft blue glow, top left.
          Positioned(
            top: -14,
            left: -10,
            child: Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    // Build 109: Aurora went blue — the glow follows the
                    // bands, not the (unchanged) kOlympusJade accent.
                    color: const Color(0xFF2E7DD6).withValues(alpha: 0.5),
                    blurRadius: 24,
                    spreadRadius: 6,
                  ),
                ],
              ),
            ),
          ),
          // Two diagonal aurora bands.
          Positioned(
            top: 16,
            left: -24,
            child: Transform.rotate(
              angle: -0.45,
              child: Container(
                width: 150,
                height: 9,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(0x006EA8FF),
                      Color(0xCC6EA8FF),
                      Color(0x002E7DD6),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 34,
            left: -24,
            child: Transform.rotate(
              angle: -0.45,
              child: Container(
                width: 150,
                height: 6,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(0x002E7DD6),
                      Color(0x992E7DD6),
                      Color(0x006EA8FF),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Positioned(top: 10, right: 16, child: _Star()),
        ];
      case _PreviewKind.imperial:
        return [
          // Golden sun, top right, with a soft glow.
          Positioned(
            top: 8,
            right: 12,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFD4AF37),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFD4AF37).withValues(alpha: 0.6),
                    blurRadius: 16,
                    spreadRadius: 4,
                  ),
                ],
              ),
            ),
          ),
          // Warm horizon.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 16,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x00D4AF37),
                    Color(0x66D4AF37),
                  ],
                ),
              ),
            ),
          ),
          const Positioned(top: 12, left: 16, child: _Star()),
        ];
    }
  }
}

/// One tiny star in a preview scene.
class _Star extends StatelessWidget {
  const _Star({this.size = 3});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Color(0xFFF5F3ED),
        shape: BoxShape.circle,
      ),
    );
  }
}

class _MoreThemeChip extends StatelessWidget {
  const _MoreThemeChip({
    required this.variant,
    required this.selected,
    required this.onTap,
  });

  final ZoroxThemeVariant variant;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? kOlympusGold
                : Colors.white.withValues(alpha: 0.15),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          variant.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected
                ? kOlympusGold
                : Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.75),
          ),
        ),
      ),
    );
  }
}
