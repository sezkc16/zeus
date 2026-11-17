// v9: the Zeus backup also carries Stremio add-ons, Nuvio repositories and
// an allow-list of app settings — never a secret, never the app-lock
// switch. Old backups still restore; the automatic sync is throttled.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/account/data/zorox_backup.dart';
import 'package:zorox/features/account/data/zorox_settings_sync.dart';

/// A backup exactly as v8 wrote it.
const String _v8Backup = '''
{
  "format": "zorox-backup",
  "version": 1,
  "exportedAt": 1763380000000,
  "history": [{"id": "tt1", "position": 120}],
  "library": [{"id": "tt2"}],
  "zoroxRepos": ["https://example.org/repo.json"],
  "zoroxPlugins": [{"packageName": "p", "repositoryUrl": "https://example.org/repo.json"}],
  "cloudstreamRepos": ["https://example.org/cs.json"],
  "cloudstreamPlugins": [{"internalName": "X", "name": "X", "url": "https://example.org/x.cs3", "repositoryUrl": "https://example.org/cs.json"}]
}
''';

void main() {
  group('ZoroxBackup', () {
    test('round trip keeps every v9 field', () {
      final backup = ZoroxBackup(
        exportedAt: 1763390000000,
        history: const [
          {'id': 'tt1', 'position': 5},
        ],
        library: const [
          {'id': 'tt2'},
        ],
        zoroxRepos: const ['https://example.org/repo.json'],
        cloudstreamRepos: const ['https://example.org/cs.json'],
        stremioAddons: const [
          {'url': 'https://v3-cinemeta.strem.io/manifest.json', 'enabled': true},
          {'url': 'https://example.org/addon/manifest.json', 'enabled': false},
        ],
        nuvioRepos: const [
          {
            'url': 'https://example.org/nuvio/manifest.json',
            'disabled': ['a'],
            'enabledOverrides': ['b'],
          },
        ],
        nuvioEnabled: true,
        settings: const {
          'accent_color': 'gold',
          'player_picture_brightness': 10,
          'player_autoplay_next_episode': false,
        },
        settingsUpdatedAt: 1763389000000,
        addonsSkippedForSecrets: 1,
      );
      final back = ZoroxBackup.fromJson(
        jsonDecode(jsonEncode(backup.toJson())) as Map<String, dynamic>,
      );
      expect(back.toJson(), backup.toJson());
      expect(back.schema, ZoroxBackup.currentSchema);
      expect(back.stremioAddons, hasLength(2));
      expect(back.stremioAddons[1]['enabled'], isFalse);
      expect(back.nuvioRepos.single['disabled'], ['a']);
      expect(back.nuvioEnabled, isTrue);
      expect(back.settings!['player_picture_brightness'], 10);
      expect(back.settingsUpdatedAt, 1763389000000);
    });

    test('the format name and version are what v8 reads', () {
      final json = ZoroxBackup(exportedAt: 1).toJson();
      expect(json['format'], 'zorox-backup');
      // v8 refuses any version but 1, so the additive revision is `schema`.
      expect(json['version'], 1);
      expect(json['schema'], 2);
    });

    test('a v8 backup restores: old sections read, new ones empty', () {
      final backup = ZoroxBackup.fromJson(
        jsonDecode(_v8Backup) as Map<String, dynamic>,
      );
      expect(backup.schema, 1);
      expect(backup.history.single['id'], 'tt1');
      expect(backup.library.single['id'], 'tt2');
      expect(backup.zoroxRepos, ['https://example.org/repo.json']);
      expect(backup.cloudstreamPlugins.single['internalName'], 'X');
      expect(backup.stremioAddons, isEmpty);
      expect(backup.nuvioRepos, isEmpty);
      expect(backup.nuvioEnabled, isNull);
      // No settings section at all: a restore must leave settings alone.
      expect(backup.settings, isNull);
      expect(backup.settingsUpdatedAt, 0);
    });

    test('a newer backup with unknown fields is read, not refused', () {
      final json = jsonDecode(_v8Backup) as Map<String, dynamic>
        ..['version'] = 3
        ..['schema'] = 9
        ..['somethingNew'] = {'a': 1}
        ..['stremioAddons'] = [
          {'url': 'https://example.org/manifest.json', 'future': true},
          'junk',
          {'noUrl': true},
        ];
      final backup = ZoroxBackup.fromJson(json);
      expect(backup.version, 3);
      expect(backup.history, hasLength(1));
      expect(backup.stremioAddons.single['url'], 'https://example.org/manifest.json');
    });

    test('not a Zeus backup, or version 0, is refused', () {
      expect(
        () => ZoroxBackup.fromJson({'format': 'other', 'version': 1}),
        throwsFormatException,
      );
      expect(
        () => ZoroxBackup.fromJson({'format': 'zorox-backup', 'version': 0}),
        throwsFormatException,
      );
    });

    test('a realistic backup is far below the 5 MB server limit', () {
      final backup = ZoroxBackup(
        exportedAt: 1763390000000,
        history: [
          for (var i = 0; i < 500; i++)
            {
              'id': 'tt${1000000 + i}',
              'title': 'A reasonably long title number $i',
              'posterUrl': 'https://image.tmdb.org/t/p/w500/abcdefghijklmnop$i.jpg',
              'url': 'https://example.org/title/$i',
              'provider': 'SomePlugin',
              'position': 123456,
              'duration': 2345678,
              'season': 1,
              'episode': i % 24,
              'updatedAt': 1763390000000 - i,
            },
        ],
        library: [
          for (var i = 0; i < 300; i++)
            {
              'id': 'tt${2000000 + i}',
              'title': 'A reasonably long title number $i',
              'posterUrl': 'https://image.tmdb.org/t/p/w500/abcdefghijklmnop$i.jpg',
              'url': 'https://example.org/title/$i',
              'provider': 'SomePlugin',
              'addedAt': 1763390000000 - i,
            },
        ],
        cloudstreamRepos: [
          for (var i = 0; i < 10; i++) 'https://example.org/repo$i/repo.json',
        ],
        cloudstreamPlugins: [
          for (var i = 0; i < 40; i++)
            {
              'internalName': 'Plugin$i',
              'name': 'Plugin $i',
              'url': 'https://example.org/repo/Plugin$i.cs3',
              'repositoryUrl': 'https://example.org/repo/repo.json',
            },
        ],
        stremioAddons: [
          for (var i = 0; i < 15; i++)
            {'url': 'https://addon$i.example.org/manifest.json', 'enabled': true},
        ],
        nuvioRepos: [
          for (var i = 0; i < 5; i++)
            {
              'url': 'https://nuvio$i.example.org/manifest.json',
              'disabled': ['a', 'b'],
              'enabledOverrides': <String>[],
            },
        ],
        settings: {for (final key in kSyncedSettingKeys) key: 'a-typical-value'},
        settingsUpdatedAt: 1763390000000,
      );
      final bytes = utf8.encode(jsonEncode(backup.toJson())).length;
      // ignore: avoid_print
      print('realistic backup size: $bytes bytes');
      expect(bytes, lessThan(500 * 1024));
    });
  });

  group('the settings allow-list', () {
    const secrets = <String>[
      'tmdb_api_key',
      'app_lock_enabled',
      'trakt_access_token',
      'trakt_refresh_token',
      'simkl_access_token',
      'mal_access_token',
      'anilist_access_token',
      'player_os_user',
      'player_os_pass',
      'opensubtitles_api_key',
      'zorox_session_token',
      'zorox_worker_url',
      'zorox_auto_sync_off',
      'download_path',
      'declined_update_tag',
    ];

    test('holds no key that names a credential, lock, server or path', () {
      for (final key in kSyncedSettingKeys) {
        expect(
          RegExp(
            r'token|secret|pass|api_?key|_key$|auth|session|login|lock|worker|server|path|dir|cookie|debrid|trakt|simkl|mal_|anilist|opensub|_os_',
          ).hasMatch(key),
          isFalse,
          reason: key,
        );
      }
      for (final key in secrets) {
        expect(kSyncedSettingKeys.contains(key), isFalse, reason: key);
      }
    });

    test('carries the approved settings', () {
      for (final key in <String>[
        'theme_mode',
        'theme_variant',
        'accent_color',
        'default_home_screen',
        'title_position',
        'home_row_prefs',
        'search_disabled_sources',
        'player_engine',
        'player_ios_mpv_pip',
        'player_seek_duration',
        'player_buffer_override_mb',
        'player_default_resize',
        'player_autoplay_next_episode',
        'player_mobile_data_max_quality',
        'player_preferred_source_language',
        'player_video_output_preset',
        'player_picture_brightness',
        'player_picture_contrast',
        'player_picture_saturation',
        'player_subtitle_default',
        'player_audio_language',
      ]) {
        expect(kSyncedSettingKeys.contains(key), isTrue, reason: key);
      }
    });

    test('collect: a secret in the box is NOT in the backup', () {
      final box = <String, Object?>{
        'accent_color': 'gold',
        'player_seek_duration': 10,
        'player_autoplay_next_episode': true,
        for (final key in secrets) key: 'do-not-leak',
        // Not a plain value: left out rather than guessed at.
        'home_row_prefs': <String, int>{'a': 1},
      };
      final settings = collectSyncedSettings((key) => box[key]);
      expect(settings, {
        'accent_color': 'gold',
        'player_seek_duration': 10,
        'player_autoplay_next_episode': true,
      });
      expect(jsonEncode(settings).contains('do-not-leak'), isFalse);
    });

    test('apply: a backup cannot write a key off the list', () async {
      final box = <String, Object?>{
        'tmdb_api_key': 'mine',
        'app_lock_enabled': true,
        'accent_color': 'green',
        'player_seek_duration': 10,
      };
      final writes = <String, Object?>{};
      final changed = await applySyncedSettings(
        {
          'accent_color': 'gold',
          'tmdb_api_key': 'theirs',
          'app_lock_enabled': false,
          'zorox_worker_url': 'https://evil.example',
          'player_os_pass': 'x',
        },
        read: (key) => box[key],
        write: (key, value) async {
          writes[key] = value;
          if (value == null) {
            box.remove(key);
          } else {
            box[key] = value;
          }
        },
      );
      // accent written; seek duration (absent from the backup) cleared.
      expect(writes, {'accent_color': 'gold', 'player_seek_duration': null});
      expect(changed, 2);
      expect(box['tmdb_api_key'], 'mine');
      expect(box['app_lock_enabled'], isTrue);
      expect(box.containsKey('zorox_worker_url'), isFalse);
      expect(box.containsKey('player_os_pass'), isFalse);
    });

    test('apply: the same settings again write nothing (no loop fuel)', () async {
      final box = <String, Object?>{'accent_color': 'gold'};
      var writes = 0;
      final changed = await applySyncedSettings(
        {'accent_color': 'gold'},
        read: (key) => box[key],
        write: (key, value) async => writes++,
      );
      expect(changed, 0);
      expect(writes, 0);
    });

    test('collect then apply on another device reproduces the settings', () async {
      final a = <String, Object?>{
        'accent_color': 'gold',
        'player_picture_contrast': -5,
        'player_ios_mpv_pip': true,
      };
      final b = <String, Object?>{'accent_color': 'green', 'title_position': 'x'};
      await applySyncedSettings(
        collectSyncedSettings((key) => a[key]),
        read: (key) => b[key],
        write: (key, value) async =>
            value == null ? b.remove(key) : b[key] = value,
      );
      expect(b, a);
    });
  });

  group('addonUrlCarriesSecret', () {
    test('plain add-on URLs are kept', () {
      for (final url in <String>[
        'https://v3-cinemeta.strem.io/manifest.json',
        'https://example.org/addon/manifest.json',
        'https://opensubtitles-v3.strem.io/manifest.json',
        'https://example.org/stremio/v1/manifest.json',
      ]) {
        expect(addonUrlCarriesSecret(url), isFalse, reason: url);
      }
    });

    test('a URL naming a debrid or API key is left out', () {
      for (final url in <String>[
        'https://torrentio.strem.fun/realdebrid=ABCDEF0123456789/manifest.json',
        'https://example.org/sort=quality|alldebrid=XYZ12345/manifest.json',
        'https://example.org/manifest.json?apikey=abcdef',
        'https://example.org/manifest.json?token=abcdef',
        'https://user:pw@example.org/manifest.json',
      ]) {
        expect(addonUrlCarriesSecret(url), isTrue, reason: url);
      }
    });

    test('a long opaque configuration segment is left out (fail closed)', () {
      final blob = base64Url.encode(
        utf8.encode('{"debridService":"realdebrid","debridApiKey":"SECRETKEY123"}'),
      );
      expect(
        addonUrlCarriesSecret('https://example.org/$blob/manifest.json'),
        isTrue,
      );
      expect(
        addonUrlCarriesSecret(
          'https://example.org/9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a/manifest.json',
        ),
        isTrue,
      );
    });

    test('an unreadable URL is left out', () {
      expect(addonUrlCarriesSecret('::not a url::'), isTrue);
    });
  });

  group('AutoSyncGate', () {
    final t0 = DateTime(2026, 11, 17, 19);
    bool may(AutoSyncGate gate, DateTime now, {
      bool loggedIn = true,
      bool enabled = true,
      bool playerOnTop = false,
      bool busy = false,
    }) => gate.mayRun(
      now: now,
      loggedIn: loggedIn,
      enabled: enabled,
      playerOnTop: playerOnTop,
      busy: busy,
    );

    test('runs the first time, then at most once every 10 minutes', () {
      final gate = AutoSyncGate();
      expect(may(gate, t0), isTrue);
      gate.markRan(t0);
      expect(may(gate, t0.add(const Duration(seconds: 30))), isFalse);
      expect(may(gate, t0.add(const Duration(minutes: 9, seconds: 59))), isFalse);
      expect(may(gate, t0.add(const Duration(minutes: 10))), isTrue);
    });

    test('never over the player, logged out, switched off or mid-sync', () {
      final gate = AutoSyncGate();
      expect(may(gate, t0, playerOnTop: true), isFalse);
      expect(may(gate, t0, loggedIn: false), isFalse);
      expect(may(gate, t0, enabled: false), isFalse);
      expect(may(gate, t0, busy: true), isFalse);
    });

    test('a refused attempt does not use up the window', () {
      final gate = AutoSyncGate();
      expect(may(gate, t0, playerOnTop: true), isFalse);
      // The player closes a moment later: the sync may still run.
      expect(may(gate, t0.add(const Duration(seconds: 5))), isTrue);
    });
  });
}
