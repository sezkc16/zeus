import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/cloudstream/cloudstream_provider.dart';
import '../../../../core/extensions/base_provider.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../home_provider.dart';

/// One entry in the Home source selector: a label and the provider it
/// activates. `provider == null` is the key-free For You feed.
class HomeSource {
  const HomeSource({required this.label, this.provider, this.pluginKey});

  final String label;
  final SkyStreamProvider? provider;

  /// The CloudStream plugin key this pill stands for, if any. A pill
  /// matches any of its plugin's providers, not just the one it
  /// activates — the provider dialog can leave a different sub-provider
  /// active, and the pill must still read as selected.
  final String? pluginKey;

  bool matches(SkyStreamProvider? active) {
    if (provider == null) return active == null;
    if (active == null) return false;
    if (pluginKey != null && active is CloudStreamProvider) {
      return active.pluginKey == pluginKey;
    }
    return active.packageName == provider!.packageName;
  }
}

/// The Home source pills: "For You" first, then one pill per installed
/// plugin. CloudStream providers group by plugin, so a plugin with
/// several providers still gets one pill (activating its first provider,
/// by name); any non-CloudStream provider gets a pill of its own, so the
/// row always shows the current selection. Pure, so the grouping is
/// tested without a widget tree.
List<HomeSource> homeSources(
  List<SkyStreamProvider> providers, {
  required String forYouLabel,
}) {
  final sources = <HomeSource>[
    HomeSource(label: forYouLabel, provider: null),
  ];
  final byPlugin = <String, List<CloudStreamProvider>>{};
  final others = <SkyStreamProvider>[];
  for (final provider in providers) {
    if (provider is CloudStreamProvider) {
      byPlugin.putIfAbsent(provider.pluginKey, () => []).add(provider);
    } else {
      others.add(provider);
    }
  }
  final pluginKeys = byPlugin.keys.toList()
    ..sort(
      (a, b) => byPlugin[a]!.first.pluginName.toLowerCase().compareTo(
        byPlugin[b]!.first.pluginName.toLowerCase(),
      ),
    );
  for (final key in pluginKeys) {
    final group = byPlugin[key]!
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    sources.add(
      HomeSource(
        label: group.first.pluginName,
        provider: group.first,
        pluginKey: key,
      ),
    );
  }
  others.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  for (final provider in others) {
    sources.add(HomeSource(label: provider.name, provider: provider));
  }
  return sources;
}

/// The horizontally scrollable pill row at the top of Home (v4).
///
/// Tapping a plugin pill makes it the active provider — HomeData then
/// serves that plugin's own home page; tapping "For You" clears the
/// active provider and restores the key-free feed. Selected pill: solid
/// gold with dark text. With no plugin installed the row is just
/// "For You" and the "Add a plugin" banner below the rows still shows.
class HomeSourceSelector extends ConsumerWidget {
  const HomeSourceSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final providers = ref.watch(extensionManagerProvider);
    final activeProvider = ref.watch(activeProviderProvider);
    final sources = homeSources(providers, forYouLabel: l10n.homeForYou);
    final colorScheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (final source in sources) ...[
            _SourcePill(
              label: source.label,
              selected: source.matches(activeProvider),
              selectedColor: colorScheme.primary,
              onSelectedColor: colorScheme.onPrimary,
              onTap: () {
                if (source.matches(activeProvider)) return;
                ref
                    .read(activeProviderProvider.notifier)
                    .set(source.provider);
                ref.invalidate(homeDataProvider);
              },
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _SourcePill extends StatelessWidget {
  const _SourcePill({
    required this.label,
    required this.selected,
    required this.selectedColor,
    required this.onSelectedColor,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color selectedColor;
  final Color onSelectedColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? selectedColor
                : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(20),
            border: selected
                ? null
                : Border.all(
                    color: colorScheme.outline.withValues(alpha: 0.25),
                  ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? onSelectedColor : colorScheme.onSurface,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
