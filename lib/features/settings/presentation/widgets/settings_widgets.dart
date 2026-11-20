import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../../core/icons/reicon_icon.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../shared/focus/app_focus.dart';

export '../../../../core/icons/reicon_icon.dart' show Reicon;

/// Settings rows are open rows (design B, public 1.0.0): no card around a
/// group, and this much clear space above and below each row's text. One
/// line to retune every Settings screen.
const double kSettingsRowVerticalPadding = 19;

/// The hairline between two consecutive rows of a group (1.0.1, design A):
/// full row width, painted over the boundary so it adds no height.
const double kSettingsRowDividerThickness = 1;

/// How strongly the hairline shows: the theme's text colour at this
/// opacity, so it is a faint light line on the dark themes and a faint
/// dark line on Frost.
const double kSettingsRowDividerOpacity = 0.10;

/// The gap between a row's icon tile and its text.
const double kSettingsRowIconGap = 14;

/// The space above a group's CAPS header — what separates one group from
/// the next now that there is no card to do it.
const double kSettingsGroupHeaderTopGap = 22;

/// Build 74 (design A, picked by the user 2026-11-18): every Settings
/// section sits in one thin rounded outline — a border only, no fill —
/// with its CAPS header above it. The corner radius of that outline.
const double kSettingsCardRadius = 18;

/// The outline's thickness.
const double kSettingsCardBorderWidth = 1;

/// How strongly the outline shows: the theme's text colour at this
/// opacity — the same family as the row hairline
/// ([kSettingsRowDividerOpacity]), a step stronger so the box reads on
/// Frost as well as on the dark themes.
const double kSettingsCardBorderOpacity = 0.18;

/// The space between the outline and the rows, left and right, so the
/// icons and text sit inside the box.
const double kSettingsCardInnerPadding = 12;

/// The gap between a section's header and its outline.
const double kSettingsCardHeaderGap = 8;

/// The outline's colour for [scheme].
Color settingsCardBorderColor(ColorScheme scheme) =>
    scheme.onSurface.withValues(alpha: kSettingsCardBorderOpacity);

/// The outline around one Settings section's rows and controls.
class SettingsSectionCard extends StatelessWidget {
  const SettingsSectionCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kSettingsCardRadius),
        border: Border.all(
          color: settingsCardBorderColor(Theme.of(context).colorScheme),
          width: kSettingsCardBorderWidth,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kSettingsCardBorderWidth + kSettingsCardInnerPadding,
          vertical: kSettingsCardBorderWidth,
        ),
        child: Column(children: children),
      ),
    );
  }
}

class SettingsGroup extends StatelessWidget {
  /// The CAPS header above the group. Null renders no header — the
  /// General group on the Settings page (build 102) has none, because
  /// its theme and accent sections carry their own Olympus headings.
  final String? title;
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
    this.title,
    required this.children,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            // The design preview's section headers: gold, all caps, 12px,
            // tracked out — not the fork's title-case bold header. The
            // header sits on the same left edge as the card (spacingMd),
            // so the whole group reads as one column.
            padding: EdgeInsets.fromLTRB(
              LayoutConstants.spacingMd,
              // Inside a dialog (filled: false) the header keeps its old gap.
              filled ? kSettingsGroupHeaderTopGap : 8,
              LayoutConstants.spacingMd,
              filled ? kSettingsCardHeaderGap : 8,
            ),
            child: Text(
              title!.toUpperCase(),
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
          // Build 74 (design A): on a page the section's rows and
          // controls sit in one thin outline — no fill. Inside a dialog
          // ([filled] false) they stay bare, as before.
          child: filled
              ? SettingsSectionCard(children: children)
              : Column(children: children),
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
/// Pass either [icon] (a Material icon) or [reicon] (a Reicon icon,
/// rendered as text in the tile); exactly one must be set. [value] is
/// the right-aligned current value (e.g. "English", "Home", "2.9.19");
/// [trailing] overrides it with a widget of its own (a Switch). [danger]
/// paints the title red — Factory Reset only.
class SettingsTile extends StatefulWidget {
  final IconData? icon;

  /// A Reicon icon, drawn in the accent colour on an accent-tinted
  /// tile, in [kSettingsIconWeight]. Every Settings row uses this.
  final Reicon? reicon;
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
    this.reicon,
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
  }) : assert(icon != null || reicon != null, 'SettingsTile needs an icon');

