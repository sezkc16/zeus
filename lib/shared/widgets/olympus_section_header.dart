/// Olympus Noir section header — a gold vertical bar beside a
/// letterspaced uppercase title, optionally with a trailing action.
///
/// Used by the Home rows (Trending Tonight, Popular, Latest, TV Shows),
/// Continue Watching and the Settings theme/accent sections, so every
/// section heading in the Olympus Noir design speaks the same language.
/// The gold is the fixed Olympus gold, not the user's accent, so the
/// headings match the approved mockup whichever accent is picked.
library;

import 'package:flutter/material.dart';
import 'package:zorox/core/theme/olympus.dart';

class OlympusSectionHeader extends StatelessWidget {
  const OlympusSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(16, 20, 16, 8),
  });

  /// Section title — rendered uppercase, letterspaced, bold.
  final String title;

  /// Optional trailing widget (Clear All button, View All chip, ...).
  final Widget? trailing;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 3,
            height: 18,
            decoration: BoxDecoration(
              color: kOlympusGold,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}
