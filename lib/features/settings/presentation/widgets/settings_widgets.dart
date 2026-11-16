import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/utils/layout_constants.dart';
import '../../../../shared/focus/app_focus.dart';

class SettingsGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;

  /// Whether the rows sit on a card of their own.
  ///
  /// True on the Settings page, where the card is what separates a group from
  /// the scaffold behind it. False inside a dialog: the card fills with
  /// [ColorScheme.surface], which the dark theme pins to pure black, so on a
  /// dialog's own surface it reads as a black box floating in a grey panel
  /// rather than as a group. The tiles keep their dividers either way, which
  /// is what actually groups them.
  final bool filled;

  const SettingsGroup({
    super.key,
    required this.title,
    required this.children,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // The design preview's section headers: gold, all caps, 12px,
          // tracked out — not the fork's title-case bold header. The
          // header sits on the same left edge as the card (spacingMd),
          // so the whole group reads as one column.
          padding: const EdgeInsets.fromLTRB(
            LayoutConstants.spacingMd,
            8,
            LayoutConstants.spacingMd,
            8,
          ),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w800,
              fontSize: 12,
              letterSpacing: 0.8,
            ),
          ),
        ),
        Container(
          // One step of inset, paid here and nowhere else: the host
          // screen's ListView must not add its own horizontal padding,
          // or the four screens of the settings tree disagree about
          // their left edge (settings_inset_test).
          margin: const EdgeInsets.symmetric(
            horizontal: LayoutConstants.spacingMd,
          ),
          decoration: filled
              ? BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Theme.of(context).dividerColor),
                )
              : null,
          child: Column(children: children),
        ),
      ],
    );
  }
}

/// A row in a [SettingsGroup], in the design preview's visual language:
/// a 34px gold-dim icon tile, title 14.5px semibold, subtitle 12px muted
/// under it, and the row's current value right-aligned in muted 13px
/// before the chevron. The fork's pattern — gold line icon, value below
/// the title, title-case header — is not used anywhere.
///
/// Pass either [icon] (a Material icon) or [emoji] (one emoji string,
/// rendered as text in the tile); exactly one must be set. [value] is
/// the right-aligned current value (e.g. "English", "Home", "2.9.19");
/// [trailing] overrides it with a widget of its own (a Switch). [danger]
/// paints the title red — Factory Reset only.
class SettingsTile extends StatefulWidget {
  final IconData? icon;

  /// One emoji string, rendered as text in the icon tile.
  final String? emoji;
  final String title;
  final String? subtitle;

  /// The row's current value, right-aligned before the chevron.
  final String? value;

  /// Whether the chevron shows after [value] (or on its own). The Version
  /// row shows its value with no chevron — it goes nowhere.
  final bool showChevron;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool isLast;
  final bool isBeta;

  /// Red title — the Factory Reset danger row only.
  final bool danger;
  final FocusNode? focusNode;

  const SettingsTile({
    super.key,
    this.icon,
    this.emoji,
    required this.title,
    this.subtitle,
    this.value,
    this.showChevron = true,
    this.trailing,
    this.onTap,
    this.isLast = false,
    this.isBeta = false,
    this.danger = false,
    this.focusNode,
  }) : assert(
         icon != null || emoji != null,
         'SettingsTile needs an icon or an emoji',
       );

  @override
  State<SettingsTile> createState() => _SettingsTileState();
}

