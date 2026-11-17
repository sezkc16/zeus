import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/cast_photo_service.dart';

/// Up to two letters for a person with no photo: "Matt Damon" → "MD".
String castInitials(String name) {
  final words = [
    for (final w in name.trim().split(RegExp(r'\s+')))
      if (w.isNotEmpty) w,
  ];
  if (words.isEmpty) return '?';
  if (words.length == 1) {
    final w = words.first;
    return (w.length >= 2 ? w.substring(0, 2) : w).toUpperCase();
  }
  return (words.first[0] + words.last[0]).toUpperCase();
}

/// A cast member's round picture: their photo, or their initials on an
/// accent-tinted circle - never a broken-image icon, never the name again.
class CastAvatar extends StatelessWidget {
  const CastAvatar({
    super.key,
    required this.name,
    required this.size,
    this.photoUrl,
    this.lookup = false,
  });

  final String name;
  final double size;

  /// The photo the title's own data sent, if any.
  final String? photoUrl;

  /// With no [photoUrl], look one up by name.
  final bool lookup;

  @override
  Widget build(BuildContext context) {
    final own = photoUrl;
    if (own != null && own.startsWith('http')) return _photo(context, own);
    if (!lookup) return _initials(context);
    return Consumer(
      builder: (context, ref, _) {
        final found = ref.watch(castPhotoProvider(name)).asData?.value;
        return found == null ? _initials(context) : _photo(context, found);
      },
    );
  }

  Widget _photo(BuildContext context, String url) => ClipOval(
    child: CachedNetworkImage(
      key: const ValueKey('cast-photo'),
      imageUrl: url,
      width: size,
      height: size,
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      placeholder: (context, _) => _initials(context),
      errorWidget: (context, _, _) => _initials(context),
    ),
  );

  Widget _initials(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('cast-initials'),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Color.alphaBlend(
          colors.primary.withValues(alpha: 0.22),
          colors.surfaceContainerHighest,
        ),
      ),
      child: Text(
        castInitials(name),
        style: TextStyle(
          color: colors.primary,
          fontSize: size * 0.34,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
