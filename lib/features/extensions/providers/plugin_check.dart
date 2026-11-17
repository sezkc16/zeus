import 'dart:async';

import '../../../core/extensions/base_provider.dart';

/// What a status check found out about one installed plugin.
///
/// Every value is something the check observed. There is no "probably fine":
/// a plugin that was not asked is simply absent from the results.
enum PluginCheckStatus {
  /// Answered in time with at least one item.
  working,

  /// Answered with at least one item, but took longer than the slow limit.
  slow,

  /// Answered, with nothing in the answer.
  empty,

  /// Threw, or did not answer before the time limit.
  notResponding,

  /// The plugin's file never loaded on this device, so it was not called.
  couldNotLoad,

  /// The plugin offers no source the check could call (a helper plugin, or
  /// its sources are switched off).
  noSource,
}

/// How bad a status is, for picking the one a plugin with several sources
/// shows: the worst of them, so a dead source is never hidden by a live one.
int _severity(PluginCheckStatus s) => switch (s) {
  PluginCheckStatus.working => 0,
  PluginCheckStatus.slow => 1,
  PluginCheckStatus.empty => 2,
  PluginCheckStatus.notResponding => 3,
  PluginCheckStatus.couldNotLoad => 4,
  PluginCheckStatus.noSource => 4,
};

/// The outcome of asking one source (one runtime provider) of a plugin.
class ProviderProbeResult {
  const ProviderProbeResult({
    required this.providerName,
    required this.status,
    required this.elapsed,
    required this.itemCount,
    required this.usedSearch,
    this.timedOut = false,
    this.error,
  });

  final String providerName;
  final PluginCheckStatus status;
  final Duration elapsed;

  /// Items in the answer that decided the status.
  final int itemCount;

  /// Whether the answer came from the search fallback instead of the main
  /// page.
  final bool usedSearch;

  /// True when [status] is notResponding because the time limit passed.
  final bool timedOut;

  /// The short reason, in the plugin's own words, when it threw.
  final String? error;
}

/// The outcome for one plugin: its status, and what each of its sources did.
class PluginCheckResult {
  const PluginCheckResult({
    required this.status,
    required this.checkedAt,
    this.probes = const [],
    this.error,
  });

  final PluginCheckStatus status;
  final DateTime checkedAt;
  final List<ProviderProbeResult> probes;

  /// The load error ([PluginCheckStatus.couldNotLoad]) or the first probe's
  /// failure reason.
  final String? error;

  /// Sources that answered with items (working or slow).
  int get okCount => probes
      .where(
        (p) =>
            p.status == PluginCheckStatus.working ||
            p.status == PluginCheckStatus.slow,
      )
      .length;

  Duration get elapsed =>
      probes.fold(Duration.zero, (sum, p) => sum + p.elapsed);
}

/// One plugin to check: its key, name, and the runtime providers it added.
class PluginCheckTarget {
  const PluginCheckTarget({
    required this.key,
    required this.name,
    this.loadError,
    this.providers = const [],
  });

  final String key;
  final String name;
  final String? loadError;
  final List<SkyStreamProvider> providers;
}

/// The limits and the neutral search word of a check.
class PluginCheckConfig {
  const PluginCheckConfig({
    this.timeout = const Duration(seconds: 20),
    this.slowAfter = const Duration(seconds: 8),
    this.searchQuery = 'one',
  });

  /// Longest one source may take before it counts as not responding.
  final Duration timeout;

  /// An answer slower than this counts as slow.
  final Duration slowAfter;

  /// The word searched for when a source has no main page.
  final String searchQuery;
}

String _shortError(Object error) {
  final text = '$error'
      .replaceFirst(
        RegExp(r'^(Exception|FormatException|Bad state|TimeoutException): '),
        '',
      )
      .trim();
  return text.length > 300 ? '${text.substring(0, 300)}…' : text;
}

