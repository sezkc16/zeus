import '../../../core/domain/entity/multimedia_item.dart';

/// One ZoroX backup: everything an account (or a backup file) carries
/// across an uninstall/reinstall.
///
/// Format version 1. The `format` marker is what the Worker checks before
/// it stores an upload, and what import checks before it restores a file,
/// so a random JSON file can never be mistaken for a backup.
///
/// History entries are the raw maps from the history box, each with its box
/// key (`{'key': ..., 'entry': {...}}`) — including the per-episode `EP_`
/// entries — so a restore keeps the original timestamps and per-episode
/// positions instead of stamping everything with "now".
///
/// Plugins are backed up as identities, not files: a repository URL plus a
/// plugin's package name (ZoroX) or internal name (CloudStream). On
/// restore the app re-adds the repository and re-installs the plugin from
/// it, so the restored plugins are the current versions, not stale files.
///
/// v9 adds, without changing the format version: Stremio add-ons and
/// Nuvio repositories (identities again — a manifest URL, re-installed on
/// restore), and the app's settings from an explicit allow-list (see
/// `zorox_settings_sync.dart`). The top-level `version` deliberately stays
/// 1: the v8 app refuses any other version and, on login, would then
/// upload its own backup over the newer one. The additions are marked by
/// [schema] instead. An older app reading a v9 backup simply ignores the
/// fields it does not know; this app reading an older backup finds the
/// new sections empty and leaves add-ons and settings alone.
class ZoroxBackup {
  static const String format = 'zorox-backup';
  static const int currentVersion = 1;

  /// The additive revision of the format: 1 = history, library, plugins
  /// (v8 and before); 2 = + add-ons, Nuvio, settings (v9).
  static const int currentSchema = 2;

  const ZoroxBackup({
    this.version = currentVersion,
    required this.exportedAt,
    this.history = const [],
    this.library = const [],
    this.zoroxRepos = const [],
    this.zoroxPlugins = const [],
    this.cloudstreamRepos = const [],
    this.cloudstreamPlugins = const [],
    this.schema = currentSchema,
    this.stremioAddons = const [],
    this.nuvioRepos = const [],
    this.nuvioEnabled,
    this.settings,
    this.settingsUpdatedAt = 0,
    this.addonsSkippedForSecrets = 0,
  });

  final int version;

  /// See [currentSchema]. 1 for a backup made before v9.
  final int schema;

  /// Installed Stremio add-ons, in the user's order:
  /// `{'url': manifestUrl, 'enabled': bool}`. Add-ons whose URL carries a
  /// credential are never in here (see `addonUrlCarriesSecret`).
  final List<Map<String, dynamic>> stremioAddons;

  /// Nuvio repositories: `{'url': manifestUrl, 'disabled': [scraperId],
  /// 'enabledOverrides': [scraperId]}`. Scraper settings and the Nuvio
  /// TMDB key are never included.
  final List<Map<String, dynamic>> nuvioRepos;

  /// Nuvio's master switch; null when the backup does not say.
  final bool? nuvioEnabled;

  /// The allow-listed app settings (`key → plain value`); null when the
  /// backup carries no settings at all (made before v9), which restores
  /// nothing — different from an empty map, which is "all defaults".
  final Map<String, dynamic>? settings;

  /// Unix milliseconds of the last change to a synced setting on the
  /// device that made the backup; 0 when unknown.
  final int settingsUpdatedAt;

  /// How many add-ons were left out because their URL carries a
  /// credential. Informational.
  final int addonsSkippedForSecrets;

  /// Unix milliseconds when the backup was made.
  final int exportedAt;

  /// Raw history entries: `{'key': String, 'entry': Map}`.
  final List<Map<String, dynamic>> history;

  /// Library items as [MultimediaItem.toJson] maps.
  final List<Map<String, dynamic>> library;

  /// ZoroX repository URLs (SharedPreferences `extension_repo_urls`).
  final List<String> zoroxRepos;

  /// Installed ZoroX plugins: `{'packageName', 'repositoryUrl'}`.
  final List<Map<String, String>> zoroxPlugins;

  /// CloudStream repository URLs.
  final List<String> cloudstreamRepos;

  /// Installed CloudStream plugins:
  /// `{'internalName', 'name', 'url', 'repositoryUrl'}`.
  final List<Map<String, String>> cloudstreamPlugins;

  Map<String, dynamic> toJson() => {
    'format': format,
    'version': version,
    'exportedAt': exportedAt,
    'history': history,
    'library': library,
    'zoroxRepos': zoroxRepos,
    'zoroxPlugins': zoroxPlugins,
    'cloudstreamRepos': cloudstreamRepos,
    'cloudstreamPlugins': cloudstreamPlugins,
    'schema': schema,
    'stremioAddons': stremioAddons,
    'nuvioRepos': nuvioRepos,
    'nuvioEnabled': ?nuvioEnabled,
    'settings': ?settings,
    'settingsUpdatedAt': settingsUpdatedAt,
    'addonsSkippedForSecrets': addonsSkippedForSecrets,
  };

