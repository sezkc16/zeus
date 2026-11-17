import 'dart:convert';

import '../../../core/storage/settings_repository.dart';

/// Settings key of the sources sheet's "Last used" memory (v7): title URL
/// → the key of the source it last played on (see `addonSourceKey`). One
/// entry per title, so a series remembers per show, not per episode.
const String kLastUsedSourceByTitleKey = 'sources_last_used_by_title';

/// How many titles are remembered; the oldest go first.
const int kLastUsedSourceLimit = 400;

/// The remembered map out of its stored JSON; empty for none or unreadable.
Map<String, String> decodeLastUsedSources(String? stored) {
  if (stored == null || stored.isEmpty) return <String, String>{};
  try {
    final decoded = jsonDecode(stored);
    if (decoded is! Map) return <String, String>{};
    return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
  } catch (_) {
    return <String, String>{};
  }
}

/// [map] with [titleUrl] now remembering [sourceKey], as the newest entry,
/// trimmed to [limit] by dropping the oldest.
Map<String, String> withLastUsedSource(
  Map<String, String> map,
  String titleUrl,
  String sourceKey, {
  int limit = kLastUsedSourceLimit,
}) {
  final next = <String, String>{...map}..remove(titleUrl);
  next[titleUrl] = sourceKey;
  while (next.length > limit) {
    next.remove(next.keys.first);
  }
  return next;
}

/// The source key remembered for [titleUrl], or null.
String? readLastUsedSource(SettingsRepository settings, String titleUrl) {
  try {
    return decodeLastUsedSources(
      settings.getPlayerSetting<String>(kLastUsedSourceByTitleKey),
    )[titleUrl];
  } catch (_) {
    return null;
  }
}

/// Remembers [sourceKey] for [titleUrl]. A write that fails just means the
/// next sheet has no "Last used".
Future<void> rememberLastUsedSource(
  SettingsRepository settings,
  String titleUrl,
  String sourceKey,
) async {
  try {
    final map = decodeLastUsedSources(
      settings.getPlayerSetting<String>(kLastUsedSourceByTitleKey),
    );
    await settings.setPlayerSetting(
      kLastUsedSourceByTitleKey,
      jsonEncode(withLastUsedSource(map, titleUrl, sourceKey)),
    );
  } catch (_) {
    // No memory is better than a failed play.
  }
}
