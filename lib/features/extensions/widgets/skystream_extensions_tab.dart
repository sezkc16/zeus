import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/models/extension_plugin.dart';
import '../../../core/extensions/models/extension_repository.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/widgets/app_snack_bar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/text_input_dialog.dart';
import '../providers/extensions_controller.dart';

/// The SkyStream tab of Settings → Extensions (b121): Zeus's own
/// extension system (.sky manifests) on its own, separate from the other
/// three sources. The user asked for four SEPARATE sections, one per
/// source (2026-11-22 ~04:02: "ek jagaha nahi... alag alag ho") — this
/// tab manages ONLY SkyStream plugins and repositories: its own
/// installed list, its own repositories, its own add / remove / refresh.
/// Nothing here touches CloudStream, Nuvio or Stremio.
///
/// It reuses [ExtensionsController] (the same store the Plugins tab
/// reads), so an install here shows up there and vice versa. The
/// repository refresh is [ExtensionsController.addRepository] on the
/// same URL: it re-fetches the manifest and rewrites that repository's
/// available plugins, so a refresh is just an add of an address that is
/// already there.
class SkyStreamExtensionsTab extends ConsumerStatefulWidget {
  const SkyStreamExtensionsTab({super.key});

  @override
  ConsumerState<SkyStreamExtensionsTab> createState() =>
      _SkyStreamExtensionsTabState();
}

class _SkyStreamExtensionsTabState
    extends ConsumerState<SkyStreamExtensionsTab> {
  bool _didEnsureInit = false;

  @override
  Widget build(BuildContext context) {
    if (!_didEnsureInit) {
      _didEnsureInit = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(extensionsControllerProvider.notifier).ensureInitialized();
      });
    }
    final state = ref.watch(extensionsControllerProvider);
    if (state is ExtensionsLoading && state.installedPlugins.isEmpty) {
      return const Center(child: AppLoadingIndicator());
    }

    final installed = state.installedPlugins
        .where((p) => !p.isDebug)
        .toList();
    final allAvailablePackageNames = state.availablePlugins.values
        .expand((list) => list)
        .map((p) => p.packageName)
        .toSet();

    return ListView(
      padding: EdgeInsets.only(
        top: LayoutConstants.spacingSm,
        bottom: LayoutConstants.pillFreeBottomContentPadding(context),
      ),
      children: [
        if (state is ExtensionsError)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LayoutConstants.spacingMd,
              vertical: LayoutConstants.spacingSm,
            ),
            child: Text(
              state.message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        if (installed.isNotEmpty)
          _SectionCard(
            title: 'Installed',
            icon: Icons.check_circle_outline,
            children: [
              for (int i = 0; i < installed.length; i++) ...[
                _SkyStreamPluginTile(
                  plugin: installed[i],
                  installedPlugin: installed[i],
                  updateAvailable:
                      state.availableUpdates[installed[i].packageName],
                  isInstalling: state.installingPlugins.contains(
                    installed[i].packageName,
                  ),
                ),
                if (i < installed.length - 1) const _RowDivider(),
              ],
            ],
          ),
        if (installed.isEmpty && state.repositories.isEmpty)
          Padding(
            padding: const EdgeInsets.all(LayoutConstants.spacingLg),
            child: Text(
              'No SkyStream extensions installed yet. Add a repository below to browse its plugins.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        for (final repo in state.repositories)
          _RepositoryCard(
            repo: repo,
            plugins: state.availablePlugins[repo.url] ?? [],
            installedPlugins: installed,
            availableUpdates: state.availableUpdates,
            installingPlugins: state.installingPlugins,
            allAvailablePackageNames: allAvailablePackageNames,
          ),
        _AddRepositoryRow(onAdd: () => _showAddRepoDialog(context, ref)),
      ],
    );
  }

  Future<void> _showAddRepoDialog(BuildContext context, WidgetRef ref) async {
    final url = await TextInputDialog.show(
      context,
      title: 'Add Repository',
      hintText: 'Repository URL or shortcode',
      keyboardType: TextInputType.url,
      confirmLabel: 'Add',
    );
    if (url == null || url.isEmpty || !context.mounted) return;
    try {
      await ref
          .read(extensionsControllerProvider.notifier)
          .addRepository(url);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(appSnackBar(content: Text('Could not add: $error')));
    }
  }
}

