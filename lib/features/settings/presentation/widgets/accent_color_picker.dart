import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/accent_color.dart';

/// Accent color picker — the design preview's swatch row in Settings >
/// General: the label "Accent Color — Green is default" and the 8 presets
/// in one row of 38px circles. Tapping a swatch sets the accent
/// immediately across the whole app (the theme is seeded from the accent,
/// so the MaterialApp rebuilds — no restart, no re-login). Gold is the
/// default; the background stays black and the layout is untouched, only
/// the accent changes.
class AccentColorPicker extends ConsumerWidget {
  const AccentColorPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(accentColorProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: Text(
            'Accent Color — Green is default',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in ZoroxAccent.values)
                _Swatch(
                  option: option,
                  selected: option == accent,
                  onTap: () => ref
                      .read(accentColorProvider.notifier)
                      .setAccent(option),
                ),
            ],
          ),
        ),
        Divider(
          height: 1,
          indent: 62,
          endIndent: 16,
          color: Theme.of(context).dividerColor.withValues(alpha: 0.8),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  final ZoroxAccent option;
  final bool selected;
  final VoidCallback onTap;

  const _Swatch({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // A dark check on the light accents (Gold, Orange, Green, Silver),
    // a white check on the dark ones (Red, Blue, Violet, Pink).
    final checkColor = option.color.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;
    return Semantics(
      button: true,
      selected: selected,
      label: option.label,
      child: Tooltip(
        message: option.label,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: option.color,
              shape: BoxShape.circle,
              // The preview marks the selected swatch with a white ring.
              border: Border.all(
                color: selected
                    ? Colors.white
                    : option.color.withValues(alpha: 0.4),
                width: selected ? 2.5 : 1.5,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: option.color.withValues(alpha: 0.5),
                        blurRadius: 10,
                      ),
                    ]
                  : null,
            ),
            child: selected
                ? Icon(Icons.check_rounded, color: checkColor, size: 20)
                : null,
          ),
        ),
      ),
    );
  }
}
