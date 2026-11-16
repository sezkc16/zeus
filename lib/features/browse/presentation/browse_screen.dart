import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/utils/layout_constants.dart';
import 'browse_category_grid.dart';

/// The preview's Browse screen: a title and subtitle, the six category
/// tiles, then the APP card whose Settings row opens Settings. It is a
/// plain screen of its own — not a wrapper around [ExploreScreen], which
/// is the legacy grid-of-all-providers view (its tiles are the same
/// [BrowseCategoryGrid], but the layout and the APP card are Browse's).
class BrowseScreen extends StatelessWidget {
  const BrowseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Scaffold(
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 8,
          bottom: LayoutConstants.shellBottomContentPadding(context),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LayoutConstants.spacingMd,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.browse,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.exploreByCategory,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const BrowseCategoryGrid(),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LayoutConstants.spacingMd,
              ),
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
          ],
        ),
      ),
    );
  }
}
