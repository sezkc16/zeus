import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/utils/motion.dart';
import 'branch_cross_fade.dart';

/// The iOS swipe-from-the-left-edge back gesture for a screen that is NOT a
/// pushed page and so has nothing for the system gesture to pop — the
/// Settings root, which is a shell branch reached from the Home gear.
///
/// Edge only: the drag must start within [edgeWidth] of the left edge, so
/// it never competes with horizontal scrollers. The screen follows the
/// finger; let go past a third of the width (or with a flick) and [onBack]
/// runs, otherwise it slides back. iOS only — Android has its system back.
class EdgeSwipeBack extends StatefulWidget {
  const EdgeSwipeBack({
    super.key,
    required this.onBack,
    required this.child,
    this.edgeWidth = 24,
    this.enabled,
  });

  final VoidCallback onBack;
  final Widget child;
  final double edgeWidth;

  /// Defaults to "on iOS".
  final bool? enabled;

  @override
  State<EdgeSwipeBack> createState() => _EdgeSwipeBackState();
}

class _EdgeSwipeBackState extends State<EdgeSwipeBack>
    with SingleTickerProviderStateMixin {
  /// 0 = at rest, 1 = dragged a full width to the right.
  late final AnimationController _drag = AnimationController(
    vsync: this,
    duration: kMotionPage,
  );

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  void _onUpdate(DragUpdateDetails details, double width) {
    _drag.value += (details.primaryDelta ?? 0) / width;
  }

  Future<void> _onEnd(DragEndDetails details) async {
    final flick = (details.primaryVelocity ?? 0) > 700;
    if (flick || _drag.value > 1 / 3) {
      widget.onBack();
      // The branch changes under us; be back at rest for the next visit.
      _drag.value = 0;
    } else {
      await _drag.animateBack(0, curve: kMotionPageCurve);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled =
        widget.enabled ?? defaultTargetPlatform == TargetPlatform.iOS;
    if (!enabled) return widget.child;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    if (rtl) return widget.child;
    // Inside the shell the branch container does the moving, so the tab
    // this screen was opened from shows underneath instead of nothing.
    final shell = BranchSwipeBackScope.maybeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (shell != null) {
          return Stack(
            children: [
              widget.child,
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: widget.edgeWidth,
                child: GestureDetector(
                  key: const ValueKey('edge-swipe-back-strip'),
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (d) =>
                      shell.dragBy((d.primaryDelta ?? 0) / width),
                  onHorizontalDragEnd: (d) =>
                      shell.dragEnd(d.primaryVelocity ?? 0),
                  onHorizontalDragCancel: shell.dragCancel,
                ),
              ),
            ],
          );
        }
        return Stack(
          children: [
            AnimatedBuilder(
              animation: _drag,
              builder: (context, child) => Transform.translate(
                offset: Offset(_drag.value * width, 0),
                child: child,
              ),
              child: widget.child,
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: widget.edgeWidth,
              child: GestureDetector(
                key: const ValueKey('edge-swipe-back-strip'),
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: (d) => _onUpdate(d, width),
                onHorizontalDragEnd: _onEnd,
                onHorizontalDragCancel: () =>
                    _drag.animateBack(0, curve: kMotionPageCurve),
              ),
            ),
          ],
        );
      },
    );
  }
}
