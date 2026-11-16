import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/config/tmdb_config.dart';
import '../../../core/storage/settings_repository.dart';

part 'general_settings_provider.g.dart';

/// Which proxy, if any, GitHub downloads go through.
///
/// The design preview's GitHub Proxy choice: None, ghproxy, or a custom
/// proxy. jsDelivr is the fourth value because it is what the old on/off
/// toggle did — rewriting `raw.githubusercontent.com` to
/// `cdn.jsdelivr.net/gh` — so an upgrade from the toggle keeps its behaviour
/// under this name instead of silently changing it.
enum GithubProxyOption {
  /// Direct: no proxy.
  none,

  /// `raw.githubusercontent.com` rewritten to `cdn.jsdelivr.net/gh`
  /// (the old toggle's behaviour).
  jsdelivr,

  /// Prefixed with `https://ghproxy.com/` — the ghproxy mirror.
  ghproxy,

  /// Prefixed with the viewer's own base URL ([GeneralSettings
  /// .githubProxyCustomUrl]).
  custom,
}

class GeneralSettings {
  final bool watchHistoryEnabled;
  final String defaultHomeScreen;

  /// The GitHub proxy choice. Replaces the old on/off toggle: a stored
  /// choice of [GithubProxyOption.none] is off, anything else is on.
  final GithubProxyOption githubProxy;

  /// The base URL a Custom proxy prefixes GitHub URLs with. Empty when
  /// never set; a Custom choice with an empty URL behaves as None.
  final String githubProxyCustomUrl;

  /// Whether any proxy is in use — the old toggle's meaning, kept for the
  /// one consumer that only ever asked that.
  bool get githubProxyEnabled => githubProxy != GithubProxyOption.none;

  final bool alwaysOnTop;
  final String titlePosition;
  final String? downloadDirectory;
  final int downloadConcurrency;
  final int downloadChunks;

  /// User-supplied TMDB API key. Empty means "fall back to the build-time
  /// `--dart-define=TMDB_API_KEY` value" (which may itself be empty).
  final String tmdbApiKey;

  const GeneralSettings({
    this.watchHistoryEnabled = true,
    this.defaultHomeScreen = '/home',
    this.githubProxy = GithubProxyOption.none,
    this.githubProxyCustomUrl = '',
    this.alwaysOnTop = false,
    this.titlePosition = 'below',
    this.downloadDirectory,
    this.downloadConcurrency = 3,
    this.downloadChunks = 8,
    this.tmdbApiKey = '',
  });

  GeneralSettings copyWith({
    bool? watchHistoryEnabled,
    String? defaultHomeScreen,
    GithubProxyOption? githubProxy,
    String? githubProxyCustomUrl,
    bool? alwaysOnTop,
    String? titlePosition,
    String? downloadDirectory,
    bool clearDownloadDirectory = false,
    int? downloadConcurrency,
    int? downloadChunks,
    String? tmdbApiKey,
  }) {
    return GeneralSettings(
      watchHistoryEnabled: watchHistoryEnabled ?? this.watchHistoryEnabled,
      defaultHomeScreen: defaultHomeScreen ?? this.defaultHomeScreen,
      githubProxy: githubProxy ?? this.githubProxy,
      githubProxyCustomUrl: githubProxyCustomUrl ?? this.githubProxyCustomUrl,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      titlePosition: titlePosition ?? this.titlePosition,
      // Null means "keep" to a nullable field, so clearing the custom
      // directory back to the default needs its own flag — the same shape
      // the player settings' clearPreferredPlayer uses. Without it the
      // Reset-to-default button wrote null to storage while the screen
      // kept showing the old folder until the next launch.
      downloadDirectory: clearDownloadDirectory
          ? null
          : (downloadDirectory ?? this.downloadDirectory),
      downloadConcurrency: downloadConcurrency ?? this.downloadConcurrency,
      downloadChunks: downloadChunks ?? this.downloadChunks,
      tmdbApiKey: tmdbApiKey ?? this.tmdbApiKey,
    );
  }
}

