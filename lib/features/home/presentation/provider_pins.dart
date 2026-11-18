import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/base_provider.dart';
import '../../../core/storage/storage_service.dart';

/// Where the pinned providers are kept: on this device only (the settings
/// box), never synced. A seam so tests need no Hive box.
class ProviderPinsStore {
  const ProviderPinsStore({required this.read, required this.write});

  /// The pinned providers' package names, in the order they were pinned.
  final List<String> Function() read;
  final Future<void> Function(List<String> packageNames) write;
}

final providerPinsStoreProvider = Provider<ProviderPinsStore>((ref) {
  final storage = ref.watch(storageServiceProvider);
  return ProviderPinsStore(
    read: storage.getPinnedProviders,
    write: storage.setPinnedProviders,
  );
});

/// The most pins kept. Pins of plugins that are no longer installed are
/// not shown anywhere; this only stops the stored list growing for ever.
const int kMaxProviderPins = 200;

/// The providers pinned in the Select Provider dialog (v2): package names
/// in the order they were pinned. A store that cannot be read means "no
/// pins" — the pins must never break the provider picker.
class ProviderPins extends Notifier<List<String>> {
  @override
  List<String> build() {
    try {
      return List<String>.unmodifiable(
        ref.watch(providerPinsStoreProvider).read(),
      );
    } catch (_) {
      return const <String>[];
    }
  }

  /// Pins [packageName] (last in the pin order), or unpins it.
  Future<void> toggle(String packageName) async {
    final next = togglePin(state, packageName);
    state = next;
    try {
      await ref.read(providerPinsStoreProvider).write(next);
    } catch (_) {
      // Kept for this session only.
    }
  }
}

final providerPinsProvider = NotifierProvider<ProviderPins, List<String>>(
  ProviderPins.new,
);

/// [pins] with [packageName] removed if it was there, else added at the
/// end (oldest pins dropped past [kMaxProviderPins]). Pure.
List<String> togglePin(List<String> pins, String packageName) {
  if (pins.contains(packageName)) {
    return List<String>.unmodifiable(pins.where((p) => p != packageName));
  }
  final next = <String>[...pins, packageName];
  return List<String>.unmodifiable(
    next.length > kMaxProviderPins
        ? next.sublist(next.length - kMaxProviderPins)
        : next,
  );
}

/// [providers] with the pinned ones first, in the order they were pinned,
/// then the rest in the order they came in. A pin whose provider is not
/// in [providers] (plugin removed or disabled) is ignored. Pure.
List<T> orderProvidersWithPins<T extends SkyStreamProvider>(
  List<T> providers,
  List<String> pins,
) {
  if (pins.isEmpty) return providers;
  final byPackage = <String, T>{for (final p in providers) p.packageName: p};
  final pinned = <T>[];
  final seen = <String>{};
  for (final pin in pins) {
    final provider = byPackage[pin];
    if (provider != null && seen.add(pin)) pinned.add(provider);
  }
  if (pinned.isEmpty) return providers;
  return <T>[
    ...pinned,
    for (final p in providers)
      if (!seen.contains(p.packageName)) p,
  ];
}
