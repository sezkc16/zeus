import 'package:flutter/widgets.dart';

import '../../core/utils/motion.dart';

/// The shell's branch container: every branch Navigator stays mounted (as
/// with go_router's default IndexedStack, so each tab keeps its state and
/// scroll position), and a branch switch cross-fades instead of snapping.
///
/// 1.0.1 build 67 — "setting tab pe ekdam fast, plugin search library
/// ekdam fast, usko smooth animation":
///
///  * tab ↔ tab: the old and the new tab are both on stage for
///    [kMotionTab] and cross-fade, the new one settling in from
///    [kMotionTabOffset] to the right;
///  * opening / closing Settings ([slideIndex], the gear): Settings slides
///    in from the right over the tab, and slides back out to the right,
///    by [kMotionSettingsOffset] of the width, fading as it goes.
///
/// The children keep a fixed place in the tree (index order, same wrapper
/// widgets whether animating or not), so nothing is ever remounted. Since
/// the paint order is the index order, the fade is always applied to the
/// upper of the two branches: it fades IN when it is the incoming one and
/// OUT when it is the outgoing one. The lower branch stays fully opaque,
/// so the pair never shows the background through both.
///
/// Outside a transition only the current branch is on stage; the others
/// are Offstage with their tickers off, exactly like the default container.
/// Reduced motion: the new branch just appears.
class BranchCrossFade extends StatefulWidget {
  const BranchCrossFade({
    super.key,
    required this.currentIndex,
    required this.children,
    this.slideIndex,
  });

  final int currentIndex;
  final List<Widget> children;

  /// The branch that opens like a page (Settings) rather than like a tab.
  final int? slideIndex;

  @override
  State<BranchCrossFade> createState() => _BranchCrossFadeState();
}

class _BranchCrossFadeState extends State<BranchCrossFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: kMotionTab,
    value: 1.0,
  )..addStatusListener(_onStatus);

  int? _previous;

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _previous != null) {
      setState(() => _previous = null);
    }
  }

  @override
  void didUpdateWidget(BranchCrossFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentIndex == oldWidget.currentIndex) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _previous = null;
      _controller.value = 1.0;
      return;
    }
    _previous = oldWidget.currentIndex;
    final page =
        widget.slideIndex != null &&
        (widget.currentIndex == widget.slideIndex ||
            _previous == widget.slideIndex);
    _controller.duration = page ? kMotionPage : kMotionTab;
    _controller.forward(from: 0.0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final current = widget.currentIndex;
        final previous = _previous;
        final animating = previous != null && previous != current;
        final page =
            animating &&
            widget.slideIndex != null &&
            (current == widget.slideIndex || previous == widget.slideIndex);
        final t = (page ? kMotionPageCurve : kMotionTabCurve).transform(
          _controller.value,
        );
        // The upper of the two (later in paint order) carries the fade.
        final upper = animating ? (current > previous ? current : previous) : -1;

        return Stack(
          fit: StackFit.expand,
          children: [
            for (var i = 0; i < widget.children.length; i++)
              _branch(
                index: i,
                onStage: i == current || (animating && i == previous),
                isCurrent: i == current,
                opacity: !animating || i != upper
                    ? 1.0
                    : (i == current ? t : 1.0 - t),
                dx: !animating
                    ? 0.0
                    : page
                    // Settings is the page: it travels, the tab stays put.
                    ? (i == widget.slideIndex
                          ? kMotionSettingsOffset *
                                (i == current ? 1.0 - t : t)
                          : 0.0)
                    : (i == current ? kMotionTabOffset * (1.0 - t) : 0.0),
              ),
          ],
        );
      },
    );
  }

  Widget _branch({
    required int index,
    required bool onStage,
    required bool isCurrent,
    required double opacity,
    required double dx,
  }) {
    return Offstage(
      key: ValueKey<int>(index),
      offstage: !onStage,
      child: TickerMode(
        enabled: isCurrent,
        child: IgnorePointer(
          ignoring: !isCurrent,
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: FractionalTranslation(
              translation: Offset(dx, 0),
              child: widget.children[index],
            ),
          ),
        ),
      ),
    );
  }
}
