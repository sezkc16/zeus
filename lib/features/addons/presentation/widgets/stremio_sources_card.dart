import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zorox/l10n/generated/app_localizations.dart';

import '../../../../core/addons/data/addon_repository.dart';
import '../../../../core/addons/data/addon_stream_service.dart';
import '../../../details/presentation/widgets/source_section_card.dart';

/// Stremio's source discovery on an add-on details screen, drawn the same way
/// the Nuvio card is drawn on a TMDB one.
///
/// **Why it is a card and not a button.** It used to be a saturated
/// [FilledButton] reading "Play from add-ons", which made it the page's
/// primary action and promised playback for a tap that opens a list of links.
/// Every other source-discovery block in the app is a [SourceSectionCard]; this
/// is that block for Stremio.
///
/// **Why it can vanish.** Only an add-on that declares the `stream` resource
/// can answer this - catalog-only add-ons (Trakt lists, Streaming Catalogs)
/// are never asked, and [AddonStreamService.streamProvidersOf] is the single
/// place that knows it. With none installed the tap could only ever open a
/// sheet that says so, which is worse than no card.
class StremioSourcesCard extends ConsumerWidget {
  const StremioSourcesCard({
    super.key,
    required this.onOpen,
    this.episode,
    this.compact = false,
    this.autofocus = false,
    this.merged = false,
    this.resumeLabel,
    this.onChangeSource,
  });

  /// Build 76 (design A): with a saved position the card offers a
  /// second, outlined button beside Resume — "Change source" — that
  /// opens the full list with nothing played by itself. Resume alone
  /// went straight to the source the title last played on, with no way
  /// to the list. Shown only together with [resumeLabel].
  final VoidCallback? onChangeSource;

  /// The second button's label.
  static const String changeSourceLabel = 'Change source';

  /// Build 75: the action's label when the title (or [episode]) has a
  /// saved position — "Resume S1 E3 · 12:34" instead of "Find sources".
  final String? resumeLabel;

  /// A title opened from Browse: its sources come from plugins, Nuvio
  /// providers and Stremio add-ons together, so the card is always there -
  /// also with no Stremio stream add-on installed (v8: it used to vanish and
  /// leave the page with no way to play).
  final bool merged;

  /// The season and episode this card resolves, or null for a movie.
  ///
  /// A series' card is a shortcut to one episode - the first of the selected
  /// season - and the label names it, because the episode list further down
  /// the page is how any other episode is reached. "Play S1 E1" already said
  /// as much; it just said "play" for something that opens a list.
  final ({int season, int episode})? episode;

  final VoidCallback onOpen;

  /// Passed through to [SourceSectionCard.compact].
  final bool compact;

  /// Passed through to [SourceSectionAction.autofocus].
  final bool autofocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final addonCount = ref.watch(
      addonRepositoryProvider.select(
        (s) => AddonStreamService.streamProvidersOf(s.enabled).length,
      ),
    );
    if (addonCount == 0 && !merged) return const SizedBox.shrink();

    final target = episode;
    final primary = SourceSectionAction(
      label: resumeLabel != null
          ? resumeLabel!
          : merged
          ? (target == null
                ? l10n.sourcesFind
                : l10n.sourcesFindForEpisode(target.season, target.episode))
          : target == null
          ? l10n.stremioSearchAddons
          // (season, episode) - the order gen-l10n emits from the ARB
          // placeholders. Both are ints, so getting it backwards compiles
          // cleanly and renders the numbers swapped.
          : l10n.stremioSearchAddonsForEpisode(target.season, target.episode),
      icon: merged ? Icons.play_arrow_rounded : Icons.search_rounded,
      onTap: onOpen,
      fitLabel: resumeLabel != null && onChangeSource != null,
      autofocus: autofocus,
      // Full bleed on a phone; capped on a desktop, where the card sits in
      // a hero column that can run past a thousand points and a button
      // stretched across all of it reads as a banner.
      maxWidth: compact && !(resumeLabel != null && onChangeSource != null)
          ? kSourceActionDesktopWidth
          : null,
    );
    return SourceSectionCard(
      key: merged ? const ValueKey('merged-sources-card') : null,
      icon: merged
          ? Icons.play_circle_outline_rounded
          : Icons.extension_rounded,
      title: merged ? l10n.sourcesCardTitle : l10n.stremioAddons,
      compact: compact,
      badge: merged
          ? null
          : SourceSectionBadge(label: l10n.stremioAddonCount(addonCount)),
      child: Padding(
        padding: compact
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: SourceSectionCard.gutter),
        child: _actions(context, primary),
      ),
    );
  }

  /// The card's action row: the main action alone, or — with a saved
  /// position and [onChangeSource] — Resume and "Change source" side by
  /// side, each as wide as its label needs. When the two do not fit in
  /// one line (a narrow phone, a long label, large text) they stack;
  /// neither label is ever cut with "…".
  Widget _actions(BuildContext context, SourceSectionAction primary) {
    final change = onChangeSource;
    if (resumeLabel == null || change == null) return primary;
    final second = SourceSectionAction(
      key: const ValueKey('change-source'),
      label: changeSourceLabel,
      icon: Icons.swap_horiz_rounded,
      onTap: change,
      maxWidth: null,
      secondary: true,
      fitLabel: true,
    );
    const gap = 8.0;
    final needFirst = SourceSectionAction.widthFor(context, primary.label);
    final needSecond = SourceSectionAction.widthFor(context, changeSourceLabel);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cap = compact ? kSourceActionDesktopWidth * 1.6 : double.infinity;
        final width = constraints.maxWidth < cap ? constraints.maxWidth : cap;
        final sideBySide = needFirst + needSecond + gap <= width;
        final Widget row = sideBySide
            ? Row(
                children: [
                  Expanded(flex: needFirst.round(), child: primary),
                  const SizedBox(width: gap),
                  Expanded(flex: needSecond.round(), child: second),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  primary,
                  const SizedBox(height: gap),
                  second,
                ],
              );
        if (!compact) return row;
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width),
            child: row,
          ),
        );
      },
    );
  }
}