/// One section card: a title row, a divider, then its rows.
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: LayoutConstants.spacingMd,
        vertical: LayoutConstants.spacingXs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LayoutConstants.spacingMd,
              vertical: LayoutConstants.spacingSm + 4,
            ),
            child: Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: LayoutConstants.spacingSm),
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: theme.dividerColor.withValues(alpha: 0.5),
          ),
          ...children,
        ],
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 56,
      endIndent: 16,
      color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
    );
  }
}

/// One SkyStream plugin row: install / update / uninstall, in the same
/// style as the Plugins tab's rows. [installedPlugin] is non-null when
/// the plugin is installed; [updateAvailable] is the newer listing when
/// its repository has one.
class _SkyStreamPluginTile extends ConsumerWidget {
  const _SkyStreamPluginTile({
    required this.plugin,
    required this.installedPlugin,
    required this.updateAvailable,
    required this.isInstalling,
  });

  final ExtensionPlugin plugin;
  final ExtensionPlugin? installedPlugin;
  final ExtensionPlugin? updateAvailable;
  final bool isInstalling;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isInstalled = installedPlugin != null;
    final version =
        'v${isInstalled ? installedPlugin!.version : plugin.version}';
    final authors = plugin.authors.take(2).join(', ');
    final metaLine = [
      version,
      if (authors.isNotEmpty) 'By $authors',
    ].join(' • ');
    final description = plugin.description;
    final hasDescription = description != null && description.isNotEmpty;

    return ListTile(
      leading: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer.withValues(
            alpha: 0.5,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          Icons.extension_outlined,
          color: Theme.of(context).colorScheme.primary,
          size: 22,
        ),
      ),
      title: Text(
        plugin.name,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasDescription)
            Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: 2),
          Text(
            metaLine,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      trailing: isInstalling
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: AppLoadingIndicator(
                constraints: BoxConstraints(
                  minWidth: 24,
                  minHeight: 24,
                  maxWidth: 24,
                  maxHeight: 24,
                ),
              ),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isInstalled && updateAvailable != null)
                  IconButton(
                    icon: const Icon(Icons.download, color: Colors.green),
                    tooltip: 'Update to v${updateAvailable!.version}',
                    onPressed: () => ref
                        .read(extensionsControllerProvider.notifier)
                        .updatePlugin(updateAvailable!),
                  ),
                if (isInstalled)
                  IconButton(
                    icon: Icon(
                      Icons.delete,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    tooltip: 'Uninstall',
                    onPressed: () => ref
                        .read(extensionsControllerProvider.notifier)
                        .uninstallPlugin(installedPlugin!),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.download),
                    tooltip: 'Install',
                    onPressed: () => ref
                        .read(extensionsControllerProvider.notifier)
                        .installPlugin(plugin),
                  ),
              ],
            ),
    );
  }
}

/// One SkyStream repository: its plugins, with install-all, refresh and
/// remove. Refresh re-adds the same URL, which re-fetches the manifest
/// and rewrites this repository's available plugins.
class _RepositoryCard extends ConsumerWidget {
  const _RepositoryCard({
    required this.repo,
    required this.plugins,
    required this.installedPlugins,
    required this.availableUpdates,
    required this.installingPlugins,
    required this.allAvailablePackageNames,
  });

  final ExtensionRepository repo;
  final List<ExtensionPlugin> plugins;
  final List<ExtensionPlugin> installedPlugins;
  final Map<String, ExtensionPlugin> availableUpdates;
  final Set<String> installingPlugins;
  final Set<String> allAvailablePackageNames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allInstalled =
        plugins.isNotEmpty &&
        plugins.every(
          (p) => installedPlugins.any((i) => i.packageName == p.packageName),
        );
    final isInstalling = plugins.any(
      (p) => installingPlugins.contains(p.packageName),
    );

