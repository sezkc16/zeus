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
    this.onSwipeBack,
  });

  /// Called when an edge swipe on the [slideIndex] branch is let go past
  /// the threshold, with the branch to return to (the one it was opened
  /// from). The page has already slid off by then.
  final ValueChanged<int>? onSwipeBack;

  final int currentIndex;
  final List<Widget> children;

  /// The branch that opens like a page (Settings) rather than like a tab.
  final int? slideIndex;

  @override
  State<BranchCrossFade> createState() => _BranchCrossFadeState();
}

/// What a screen inside the [BranchCrossFade.slideIndex] branch uses to
/// drive the back swipe: the container moves the page and shows the branch
/// it was opened from underneath, like a native iOS back swipe.
abstract class BranchSwipeBackHandle {
  /// Move the page by [fraction] of the width (positive = to the right).
  void dragBy(double fraction);

  /// The finger left the screen moving at [velocity] px/s.
  void dragEnd(double velocity);

  /// The gesture was taken away: slide back.
  void dragCancel();
}

class BranchSwipeBackScope extends InheritedWidget {
  const BranchSwipeBackScope({
    super.key,
    required this.handle,
    required super.child,
  });

  final BranchSwipeBackHandle handle;

  static BranchSwipeBackHandle? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<BranchSwipeBackScope>()?.handle;

  @override
  bool updateShouldNotify(BranchSwipeBackScope oldWidget) =>
      handle != oldWidget.handle;
}

/// How far the page underneath is shifted left when the swipe starts; it
/// settles to its place as the page above leaves (iOS-like parallax).
const double kMotionSwipeParallax = 0.25;

class _BranchCrossFadeState extends State<BranchCrossFade>
    with TickerProviderStateMixin
    implements BranchSwipeBackHandle {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: kMotionTab,
    value: 1.0,
  )..addStatusListener(_onStatus);

  /// The back swipe: 0 = the page at rest, 1 = slid a full width away.
  late final AnimationController _swipe = AnimationController(
    vsync: this,
    duration: kMotionPage,
  );

  int? _previous;

  /// The branch the [BranchCrossFade.slideIndex] page was opened from.
  int _origin = 0;

  /// The swipe already showed the change: the next switch must not animate.
  bool _switchSilently = false;

  bool get _onPage =>
      widget.slideIndex != null && widget.currentIndex == widget.slideIndex;

  @override
  void dragBy(double fraction) {
    if (!_onPage || _swipe.isAnimating) return;
    _swipe.value = (_swipe.value + fraction).clamp(0.0, 1.0);
  }

  @override
  void dragEnd(double velocity) {
    if (!_onPage || _swipe.isAnimating) return;
    if (velocity > 700 || _swipe.value > 1 / 3) {
      _finishSwipe();
    } else {
      _swipe.animateBack(0, curve: kMotionPageCurve);
    }
  }

  @override
  void dragCancel() {
    if (_swipe.isAnimating) return;
    _swipe.animateBack(0, curve: kMotionPageCurve);
  }

  Future<void> _finishSwipe() async {
    // Let the page finish leaving, then change branch with nothing more
    // to show: the branch underneath is already in place.
    if (!MediaQuery.disableAnimationsOf(context)) {
      try {
        await _swipe.animateTo(1, curve: Curves.easeOut).orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted) return;
    final onSwipeBack = widget.onSwipeBack;
    if (onSwipeBack == null || !_onPage) {
      _swipe.value = 0;
      return;
    }
    _switchSilently = true;
    onSwipeBack(_origin);
    // If the branch did not change (the router refused), come back.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_switchSilently) return;
      _switchSilently = false;
      _swipe.value = 0;
    });
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _previous != null) {
      setState(() => _previous = null);
    }
  }

  @override
  void didUpdateWidget(BranchCrossFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentIndex == oldWidget.currentIndex) return;
    if (widget.currentIndex == widget.slideIndex) {
      _origin = oldWidget.currentIndex;
    }
    if (_switchSilently) {
      // The back swipe already slid the page off over this branch.
      _switchSilently = false;
      _previous = null;
      _controller.value = 1.0;
      _swipe.value = 0;
      return;
    }
    _swipe.value = 0;
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
    _swipe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BranchSwipeBackScope(handle: this, child: _buildStack());
  }

  Widget _buildStack() {
    return AnimatedBuilder(
      animation: Listenable.merge([_controller, _swipe]),
      builder: (context, _) {
        final current = widget.currentIndex;
        final swipe = _swipe.value;
        if (swipe > 0 && _onPage && _origin != current) {
          // Back swipe: the page follows the finger, opaque, and the branch
          // it was opened from is painted underneath it.
          return Stack(
            fit: StackFit.expand,
            children: [
              for (var i = 0; i < widget.children.length; i++)
                _branch(
                  index: i,
                  onStage: i == current || i == _origin,
                  isCurrent: i == current,
                  opacity: 1.0,
                  dx: i == current
                      ? swipe
                      : (i == _origin
                            ? -kMotionSwipeParallax * (1.0 - swipe)
                            : 0.0),
                ),
            ],
          );
        }
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
        final upper = animating
            ? (current > previous ? current : previous)
            : -1;

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
                          ? kMotionSettingsOffset * (i == current ? 1.0 - t : t)
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
