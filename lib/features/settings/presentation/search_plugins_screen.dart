import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/addons/data/addon_repository.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/nuvio/data/nuvio_repository.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../core/addons/data/addon_client.dart';
import '../../explore/data/explore_tmdb_provider.dart';
import '../../search/domain/search_plugin_filter.dart';
import '../../search/presentation/search_sources.dart';
import 'widgets/settings_widgets.dart';

/// Settings → "Search in plugins" (v7): every source Search asks — the
/// installed plugins, and the add-ons and Nuvio that can search — each with
/// a switch. All on by default; Search asks only the ones left on, so a
/// plugin nobody wants results from does not cost the search its time.
class SearchPluginsScreen extends ConsumerWidget {
  const SearchPluginsScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const SearchPluginsScreen()),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // Watched so the list follows an install or an uninstall.
    ref.watch(extensionManagerProvider);
    final plugins = ref.read(extensionManagerProvider.notifier).getAllProviders();
    final others = searchSources(
      addons: ref.watch(addonRepositoryProvider).enabled,
      client: ref.read(addonClientProvider),
      nuvioActive: ref.watch(nuvioRepositoryProvider).activeScrapers.isNotEmpty,
      tmdb: ref.read(tmdbServiceProvider),
    );
    final disabled = ref.watch(searchDisabledSourcesProvider);
    final notifier = ref.read(searchDisabledSourcesProvider.notifier);

    List<Widget> tiles(List<SkyStreamProvider> sources, Reicon reicon) => [
      for (var i = 0; i < sources.length; i++)
        SettingsTile(
          key: ValueKey('search-source-${sources[i].packageName}'),
          reicon: reicon,
          title: sources[i].name,
          isLast: i == sources.length - 1,
          trailing: Switch(
            value: !disabled.contains(sources[i].packageName),
            onChanged: (on) =>
                unawaited(notifier.setEnabled(sources[i].packageName, on)),
          ),
          onTap: () => unawaited(
            notifier.setEnabled(
              sources[i].packageName,
              disabled.contains(sources[i].packageName),
            ),
          ),
        ),
    ];

    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.searchInPlugins),
        actions: [
          if (disabled.isNotEmpty)
            TextButton(
              key: const ValueKey('search-sources-enable-all'),
              onPressed: () => unawaited(notifier.enableAll()),
              child: Text(l10n.searchInPluginsEnableAll),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            // Vertical only; SettingsGroup owns the horizontal inset.
            padding: const EdgeInsets.symmetric(
              vertical: LayoutConstants.spacingSm,
            ).copyWith(bottom: LayoutConstants.pillFreeBottomContentPadding(context)),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LayoutConstants.spacingMd,
                  4,
                  LayoutConstants.spacingMd,
                  LayoutConstants.spacingSm,
                ),
                child: Text(
                  l10n.searchInPluginsHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (plugins.isEmpty && others.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(LayoutConstants.spacingLg),
                  child: Text(
                    l10n.searchInPluginsEmpty,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (plugins.isNotEmpty)
                SettingsGroup(
                  title: l10n.searchInPluginsPlugins,
                  children: tiles(plugins, Reicon.puzzlePiece),
                ),
              if (plugins.isNotEmpty && others.isNotEmpty)
                const SizedBox(height: LayoutConstants.spacingLg),
              if (others.isNotEmpty)
                SettingsGroup(
                  title: l10n.searchInPluginsAddons,
                  children: tiles(others, Reicon.magnet),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