class _SettingsTileState extends State<SettingsTile> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final showFocus = showFocusIndicator(context, _isFocused);
    return Column(
      children: [
        Focus(
          // Passive observer — we want the inner ListTile's InkWell to remain
          // the actual focus target (it's what handles onTap when OK is
          // pressed). hasFocus on this node reflects "any descendant focused"
          // so onFocusChange still fires when the tile is reached.
          focusNode: widget.focusNode,
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (f) {
            setState(() => _isFocused = f);
            if (f) {
              // Center the focused setting row in the viewport.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final ctx = FocusManager.instance.primaryFocus?.context;
                final ro = ctx?.findRenderObject();
                if (ctx != null && ctx.mounted && ro != null) {
                  Scrollable.maybeOf(ctx)?.position.ensureVisible(
                    ro,
                    alignment: 0.5,
                    duration: const Duration(milliseconds: 380),
                    curve: Curves.fastOutSlowIn,
                  );
                }
              });
            }
          },
          child: AnimatedContainer(
            duration: AppFocus.duration,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              // A neutral wash and a neutral ring, and only for whoever is
              // driving the app without a pointer. What was here was a 22 %
              // accent fill and a 2 dp accent border that stayed on screen
              // after a tap on a phone, where nothing about the interaction
              // called for a focus indicator at all.
              color: AppFocus.rowTint(context, focused: showFocus),
              border:
                  AppFocus.border(context, focused: showFocus) ??
                  Border.all(
                    color: Colors.transparent,
                    width: AppFocus.ringWidth,
                  ),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: ListTile(
                focusColor: Colors.transparent,
                hoverColor: primary.withValues(alpha: 0.10),
                minTileHeight: 52,
                minLeadingWidth: 34,
                horizontalTitleGap: 12,
                leading: Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: widget.emoji != null
                      ? Text(
                          widget.emoji!,
                          style: const TextStyle(fontSize: 18),
                        )
                      : Icon(widget.icon, color: primary, size: 20),
                ),
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        widget.title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5,
                          color: widget.danger
                              ? const Color(0xFFFF7A6B)
                              : null,
                        ),
                      ),
                    ),
                    if (widget.isBeta) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary
                              .withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          "BETA",
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: widget.subtitle != null
                    ? Text(
                        widget.subtitle!,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                      )
                    : null,
                trailing: widget.trailing != null
                    ? ExcludeFocus(
                        excluding: true,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // A value and a trailing widget together: the
                            // value names the choice, the trailing shows
                            // it. The subtitle Text Colour row is the one
                            // that has both — "Yellow" beside its swatch.
                            // A trailing on its own (a Switch) still
                            // replaces the value + chevron, as before: a
                            // Switch tile's `value:` belongs to the Switch
                            // itself, not to this tile, so `widget.value`
                            // is null there and nothing changes.
                            if (widget.value != null) ...[
                              Text(
                                widget.value!,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            showFocus
                                ? SwitchTheme(
                                    data: SwitchThemeData(
                                      thumbIcon:
                                          WidgetStateProperty.resolveWith<
                                            Icon?
                                          >((states) {
                                            if (states.contains(
                                              WidgetState.selected,
                                            )) {
                                              return const Icon(
                                                Icons.check_rounded,
                                                size: 14,
                                              );
                                            } else {
                                              return const Icon(
                                                Icons.close_rounded,
                                                size: 14,
                                              );
                                            }
                                          }),
                                    ),
                                    child: widget.trailing!,
                                  )
                                : widget.trailing!,
                          ],
                        ),
                      )
                    : widget.value != null
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.value!,
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                          if (widget.showChevron) ...[
                            const SizedBox(width: 4),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 20,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ],
                      )
                    : widget.showChevron
                    ? const Icon(Icons.chevron_right_rounded, size: 20)
                    : const SizedBox.shrink(),
                onTap: widget.onTap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ),
        if (!widget.isLast && !showFocus)
          Divider(
            height: 1,
            indent: 62,
            endIndent: 16,
            color: Theme.of(context).dividerColor.withValues(alpha: 0.8),
          ),
      ],
    );
  }
}

/// Scrolls its child into view once, on the frame after the picker is laid
/// out.
///
/// [ListTile.autofocus] gives the current value the focus but does not move a
/// [Scrollable]. In a picker taller than its dialog — the language list is
/// thirty-odd rows — that would focus the right row off screen and still open
/// the list on row one, which is the bug this is here to close. A no-op when
/// the list already fits, since there is then nothing to scroll.
class ScrollIntoView extends StatefulWidget {
  const ScrollIntoView({required this.child, super.key});

  final Widget child;

  @override
  State<ScrollIntoView> createState() => _ScrollIntoViewState();
}

class _ScrollIntoViewState extends State<ScrollIntoView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || Scrollable.maybeOf(context) == null) return;
      // Duration.zero jumps rather than animating: the picker should already
      // be showing the current value on the first frame the viewer sees.
      unawaited(
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: Duration.zero,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Wraps the one option row that matches the current value so it is scrolled
/// into view. Pair with `autofocus: isCurrent` on the row itself.
Widget currentOption({required bool isCurrent, required Widget child}) =>
    isCurrent ? ScrollIntoView(child: child) : child;
