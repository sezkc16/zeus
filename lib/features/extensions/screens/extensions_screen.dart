import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/layout_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/cloudstream/cloudstream_repository.dart';
import '../../../core/extensions/models/extension_plugin.dart';
import '../../../core/extensions/models/extension_repository.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/widgets/app_snack_bar.dart';
import '../providers/extensions_controller.dart';
import '../widgets/cloudstream_plugin_section.dart';
import '../widgets/installed_other_sources.dart';
import 'plugin_settings_dialog.dart';
import '../../../shared/widgets/cards_wrapper.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/text_input_dialog.dart';
import '../../../shared/focus/app_focus.dart';
import '../../settings/presentation/widgets/settings_widgets.dart';

import 'package:zorox/l10n/generated/app_localizations.dart';

/// Whether [installed] came from the repository at [repositoryUrl]. An
/// install from before addresses were kept came from none that can be told.
bool _installedFrom(ExtensionPlugin installed, String repositoryUrl) {
  final from = installed.repositoryUrl;
  return from != null && ExtensionsController.sameAddress(from, repositoryUrl);
}

/// The two halves of the Plugins tab: what is installed, and everything
/// for adding more (Add Repository, the repository sections, More Sources).
enum PluginsSegment { installed, add }

/// Which segment the Plugins tab shows. Kept alive (not autoDispose) so the
/// choice is remembered while the app is open — leaving the tab and coming
/// back, or a rebuild of the screen, lands on the same segment. In memory
/// only: a fresh launch starts on Installed again.
class PluginsSegmentNotifier extends Notifier<PluginsSegment> {
  @override
  PluginsSegment build() => PluginsSegment.installed;

  void select(PluginsSegment segment) => state = segment;
}

final pluginsSegmentProvider =
    NotifierProvider<PluginsSegmentNotifier, PluginsSegment>(
      PluginsSegmentNotifier.new,
    );

class ExtensionsScreen extends ConsumerStatefulWidget {
  final bool isEmbedded;

  const ExtensionsScreen({super.key, this.isEmbedded = false});

  @override
  ConsumerState<ExtensionsScreen> createState() => _ExtensionsScreenState();
}

class _ExtensionsScreenState extends ConsumerState<ExtensionsScreen> {
  bool _didEnsureInit = false;

  /// The Add Repository URL field, kept across rebuilds so typing is not
  /// lost while the repository list refreshes underneath it.
  final TextEditingController _addRepoController = TextEditingController();
  bool _isAddingRepo = false;

  @override
  void dispose() {
    _addRepoController.dispose();
    super.dispose();
  }

