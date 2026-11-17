import 'dart:convert';

/// The row id of Continue Watching in a Home row order. Plugin rows are
/// identified by their own name; this one is not a plugin row, so it gets
/// an id no plugin row would use.
const String kHomeRowContinueWatching = '__continue_watching__';

/// The source key of the key-free feed (no provider selected, or the feed
/// Home fell back to when a plugin's home page failed).
const String kHomeRowsKeyFreeSource = '__key_free_feed__';

/// The key Home row preferences are saved under for what Home is showing:
/// the active provider's package name, or the key-free feed's fixed key
/// when there is no provider or Home fell back to that feed.
String homeRowsSourceKey(String? activePackageName, {bool fellBack = false}) =>
    activePackageName == null || fellBack
    ? kHomeRowsKeyFreeSource
    : activePackageName;

/// The saved order and hidden rows of one source's Home.
class HomeRowPrefs {
  const HomeRowPrefs({this.order = const [], this.hidden = const {}});

  /// Row ids in the order the user arranged them. Rows not in it are new to
  /// the user and go after it.
  final List<String> order;

  /// Row ids the user switched off.
  final Set<String> hidden;

  bool get isDefault => order.isEmpty && hidden.isEmpty;

  Map<String, dynamic> toJson() => {
    'order': order,
    'hidden': hidden.toList(),
  };

  static HomeRowPrefs fromJson(Object? json) {
    if (json is! Map) return const HomeRowPrefs();
    List<String> strings(Object? v) => [
      if (v is List)
        for (final e in v)
          if (e is String) e,
    ];
    return HomeRowPrefs(
      order: strings(json['order']),
      hidden: strings(json['hidden']).toSet(),
    );
  }
}

/// [rows] in the user's order, hidden ones included: the saved order first
/// (only the rows that exist now), then every row the saved order does not
/// know, in the order the source gave them. With nothing saved this is
/// [rows] unchanged.
List<String> orderHomeRows(List<String> rows, HomeRowPrefs? prefs) {
  if (prefs == null || prefs.order.isEmpty) return List.of(rows);
  final present = rows.toSet();
  final seen = <String>{};
  final ordered = <String>[
    for (final id in prefs.order)
      if (present.contains(id) && seen.add(id)) id,
  ];
  for (final id in rows) {
    if (seen.add(id)) ordered.add(id);
  }
  return ordered;
}

/// The rows Home draws, in order: [orderHomeRows] without the hidden ones.
/// May be empty (every row hidden) - Home then shows its hero only.
List<String> applyHomeRowPrefs(List<String> rows, HomeRowPrefs? prefs) {
  final ordered = orderHomeRows(rows, prefs);
  if (prefs == null || prefs.hidden.isEmpty) return ordered;
  return [
    for (final id in ordered)
      if (!prefs.hidden.contains(id)) id,
  ];
}

/// The rows the customise screen lists: the rows Home has now, plus rows the
/// saved order remembers that are not loaded at the moment (still loading,
/// or the source left them out this time), so they keep their place.
List<String> knownHomeRows(List<String> current, HomeRowPrefs? prefs) {
  final rows = <String>[kHomeRowContinueWatching];
  final seen = <String>{kHomeRowContinueWatching};
  for (final id in current) {
    if (seen.add(id)) rows.add(id);
  }
  for (final id in prefs?.order ?? const <String>[]) {
    if (seen.add(id)) rows.add(id);
  }
  return orderHomeRows(rows, prefs);
}

Map<String, HomeRowPrefs> decodeHomeRowPrefs(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    return {
      for (final entry in decoded.entries)
        if (entry.key is String)
          entry.key as String: HomeRowPrefs.fromJson(entry.value),
    };
  } catch (_) {
    return {};
  }
}

String? encodeHomeRowPrefs(Map<String, HomeRowPrefs> prefs) {
  final kept = {
    for (final entry in prefs.entries)
      if (!entry.value.isDefault) entry.key: entry.value.toJson(),
  };
  return kept.isEmpty ? null : jsonEncode(kept);
}
