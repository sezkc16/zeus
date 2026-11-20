/// Olympus Noir theme cards (build 102) — the "APP THEME" section of
/// Settings: Obsidian / Aurora / Imperial, each with a miniature
/// preview. The selected card wears a gold outline, a gold checkmark
/// and a soft glow.
///
/// The three cards map onto the existing theme system, so no saved
/// setting is ever lost:
///
/// * Obsidian → [ZoroxThemeVariant.obsidian] (the new Olympus Noir
///   palette, #090B10 / #E7BE63).
/// * Aurora → [ZoroxThemeVariant.liquidGlass] (the cool glass dark
///   theme, closest in spirit to the mockup's aurora card).
/// * Imperial → [ZoroxThemeVariant.arenaGold] (the warm gold dark
///   theme, closest to the mockup's imperial card).
///
/// Midnight and Frost are not in the mockup, so they live one line
/// below as "More themes" chips — still selectable, never removed.
library;

import 'package:flutter/material.dart';
import 'package:zorox/core/theme/olympus.dart';
import 'package:zorox/core/theme/theme_variant.dart';

class OlympusThemeCards extends StatelessWidget {
  const OlympusThemeCards({
    super.key,
    required this.current,
    required this.onChanged,
  });

  final ZoroxThemeVariant current;
  final ValueChanged<ZoroxThemeVariant> onChanged;

  @override
  Widget build(BuildContext context) {
    const cards = <_OlympusThemeCard>[
      _OlympusThemeCard(
        label: 'Obsidian',
        variant: ZoroxThemeVariant.obsidian,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A1D26), Color(0xFF090B10)],
        ),
        glyph: Icons.account_balance_rounded,
        glyphColor: kOlympusGold,
      ),
      _OlympusThemeCard(
        label: 'Aurora',
        variant: ZoroxThemeVariant.liquidGlass,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF123B33), Color(0xFF0B0D12)],
        ),
        glyph: Icons.nights_stay_rounded,
        glyphColor: kOlympusJade,
      ),
      _OlympusThemeCard(
        label: 'Imperial',
        variant: ZoroxThemeVariant.arenaGold,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3A2A12), Color(0xFF0B0D12)],
        ),
        glyph: Icons.emoji_events_rounded,
        glyphColor: Color(0xFFD4AF37),
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
                    onTap: () => onChanged(card.variant),
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
                  onTap: () => onChanged(variant),
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
    required this.gradient,
    required this.glyph,
    required this.glyphColor,
  });

  final String label;
  final ZoroxThemeVariant variant;
  final Gradient gradient;
  final IconData glyph;
  final Color glyphColor;
}

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
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                height: 64,
                decoration: BoxDecoration(
                  gradient: card.gradient,
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
                child: Center(
                  child: Icon(card.glyph, color: card.glyphColor, size: 26),
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
