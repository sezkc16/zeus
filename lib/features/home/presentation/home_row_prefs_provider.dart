import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_repository.dart';
import 'home_row_prefs.dart';

/// Every source's saved Home row order and hidden rows, by source key
/// ([homeRowsSourceKey]). Persisted through the settings repository.
final homeRowPrefsProvider =
    NotifierProvider<HomeRowPrefsNotifier, Map<String, HomeRowPrefs>>(
      HomeRowPrefsNotifier.new,
    );

class HomeRowPrefsNotifier extends Notifier<Map<String, HomeRowPrefs>> {
  @override
  Map<String, HomeRowPrefs> build() => decodeHomeRowPrefs(
    ref.watch(settingsRepositoryProvider).getHomeRowPrefsJson(),
  );

  Future<void> _save(Map<String, HomeRowPrefs> next) async {
    state = next;
    await ref
        .read(settingsRepositoryProvider)
        .setHomeRowPrefsJson(encodeHomeRowPrefs(next));
  }

  /// Saves [order] (every row the screen lists, hidden ones too) for
  /// [sourceKey].
  Future<void> setOrder(String sourceKey, List<String> order) => _save({
    ...state,
    sourceKey: HomeRowPrefs(
      order: List.unmodifiable(order),
      hidden: state[sourceKey]?.hidden ?? const {},
    ),
  });

  /// Shows or hides [rowId] on [sourceKey]'s Home.
  Future<void> setHidden(String sourceKey, String rowId, bool hidden) {
    final current = state[sourceKey] ?? const HomeRowPrefs();
    final next = {...current.hidden};
    if (hidden) {
      next.add(rowId);
    } else {
      next.remove(rowId);
    }
    return _save({
      ...state,
      sourceKey: HomeRowPrefs(order: current.order, hidden: next),
    });
  }

  /// Back to the source's own order with every row shown.
  Future<void> reset(String sourceKey) =>
      _save({...state}..remove(sourceKey));
}