    return Card(
      margin: const EdgeInsets.only(
        bottom: LayoutConstants.spacingMd,
        left: LayoutConstants.spacingMd,
        right: LayoutConstants.spacingMd,
      ),
      child: ExpansionTile(
        key: PageStorageKey('skystream_repo_${repo.url}'),
        shape: const Border(),
        collapsedShape: const Border(),
        initiallyExpanded: false,
        backgroundColor: Colors.transparent,
        collapsedBackgroundColor: Colors.transparent,
        tilePadding: const EdgeInsets.symmetric(
          horizontal: LayoutConstants.spacingMd,
          vertical: LayoutConstants.spacingXs,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              repo.name,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (repo.description?.isNotEmpty ?? false) ...[
              const SizedBox(height: 2),
              Text(
                repo.description!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LayoutConstants.spacingMd,
              vertical: LayoutConstants.spacingXs,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (isInstalling)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: AppLoadingIndicator(
                      constraints: BoxConstraints(
                        minWidth: 24,
                        minHeight: 24,
                        maxWidth: 24,
                        maxHeight: 24,
                      ),
                    ),
                  )
                else ...[
                  TextButton.icon(
                    icon: Icon(
                      allInstalled
                          ? Icons.check_circle_outline
                          : Icons.download,
                      color: allInstalled
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    label: Text(
                      allInstalled ? 'All installed' : 'Install all',
                    ),
                    onPressed: allInstalled || plugins.isEmpty
                        ? null
                        : () {
                            final toInstall = plugins.where((p) {
                              final installed = installedPlugins
                                  .cast<ExtensionPlugin?>()
                                  .firstWhere(
                                    (inst) =>
                                        inst?.packageName == p.packageName,
                                    orElse: () => null,
                                  );
                              return installed == null;
                            }).toList();
                            if (toInstall.isNotEmpty) {
                              ref
                                  .read(
                                    extensionsControllerProvider.notifier,
                                  )
                                  .installPlugins(toInstall);
                            }
                          },
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded),
                    tooltip: 'Refresh repository',
                    onPressed: () => unawaited(
                      ref
                          .read(extensionsControllerProvider.notifier)
                          .addRepository(repo.url),
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                    label: const Text('Remove'),
                    onPressed: () =>
                        _confirmDeleteRepo(context, ref, repo),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          ...plugins.asMap().entries.map((entry) {
            final plugin = entry.value;
            final installed = installedPlugins
                .cast<ExtensionPlugin?>()
                .firstWhere(
                  (p) => p?.packageName == plugin.packageName,
                  orElse: () => null,
                );
            final isLast = entry.key == plugins.length - 1;
            return Column(
              children: [
                _SkyStreamPluginTile(
                  plugin: plugin,
                  installedPlugin: installed,
                  updateAvailable: availableUpdates[plugin.packageName],
                  isInstalling: installingPlugins.contains(
                    plugin.packageName,
                  ),
                ),
                if (!isLast) const _RowDivider(),
              ],
            );
          }),
        ],
      ),
    );
  }

  void _confirmDeleteRepo(
    BuildContext context,
    WidgetRef ref,
    ExtensionRepository repo,
  ) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${repo.name}?'),
        content: const Text(
          'Its plugins will be uninstalled as well.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              ref
                  .read(extensionsControllerProvider.notifier)
                  .removeRepository(repo.url);
              Navigator.of(context).pop();
            },
            child: Text(
              'Remove',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }
}

/// The add-repository row at the bottom of the tab: one entry point for
/// the SkyStream store only.
class _AddRepositoryRow extends StatelessWidget {
  const _AddRepositoryRow({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LayoutConstants.spacingMd,
        vertical: LayoutConstants.spacingSm,
      ),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: Icon(
            Icons.add_circle_outline,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(
            'Add Repository',
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          onTap: onAdd,
        ),
      ),
    );
  }
}
