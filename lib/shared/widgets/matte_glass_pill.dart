import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Softly diffused glass with fine matte grain and crisp foreground content.
class MatteGlassPill extends StatelessWidget {
  const MatteGlassPill({
    super.key,
    required this.child,
    this.surfaceColor = surface,
    this.blendMode = BlendMode.srcOver,
  });

  final Widget child;
  final Color surfaceColor;
  final BlendMode blendMode;

  static const surface = Color(0x38181C20);

  // Keep most of the scene's colour and brightness beneath the diffusion.
  // A light tint and fine grain soften the glass without hiding it.
  static final ui.ImageFilter _filter = ui.ImageFilter.compose(
    outer: const ColorFilter.matrix(<double>[
      0.724,
      0.250,
      0.026,
      0,
      0,
      0.074,
      0.900,
      0.026,
      0,
      0,
      0.074,
      0.250,
      0.676,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]),
    inner: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
  );

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      // Grouped: under a [BackdropGroup], pills side by side share one read
      // of what is behind them.
      child: BackdropFilter.grouped(
        filter: _filter,
        blendMode: blendMode,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(999),
          ),
          child: CustomPaint(
            painter: const _MatteGrain(),
            child: Padding(padding: const EdgeInsets.all(3), child: child),
          ),
        ),
      ),
    );
  }
}

/// Frosted-glass card: the same material as [MatteGlassPill] — the
/// composed colour-matrix + blur-18 filter over the scene, the
/// 0.22-alpha dark surface, fine matte grain — with a rectangular
/// shape and a thin light border, for small floating panels such as
/// the profile dropdown. Unlike the 0.78–0.9-alpha "glass-dialog
/// shell" ([UnifiedFilterDialog] and the build-116 switcher), this is
/// genuinely translucent: the blurred scene shows through it.
class MatteGlassCard extends StatelessWidget {
  const MatteGlassCard({
    super.key,
    required this.child,
    this.borderRadius = 20,
    this.surfaceColor = MatteGlassPill.surface,
  });

  final Widget child;
  final double borderRadius;
  final Color surfaceColor;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: MatteGlassPill._filter,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.22),
              width: 1,
            ),
          ),
          child: CustomPaint(
            painter: const _MatteGrain(),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Fixed fine grain: two batched draws, no animation or additional filter.
class _MatteGrain extends CustomPainter {
  const _MatteGrain();

  /// The grain's points for the sizes painted lately. They depend on the size
  /// alone, and a pill repaints with every frame of the bar's fade; a handful
  /// of sizes covers every pill on screen, and a resize moves through new ones.
  static final Map<Size, (List<Offset>, List<Offset>)> _recent = {};

  static (List<Offset>, List<Offset>) _pointsFor(Size size) {
    final cached = _recent.remove(size);
    final points = cached ?? _scatter(size);
    _recent[size] = points;
    if (_recent.length > 8) _recent.remove(_recent.keys.first);
    return points;
  }

  static (List<Offset>, List<Offset>) _scatter(Size size) {
    final light = <Offset>[];
    final dark = <Offset>[];
    for (int y = 0; y < size.height.ceil(); y += 3) {
      for (int x = 0; x < size.width.ceil(); x += 3) {
        final hash = ((x * 73856093) ^ (y * 19349663)) & 255;
        final point = Offset(x + (hash & 3) * 0.5, y + (hash >> 2 & 3) * 0.5);
        (hash.isEven ? light : dark).add(point);
      }
    }
    return (light, dark);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final (light, dark) = _pointsFor(size);
    canvas.drawPoints(
      ui.PointMode.points,
      light,
      Paint()
        ..color = const Color(0x06FFFFFF)
        ..strokeWidth = 0.6,
    );
    canvas.drawPoints(
      ui.PointMode.points,
      dark,
      Paint()
        ..color = const Color(0x06000000)
        ..strokeWidth = 0.6,
    );
  }

  @override
  bool shouldRepaint(_MatteGrain oldDelegate) => false;
}
