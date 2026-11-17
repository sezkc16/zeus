import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cloudstream/cloudstream_provider.dart';
import '../../../core/cloudstream/cloudstream_repository.dart';
import '../../../core/extensions/extension_manager.dart';
import 'plugin_check.dart';

/// The Installed segment's plugin status check: what the last run found, by
/// plugin key ([CloudStreamRepository.keyOf]), and whether one is running.
///
/// Kept in memory only, until the next check replaces it.
class PluginCheckState {
  const PluginCheckState({
    this.results = const {},
    this.running = false,
    this.runningKey,
    this.total = 0,
    this.finishedAt,
    this.wasCancelled = false,
  });

  final Map<String, PluginCheckResult> results;
  final bool running;

  /// The plugin being asked right now.
  final String? runningKey;

  /// Plugins in the current (or last) run.
  final int total;

  /// When the last run ended (finished or stopped); null before any run.
  final DateTime? finishedAt;

  /// Whether the last run was stopped before every plugin was checked.
  final bool wasCancelled;

  PluginCheckState copyWith({
    Map<String, PluginCheckResult>? results,
    bool? running,
    String? runningKey,
    bool clearRunningKey = false,
    int? total,
    DateTime? finishedAt,
    bool clearFinishedAt = false,
    bool? wasCancelled,
  }) => PluginCheckState(
    results: results ?? this.results,
    running: running ?? this.running,
    runningKey: clearRunningKey ? null : (runningKey ?? this.runningKey),
    total: total ?? this.total,
    finishedAt: clearFinishedAt ? null : (finishedAt ?? this.finishedAt),
    wasCancelled: wasCancelled ?? this.wasCancelled,
  );
}

/// The plugins a check asks: the installed .cs3 plugins, each with the
/// runtime providers it added to the provider list. Overridable in tests.
final pluginCheckTargetsProvider = Provider<List<PluginCheckTarget>>((ref) {
  final installed = ref.watch(
    cloudStreamRepositoryProvider.select((s) => s.installed),
  );
  final providers = ref.watch(extensionManagerProvider);
  return [
    for (final plugin in installed)
      PluginCheckTarget(
        key: CloudStreamRepository.keyOf(plugin.info),
        name: plugin.info.name,
        loadError: plugin.loadError,
        providers: [
          for (final p in providers)
            if (p is CloudStreamProvider &&
                p.pluginKey == CloudStreamRepository.keyOf(plugin.info))
              p,
        ],
      ),
  ];
});

/// The limits of a check. Overridable in tests.
final pluginCheckConfigProvider = Provider<PluginCheckConfig>(
  (ref) => const PluginCheckConfig(),
);

final pluginCheckProvider =
    NotifierProvider<PluginCheckNotifier, PluginCheckState>(
      PluginCheckNotifier.new,
    );

class PluginCheckNotifier extends Notifier<PluginCheckState> {
  Completer<void>? _cancel;

  @override
  PluginCheckState build() {
    ref.onDispose(() {
      final cancel = _cancel;
      if (cancel != null && !cancel.isCompleted) cancel.complete();
    });
    return const PluginCheckState();
  }

  /// Checks every installed plugin, one at a time. Does nothing while a
  /// check is already running.
  Future<void> start() async {
    if (state.running) return;
    final targets = ref.read(pluginCheckTargetsProvider);
    final config = ref.read(pluginCheckConfigProvider);
    final cancel = Completer<void>();
    _cancel = cancel;
    state = PluginCheckState(running: true, total: targets.length);
    final finished = await runPluginChecks(
      targets,
      cancelled: cancel.future,
      config: config,
      describeError: (e) {
        final text = CloudStreamRepository.errorMessage(e).trim();
        return text.length > 300 ? '${text.substring(0, 300)}…' : text;
      },
      onStart: (key) {
        if (!ref.mounted) return;
        state = state.copyWith(runningKey: key);
      },
      onResult: (key, result) {
        if (!ref.mounted) return;
        state = state.copyWith(results: {...state.results, key: result});
      },
    );
    if (!ref.mounted) return;
    if (identical(_cancel, cancel)) _cancel = null;
    state = state.copyWith(
      running: false,
      clearRunningKey: true,
      finishedAt: DateTime.now(),
      wasCancelled: !finished,
    );
  }

  /// Stops the running check. Results already in stay.
  void cancel() {
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }
}
