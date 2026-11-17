import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/extensions/base_provider.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/utils/layout_constants.dart';
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

/// What the Home header's provider chip reads, or null when it is hidden.
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

/// The Home header chip (puzzle icon + label) that opens the Select
/// Provider dialog (v5). It replaced the v4 source pill row: the dialog
/// is the one place a plugin is chosen.
class HomeProviderChip extends ConsumerWidget {
  const HomeProviderChip({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final active = ref.watch(activeProviderProvider);
    final installed = ref.watch(extensionManagerProvider);
    final label = homeProviderChipLabel(
      installed: installed,
      active: active,
      selectLabel: l10n.homeProviderSelect,
    );
    if (label == null) return const SizedBox.shrink();
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final isDebug = active?.isDebug ?? false;
    return Padding(
      padding: const EdgeInsets.only(right: LayoutConstants.spacingMd),
      child: CardsWrapper(
        onTap: onTap,
        borderRadius: BorderRadius.circular(50),
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: onSurface.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(50),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.extension, color: onSurface, size: 16),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 110),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: onSurface,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (isDebug) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
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
            ],
          ),
        ),
      ),
    );
  }
}