  /// Adds a CloudStream repository from the Add Repository card's URL
  /// field — the preview's "Paste a CloudStream repository URL" flow
  /// (repo.json + .cs3). The same resolve / refresh-or-add / snackbar
  /// flow as [CloudStreamRepositoriesSection]'s dialog, minus the dialog.
  Future<void> _addCloudStreamRepo() async {
    final input = _addRepoController.text.trim();
    if (input.isEmpty || _isAddingRepo) return;
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isAddingRepo = true);
    try {
      final notifier = ref.read(cloudStreamRepositoryProvider.notifier);
      final url = await notifier.resolveUrl(input);
      final existing = ref
          .read(cloudStreamRepositoryProvider)
          .repositories
          .where((r) => r.url == url)
          .firstOrNull;
      if (existing != null) {
        final failure = await notifier.refreshRepository(url);
        if (failure != null) {
          messenger.showSnackBar(
            appSnackBar(content: Text(l10n.cloudStreamCouldNotAdd(failure))),
          );
          return;
        }
        messenger.showSnackBar(
          appSnackBar(
            content: Text(
              l10n.cloudStreamRepositoryAdded(
                existing.plugins.length,
                existing.name,
              ),
            ),
          ),
        );
        return;
      }
      final repo = await notifier.addRepository(input);
      messenger.showSnackBar(
        appSnackBar(
          content: Text(
            l10n.cloudStreamRepositoryAdded(repo.plugins.length, repo.name),
          ),
        ),
      );
      _addRepoController.clear();
    } catch (error) {
      messenger.showSnackBar(
        appSnackBar(
          content: Text(
            l10n.cloudStreamCouldNotAdd(
              CloudStreamRepository.errorMessage(error),
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isAddingRepo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!_didEnsureInit) {
      _didEnsureInit = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(extensionsControllerProvider.notifier).ensureInitialized();
      });
    }
    ref.listen(extensionsControllerProvider, (previous, next) {
      if (next is ExtensionsError &&
          (previous is! ExtensionsError || previous.message != next.message)) {
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.error),
            content: Text(next.message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.ok),
              ),
            ],
          ),
        );
      }
    });

    final state = ref.watch(extensionsControllerProvider);

    final segment = ref.watch(pluginsSegmentProvider);

    // v5: two segments under the title — "Installed" (left) and
    // "Add Plugins" (right). Everything the single scroll used to show is
    // still here, under one of the two: the installed lists under
    // Installed; the Add Repository card, the repository sections (Zeus,
    // Zeus (SkyStream), CloudStream) and More Sources (Nuvio, Stremio)
    // under Add Plugins. The subtitle and the segment row stay pinned; the
    // list below them scrolls, with the shell's bottom clearance in both
    // segments so nothing hides under the floating nav pill.
    final body = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LayoutConstants.spacingMd,
                LayoutConstants.spacingMd,
                LayoutConstants.spacingMd,
                0,
              ),
              child: Text(
                l10n.extensionsSubtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LayoutConstants.spacingMd,
                LayoutConstants.spacingMd,
                LayoutConstants.spacingMd,
                LayoutConstants.spacingSm,
              ),
              child: _PluginsSegmentRow(
                selected: segment,
                installedLabel: l10n.pluginsSegmentInstalled,
                addLabel: l10n.pluginsSegmentAdd,
                onSelected: (s) =>
                    ref.read(pluginsSegmentProvider.notifier).select(s),
              ),
            ),
            Expanded(
              child: ListView(
                // One list per segment, so each starts at its own top.
                key: ValueKey('plugins-list-${segment.name}'),
                padding: EdgeInsets.only(
                  bottom: LayoutConstants.shellBottomContentPadding(context),
                  top: LayoutConstants.spacingSm,
                ),
                children: segment == PluginsSegment.installed
                    ? _installedWidgets(context, ref, state)
                    : [
                        _buildAddRepositoryCard(context, ref),
                        ..._repositoryWidgets(context, ref, state),
                        _buildMoreSourcesCard(context),
                      ],
              ),
            ),
          ],
        ),
      ),
    );

    if (widget.isEmbedded) {
      return body;
    }

    return Scaffold(
      appBar: AppBar(
        // No back button (v20+37): the bottom pill nav (Plugins tab) is
        // the way back. automaticallyImplyLeading is off too, so a pushed
        // route does not imply one either.
        automaticallyImplyLeading: false,
        title: const Text('Plugins'),
      ),
      body: body,
    );
  }
  List<Widget> _installedWidgets(
    BuildContext context,
    WidgetRef ref,
    ExtensionsState state,
  ) {
    final l10n = AppLocalizations.of(context)!;
    // Installed CloudStream plugins live beside Zeus's own: without
    // them here, a plugin installed from the Repositories tab would not
    // show up as installed anywhere on this screen.
    final csInstalled = ref.watch(
      cloudStreamRepositoryProvider.select((s) => s.installed),
    );
    if (state is ExtensionsLoading && state.installedPlugins.isEmpty) {
      return [const Center(child: AppLoadingIndicator())];
    }

    final debugPlugins = state.installedPlugins
        .where((p) => p.isDebug)
        .toList();
    final hasDebug = debugPlugins.isNotEmpty;

    final allAvailablePackageNames = state.availablePlugins.values
        .expand((list) => list)
        .map((p) => p.packageName)
        .toSet();

    final installedPlugins = state.installedPlugins
        .where(
          (p) =>
              !p.isDebug &&
              (state.availablePlugins.isEmpty ||
                  allAvailablePackageNames.contains(p.packageName)),
        )
        .toList();

    final installedOnlyPlugins = state.installedPlugins
        .where(
          (p) =>
              !p.isDebug &&
              state.availablePlugins.isEmpty == false &&
              !allAvailablePackageNames.contains(p.packageName),
        )
        .toList();
    final hasInstalledOnly = installedOnlyPlugins.isNotEmpty;

    // Installed Stremio add-ons and Nuvio repositories count as installed
    // too (v5) — they are listed at the end of this segment.
    final hasOtherSources = InstalledOtherSources.hasAny(ref);
    if (state.installedPlugins.isEmpty &&
        csInstalled.isEmpty &&
        !hasOtherSources) {
      // Nothing installed: say so, and offer the way to the other
      // segment, where the Add Repository card and the repositories are.
      return [
        Padding(
          padding: const EdgeInsets.all(LayoutConstants.spacingLg),
          child: _FocusableCard(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(LayoutConstants.spacingLg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.extension_outlined,
                    size: 48,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: LayoutConstants.spacingMd),
                  Text(
                    l10n.noExtensionsInstalled,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: LayoutConstants.spacingSm),
                  Text(
                    l10n.pluginsEmptyInstalledHint,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: LayoutConstants.spacingMd),
                  FilledButton.icon(
                    key: const ValueKey('plugins-empty-add-button'),
                    onPressed: () => ref
                        .read(pluginsSegmentProvider.notifier)
                        .select(PluginsSegment.add),
                    icon: const Icon(Icons.add_rounded),
                    label: Text(l10n.pluginsSegmentAdd),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];
    }

    return [
      if (hasDebug) _buildDebugSection(context, debugPlugins),
      _buildInstalledSection(context, ref, installedPlugins),
      if (hasInstalledOnly)
        _buildInstalledOnlySection(
          context,
          ref,
          installedOnlyPlugins,
          hasRepos: state.repositories.isNotEmpty,
        ),
      if (csInstalled.isNotEmpty) const CloudStreamInstalledSection(),
      if (hasOtherSources) const InstalledOtherSources(),
    ];
  }

  List<Widget> _repositoryWidgets(
    BuildContext context,
    WidgetRef ref,
    ExtensionsState state,
  ) {
    final l10n = AppLocalizations.of(context)!;
    // CloudStream's repositories live in their own store, separate from
    // Zeus's extension system. Zeus's section keeps its own add row
    // below (a Zeus manifest carries an id/packageName, which the
    // CloudStream flow does not need); the CloudStream section's add row
    // is hidden because the inline Add Repository card above already
    // feeds that flow. A repository added in one section lands in that
    // section only.
    final csRepositories = ref.watch(
      cloudStreamRepositoryProvider.select((s) => s.repositories),
    );
    final csLoading = ref.watch(
      cloudStreamRepositoryProvider.select((s) => s.isLoading),
    );
    if (state is ExtensionsLoading &&
        state.repositories.isEmpty &&
        csRepositories.isEmpty &&
        csLoading) {
      return [const Center(child: AppLoadingIndicator())];
    }
    // Three separate sections, so a repository lands in the section it
    // belongs to. The owner's own repo (Zeus Repo repo.json, .cs3) has its
    // own "Zeus" section first ([ZeusRepositorySection]); Zeus's own
    // extension system (.sky manifests) takes the "Zeus (SkyStream)"
    // section next; CloudStream's store (repo.json) takes the
    // "CloudStream" section last. The single add row used to feed only
    // Zeus's fetcher, which requires a manifest to carry an id/packageName
    // — so no CloudStream repo.json could be added at all.
    // The SkyStream and CloudStream sections stay visible even with
    // nothing in them yet, so each add flow is always reachable. The
    // Zeus section hides when its repository is not stored (removed).
    return [
      // The owner's own repository (.cs3), in its own section.
      const ZeusRepositorySection(),
      // Zeus's own extension system (.sky repository manifests).
      const RepositoryGroupHeader(
        icon: Icons.extension_rounded,
        label: 'Zeus (SkyStream)',
      ),
      for (final repo in state.repositories)
        _buildRepositoryCard(
          context,
          ref,
          state,
          repo,
          state.availablePlugins[repo.url] ?? [],
          l10n,
        ),
      // The section stays when its last repository is removed: the
      // header and the add row remain, so a repository can be added
      // back into this section.
      if (state.repositories.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LayoutConstants.spacingMd,
            vertical: LayoutConstants.spacingSm,
          ),
          child: Text(
            l10n.noZoroxReposYet,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      _buildAddRepoRow(
        context,
        title: l10n.addRepository,
        onTap: () => _showAddRepoDialog(context, ref),
      ),
      // CloudStream's store (repo.json): its own header and cards live
      // in [CloudStreamRepositoriesSection]; its add row is hidden
      // there (showAddRow: false) because the inline Add Repository
      // card above already feeds the same CloudStream flow.
      const CloudStreamRepositoriesSection(showAddRow: false),
    ];
  }

  /// The preview's Add Repository card: a URL field and a solid gold Add
  /// button, feeding the CloudStream (.cs3) flow. The Zeus-manifest add
  /// row stays in the Repositories section below for its own store.
  Widget _buildAddRepositoryCard(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LayoutConstants.spacingMd,
        vertical: LayoutConstants.spacingSm,
      ),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(LayoutConstants.spacingMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.addRepository.toUpperCase(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: LayoutConstants.spacingMd),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _addRepoController,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        hintText: 'https://…/repo.json',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      onSubmitted: (_) => _addCloudStreamRepo(),
                    ),
                  ),
                  const SizedBox(width: LayoutConstants.spacingSm),
                  FilledButton(
                    onPressed: _isAddingRepo ? null : _addCloudStreamRepo,
                    child: _isAddingRepo
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.add),
                  ),
                ],
              ),
              const SizedBox(height: LayoutConstants.spacingSm),
              Text(
                l10n.pasteRepoUrlHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The preview's More Sources card: Nuvio plugins and Stremio add-ons.
  /// No SkyStream row — the user said nothing SkyStream-related.
  Widget _buildMoreSourcesCard(BuildContext context) {
    return SettingsGroup(
      title: 'More Sources',
      children: [
        SettingsTile(
          emoji: '🔌',
          title: 'Nuvio Plugins',
          subtitle: 'Scraper plugins for movies & shows',
          onTap: () => const NuvioPluginsRoute().go(context),
        ),
        SettingsTile(
          emoji: '🧲',
          title: 'Stremio Add-ons',
          subtitle: 'Install add-ons by manifest URL',
          isLast: true,
          onTap: () => const AddonsRoute().go(context),
        ),
      ],
    );
  }

  /// The add-repository row for a section: the same card as the old single
  /// row, now one per section so each section adds into its own store.
  Widget _buildAddRepoRow(
    BuildContext context, {
    required String title,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LayoutConstants.spacingMd,
        vertical: LayoutConstants.spacingSm,
      ),
      child: _FocusableCard(
        margin: EdgeInsets.zero,
        borderColor: Theme.of(context).colorScheme.primary
            .withValues(alpha: 0.3),
        // A card holding one row still hands the focus affordance to the
        // row, so this is marked like every other row in the list.
        child: _FocusableRow(
          child: ListTile(
            focusColor: Theme.of(context).colorScheme.primary
                .withValues(alpha: 0.15),
            leading: Icon(
              Icons.add_circle_outline,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(
              title,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            onTap: onTap,
          ),
        ),
      ),
    );
  }

  Widget _buildInstalledSection(
    BuildContext context,
    WidgetRef ref,
    List<ExtensionPlugin> plugins,
  ) {
    if (plugins.isEmpty) return const SizedBox.shrink();

    return _FocusableCard(
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
                Icon(
                  Icons.check_circle_outline,
                  color: Theme.of(context).colorScheme.primary,
                  size: 22,
                ),
                const SizedBox(width: LayoutConstants.spacingSm),
                Text(
                  'Installed Extensions',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
          ),
          for (int i = 0; i < plugins.length; i++) ...[
            _PluginTile(plugin: plugins[i]),
            if (i < plugins.length - 1)
              Divider(
                height: 1,
                indent: 56,
                endIndent: 16,
                color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildInstalledOnlySection(
    BuildContext context,
    WidgetRef ref,
    List<ExtensionPlugin> plugins, {
    required bool hasRepos,
  }) {
    if (plugins.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    return _FocusableCard(
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.extension_outlined,
                      color: Theme.of(context).colorScheme.primary,
                      size: 22,
                    ),
                    const SizedBox(width: LayoutConstants.spacingSm),
                    Text(
                      l10n.extensionsNotInRepos,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  hasRepos ? l10n.noLongerInRepo : l10n.addRepoToBrowse,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
          ),
          for (int i = 0; i < plugins.length; i++) ...[
            _PluginTile(plugin: plugins[i]),
            if (i < plugins.length - 1)
              Divider(
                height: 1,
                indent: 56,
                endIndent: 16,
                color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildDebugSection(
    BuildContext context,
    List<ExtensionPlugin> debugPlugins,
  ) {
    if (debugPlugins.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    return _FocusableCard(
      margin: const EdgeInsets.symmetric(
        horizontal: LayoutConstants.spacingMd,
        vertical: LayoutConstants.spacingXs,
      ),
      borderColor: Theme.of(context).colorScheme.tertiary
          .withValues(alpha: 0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LayoutConstants.spacingMd,
              vertical: LayoutConstants.spacingSm + 4,
            ),
            child: Text(
              l10n.debugExtensions,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.tertiary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Divider(
            height: 1,
            color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
          ),
          for (int i = 0; i < debugPlugins.length; i++) ...[
            _PluginTile(plugin: debugPlugins[i], isDebugSection: true),
            if (i < debugPlugins.length - 1)
              Divider(
                height: 1,
                indent: 16,
                endIndent: 16,
                color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildRepositoryCard(
    BuildContext context,
    WidgetRef ref,
    ExtensionsState state,
    ExtensionRepository repo,
    List<ExtensionPlugin> plugins,
    AppLocalizations l10n,
  ) {
    final allInstalled =
        plugins.isNotEmpty &&
        plugins.every(
          (p) => state.installedPlugins.any(
            (i) => !i.isDebug && i.packageName == p.packageName,
          ),
        );

    final isRepoInstalling = plugins.any(
      (p) => state.installingPlugins.contains(p.packageName),
    );

    return _FocusableCard(
      margin: const EdgeInsets.only(
        bottom: LayoutConstants.spacingMd,
        left: LayoutConstants.spacingMd,
        right: LayoutConstants.spacingMd,
      ),
      child: ExpansionTile(
        key: PageStorageKey('repo_${repo.url}'),
        shape: const Border(),
        collapsedShape: const Border(),
        initiallyExpanded: false,
        backgroundColor: Colors.transparent,
        collapsedBackgroundColor: Colors.transparent,
        tilePadding: const EdgeInsets.symmetric(
          horizontal: LayoutConstants.spacingMd,
          vertical: LayoutConstants.spacingXs,
        ),
        // The description sits in the title rather than in ExpansionTile's
        // subtitle, which adds a gap and shifts the buttons off centre.
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
          // The repository actions live in the children rather than the
          // header, where they would conflict with D-pad focus on the
          // ExpansionTile.
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LayoutConstants.spacingMd,
              vertical: LayoutConstants.spacingXs,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (isRepoInstalling)
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
                      allInstalled
                          ? 'All installed'
                          : l10n.downloadAllProviders,
                    ),
                    onPressed: allInstalled || plugins.isEmpty
                        ? null
                        : () {
                            // A plugin installed from another repository is
                            // that one's to update: this one's copy would
                            // move it here.
                            final pluginsToInstall = plugins.where((p) {
                              final installed = state.installedPlugins
                                  .cast<ExtensionPlugin?>()
                                  .firstWhere(
                                    (inst) =>
                                        inst?.packageName == p.packageName,
                                    orElse: () => null,
                                  );
                              return installed == null ||
                                  (_installedFrom(installed, repo.url) &&
                                      p.version > installed.version);
                            }).toList();

                            if (pluginsToInstall.isNotEmpty) {
                              ref
                                  .read(extensionsControllerProvider.notifier)
                                  .installPlugins(pluginsToInstall);
                            }
                          },
                  ),
                  const SizedBox(width: LayoutConstants.spacingSm),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                    label: Text(l10n.delete),
                    onPressed: () => _confirmDeleteRepo(context, ref, repo),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          ...plugins.asMap().entries.map((entry) {
            final isLast = entry.key == plugins.length - 1;
            return Column(
              children: [
                _PluginTile(plugin: entry.value, repository: repo),
                if (!isLast)
                  Divider(
                    height: 1,
                    indent: 56,
                    endIndent: 16,
                    color: Theme.of(context).dividerColor
                        .withValues(alpha: 0.5),
                  ),
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
    final l10n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.removeRepoConfirm(repo.name)),
        content: Text(l10n.removeRepoWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              ref
                  .read(extensionsControllerProvider.notifier)
                  .removeRepository(repo.url);
              Navigator.of(context).pop();
            },
            child: Text(
              l10n.delete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddRepoDialog(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final url = await TextInputDialog.show(
      context,
      title: l10n.addRepository,
      hintText: l10n.repoUrlOrShortcode,
      keyboardType: TextInputType.url,
      confirmLabel: l10n.addRepo,
    );
    if (url == null || url.isEmpty || !context.mounted) {
      return;
    }
    unawaited(
      ref.read(extensionsControllerProvider.notifier).addRepository(url),
    );
  }
}

class _PluginTile extends ConsumerStatefulWidget {
  final ExtensionPlugin plugin;
  final bool isDebugSection;

  /// The repository whose card the row is on, which listed [plugin]. Null
  /// outside a repository's card.
  final ExtensionRepository? repository;

  const _PluginTile({
    required this.plugin,
    this.isDebugSection = false,
    this.repository,
  });

  @override
  ConsumerState<_PluginTile> createState() => _PluginTileState();
}

class _PluginTileState extends ConsumerState<_PluginTile> {
  final FocusNode _settingsFocusNode = FocusNode();
  Future<List<PluginSettingDefinition>>? _settingsFuture;
  String? _settingsFutureIdentity;

  String _settingsIdentity(ExtensionPlugin plugin) =>
      '${plugin.packageName}:${plugin.version}:${plugin.sourceUrl}';

  Future<List<PluginSettingDefinition>> _settingsFor(ExtensionPlugin plugin) {
    final identity = _settingsIdentity(plugin);
    if (_settingsFuture == null || _settingsFutureIdentity != identity) {
      _settingsFutureIdentity = identity;
      _settingsFuture = ref
          .read(extensionManagerProvider.notifier)
          .getSettingsForPlugin(plugin);
    }
    return _settingsFuture!;
  }

  @override
  void didUpdateWidget(covariant _PluginTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_settingsIdentity(oldWidget.plugin) !=
        _settingsIdentity(widget.plugin)) {
      _settingsFuture = null;
      _settingsFutureIdentity = null;
    }
  }

  @override
  void dispose() {
    _settingsFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (widget.isDebugSection) {
      final tile = ListTile(
        leading: Container(
          padding: const EdgeInsets.all(LayoutConstants.spacingXs),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.tertiary
                .withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.bug_report,
            color: Theme.of(context).colorScheme.tertiary,
            size: 20,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                widget.plugin.name,
                style: const TextStyle(fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: LayoutConstants.spacingXs),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
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
        ),
        subtitle: Text(
          "v${widget.plugin.version} • ${l10n.assetPlugin}",
          style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color),
        ),
      );
      return _FocusableRow(child: tile);
    }

    final state = ref.watch(extensionsControllerProvider);

    final installedPlugin = state.installedPlugins
        .cast<ExtensionPlugin?>()
        .firstWhere((p) {
          if (p == null) return false;
          if (p.isDebug) return false;
          return p.packageName == widget.plugin.packageName;
        }, orElse: () => null);

    final isInstalled = installedPlugin != null;
    final updateAvailable = state.availableUpdates[widget.plugin.packageName];

    final isInstalling = state.installingPlugins.contains(
      widget.plugin.packageName,
    );

    final tile = ListTile(
      leading: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer
              .withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          Icons.extension_outlined,
          color: Theme.of(context).colorScheme.primary,
          size: 22,
        ),
      ),
      title: Text(
        widget.plugin.name,
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: _buildSubtitle(context, isInstalled, installedPlugin),
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
                    tooltip: l10n.updateTo(updateAvailable.version.toString()),
                    onPressed: () {
                      ref
                          .read(extensionsControllerProvider.notifier)
                          .updatePlugin(updateAvailable);
                    },
                  ),

                // Installed from another repository: that one alone updates
                // it, so with it gone it would never update again. Moving it
                // here is the user's call, made in a dialog that says where
                // the copy they have came from.
                if ((widget.repository, installedPlugin?.repositoryUrl)
                    case (final repository?, final from?)
                    when !ExtensionsController.sameAddress(
                      from,
                      repository.url,
                    ))
                  IconButton(
                    icon: const Icon(Icons.swap_horiz),
                    tooltip: l10n.installFromThisRepository,
                    onPressed: () => _confirmInstallHere(from, repository),
                  ),

                if (isInstalled)
                  FutureBuilder<List<PluginSettingDefinition>>(
                    future: _settingsFor(installedPlugin),
                    builder: (context, snapshot) {
                      final manifestSettings =
                          installedPlugin.manifest['settings'];
                      final hasManifestSettings =
                          manifestSettings is List &&
                          manifestSettings.isNotEmpty;
                      final hasScriptSettings =
                          snapshot.data?.isNotEmpty ?? false;
                      final declaresScriptSettings =
                          installedPlugin.manifest['hasSettings'] == true;
                      final hasDomains =
                          installedPlugin.domains?.isNotEmpty ?? false;
                      final hasStaticProviders =
                          installedPlugin.providers?.isNotEmpty ?? false;

                      final loadedProviders = ref.watch(
                        extensionManagerProvider,
                      );
                      final hasLoadedSubProviders = loadedProviders.any(
                        (provider) => provider.packageName.startsWith(
                          '${installedPlugin.packageName}::',
                        ),
                      );
                      final hasDynamicProviders = ref
                          .read(extensionManagerProvider.notifier)
                          .getProvidersForPlugin(installedPlugin)
                          .isNotEmpty;

                      final hasSettings =
                          hasManifestSettings ||
                          hasScriptSettings ||
                          declaresScriptSettings ||
                          hasDomains ||
                          hasStaticProviders ||
                          hasDynamicProviders ||
                          hasLoadedSubProviders;

                      if (!hasSettings) {
                        return const SizedBox.shrink();
                      }

                      return IconButton(
                        focusNode: _settingsFocusNode,
                        icon: const Icon(Icons.settings_outlined),
                        tooltip: l10n.settings,
                        onPressed: () async {
                          await PluginSettingsDialog.open(
                            context,
                            installedPlugin,
                          );
                          // Back to the gear it came from, so a remote does
                          // not have to walk the list again.
                          if (context.mounted) {
                            _settingsFocusNode.requestFocus();
                          }
                        },
                      );
                    },
                  ),

                if (isInstalled)
                  IconButton(
                    icon: Icon(
                      Icons.delete,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    tooltip: l10n.delete,
                    onPressed: () {
                      ref
                          .read(extensionsControllerProvider.notifier)
                          .uninstallPlugin(installedPlugin);
                    },
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.download),
                    tooltip: l10n.install,
                    onPressed: () {
                      ref
                          .read(extensionsControllerProvider.notifier)
                          .installPlugin(widget.plugin);
                    },
                  ),
              ],
            ),
    );

    return _FocusableRow(child: tile);
  }

  /// Installs [repository]'s copy of the plugin in place of the one installed
  /// from [from], once the user agrees: its updates come from [repository]
  /// from then on.
  Future<void> _confirmInstallHere(
    String from,
    ExtensionRepository repository,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.installFromThisRepositoryTitle(widget.plugin.name)),
        content: Text(
          l10n.installFromThisRepositoryMessage(
            from,
            widget.plugin.version.toString(),
            repository.name,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.install),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref
        .read(extensionsControllerProvider.notifier)
        .installPlugin(widget.plugin);
  }

  /// Subtitle widget: description · version/authors line · language chips.
  Widget _buildSubtitle(
    BuildContext context,
    bool isInstalled,
    ExtensionPlugin? installedPlugin,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final descStyle = textTheme.bodyMedium?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    final metaStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );

    // The installed copy's version if there is one, otherwise the catalog's.
    final version =
        'v${isInstalled ? installedPlugin!.version : widget.plugin.version}';

    final authors = widget.plugin.authors.take(2).join(', ');

    final metaParts = [version, if (authors.isNotEmpty) 'By $authors'];
    final metaLine = metaParts.join(' • ');

    final desc = widget.plugin.description;
    final hasDesc = desc != null && desc.isNotEmpty;
    final hasLanguages = widget.plugin.languages.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasDesc)
          Text(
            desc,
            style: descStyle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        const SizedBox(height: 2),
        Text(
          metaLine,
          style: metaStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (hasLanguages) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: widget.plugin.languages.take(5).map((lang) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  lang.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }
}

/// Dispatched by a [_FocusableRow] whenever it gains or loses focus.
///
/// The enclosing [_FocusableCard] listens so it can stay unlit while one of
/// its rows is the thing the user is pointed at.
class _RowFocusNotification extends Notification {
  final Object row;
  final bool focused;

  _RowFocusNotification(this.row, this.focused);
}

/// The focus affordance for ONE row of a plugin list.
///
/// Draws the app's shared card focus recipe ([CardFocusAffordance]) around a
/// single row and tells the enclosing [_FocusableCard] to stay quiet while it
/// does. Two departures from how [CardsWrapper] applies the same recipe:
///
/// The ring is painted behind the child, not in front of it as [CardsWrapper]
/// does; a row's child is text on a transparent [Material], so a foreground
/// layer would sit over the label it points at.
///
/// An opaque fill sits between the shadow and the row, because Flutter paints
/// a [BoxShadow] across the whole shape rather than just its rim, and without
/// something opaque in the middle it floods the row.
class _FocusableRow extends StatefulWidget {
  final Widget child;

  const _FocusableRow({required this.child});

  @override
  State<_FocusableRow> createState() => _FocusableRowState();
}

class _FocusableRowState extends State<_FocusableRow> {
  /// Tighter than the 16 dp card so the two curves stay roughly concentric
  /// once the row is inset by the ring's width.
  static const BorderRadius _radius = BorderRadius.all(Radius.circular(12));

  bool _isFocused = false;

  void _onFocusChange(bool focused) {
    setState(() => _isFocused = focused);
    _RowFocusNotification(this, focused).dispatch(context);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Focus(
      // Passive observer: the row is not a traversal stop, the buttons inside
      // it are, so hasFocus means one of those controls is focused.
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _onFocusChange,
      child: Container(
        // The ring is stroke-aligned outside the row, so the row needs that
        // much clearance inside the card's antiAlias clip or the ring is
        // sliced off down both long edges.
        margin: const EdgeInsets.all(CardFocusAffordance.ringWidth),
        decoration: CardFocusAffordance.glow(
          borderRadius: _radius,
          focused: showFocusIndicator(context, _isFocused),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            // The colour the card already fills itself with, so this is
            // invisible until the glow needs something to hide behind.
            color: colorScheme.surface,
            borderRadius: _radius,
          ),
          child: Container(
            decoration: CardFocusAffordance.ring(
              context,
              borderRadius: _radius,
              focused: showFocusIndicator(context, _isFocused),
            ),
            // The row's own ink surface. A ListTile paints its splashes on the
            // nearest Material ancestor, and ink is painted before that
            // Material's child, so without this the two fills above would
            // swallow every splash the row draws.
            child: Material(
              type: MaterialType.transparency,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

class _FocusableCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry? margin;
  final Color? borderColor;

  const _FocusableCard({required this.child, this.margin, this.borderColor});

  @override
  State<_FocusableCard> createState() => _FocusableCardState();
}

class _FocusableCardState extends State<_FocusableCard> {
  bool _isFocused = false;

  /// The [_FocusableRow] inside this card that currently owns the focus, if
  /// any. Identity rather than a counter, so the two notifications of a
  /// row-to-row move are order-independent.
  Object? _focusedRow;

  bool _onRowFocus(_RowFocusNotification notification) {
    setState(() {
      if (notification.focused) {
        _focusedRow = notification.row;
      } else if (identical(_focusedRow, notification.row)) {
        _focusedRow = null;
      }
    });
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // The card lights up only for focus it owns itself, such as its
    // ExpansionTile header. A focused row draws its own affordance instead.
    // And only for a remote or a keyboard: under a thumb, a field tapped
    // inside the card is focus the card must not light up for.
    final highlight =
        showFocusIndicator(context, _isFocused) && _focusedRow == null;

    return NotificationListener<_RowFocusNotification>(
      onNotification: _onRowFocus,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => setState(() {
          _isFocused = focused;
          // A focused row can leave the tree (a repository collapses, a plugin
          // is uninstalled) without sending its focus-lost notification, which
          // would otherwise mute this card for good.
          if (!focused) _focusedRow = null;
        }),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin:
              widget.margin ?? const EdgeInsets.all(LayoutConstants.spacingMd),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: highlight
                  ? theme.colorScheme.primary
                  : (widget.borderColor ??
                        theme.dividerColor.withValues(alpha: 0.5)),
              width: highlight ? 2.0 : 1.0,
            ),
            boxShadow: highlight
                ? [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.25),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(color: Colors.transparent, child: widget.child),
        ),
      ),
    );
  }
}

/// The Plugins tab's two-segment row: "Installed" on the left, "Add
/// Plugins" on the right. The selected segment is filled with the accent
/// (text onPrimary); the other sits on a subtle surface tint.
class _PluginsSegmentRow extends StatelessWidget {
  const _PluginsSegmentRow({
    required this.selected,
    required this.installedLabel,
    required this.addLabel,
    required this.onSelected,
  });

  final PluginsSegment selected;
  final String installedLabel;
  final String addLabel;
  final ValueChanged<PluginsSegment> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            Expanded(
              child: _PluginsSegmentButton(
                key: const ValueKey('plugins-segment-installed'),
                label: installedLabel,
                icon: Icons.check_circle_outline_rounded,
                selected: selected == PluginsSegment.installed,
                onTap: () => onSelected(PluginsSegment.installed),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: _PluginsSegmentButton(
                key: const ValueKey('plugins-segment-add'),
                label: addLabel,
                icon: Icons.add_circle_outline_rounded,
                selected: selected == PluginsSegment.add,
                onTap: () => onSelected(PluginsSegment.add),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PluginsSegmentButton extends StatelessWidget {
  const _PluginsSegmentButton({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.onPrimary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? scheme.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 40,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: foreground),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
