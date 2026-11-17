import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/addons/data/addon_repository.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../shared/widgets/cards_wrapper.dart';
import '../../addons/presentation/addon_providers.dart';
import '../../addons/presentation/addons_screen.dart';
import '../../explore/presentation/delegates/explore_search_delegate.dart';

/// The Browse tab. It has no content of its own: it lists the catalogs of
/// the Stremio add-ons the person installed (Cinemeta, Anime Kitsu, a
/// streaming-catalogs add-on, ...), one row per catalog, through
/// [AddonCatalogsTabView].
///
/// With no catalog add-on installed the page is empty but for one line and
/// a button to the Stremio add-ons screen; nothing is fetched. The header
/// holds a button to that screen and, once an installed add-on has a
/// searchable catalog, a search over the installed add-ons' catalogs.
class BrowseScreen extends ConsumerStatefulWidget {
  const BrowseScreen({super.key});

  @override
  ConsumerState<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends ConsumerState<BrowseScreen> {
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<double> _barOpacity = ValueNotifier<double>(0);
  final FocusNode _firstActionFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final opacity = (_scrollController.offset * 0.8 / 300).clamp(0.0, 1.0);
    if (opacity != _barOpacity.value) _barOpacity.value = opacity;
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _barOpacity.dispose();
    _firstActionFocusNode.dispose();
    super.dispose();
  }

  /// The Stremio add-ons screen lives in the Settings branch, so it is gone
  /// to rather than pushed - the same way the Plugins tab opens it.
  void _openAddons({bool discover = false}) {
    AddonsRoute(initialTab: discover ? 1 : 0).go(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final loading = ref.watch(addonRepositoryProvider).isLoading;
    final hasCatalogs = ref.watch(browsableCatalogsProvider).isNotEmpty;
    // Search asks the installed add-ons' own catalogs. With none of them
    // searchable the search provider would fall back to the built-in
    // Cinemeta, which is content the person never installed - so the
    // button is only offered when an installed add-on can answer.
    final canSearch = ref
        .watch(addonRepositoryProvider)
        .enabled
        .any(
          (addon) =>
              (addon.manifest?.hasResource('catalog') ?? false) &&
              addon.manifest!.catalogs.any((c) => c.supportsSearch),
        );
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      // The first catalog's banner runs up behind the header, which fades
      // in a background of its own as the page scrolls.
      extendBodyBehindAppBar: hasCatalogs,
      appBar: AppBar(
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        forceMaterialTransparency: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        flexibleSpace: ValueListenableBuilder<double>(
          valueListenable: _barOpacity,
          builder: (context, opacity, _) => ColoredBox(
            color: theme.scaffoldBackgroundColor.withValues(
              alpha: hasCatalogs ? opacity : 1,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        title: Text(
          l10n.browse,
          style: TextStyle(
            color: theme.colorScheme.onSurface,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: false,
        actions: [
          _HeaderButton(
            key: const ValueKey('browse-addons-button'),
            icon: Icons.dashboard_customize_rounded,
            tooltip: l10n.browseOpenAddons,
            focusNode: _firstActionFocusNode,
            onTap: _openAddons,
          ),
          if (hasCatalogs && canSearch)
            _HeaderButton(
              key: const ValueKey('browse-search-button'),
              icon: Icons.search,
              tooltip: l10n.search,
              onTap: () => unawaited(showExploreSearch(context)),
            ),
        ],
      ),
      body: hasCatalogs
          ? AddonCatalogsTabView(
              scrollController: _scrollController,
              firstActionFocusNode: _firstActionFocusNode,
            )
          : loading
          ? const SizedBox.shrink()
          : _EmptyBrowse(onOpenAddons: () => _openAddons(discover: true)),
    );
  }
}

/// A round header button, the size and tint the app's other headers use.
class _HeaderButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  const _HeaderButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: LayoutConstants.spacingMd),
      child: CardsWrapper(
        focusNode: focusNode,
        onTap: onTap,
        borderRadius: BorderRadius.circular(50),
        child: Tooltip(
          message: tooltip,
          child: CircleAvatar(
            backgroundColor: scheme.onSurface.withValues(alpha: 0.1),
            radius: 18,
            child: Icon(icon, color: scheme.onSurface, size: 18),
          ),
        ),
      ),
    );
  }
}

/// Browse with no catalog add-on installed: one line and the way to them.
class _EmptyBrowse extends StatelessWidget {
  final VoidCallback onOpenAddons;

  const _EmptyBrowse({required this.onOpenAddons});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.only(
          left: 28,
          right: 28,
          bottom: LayoutConstants.shellBottomContentPadding(context),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.browseEmptyHint,
              key: const ValueKey('browse-empty-hint'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: LayoutConstants.spacingMd),
            FilledButton.icon(
              key: const ValueKey('browse-empty-addons-button'),
              onPressed: onOpenAddons,
              icon: const Icon(Icons.dashboard_customize_rounded),
              label: Text(l10n.browseOpenAddons),
            ),
          ],
        ),
      ),
    );
  }
}
