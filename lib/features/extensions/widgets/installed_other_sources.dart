import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/addons/data/addon_repository.dart';
import '../../../core/nuvio/data/nuvio_repository.dart';
import '../../settings/presentation/widgets/settings_widgets.dart';

/// The Stremio add-ons and Nuvio repositories the user installed, for the
/// Plugins tab's "Installed" segment (v5): name, version, a type line and a
/// delete action each. Renders nothing when there are none.
class InstalledOtherSources extends ConsumerWidget {
  const InstalledOtherSources({super.key});

  /// Whether anything of either kind is installed.
  static bool hasAny(WidgetRef ref) =>
      ref.watch(addonRepositoryProvider).addons.isNotEmpty ||
      ref.watch(nuvioRepositoryProvider).repos.isNotEmpty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final addons = ref.watch(addonRepositoryProvider).addons;
    final repos = ref.watch(nuvioRepositoryProvider).repos;
    final cs = Theme.of(context).colorScheme;

    Widget delete(String key, VoidCallback onPressed) => IconButton(
      key: ValueKey(key),
      tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
      icon: Icon(Icons.delete_outline_rounded, color: cs.error),
      onPressed: onPressed,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (addons.isNotEmpty)
          SettingsGroup(
            title: 'Stremio Add-ons',
            children: [
              for (var i = 0; i < addons.length; i++)
                SettingsTile(
                  reicon: Reicon.magnet,
                  title: addons[i].displayName,
                  subtitle: [
                    if (addons[i].manifest != null)
                      'v${addons[i].manifest!.version}',
                    'Stremio add-on',
                    if (!addons[i].enabled) 'off',
                  ].join(' · '),
                  showChevron: false,
                  isLast: i == addons.length - 1,
                  trailing: delete(
                    'installed-stremio-delete-${addons[i].manifestUrl}',
                    () => ref
                        .read(addonRepositoryProvider.notifier)
                        .remove(addons[i].manifestUrl),
                  ),
                ),
            ],
          ),
        if (repos.isNotEmpty)
          SettingsGroup(
            title: 'Nuvio',
            children: [
              for (var i = 0; i < repos.length; i++)
                SettingsTile(
                  reicon: Reicon.plug,
                  title:
                      repos[i].manifest?.name ??
                      Uri.tryParse(repos[i].manifestUrl)?.host ??
                      'Nuvio',
                  subtitle: [
                    if (repos[i].manifest != null)
                      'v${repos[i].manifest!.version}',
                    if (repos[i].manifest != null)
                      '${repos[i].manifest!.scrapers.length} Nuvio providers'
                    else
                      'Nuvio providers',
                  ].join(' · '),
                  showChevron: false,
                  isLast: i == repos.length - 1,
                  trailing: delete(
                    'installed-nuvio-delete-${repos[i].manifestUrl}',
                    () => ref
                        .read(nuvioRepositoryProvider.notifier)
                        .removeRepository(repos[i].manifestUrl),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
