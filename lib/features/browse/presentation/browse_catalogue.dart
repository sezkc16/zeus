import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/addons/models/addon_manifest.dart';
import '../../../../core/config/tmdb_config.dart';
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

/// What is stored for "All catalogues" now that nothing stored means the
/// default (TMDB "Movies & Shows" when the build has a TMDB key).
const String kBrowseAllChoice = '__all__';

/// The selection value for TMDB "Movies & Shows".
const String kBrowseTmdbSelection = 'tmdb';

/// TMDB's name in the switcher - the name upstream's Explore Source
/// dialog gave it.
const String kBrowseTmdbLabel = 'Movies & Shows';

/// Whether this app can ask TMDB at all: a key baked into the build, or
/// one the person entered. Without one Browse behaves as it did before
/// TMDB came back: add-on catalogues only.
final browseTmdbAvailableProvider = Provider<bool>(
  (ref) => TmdbConfig.apiKey.isNotEmpty,
);

/// What the person picked, as stored: null (never picked, or picked
/// TMDB), [kBrowseAllChoice], or an add-on's manifest URL.
/// [browseSelectionProvider] is what Browse actually shows.
class BrowseCatalogueChoice extends Notifier<String?> {
  @override
  String? build() => ref.watch(browseCatalogueStoreProvider).read();

  /// [selection] is [kBrowseTmdbSelection], [kBrowseAllChoice], an
  /// add-on's manifest URL - or null, the older spelling of "all".
  Future<void> choose(String? selection) async {
    final stored = selection == kBrowseTmdbSelection
        ? null
        : (selection ?? kBrowseAllChoice);
    state = stored;
    await ref.read(browseCatalogueStoreProvider).write(stored);
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

/// What Browse shows: [kBrowseTmdbSelection], [kBrowseAllChoice] or an
/// add-on's manifest URL.
///
/// Nothing stored means TMDB when the app has a key, and all add-on
/// catalogues when it has none. A stored add-on stays chosen while it
/// is installed; once it is removed or disabled the default applies
/// again, silently.
final browseSelectionProvider = Provider<String>((ref) {
  final fallback = ref.watch(browseTmdbAvailableProvider)
      ? kBrowseTmdbSelection
      : kBrowseAllChoice;
  final choice = ref.watch(browseCatalogueChoiceProvider);
  if (choice == null) return fallback;
  if (choice == kBrowseAllChoice) return kBrowseAllChoice;
  final addons = ref.watch(browseCatalogueAddonsProvider);
  return addons.any((a) => a.manifestUrl == choice) ? choice : fallback;
});

/// True when Browse shows TMDB "Movies & Shows".
final browseShowsTmdbProvider = Provider<bool>((ref) {
  // Asked first, so a build without a key never touches storage here.
  if (!ref.watch(browseTmdbAvailableProvider)) return false;
  return ref.watch(browseSelectionProvider) == kBrowseTmdbSelection;
});

/// The switcher's entries in order: TMDB first (when the app has a
/// key), "All catalogues" (with two or more catalog add-ons), then each
/// catalog add-on.
final browseSelectionOptionsProvider = Provider<List<BrowseOption>>((ref) {
  final addons = ref.watch(browseCatalogueAddonsProvider);
  return [
    if (ref.watch(browseTmdbAvailableProvider))
      const BrowseOption(kBrowseTmdbSelection, kBrowseTmdbLabel),
    if (addons.length >= 2)
      const BrowseOption(kBrowseAllChoice, kBrowseAllCatalogues),
    for (final addon in addons)
      BrowseOption(addon.manifestUrl, addon.displayName),
  ];
});

/// One entry of the switcher: what is selected and what it is called.
class BrowseOption {
  const BrowseOption(this.value, this.label);

  final String value;
  final String label;
}

/// The add-on the add-on catalogue view is limited to, or null for
/// every add-on.
final browseCatalogueProvider = Provider<String?>((ref) {
  final selection = ref.watch(browseSelectionProvider);
  if (selection == kBrowseTmdbSelection || selection == kBrowseAllChoice) {
    return null;
  }
  return selection;
});

/// "All catalogues".
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
    final options = ref.watch(browseSelectionOptionsProvider);
    final selection = ref.watch(browseSelectionProvider);
    final label = options
        .firstWhere(
          (o) => o.value == selection,
          orElse: () => BrowseOption(selection, kBrowseAllCatalogues),
        )
        .label;

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
    final options = ref.watch(browseSelectionOptionsProvider);
    final selection = ref.watch(browseSelectionProvider);

    void pick(String? value) {
      if (value == null) return;
      ref.read(browseCatalogueChoiceProvider.notifier).choose(value);
      Navigator.pop(context);
    }

    Key keyFor(String value) => switch (value) {
      kBrowseTmdbSelection => const ValueKey('browse-catalogue-tmdb'),
      kBrowseAllChoice => const ValueKey('browse-catalogue-all'),
      _ => ValueKey('browse-catalogue-$value'),
    };

    return AlertDialog(
      title: const Text('Select catalogue'),
      contentPadding: const EdgeInsets.fromLTRB(0, 20, 0, 0),
      content: SizedBox(
        width: 600,
        child: RadioGroup<String>(
          groupValue: selection,
          onChanged: pick,
          child: Material(
            color: Colors.transparent,
            clipBehavior: Clip.hardEdge,
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final option in options)
                  ListTile(
                    key: keyFor(option.value),
                    title: Text(
                      option.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: option.value == kBrowseTmdbSelection
                        ? const Text('via TMDB')
                        : null,
                    leading: Radio<String>(value: option.value),
                    onTap: () => pick(option.value),
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
