import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/addons/models/addon_manifest.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/cards_wrapper.dart';
import '../../addons/presentation/addon_providers.dart';

/// Where the Browse catalogue choice is kept: on this device only (the
/// settings box), never synced. A seam so tests need no Hive box.
class BrowseCatalogueStore {
  const BrowseCatalogueStore({required this.read, required this.write});

  /// The chosen add-on's manifest URL, or null for "All catalogues".
  final String? Function() read;
  final Future<void> Function(String? manifestUrl) write;
}

final browseCatalogueStoreProvider = Provider<BrowseCatalogueStore>((ref) {
  final storage = ref.watch(storageServiceProvider);
  return BrowseCatalogueStore(
    read: storage.getBrowseCatalogueAddon,
    write: storage.setBrowseCatalogueAddon,
  );
});

/// The add-on Browse is limited to (its manifest URL), or null for all.
/// This is what the person picked; [browseCatalogueProvider] is what
/// Browse actually uses.
class BrowseCatalogueChoice extends Notifier<String?> {
  @override
  String? build() => ref.watch(browseCatalogueStoreProvider).read();

  Future<void> choose(String? manifestUrl) async {
    state = manifestUrl;
    await ref.read(browseCatalogueStoreProvider).write(manifestUrl);
  }
}

final browseCatalogueChoiceProvider =
    NotifierProvider<BrowseCatalogueChoice, String?>(BrowseCatalogueChoice.new);

/// The installed, enabled add-ons that have at least one browsable
/// catalog, in the person's add-on order.
final browseCatalogueAddonsProvider = Provider<List<ManagedAddon>>((ref) {
  final seen = <String>{};
  return [
    for (final entry in ref.watch(browsableCatalogsProvider))
      if (seen.add(entry.addon.manifestUrl)) entry.addon,
  ];
});

/// The add-on Browse shows, or null for every add-on. A stored choice
/// whose add-on was removed or disabled - or with fewer than two catalog
/// add-ons left, when the line is hidden - falls back to all, silently.
final browseCatalogueProvider = Provider<String?>((ref) {
  final choice = ref.watch(browseCatalogueChoiceProvider);
  if (choice == null) return null;
  final addons = ref.watch(browseCatalogueAddonsProvider);
  if (addons.length < 2) return null;
  return addons.any((a) => a.manifestUrl == choice) ? choice : null;
});

/// "All catalogues" - the chooser's first entry and the line's default.
const String kBrowseAllCatalogues = 'All catalogues';

/// Browse's second header line, in the style of Home's provider line
/// (`HomeProviderChipBar`): `from <catalogue> ▾`, "from" in the header
/// text colour, the name bold in the accent colour, a small chevron. No
/// pill, background or border; the whole line is a 44 px tap target and
/// opens the chooser. Used as the AppBar's `bottom`.
class BrowseCatalogueBar extends ConsumerWidget
    implements PreferredSizeWidget {
  const BrowseCatalogueBar({super.key});

  static const double tapHeight = 44;
  static const double gapAbove = 5;
  static const double maxWidthFraction = 0.7;
  static const Key tapKey = ValueKey('browse-catalogue-line');

  @override
  Size get preferredSize => const Size.fromHeight(tapHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final addons = ref.watch(browseCatalogueAddonsProvider);
    final chosen = ref.watch(browseCatalogueProvider);
    final label = chosen == null
        ? kBrowseAllCatalogues
        : addons.firstWhere((a) => a.manifestUrl == chosen).displayName;

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final base = theme.colorScheme.onSurface.withValues(alpha: 0.95);
    final shadows = [
      Shadow(
        color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.6),
        blurRadius: 6,
        offset: const Offset(0, 1),
      ),
    ];
    final baseStyle = TextStyle(
      color: base,
      fontSize: 13,
      height: 1.25,
      fontWeight: FontWeight.w600,
      shadows: shadows,
    );
    final accentStyle = baseStyle.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w700,
    );
    final width = MediaQuery.sizeOf(context).width;

    return SizedBox(
      height: tapHeight,
      child: Align(
        alignment: AlignmentDirectional.topStart,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width * maxWidthFraction),
          child: CardsWrapper(
            key: tapKey,
            onTap: () => showBrowseCatalogueChooser(context),
            scaleFactor: 1.0,
            borderRadius: BorderRadius.circular(8),
            child: Semantics(
              button: true,
              child: SizedBox(
                height: tapHeight,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: NavigationToolbar.kMiddleSpacing,
                    end: 8,
                    top: gapAbove,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.topStart,
                    widthFactor: 1,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(l10n.homeProviderFrom, style: baseStyle),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: accentStyle,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: base,
                          shadows: shadows,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The catalogue chooser: a radio list in the style of Home's Select
/// Provider dialog - "All catalogues", then each catalog add-on.
Future<void> showBrowseCatalogueChooser(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const _BrowseCatalogueDialog(),
  );
}

class _BrowseCatalogueDialog extends ConsumerWidget {
  const _BrowseCatalogueDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final addons = ref.watch(browseCatalogueAddonsProvider);
    final chosen = ref.watch(browseCatalogueProvider);

    void pick(String? manifestUrl) {
      ref.read(browseCatalogueChoiceProvider.notifier).choose(manifestUrl);
      Navigator.pop(context);
    }

    return AlertDialog(
      title: const Text('Select catalogue'),
      contentPadding: const EdgeInsets.fromLTRB(0, 20, 0, 0),
      content: SizedBox(
        width: 600,
        child: RadioGroup<String?>(
          groupValue: chosen,
          onChanged: pick,
          child: Material(
            color: Colors.transparent,
            clipBehavior: Clip.hardEdge,
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                ListTile(
                  key: const ValueKey('browse-catalogue-all'),
                  title: const Text(kBrowseAllCatalogues),
                  leading: const Radio<String?>(value: null),
                  onTap: () => pick(null),
                ),
                for (final addon in addons)
                  ListTile(
                    key: ValueKey('browse-catalogue-${addon.manifestUrl}'),
                    title: Text(
                      addon.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    leading: Radio<String?>(value: addon.manifestUrl),
                    onTap: () => pick(addon.manifestUrl),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }
}
