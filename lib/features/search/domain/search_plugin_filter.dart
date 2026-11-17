import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_repository.dart';

/// Settings key of "Search in plugins" (v7): the ids of the sources Search
/// leaves out, as a JSON list. The ones switched OFF are what is stored, so
/// a plugin installed later is searched without anyone turning it on.
const String kSearchDisabledSourcesKey = 'search_disabled_sources';

/// How long Search waits for one plugin or add-on (v7). One that takes
/// longer is dropped from this search — the rest are already on screen —
/// and is asked again on the next one.
const Duration kSearchSourceTimeout = Duration(seconds: 20);

/// The stored list out of its JSON; empty for none or unreadable.
Set<String> decodeSearchDisabledSources(String? stored) {
  if (stored == null || stored.isEmpty) return <String>{};
  try {
    final decoded = jsonDecode(stored);
    if (decoded is! List) return <String>{};
    return {for (final id in decoded) id.toString()};
  } catch (_) {
    return <String>{};
  }
}

/// [sources] without the ones switched off in "Search in plugins".
/// [idOf] is the source's id (a provider's `packageName`).
List<T> enabledSearchSources<T>(
  Iterable<T> sources,
  Set<String> disabled,
  String Function(T source) idOf,
) => [
  for (final source in sources)
    if (!disabled.contains(idOf(source))) source,
];

/// [search] with [limit] on it: a [TimeoutException] when it takes longer,
/// after [onTimeout] (which cancels the request that is still out).
Future<T> searchWithin<T>(
  Future<T> search, {
  Duration limit = kSearchSourceTimeout,
  void Function()? onTimeout,
}) => search.timeout(
  limit,
  onTimeout: () {
    onTimeout?.call();
    throw TimeoutException('search took longer than $limit', limit);
  },
);

/// Whether the app still offers the "Search in plugins" switches. Off since
/// 1.0.1: the owner had the row removed from Settings and it has no other
/// entry point, so nobody could turn a switched-off source back on.
const bool kSearchInPluginsOffered = false;

/// What Search actually leaves out. While the switches are not offered
/// that is nothing — every installed plugin and add-on is asked, whatever
/// an older build (or a synced backup) stored. The stored value is only
/// ignored when read; nothing is rewritten.
Set<String> effectiveSearchDisabledSources(
  Set<String> stored, {
  bool offered = kSearchInPluginsOffered,
}) => offered ? stored : const <String>{};

/// The sources "Search in plugins" has switched off, by id.
class SearchDisabledSources extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    try {
      return decodeSearchDisabledSources(
        ref
            .read(settingsRepositoryProvider)
            .getPlayerSetting<String>(kSearchDisabledSourcesKey),
      );
    } catch (_) {
      return <String>{};
    }
  }

  /// Switches [id] on or off for Search, and keeps it.
  Future<void> setEnabled(String id, bool enabled) async {
    final next = {...state};
    enabled ? next.remove(id) : next.add(id);
    state = next;
    await _save();
  }

  /// Everything on again.
  Future<void> enableAll() async {
    state = <String>{};
    await _save();
  }

  Future<void> _save() async {
    try {
      await ref
          .read(settingsRepositoryProvider)
          .setPlayerSetting(
            kSearchDisabledSourcesKey,
            jsonEncode(state.toList()..sort()),
          );
    } catch (_) {
      // Kept for this session at least.
    }
  }
}

final searchDisabledSourcesProvider =
    NotifierProvider<SearchDisabledSources, Set<String>>(
      SearchDisabledSources.new,
    );
