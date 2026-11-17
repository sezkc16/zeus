import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Lightning that strikes behind a dialog's content (1.0.1 build 67, the
/// Select Provider dialog, approved design R3).
///
/// Nothing is drawn between strikes. Every [minGap]..[maxGap] a newly
/// generated bolt (alternating right side / left side) flashes for
/// [strikeDuration] and dies away: a jagged main channel from the top edge
/// down about three quarters of the box with thinner side branches, in
/// three layers (wide blurred glow, mid stroke, near-white core), plus a
/// soft sky-glow from the top.
///
/// One [AnimationController] drives the flash; the bolt's paths are built
/// once per strike, not per frame. The painter sits in a [RepaintBoundary]
/// and ignores pointers. The timer and ticker stop when the widget is
/// disposed and while the app is in the background. With reduced motion
/// ("disable animations") nothing is shown and nothing runs.
///
/// On a light theme the bolt is a darker blue at a lower strength, so it
/// stays a hint rather than a glare on the pale card.
class StrikingLightning extends StatefulWidget {
  const StrikingLightning({super.key, this.random});

  /// Injected by tests for a repeatable bolt.
  final math.Random? random;

  static const Duration firstDelay = Duration(milliseconds: 400);
  static const Duration strikeDuration = Duration(milliseconds: 800);
  static const Duration minGap = Duration(milliseconds: 3500);
  static const Duration maxGap = Duration(milliseconds: 6500);

  /// Key of the painter (tests).
  static const Key paintKey = ValueKey('striking-lightning-paint');

  @override
  State<StrikingLightning> createState() => _StrikingLightningState();
}