  factory ZoroxBackup.fromJson(Map<String, dynamic> json) {
    if (json['format'] != format) {
      throw const FormatException('That file is not a Zeus backup.');
    }
    final version = (json['version'] as num?)?.toInt() ?? 0;
    // Version 1 and anything newer: read what this app knows, ignore the
    // rest. (v8 refused every version but 1, which is why v9 keeps 1.)
    if (version < 1) {
      throw FormatException(
        'Backup version $version is not supported (this app reads version $currentVersion).',
      );
    }
    final rawSettings = json['settings'];
    return ZoroxBackup(
      version: version,
      exportedAt: (json['exportedAt'] as num?)?.toInt() ?? 0,
      history: [
        for (final e in (json['history'] as List?) ?? const [])
          if (e is Map) Map<String, dynamic>.from(e),
      ],
      library: [
        for (final e in (json['library'] as List?) ?? const [])
          if (e is Map) Map<String, dynamic>.from(e),
      ],
      zoroxRepos: [
        for (final e in (json['zoroxRepos'] as List?) ?? const [])
          if (e is String) e,
      ],
      zoroxPlugins: [
        for (final e in (json['zoroxPlugins'] as List?) ?? const [])
          if (e is Map)
            {for (final kv in e.entries) '${kv.key}': '${kv.value}'},
      ],
      cloudstreamRepos: [
        for (final e in (json['cloudstreamRepos'] as List?) ?? const [])
          if (e is String) e,
      ],
      cloudstreamPlugins: [
        for (final e in (json['cloudstreamPlugins'] as List?) ?? const [])
          if (e is Map)
            {for (final kv in e.entries) '${kv.key}': '${kv.value}'},
      ],
      schema: (json['schema'] as num?)?.toInt() ?? 1,
      stremioAddons: [
        for (final e in (json['stremioAddons'] as List?) ?? const [])
          if (e is Map && e['url'] is String)
            {'url': e['url'] as String, 'enabled': e['enabled'] != false},
      ],
      nuvioRepos: [
        for (final e in (json['nuvioRepos'] as List?) ?? const [])
          if (e is Map && e['url'] is String)
            {
              'url': e['url'] as String,
              'disabled': [
                for (final id in (e['disabled'] as List?) ?? const [])
                  if (id is String) id,
              ],
              'enabledOverrides': [
                for (final id in (e['enabledOverrides'] as List?) ?? const [])
                  if (id is String) id,
              ],
            },
      ],
      nuvioEnabled: json['nuvioEnabled'] is bool
          ? json['nuvioEnabled'] as bool
          : null,
      settings: rawSettings is Map
          ? {for (final kv in rawSettings.entries) '${kv.key}': kv.value}
          : null,
      settingsUpdatedAt: (json['settingsUpdatedAt'] as num?)?.toInt() ?? 0,
      addonsSkippedForSecrets:
          (json['addonsSkippedForSecrets'] as num?)?.toInt() ?? 0,
    );
  }
}

/// What a restore did, for the confirmation toast: counts of what came
/// back, and one line per thing that could not be restored (a plugin its
/// repository no longer lists, a repository that would not load). It always
/// starts with "Import successful", so the toast answers the question the
/// viewer is asking — whether the import worked — before the detail.
class ZoroxRestoreReport {
  const ZoroxRestoreReport({
    this.historyRestored = 0,
    this.historySkipped = 0,
    this.historyInBackup = 0,
    this.libraryRestored = 0,
    this.zoroxReposRestored = 0,
    this.zoroxPluginsRestored = 0,
    this.cloudstreamReposRestored = 0,
    this.cloudstreamPluginsRestored = 0,
    this.addonsRestored = 0,
    this.nuvioReposRestored = 0,
    this.settingsChanged = 0,
    this.errors = const [],
  });

  /// Stremio add-ons re-installed, Nuvio repositories re-added, and
  /// settings keys changed (v9).
  final int addonsRestored;
  final int nuvioReposRestored;
  final int settingsChanged;

  final int historyRestored;

  /// Entries the local copy already had newer than the backup.
  final int historySkipped;

  /// How many history entries the backup file actually held (0 when it was
  /// exported from an empty app). Lets the summary tell an empty backup
  /// apart from a restore that found nothing new.
  final int historyInBackup;
  final int libraryRestored;
  final int zoroxReposRestored;
  final int zoroxPluginsRestored;
  final int cloudstreamReposRestored;
  final int cloudstreamPluginsRestored;
  final List<String> errors;

  /// True when nothing at all came back (an empty or foreign backup).
  bool get isEmpty =>
      historyRestored == 0 &&
      libraryRestored == 0 &&
      zoroxPluginsRestored == 0 &&
      cloudstreamPluginsRestored == 0 &&
      addonsRestored == 0 &&
      nuvioReposRestored == 0 &&
      settingsChanged == 0;

  String get summary {
    final parts = <String>[
      if (historyRestored > 0)
        '$historyRestored history item${historyRestored == 1 ? '' : 's'}',
      if (libraryRestored > 0)
        '$libraryRestored bookmark${libraryRestored == 1 ? '' : 's'}',
      if (zoroxPluginsRestored > 0 || cloudstreamPluginsRestored > 0)
        '${zoroxPluginsRestored + cloudstreamPluginsRestored} plugin${zoroxPluginsRestored + cloudstreamPluginsRestored == 1 ? '' : 's'}',
      if (addonsRestored + nuvioReposRestored > 0)
        '${addonsRestored + nuvioReposRestored} add-on${addonsRestored + nuvioReposRestored == 1 ? '' : 's'}',
      if (settingsChanged > 0) 'settings',
    ];
    if (parts.isEmpty) {
      // A backup exported from an empty app holds no history at all — say
      // that plainly, instead of the vague "Nothing new", so the user can
      // tell an empty backup from a restore that skipped what was already
      // on this device (historyInBackup > 0, all skipped = already here).
      if (historyInBackup == 0) {
        return 'Import successful — this backup has no watch history.';
      }
      return 'Import successful — nothing new to restore.';
    }
    return 'Import successful — restored ${parts.join(', ')}.';
  }
}

/// A [MultimediaItem] rebuilt from a backup's library map, or null when the
/// map does not describe a usable item (no URL to key it by).
MultimediaItem? libraryItemFromBackup(Map<String, dynamic> map) {
  try {
    final item = MultimediaItem.fromJson(map);
    if (item.url.isEmpty) return null;
    return item;
  } catch (_) {
    return null;
  }
}
