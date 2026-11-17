import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/extensions/base_provider.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/cards_wrapper.dart';

/// A plugin's display name without the class-name suffix some extension
/// authors publish it with ("AnikotoProvider" -> "Anikoto"). A name that
/// is nothing but the suffix is left alone.
String cleanPluginName(String name) {
  final trimmed = name.trim();
  const suffix = 'Provider';
  if (trimmed.length > suffix.length && trimmed.endsWith(suffix)) {
    return trimmed.substring(0, trimmed.length - suffix.length).trim();
  }
  return trimmed;
}

/// What the Home header's provider line names, or null when it is hidden.
///
/// Hidden with no plugin installed. With plugins installed it is the
/// active provider's own name, or [selectLabel] when none is active and
/// Home shows the key-free feed. An active provider always shows, even
/// if the installed list has not caught up with it yet.
String? homeProviderChipLabel({
  required List<SkyStreamProvider> installed,
  required SkyStreamProvider? active,
  required String selectLabel,
}) {
  if (active != null) return active.name;
  if (installed.isEmpty) return null;
  return selectLabel;
}

/// Whether Home's header shows the provider line: an active provider, or
/// at least one installed plugin to pick from.
bool homeProviderChipVisible(WidgetRef ref) =>
    ref.watch(activeProviderProvider) != null ||
    ref.watch(extensionManagerProvider).isNotEmpty;

/// The Home header's second line (v6, approved design B): plain text
/// directly under the logo + app name, left-aligned with the logo —
/// `from Provider ▾`, the provider's name in the accent colour, or
/// "Select source ▾" when no provider is active. No pill, no background,
/// no border; a soft shadow keeps it readable over the hero art.
///
/// It is the AppBar's `bottom`, so the toolbar row above it (logo left;
/// search + settings right) is untouched and the line can never run into
/// those buttons. The whole line is the tap target and opens the Select
/// Provider dialog. Hidden (zero height) when no plugin is installed.
class HomeProviderChipBar extends ConsumerWidget
    implements PreferredSizeWidget {
  const HomeProviderChipBar({super.key, required this.onTap});

  final VoidCallback onTap;

  /// Height of the bar and of the tap target.
  static const double tapHeight = 44;

  /// Gap between the toolbar row and the text.
  static const double gapAbove = 5;

  /// Share of the screen width the line may take before the provider
  /// name ellipsizes.
  static const double maxWidthFraction = 0.55;

  /// Key of the tap target (tests).
  static const Key tapKey = ValueKey('home-provider-line');

  @override
  Size get preferredSize => const Size.fromHeight(tapHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final active = ref.watch(activeProviderProvider);
    final installed = ref.watch(extensionManagerProvider);
    final label = homeProviderChipLabel(
      installed: installed,
      active: active,
      selectLabel: l10n.homeProviderSelectSource,
    );
    if (label == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // Same colour family as the "Zeus" wordmark above it: white in the
    // dark variants, the dark on-surface colour in the light one.
    final base = theme.colorScheme.onSurface.withValues(alpha: 0.95);
    final accent = theme.colorScheme.primary;
    final shadows = [
      Shadow(
        color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.6),
        blurRadius: 6,
        offset: const Offset(0, 1),
      ),
    ];
    final baseStyle = TextStyle(
      color: base,
      fontSize: 13,
      height: 1.25,
      fontWeight: FontWeight.w600,
      shadows: shadows,
    );
    final accentStyle = baseStyle.copyWith(
      color: accent,
      fontWeight: FontWeight.w700,
    );
    final isDebug = active?.isDebug ?? false;
    final width = MediaQuery.sizeOf(context).width;

    return SizedBox(
      height: tapHeight,
      child: Align(
        alignment: AlignmentDirectional.topStart,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width * maxWidthFraction),
          child: CardsWrapper(
            key: tapKey,
            onTap: onTap,
            scaleFactor: 1.0,
            borderRadius: BorderRadius.circular(8),
            child: Semantics(
              button: true,
              child: SizedBox(
                height: tapHeight,
                child: Padding(
                  // The AppBar title's own start inset, so the text starts
                  // under the logo's left edge. The AppBar adds the
                  // safe-area inset to both.
                  padding: const EdgeInsetsDirectional.only(
                    start: NavigationToolbar.kMiddleSpacing,
                    end: 8,
                    top: gapAbove,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.topStart,
                    widthFactor: 1,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (active != null) ...[
                          Text(l10n.homeProviderFrom, style: baseStyle),
                          const SizedBox(width: 4),
                        ],
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: accentStyle,
                          ),
                        ),
                        if (isDebug) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              l10n.debug,
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 2),
                        Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: base,
                          shadows: shadows,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
