import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/layout_constants.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../providers/plugin_check.dart';
import '../providers/plugin_check_provider.dart';

String _seconds(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(1);

String pluginCheckStatusLabel(AppLocalizations l10n, PluginCheckStatus s) =>
    switch (s) {
      PluginCheckStatus.working => l10n.pluginStatusWorking,
      PluginCheckStatus.slow => l10n.pluginStatusSlow,
      PluginCheckStatus.empty => l10n.pluginStatusEmpty,
      PluginCheckStatus.notResponding => l10n.pluginStatusNotResponding,
      PluginCheckStatus.couldNotLoad => l10n.pluginStatusCouldNotLoad,
      PluginCheckStatus.noSource => l10n.pluginStatusNoSource,
    };

Color pluginCheckStatusColor(ColorScheme cs, PluginCheckStatus s) =>
    switch (s) {
      PluginCheckStatus.working => const Color(0xFF66BB6A),
      PluginCheckStatus.slow => const Color(0xFFFFB300),
      PluginCheckStatus.empty => const Color(0xFFFFB300),
      PluginCheckStatus.notResponding => cs.error,
      PluginCheckStatus.couldNotLoad => cs.error,
      PluginCheckStatus.noSource => cs.outline,
    };

/// The top of the Plugins tab's Installed segment: when the plugins were
/// last checked on the left, the Check button (Cancel while a check runs)
/// on the right.
class PluginCheckBar extends ConsumerStatefulWidget {
  const PluginCheckBar({super.key});

  @override
  ConsumerState<PluginCheckBar> createState() => _PluginCheckBarState();
}

class _PluginCheckBarState extends ConsumerState<PluginCheckBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // "Checked X min ago" moves on its own.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final state = ref.watch(pluginCheckProvider);
    final hasTargets = ref.watch(
      pluginCheckTargetsProvider.select((t) => t.isNotEmpty),
    );
    if (!hasTargets && !state.running) return const SizedBox.shrink();

    final String line;
    if (state.running) {
      line = l10n.pluginCheckProgress(
        (state.results.length + 1).clamp(1, state.total < 1 ? 1 : state.total),
        state.total,
      );
    } else if (state.finishedAt == null) {
      line = l10n.pluginCheckHint;
    } else {
      final minutes = DateTime.now().difference(state.finishedAt!).inMinutes;
      final ago = minutes < 1
          ? l10n.pluginCheckedJustNow
          : l10n.pluginCheckedMinutesAgo(minutes);
      line = state.wasCancelled
          ? '${l10n.pluginCheckStopped(state.results.length, state.total)} · $ago'
          : ago;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LayoutConstants.spacingMd + 4,
        LayoutConstants.spacingXs,
        LayoutConstants.spacingMd,
        LayoutConstants.spacingXs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              line,
              key: const ValueKey('plugin-check-line'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: LayoutConstants.spacingSm),
          if (state.running)
            OutlinedButton.icon(
              key: const ValueKey('plugin-check-cancel'),
              onPressed: () => ref.read(pluginCheckProvider.notifier).cancel(),
              icon: const Icon(Icons.close_rounded, size: 18),
              label: Text(l10n.cancel),
            )
          else
            FilledButton.tonalIcon(
              key: const ValueKey('plugin-check-start'),
              onPressed: () =>
                  unawaited(ref.read(pluginCheckProvider.notifier).start()),
              icon: const Icon(Icons.monitor_heart_outlined, size: 18),
              label: Text(l10n.pluginCheckButton),
            ),
        ],
      ),
    );
  }
}

/// One installed plugin's check status, for its tile's subtitle column: a
/// dot and a word, a spinner while it is the one being asked, "Not checked"
/// until it has been. Tapping a result shows what each source answered.
class PluginCheckStatusLine extends ConsumerWidget {
  const PluginCheckStatusLine({required this.pluginKey, super.key});

  final String pluginKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final result = ref.watch(
      pluginCheckProvider.select((s) => s.results[pluginKey]),
    );
    final checking = ref.watch(
      pluginCheckProvider.select((s) => s.running && s.runningKey == pluginKey),
    );
    final style = theme.textTheme.bodySmall;

    if (checking) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: cs.primary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              l10n.pluginStatusChecking,
              style: style?.copyWith(color: cs.primary),
            ),
          ],
        ),
      );
    }

    if (result == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Dot(color: cs.outline),
            const SizedBox(width: 6),
            Text(
              l10n.pluginStatusNotChecked,
              style: style?.copyWith(color: cs.outline),
            ),
          ],
        ),
      );
    }

    final color = pluginCheckStatusColor(cs, result.status);
    var text = pluginCheckStatusLabel(l10n, result.status);
    if (result.probes.length > 1) {
      text = l10n.pluginStatusPartial(
        text,
        result.okCount,
        result.probes.length,
      );
    } else if (result.probes.length == 1) {
      text = l10n.pluginStatusSeconds(text, _seconds(result.elapsed));
    }
    return InkWell(
      key: ValueKey('plugin-check-status-$pluginKey'),
      onTap: () => unawaited(_showDetails(context, l10n, result)),
      child: Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Dot(color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.info_outline_rounded, size: 13, color: color),
          ],
        ),
      ),
    );
  }

  static Future<void> _showDetails(
    BuildContext context,
    AppLocalizations l10n,
    PluginCheckResult result,
  ) {
    final lines = <String>[];
    switch (result.status) {
      case PluginCheckStatus.couldNotLoad:
        lines.add(l10n.pluginCheckDetailCouldNotLoad(result.error ?? ''));
      case PluginCheckStatus.noSource:
        lines.add(l10n.pluginCheckDetailNoSource);
      default:
        for (final p in result.probes) {
          final String what;
          if (p.timedOut) {
            what = l10n.pluginCheckDetailTimedOut(_seconds(p.elapsed));
          } else if (p.error != null) {
            what = p.error!;
          } else {
            what = l10n.pluginCheckDetailAnswered(
              p.itemCount,
              _seconds(p.elapsed),
              p.usedSearch
                  ? l10n.pluginCheckDetailViaSearch
                  : l10n.pluginCheckDetailMainPage,
            );
          }
          lines.add(
            '${p.providerName} — '
            '${pluginCheckStatusLabel(l10n, p.status)}\n$what',
          );
        }
        if (result.probes.any((p) => p.status == PluginCheckStatus.empty)) {
          lines.add(l10n.pluginCheckDetailEmptyNote);
        }
    }
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(pluginCheckStatusLabel(l10n, result.status)),
        content: SingleChildScrollView(
          child: SelectableText(lines.join('\n\n')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.close),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
