import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cloudstream/cloudstream_models.dart';
import '../../../core/cloudstream/cloudstream_repository.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/widgets/app_snack_bar.dart';
import '../../../l10n/generated/app_localizations.dart';

/// The installed .cs3 plugins a repository offers a newer version of, in
/// the order they are installed. Pure, so the Installed segment's "Update
/// all" bar and its test read the same answer.
List<({CsInstalledPlugin installed, CsPluginInfo newer})> pluginUpdatesOf(
  CloudStreamState state,
) => [
  for (final plugin in state.installed)
    if (state.updateFor(plugin) case final newer?)
      (installed: plugin, newer: newer),
];

/// What one "Update all" pass did.
class PluginUpdateAllResult {
  const PluginUpdateAllResult({required this.updated, required this.failed});

  /// Names of the plugins now running their new version.
  final List<String> updated;

  /// Names of the plugins whose update did not download or did not load.
  final List<String> failed;
}

/// Updates every plugin in [updates] one at a time through [install] (the
/// repository's own in-place install: it downloads the new .cs3, unloads
/// the old one, swaps the file and loads the new code — no uninstall, no
/// app restart, and the plugin's own settings stay where they are).
///
/// One at a time on purpose: each load runs the plugin through the engine,
/// and a phone does not need several of those at once.
Future<PluginUpdateAllResult> updateAllPlugins(
  List<({CsInstalledPlugin installed, CsPluginInfo newer})> updates,
  Future<CsInstalledPlugin> Function(CsPluginInfo newer) install,
) async {
  final updated = <String>[];
  final failed = <String>[];
  for (final update in updates) {
    try {
      final installed = await install(update.newer);
      (installed.loadError == null ? updated : failed).add(update.newer.name);
    } catch (_) {
      failed.add(update.newer.name);
    }
  }
  return PluginUpdateAllResult(updated: updated, failed: failed);
}

/// The Installed segment's update bar (v7): shown only while at least one
/// installed plugin has a newer version in its repository — "N updates
/// available" and an "Update all" button.
class PluginUpdatesBar extends ConsumerStatefulWidget {
  const PluginUpdatesBar({super.key});

  @override
  ConsumerState<PluginUpdatesBar> createState() => _PluginUpdatesBarState();
}

class _PluginUpdatesBarState extends ConsumerState<PluginUpdatesBar> {
  bool _running = false;

  Future<void> _updateAll() async {
    if (_running) return;
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(cloudStreamRepositoryProvider.notifier);
    final updates = pluginUpdatesOf(ref.read(cloudStreamRepositoryProvider));
    if (updates.isEmpty) return;
    setState(() => _running = true);
    try {
      final result = await updateAllPlugins(updates, notifier.install);
      messenger.showSnackBar(
        appSnackBar(
          content: Text(
            result.failed.isEmpty
                ? l10n.pluginsUpdatedCount(result.updated.length)
                : l10n.pluginsUpdateSomeFailed(
                    result.updated.length,
                    result.failed.join(', '),
                  ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = ref.watch(
      cloudStreamRepositoryProvider.select((s) => pluginUpdatesOf(s).length),
    );
    final on = ref.watch(
      cloudStreamRepositoryProvider.select((s) => s.enabled),
    );
    if (count == 0) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      key: const ValueKey('plugins-updates-bar'),
      margin: const EdgeInsets.symmetric(
        horizontal: LayoutConstants.spacingMd,
        vertical: LayoutConstants.spacingXs,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LayoutConstants.spacingMd,
          vertical: LayoutConstants.spacingSm,
        ),
        child: Row(
          children: [
            Icon(Icons.system_update_alt_rounded, color: cs.primary, size: 22),
            const SizedBox(width: LayoutConstants.spacingSm),
            Expanded(
              child: Text(
                l10n.cloudStreamUpdatesAvailable(count),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: LayoutConstants.spacingSm),
            FilledButton(
              key: const ValueKey('plugins-update-all'),
              onPressed: on && !_running ? () => unawaited(_updateAll()) : null,
              child: _running
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.pluginsUpdateAll),
            ),
          ],
        ),
      ),
    );
  }
}