  @override
  State<SettingsTile> createState() => _SettingsTileState();
}

class _SettingsTileState extends State<SettingsTile> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final showFocus = showFocusIndicator(context, _isFocused);
    return SettingsRowLine(
      color: Theme.of(context).colorScheme.onSurface
          .withValues(alpha: kSettingsRowDividerOpacity),
      child: _buildRow(context, primary, showFocus),
    );
  }

  Widget _buildRow(BuildContext context, Color primary, bool showFocus) {
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
                minLeadingWidth: 36,
                minVerticalPadding: kSettingsRowVerticalPadding,
                // No card, so no inset inside one: the icon tiles stand on the
                // header's left edge.
                contentPadding: EdgeInsets.zero,
                horizontalTitleGap: kSettingsRowIconGap,
                leading: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: widget.reicon != null
                      ? ReiconIcon(widget.reicon!, color: primary, size: 21)
                      : Icon(widget.icon, color: primary, size: 21),
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
                          color: widget.danger ? const Color(0xFFFF7A6B) : null,
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
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
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
      ],
    );
  }
}

/// Marks a Settings row and paints the hairline above it when the row
/// directly above it, in the same vertical column, is a Settings row too.
///
/// The row decides at paint time by looking at its neighbours, so callers
/// pass nothing: a hidden row (not built, or built with no height) leaves
/// neither a doubled nor an orphan line, the first row of a group and the
/// row after a non-row block (the theme picker, the accent swatches, a
/// preview) get none, and no line ever follows the last row. The line is
/// painted over the row's top edge and takes no space.
class SettingsRowLine extends SingleChildRenderObjectWidget {
  const SettingsRowLine({required this.color, super.child, super.key});

  final Color color;

  @override
  RenderSettingsRowLine createRenderObject(BuildContext context) =>
      RenderSettingsRowLine(color: color);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSettingsRowLine renderObject,
  ) {
    renderObject.color = color;
  }
}

class RenderSettingsRowLine extends RenderProxyBox {
  RenderSettingsRowLine({required Color color}) : _color = color;

  Color _color;
  Color get color => _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  /// Whether this row currently draws the hairline on its top edge.
  bool get hasLineAbove {
    if (!hasSize || size.height <= 0) return false;
    final above = _visibleBoxAbove(this);
    return above != null && _endsWithRow(above);
  }

  static bool _isColumn(Object? box) =>
      box is RenderFlex && box.direction == Axis.vertical;

  /// The nearest box with height that sits above [box] in its column,
  /// stepping out of a nested column when [box] is the first thing in it.
  static RenderBox? _visibleBoxAbove(RenderBox box) {
    final parent = box.parent;
    if (!_isColumn(parent)) return null;
    var data = box.parentData;
    while (data is FlexParentData && data.previousSibling != null) {
      final sibling = data.previousSibling!;
      if (sibling.hasSize && sibling.size.height > 0) return sibling;
      data = sibling.parentData;
    }
    return _visibleBoxAbove(parent! as RenderBox);
  }

  /// Whether the bottom of [box] is a Settings row: the box itself, or the
  /// last visible thing in a nested column.
  static bool _endsWithRow(RenderBox box) {
    if (box is RenderSettingsRowLine) return true;
    if (!_isColumn(box)) return false;
    var child = (box as RenderFlex).lastChild;
    while (child != null) {
      if (child.hasSize && child.size.height > 0) return _endsWithRow(child);
      child = (child.parentData! as FlexParentData).previousSibling;
    }
    return false;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (!hasLineAbove) return;
    context.canvas.drawRect(
      Rect.fromLTWH(
        offset.dx,
        offset.dy - kSettingsRowDividerThickness / 2,
        size.width,
        kSettingsRowDividerThickness,
      ),
      Paint()..color = _color,
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