class _StrikingLightningState extends State<StrikingLightning>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: StrikingLightning.strikeDuration,
  )..addStatusListener(_onFlashStatus);
  late final math.Random _random = widget.random ?? math.Random();

  Timer? _timer;
  _Bolt? _bolt;
  Size _size = Size.zero;
  bool _rightSide = true;
  bool _reducedMotion = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion) {
      _halt();
    } else if (_timer == null && !_flash.isAnimating) {
      _schedule(StrikingLightning.firstDelay);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _halt();
    } else if (!_reducedMotion && _timer == null && !_flash.isAnimating) {
      _schedule(_nextGap());
    }
  }

  void _halt() {
    _timer?.cancel();
    _timer = null;
    _flash.stop();
    _flash.value = 0;
  }

  Duration _nextGap() {
    const min = StrikingLightning.minGap;
    const max = StrikingLightning.maxGap;
    return min +
        Duration(
          milliseconds: _random.nextInt(
            max.inMilliseconds - min.inMilliseconds + 1,
          ),
        );
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, _strike);
  }

  void _strike() {
    _timer = null;
    if (!mounted || _reducedMotion || !_foreground) return;
    if (_size.isEmpty) {
      // Not laid out yet: try again shortly.
      _schedule(const Duration(milliseconds: 200));
      return;
    }
    setState(() {
      _bolt = _Bolt.generate(_size, _random, rightSide: _rightSide);
      _rightSide = !_rightSide;
    });
    _flash.forward(from: 0);
  }

  void _onFlashStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!mounted || _reducedMotion || !_foreground) return;
    _schedule(_nextGap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_reducedMotion) return const SizedBox.shrink();
    final light = Theme.of(context).brightness == Brightness.light;
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          _size = constraints.biggest;
          return RepaintBoundary(
            child: CustomPaint(
              key: StrikingLightning.paintKey,
              size: constraints.biggest,
              painter: _LightningPainter(
                bolt: _bolt,
                flash: _flash,
                light: light,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// How bright the strike is at [t] (0..1 of the strike): a quick rise, a
/// dip, a re-strike, then the fade.
@visibleForTesting
double lightningFlashAt(double t) {
  const keys = <(double, double)>[
    (0.00, 0.00),
    (0.07, 0.95),
    (0.18, 0.20),
    (0.30, 0.80),
    (0.48, 0.35),
    (1.00, 0.00),
  ];
  if (t <= 0) return 0;
  if (t >= 1) return 0;
  for (var i = 1; i < keys.length; i++) {
    final (t1, v1) = keys[i];
    if (t <= t1) {
      final (t0, v0) = keys[i - 1];
      return v0 + (v1 - v0) * ((t - t0) / (t1 - t0));
    }
  }
  return 0;
}

/// One strike's geometry, built once.
class _Bolt {
  _Bolt(this.main, this.branches, this.top);

  final Path main;
  final Path branches;

  /// Where the bolt enters, for the sky-glow.
  final Offset top;

  static _Bolt generate(Size size, math.Random r, {required bool rightSide}) {
    final w = size.width;
    final h = size.height;
    final x0 = rightSide
        ? w * (0.62 + r.nextDouble() * 0.26)
        : w * (0.12 + r.nextDouble() * 0.26);
    final start = Offset(x0, 0);
    final end = Offset(
      (x0 + (r.nextDouble() - 0.5) * w * 0.30).clamp(w * 0.06, w * 0.94),
      h * (0.70 + r.nextDouble() * 0.08),
    );
    final channel = _displace(start, end, w * 0.11, 6, r);

    final main = Path()..moveTo(channel.first.dx, channel.first.dy);
    for (final p in channel.skip(1)) {
      main.lineTo(p.dx, p.dy);
    }

    final branches = Path();
    final count = 4 + r.nextInt(3); // 4..6
    for (var i = 0; i < count; i++) {
      // Leave the channel somewhere in its upper 80%.
      final at = (channel.length * (0.10 + r.nextDouble() * 0.70)).floor();
      final from = channel[at];
      final side = r.nextBool() ? 1.0 : -1.0;
      final length = h * (0.10 + r.nextDouble() * 0.14);
      final to = Offset(
        from.dx + side * length * (0.55 + r.nextDouble() * 0.5),
        from.dy + length * (0.55 + r.nextDouble() * 0.5),
      );
      final twig = _displace(from, to, length * 0.16, 4, r);
      branches.moveTo(twig.first.dx, twig.first.dy);
      for (final p in twig.skip(1)) {
        branches.lineTo(p.dx, p.dy);
      }
      if (r.nextDouble() < 0.5) {
        // A sub-branch off the middle of this one.
        final mid = twig[twig.length ~/ 2];
        final subLen = length * 0.5;
        final subTo = Offset(
          mid.dx - side * subLen * (0.2 + r.nextDouble() * 0.5),
          mid.dy + subLen,
        );
        final sub = _displace(mid, subTo, subLen * 0.18, 3, r);
        branches.moveTo(sub.first.dx, sub.first.dy);
        for (final p in sub.skip(1)) {
          branches.lineTo(p.dx, p.dy);
        }
      }
    }
    return _Bolt(main, branches, start);
  }

  /// Midpoint displacement: each pass splits every segment and pushes the
  /// new point sideways by up to [spread], which halves each pass.
  static List<Offset> _displace(
    Offset a,
    Offset b,
    double spread,
    int passes,
    math.Random r,
  ) {
    var points = <Offset>[a, b];
    var s = spread;
    for (var pass = 0; pass < passes; pass++) {
      final next = <Offset>[points.first];
      for (var i = 1; i < points.length; i++) {
        final p = points[i - 1];
        final q = points[i];
        final d = q - p;
        final len = d.distance;
        final normal = len == 0 ? Offset.zero : Offset(-d.dy, d.dx) / len;
        final mid = (p + q) / 2 + normal * ((r.nextDouble() - 0.5) * 2 * s);
        next
          ..add(mid)
          ..add(q);
      }
      points = next;
      s *= 0.52;
    }
    return points;
  }
}

class _LightningPainter extends CustomPainter {
  _LightningPainter({
    required this.bolt,
    required this.flash,
    required this.light,
  }) : super(repaint: flash);

  final _Bolt? bolt;
  final Animation<double> flash;
  final bool light;

  // Dark themes: the approved cyan. Light theme: a darker blue.
  static const Color _glowDark = Color(0xFF4FC8FF);
  static const Color _midDark = Color(0xFF9FE6FF);
  static const Color _coreDark = Color(0xFFF2FCFF);
  static const Color _glowLight = Color(0xFF2A8FD8);
  static const Color _midLight = Color(0xFF1E78C8);
  static const Color _coreLight = Color(0xFF0F5FA8);

  /// Overall strength on a light theme.
  static const double lightStrength = 0.45;

  @override
  void paint(Canvas canvas, Size size) {
    final bolt = this.bolt;
    if (bolt == null) return;
    var k = lightningFlashAt(flash.value);
    if (k <= 0.001) return;
    if (light) k *= lightStrength;

    final glow = light ? _glowLight : _glowDark;
    final mid = light ? _midLight : _midDark;
    final core = light ? _coreLight : _coreDark;

    // Sky-glow from the top of the card, around where the bolt enters.
    final radius = size.width * 0.9;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(bolt.top, radius, [
          glow.withValues(alpha: 0.35 * k),
          glow.withValues(alpha: 0),
        ]),
    );

    void stroke(Path path, Color color, double width, double alpha, double blur) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: (alpha * k).clamp(0.0, 1.0))
          ..maskFilter = blur > 0
              ? MaskFilter.blur(BlurStyle.normal, blur)
              : null,
      );
    }

    // Branches: thinner and dimmer than the main channel.
    stroke(bolt.branches, glow, 5, 0.35, 5);
    stroke(bolt.branches, mid, 1.6, 0.55, 0.8);
    stroke(bolt.branches, core, 0.8, 0.65, 0);
    // Main channel: wide glow, mid stroke, near-white core.
    stroke(bolt.main, glow, 11, 0.55, 9);
    stroke(bolt.main, mid, 3.2, 0.85, 1.4);
    stroke(bolt.main, core, 1.4, 1.0, 0);
  }

  @override
  bool shouldRepaint(_LightningPainter old) =>
      old.bolt != bolt || old.light != light || old.flash != flash;
}
