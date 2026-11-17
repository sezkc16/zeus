import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/extension_manager.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../home/presentation/home_provider.dart';
import '../../home/presentation/home_row_prefs.dart';
import '../../home/presentation/home_row_prefs_provider.dart';
import '../../home/presentation/home_state.dart';
import 'widgets/settings_widgets.dart';

/// Settings → General → Home rows: the rows of the source Home is showing
/// now (Continue Watching and the active provider's rows, or the default
/// feed's), to drag into order and switch off one by one. Saved per source.
class HomeRowsSettingsScreen extends ConsumerWidget {
  const HomeRowsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final active = ref.watch(activeProviderProvider);
    final home = ref.watch(homeDataProvider);

    final fellBack = home is HomeSuccess && home.fellBackFrom != null;
    final sourceKey = homeRowsSourceKey(
      active?.packageName,
      fellBack: fellBack,
    );
    final sourceName = active == null || fellBack
        ? l10n.homeRowsSourceDefaultFeed
        : active.name;
    final current = home is HomeSuccess
        ? home.data.keys.where((k) => k != 'Trending').toList()
        : const <String>[];
    final prefs = ref.watch(homeRowPrefsProvider.select((m) => m[sourceKey]));
    final rows = knownHomeRows(current, prefs);
    final hidden = prefs?.hidden ?? const <String>{};
    final notifier = ref.read(homeRowPrefsProvider.notifier);

    // What is known about the source's rows right now, said plainly.
    final String? note = switch (home) {
      HomeSuccess() => null,
      HomeLoading() => l10n.homeRowsLoading,
      _ => l10n.homeRowsOpenHomeFirst,
    };

    return Scaffold(
      appBar: AppBar(title: Text(l10n.homeRowsTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: const EdgeInsets.symmetric(
              vertical: LayoutConstants.spacingSm,
            ).copyWith(bottom: LayoutConstants.pillFreeBottomContentPadding(context)),
            children: [
              SettingsGroup(
                title: l10n.homeRowsHeader(sourceName),
                children: [
                  ReorderableListView(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    onReorderItem: (oldIndex, newIndex) {
                      final next = List.of(rows);
                      next.insert(newIndex, next.removeAt(oldIndex));
                      notifier.setOrder(sourceKey, next);
                    },
                    children: [
                      for (var i = 0; i < rows.length; i++)
                        SettingsTile(
                          key: ValueKey('home-row-${rows[i]}'),
                          reicon: rows[i] == kHomeRowContinueWatching
                              ? Reicon.history
                              : Reicon.film,
                          title: rows[i] == kHomeRowContinueWatching
                              ? l10n.continueWatching
                              : rows[i],
                          subtitle:
                              rows[i] != kHomeRowContinueWatching &&
                                  home is HomeSuccess &&
                                  !current.contains(rows[i])
                              ? l10n.homeRowsNotOnHomeNow
                              : null,
                          isLast: i == rows.length - 1,
                          showChevron: false,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                key: ValueKey('home-row-switch-${rows[i]}'),
                                value: !hidden.contains(rows[i]),
                                onChanged: (on) =>
                                    notifier.setHidden(sourceKey, rows[i], !on),
                              ),
                              ReorderableDragStartListener(
                                index: i,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Icon(
                                    Icons.drag_handle_rounded,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LayoutConstants.spacingMd + 4,
                  LayoutConstants.spacingSm,
                  LayoutConstants.spacingMd + 4,
                  0,
                ),
                child: Text(
                  [?note, l10n.homeRowsHint].join('\n\n'),
                  key: const ValueKey('home-rows-note'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: LayoutConstants.spacingLg),
              SettingsGroup(
                title: l10n.homeRowsResetHeader,
                children: [
                  SettingsTile(
                    key: const ValueKey('home-rows-reset'),
                    reicon: Reicon.rotateLeft,
                    title: l10n.resetToDefault,
                    subtitle: l10n.homeRowsResetSubtitle,
                    showChevron: false,
                    isLast: true,
                    onTap: () => notifier.reset(sourceKey),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