@Riverpod(keepAlive: true)
class GeneralSettingsNotifier extends _$GeneralSettingsNotifier {
  @override
  GeneralSettings build() {
    final repository = ref.watch(settingsRepositoryProvider);
    // A stored choice wins; without one the legacy toggle decides, so an
    // upgrade from the on/off switch keeps its behaviour (on = jsDelivr).
    // An unrecognised name — written by a newer build, or a corrupted box —
    // reads as None, the safe side.
    final storedOption = repository.getGithubProxyOption();
    final githubProxy = storedOption == null
        ? (repository.isGithubProxyEnabled()
              ? GithubProxyOption.jsdelivr
              : GithubProxyOption.none)
        : GithubProxyOption.values.firstWhere(
            (e) => e.name == storedOption,
            orElse: () => GithubProxyOption.none,
          );
    return GeneralSettings(
      watchHistoryEnabled: repository.isWatchHistoryEnabled(),
      defaultHomeScreen: repository.getDefaultHomeScreen(),
      githubProxy: githubProxy,
      githubProxyCustomUrl: repository.getGithubProxyCustomUrl(),
      alwaysOnTop: repository.isAlwaysOnTop(),
      titlePosition: repository.getTitlePosition(),
      downloadDirectory: repository.getDownloadDirectory(),
      downloadConcurrency: repository.getDownloadConcurrency(),
      downloadChunks: repository.getDownloadChunks(),
      tmdbApiKey: repository.getTmdbApiKey(),
    );
  }

  Future<void> setWatchHistoryEnabled(bool enabled) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setWatchHistoryEnabled(enabled);
    state = state.copyWith(watchHistoryEnabled: enabled);
  }

  Future<void> setDefaultHomeScreen(String path) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setDefaultHomeScreen(path);
    state = state.copyWith(defaultHomeScreen: path);
  }

  /// Picks the GitHub proxy, and the custom base URL when the choice is
  /// Custom. A Custom choice with an empty URL behaves as None (see
  /// [applyGithubProxy]); the empty URL is still stored, so the field the
  /// viewer typed is not lost when they come back.
  Future<void> setGithubProxy(
    GithubProxyOption option, {
    String? customUrl,
  }) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setGithubProxyOption(option.name);
    final url = customUrl?.trim() ?? state.githubProxyCustomUrl;
    if (customUrl != null) {
      await repository.setGithubProxyCustomUrl(url);
    }
    // The legacy toggle mirrors the choice, so anything still reading it —
    // and a downgrade back to the old build — sees the same on/off.
    await repository.setGithubProxyEnabled(option != GithubProxyOption.none);
    state = state.copyWith(githubProxy: option, githubProxyCustomUrl: url);
  }

  Future<void> setGithubProxyEnabled(bool enabled) async {
    await setGithubProxy(
      enabled ? GithubProxyOption.jsdelivr : GithubProxyOption.none,
    );
  }

  Future<void> setAlwaysOnTop(bool enabled) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setAlwaysOnTop(enabled);
    state = state.copyWith(alwaysOnTop: enabled);
  }

  Future<void> setTitlePosition(String position) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setTitlePosition(position);
    state = state.copyWith(titlePosition: position);
  }

  Future<void> setDownloadDirectory(String? path) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setDownloadDirectory(path);
    state = state.copyWith(
      downloadDirectory: path,
      clearDownloadDirectory: path == null,
    );
  }

  Future<void> setDownloadConcurrency(int value) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setDownloadConcurrency(value);
    state = state.copyWith(downloadConcurrency: value);
  }

  /// Persists a user-supplied TMDB key and mirrors it into [TmdbConfig] so
  /// in-flight screens pick it up without an app restart. Passing an empty
  /// string clears the override and reverts to the build-time key.
  Future<void> setTmdbApiKey(String value) async {
    final trimmed = value.trim();
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setTmdbApiKey(trimmed);
    TmdbConfig.setUserApiKey(trimmed);
    state = state.copyWith(tmdbApiKey: trimmed);
  }

  Future<void> setDownloadChunks(int value) async {
    final repository = ref.read(settingsRepositoryProvider);
    await repository.setDownloadChunks(value);
    state = state.copyWith(downloadChunks: value);
  }
}
