import 'package:flutter/material.dart';

import '../data/zeus_profile.dart';

/// A profile's avatar tile: a rounded square in the profile's palette
/// colour with the big initial letter, the way Netflix draws its
/// profiles. No image assets.
class ZeusProfileAvatar extends StatelessWidget {
  const ZeusProfileAvatar({
    required this.profile,
    this.size = 76,
    this.fontSize,
    super.key,
  });

  final ZeusProfile profile;
  final double size;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    final color = zeusProfileColor(profile.color);
    final initial = profile.name.isEmpty
        ? '?'
        : profile.name.trim()[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize ?? size * 0.44,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
