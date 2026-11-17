import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/utils/motion.dart';

/// Height of the track of a [ZeusSegmentedControl].
const double kZeusSegmentedHeight = 40;

/// Gap between the track's edge and the pill inside it.
const double kZeusSegmentedInset = 3;

/// How long the pill takes to slide to the tapped option.
const Duration kZeusSegmentedSlide = kMotionPill;

/// How strongly the track is tinted with the theme's text colour: a light
/// tint on the dark themes, a dark tint on Frost.
const double kZeusSegmentedTrackOpacity = 0.09;

/// One option of a [ZeusSegmentedControl].
class ZeusSegment<T> {
  const ZeusSegment({required this.value, required this.label});

  final T value;
  final String label;
}

/// The iOS-style sliding segmented control (1.0.1): one rounded track with
/// no outline and no dividers, and a rounded pill inside it that marks the
/// selected option and slides to the tapped one. No checkmark.
///
/// Options share the width equally and every label stays on one line — it
/// scales down rather than wrapping or truncating. The pill wears the
/// accent, its label the matching on-accent colour (dark on a very light
/// accent such as White, see `AppTheme`), so the control follows the accent
/// on every theme.
///
/// With the system's reduced-motion setting on the pill jumps instead of
/// sliding. With a keyboard or remote, the control takes focus as a whole
/// (shown by an accent ring) and left / right move the selection.
class ZeusSegmentedControl<T> extends StatelessWidget {
  const ZeusSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.maxWidth,
  }) : assert(segments.length >= 2);

  final List<ZeusSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Widest the control may get; it never exceeds the space it is given.
  /// Null fills the available width.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final control = _ZeusSegmentedBody<T>(
      segments: segments,
      selected: selected,
      onChanged: onChanged,
    );
    final width = maxWidth;
    if (width == null) return control;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: control,
      ),
    );
  }
}

class _ZeusSegmentedBody<T> extends StatefulWidget {
  const _ZeusSegmentedBody({
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final List<ZeusSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  State<_ZeusSegmentedBody<T>> createState() => _ZeusSegmentedBodyState<T>();
}

class _ZeusSegmentedBodyState<T> extends State<_ZeusSegmentedBody<T>> {
  bool _focused = false;

  int get _selectedIndex {
    final index = widget.segments.indexWhere(
      (segment) => segment.value == widget.selected,
    );
    return index < 0 ? 0 : index;
  }

  void _select(int index) {
    if (index < 0 || index >= widget.segments.length) return;
    final value = widget.segments[index].value;
    if (value == widget.selected) return;
    widget.onChanged(value);
  }

  /// Left / right move the selection by one, in reading direction.
  void _step(int visualDelta) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    _select(_selectedIndex + (rtl ? -visualDelta : visualDelta));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = widget.segments.length;
    final index = _selectedIndex;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kZeusSegmentedSlide;
    const radius = kZeusSegmentedHeight / 2;

    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowLeft): _StepIntent(-1),
        SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(1),
      },
      actions: {
        _StepIntent: CallbackAction<_StepIntent>(
          onInvoke: (intent) {
            _step(intent.delta);
            return null;
          },
        ),
      },
      child: Container(
        height: kZeusSegmentedHeight,
        // The focus ring is painted over the track, so focus never changes
        // the control's size.
        foregroundDecoration: _focused
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: scheme.primary, width: 2),
              )
            : null,
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(
            alpha: kZeusSegmentedTrackOpacity,
          ),
          borderRadius: BorderRadius.circular(radius),
        ),
        padding: const EdgeInsets.all(kZeusSegmentedInset),
        child: Stack(
          children: [
            // The pill: one segment wide, slid to the selected option.
            AnimatedAlign(
              duration: duration,
              curve: kMotionPillCurve,
              alignment: AlignmentDirectional(
                -1 + 2 * index / (count - 1),
                0,
              ),
              child: FractionallySizedBox(
                widthFactor: 1 / count,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(
                      radius - kZeusSegmentedInset,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Row(
              children: [
                for (var i = 0; i < count; i++)
                  Expanded(
                    child: Semantics(
                      button: true,
                      selected: i == index,
                      inMutuallyExclusiveGroup: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _select(i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: AnimatedDefaultTextStyle(
                                duration: duration,
                                style: TextStyle(
                                  fontFamily: DefaultTextStyle.of(
                                    context,
                                  ).style.fontFamily,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: i == index
                                      ? scheme.onPrimary
                                      : scheme.onSurface,
                                ),
                                child: Text(
                                  widget.segments[i].label,
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StepIntent extends Intent {
  const _StepIntent(this.delta);

  final int delta;
}