/// Asks one [provider] for its main page and, when that has no items (a
/// source without a main page answers with nothing), for a search of the
/// neutral word. The whole probe shares one time limit.
Future<ProviderProbeResult> probeProvider(
  SkyStreamProvider provider, {
  PluginCheckConfig config = const PluginCheckConfig(),
  String Function(Object error) describeError = _shortError,
}) async {
  final watch = Stopwatch()..start();
  var usedSearch = false;
  try {
    final home = await provider.getHome().timeout(config.timeout);
    var count = home.values.fold<int>(0, (sum, row) => sum + row.length);
    if (count == 0 && provider.hasSearch) {
      final left = config.timeout - watch.elapsed;
      if (left <= Duration.zero) throw TimeoutException(null);
      usedSearch = true;
      final found = await provider.search(config.searchQuery).timeout(left);
      count = found.length;
    }
    watch.stop();
    return ProviderProbeResult(
      providerName: provider.name,
      status: count == 0
          ? PluginCheckStatus.empty
          : (watch.elapsed > config.slowAfter
                ? PluginCheckStatus.slow
                : PluginCheckStatus.working),
      elapsed: watch.elapsed,
      itemCount: count,
      usedSearch: usedSearch,
    );
  } on TimeoutException {
    watch.stop();
    return ProviderProbeResult(
      providerName: provider.name,
      status: PluginCheckStatus.notResponding,
      elapsed: watch.elapsed,
      itemCount: 0,
      usedSearch: usedSearch,
      timedOut: true,
    );
  } catch (error) {
    watch.stop();
    return ProviderProbeResult(
      providerName: provider.name,
      status: PluginCheckStatus.notResponding,
      elapsed: watch.elapsed,
      itemCount: 0,
      usedSearch: usedSearch,
      error: describeError(error),
    );
  }
}

/// Checks one plugin: its sources one after another. A plugin that never
/// loaded is reported without being called.
Future<PluginCheckResult> checkPlugin(
  PluginCheckTarget target, {
  PluginCheckConfig config = const PluginCheckConfig(),
  String Function(Object error) describeError = _shortError,
  DateTime Function() now = DateTime.now,
}) async {
  if (target.loadError != null) {
    return PluginCheckResult(
      status: PluginCheckStatus.couldNotLoad,
      checkedAt: now(),
      error: target.loadError,
    );
  }
  if (target.providers.isEmpty) {
    return PluginCheckResult(
      status: PluginCheckStatus.noSource,
      checkedAt: now(),
    );
  }
  final probes = <ProviderProbeResult>[];
  for (final provider in target.providers) {
    probes.add(
      await probeProvider(
        provider,
        config: config,
        describeError: describeError,
      ),
    );
  }
  var worst = probes.first;
  for (final p in probes) {
    if (_severity(p.status) > _severity(worst.status)) worst = p;
  }
  return PluginCheckResult(
    status: worst.status,
    checkedAt: now(),
    probes: probes,
    error: probes.where((p) => p.error != null).firstOrNull?.error,
  );
}

/// Checks [targets] strictly one at a time, in order.
///
/// [onStart] fires before a plugin is asked and [onResult] after it answered.
/// When [cancelled] completes the run stops at once: the plugin being asked
/// gets no result (its call is abandoned, not reported), and nothing after
/// it is started. Returns true when every target was checked.
Future<bool> runPluginChecks(
  List<PluginCheckTarget> targets, {
  required void Function(String key) onStart,
  required void Function(String key, PluginCheckResult result) onResult,
  Future<void>? cancelled,
  PluginCheckConfig config = const PluginCheckConfig(),
  String Function(Object error) describeError = _shortError,
  DateTime Function() now = DateTime.now,
}) async {
  var stop = false;
  final stopSignal = cancelled?.then((_) {
    stop = true;
  });
  for (final target in targets) {
    if (stop) return false;
    onStart(target.key);
    final check = checkPlugin(
      target,
      config: config,
      describeError: describeError,
      now: now,
    );
    final result = stopSignal == null
        ? await check
        : await Future.any<PluginCheckResult?>([
            check,
            stopSignal.then<PluginCheckResult?>((_) => null),
          ]);
    if (stop || result == null) return false;
    onResult(target.key, result);
  }
  return true;
}
