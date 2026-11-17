import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/addons/data/addon_client.dart';
import '../../../../core/addons/data/builtin_addons.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/utils/layout_constants.dart';
import 'browse_rows.dart';

/// The Browse tab: the title, poster rows straight from the built-in
/// Cinemeta add-on (popular, featured, this year's, a few genres), then the
/// APP card whose Settings row opens Settings.
///
/// Each row asks for its own catalog when it scrolls into view and shows its
/// own skeleton, failure or posters; a catalog that comes back empty leaves
/// the list. Pulling down asks Cinemeta again for every row.
class BrowseScreen extends ConsumerStatefulWidget {
  const BrowseScreen({super.key});

  @override
  ConsumerState<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends ConsumerState<BrowseScreen> {
  late final List<BrowseRowSpec> _specs = browseRowSpecs(
    year: DateTime.now().year,
  );

  /// Rows whose catalog came back empty. They are taken out of the list
  /// rather than left as zero-height rows, which a lazily built sliver list
  /// cannot scroll back up through (see catalog_rows_scroll_test.dart).
  final Set<String> _empty = {};

  /// Rows that have been built, and so have asked Cinemeta for a catalog.
  final Set<String> _asked = {};

  Future<void> _refresh() async {
    final client = ref.read(addonClientProvider);
    // The client keeps a catalog for 15 minutes, so invalidating a row's
    // provider alone would hand back the same answer. Rows that have been
    // asked for - on screen, scrolled past or hidden as empty - are fetched
    // again past that cache; the rest have nothing cached to go stale.
    final asked = [
      for (final spec in _specs)
        if (_asked.contains(spec.slug)) spec,
    ];
    await Future.wait([
      for (final spec in asked)
        client
            .catalog(
              BuiltInAddons.cinemeta,
              type: spec.type,
              id: spec.id,
              extra: spec.genre == null ? null : {'genre': spec.genre!},
              forceRefresh: true,
            )
            .timeout(const Duration(seconds: 20))
            .then<void>((_) {}, onError: (Object _) {}),
    ]);
    if (!mounted) return;
    setState(_empty.clear);
    for (final spec in _specs) {
      ref.invalidate(spec.provider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final rows = [
      for (final spec in _specs)
        if (!_empty.contains(spec.slug)) spec,
    ];

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        edgeOffset: MediaQuery.paddingOf(context).top,
        child: CustomScrollView(
          key: const ValueKey('browse-scroll'),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(
                top: MediaQuery.paddingOf(context).top + 8,
                left: LayoutConstants.spacingMd,
                right: LayoutConstants.spacingMd,
              ),
              sliver: SliverToBoxAdapter(
                child: Text(
                  l10n.browse,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final spec = rows[index];
                _asked.add(spec.slug);
                return BrowseCatalogRow(
                  spec: spec,
                  onEmpty: () {
                    if (!mounted || _empty.contains(spec.slug)) return;
                    setState(() => _empty.add(spec.slug));
                  },
                );
              },
            ),
            SliverPadding(
              padding: EdgeInsets.only(
                top: LayoutConstants.spacingLg,
                left: LayoutConstants.spacingMd,
                right: LayoutConstants.spacingMd,
                bottom: LayoutConstants.shellBottomContentPadding(context),
              ),
              sliver: SliverToBoxAdapter(
                child: Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(LayoutConstants.spacingMd),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.appSection.toUpperCase(),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: LayoutConstants.spacingSm),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.settings_rounded),
                          title: Text(l10n.settings),
                          subtitle: Text(l10n.browseSettingsSubtitle),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => const SettingsRoute().go(context),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
