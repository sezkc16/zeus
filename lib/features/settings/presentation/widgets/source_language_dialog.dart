import 'package:flutter/material.dart';

import '../../../../core/utils/source_language.dart';

/// The "Preferred source language" picker (v9): Off and the languages the
/// source list can recognise. Returns the choice, or null when dismissed.
Future<SourceLanguage?> showSourceLanguageDialog(
  BuildContext context, {
  required SourceLanguage current,
}) {
  return showDialog<SourceLanguage>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return SimpleDialog(
        title: const Text('Preferred source language'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Sources that name this language are listed first. Nothing is '
              'hidden. A source that does not say its language is not guessed.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          for (final language in SourceLanguage.values)
            ListTile(
              key: ValueKey('source_language_${language.name}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              title: Text(language.label),
              trailing: language == current
                  ? Icon(Icons.check_rounded, color: scheme.primary)
                  : null,
              onTap: () => Navigator.of(context).pop(language),
            ),
        ],
      );
    },
  );
}
