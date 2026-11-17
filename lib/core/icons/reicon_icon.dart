import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'reicon_data.dart';

export 'reicon_data.dart';

/// The two weights Reicon ships.
enum ReiconWeight { outline, filled }

/// The weight every Settings icon is drawn in. One line to switch the
/// whole of Settings between Filled and Outline.
const ReiconWeight kSettingsIconWeight = ReiconWeight.filled;

/// The complete SVG document for [icon] in [weight].
String reiconSvg(Reicon icon, ReiconWeight weight) =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
    'fill="none">'
    '${weight == ReiconWeight.filled ? icon.filled : icon.outline}</svg>';

/// A Reicon icon in one colour.
class ReiconIcon extends StatelessWidget {
  const ReiconIcon(
    this.icon, {
    required this.color,
    this.size = 21,
    this.weight = kSettingsIconWeight,
    super.key,
  });

  final Reicon icon;
  final Color color;
  final double size;
  final ReiconWeight weight;

  @override
  Widget build(BuildContext context) => SvgPicture.string(
    reiconSvg(icon, weight),
    width: size,
    height: size,
    // The icons paint with `currentColor`.
    theme: SvgTheme(currentColor: color),
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    excludeFromSemantics: true,
  );
}
