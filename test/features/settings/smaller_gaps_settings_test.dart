import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:zorox/core/extensions/services/repository_service.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/features/settings/presentation/general_settings_provider.dart';
import 'package:zorox/features/settings/presentation/player_settings_provider.dart';
import 'package:zorox/features/settings/presentation/widgets/settings_dialogs.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// The smaller-gaps settings, against a real Hive box in a temp directory:
/// PiP mode, the Seek gesture, the new subtitle defaults, the GitHub proxy
/// choice, and download segments up to 16.
///
/// A plain `test`, not a widget test: a real Hive box never completes its
/// writes inside a widget test's fake-async zone (see
/// `test/features/library/library_storage_test.dart`).
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late StorageService storage;
  late Map<String, String> keychain;
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('smaller_gaps_settings');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => dir.path,
    );
    storage = StorageService();
    await storage.init();
    keychain = <String, String>{};
    FlutterSecureStorage.setMockInitialValues(keychain);
  });

  tearDown(() async {
    await Hive.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  ProviderContainer boot() {
    final container = ProviderContainer(
      overrides: [storageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<PlayerSettings> playerSettings(ProviderContainer container) async {
    await container.read(playerSettingsProvider.future);
    return container.read(playerSettingsProvider).requireValue;
  }

  group('PiP mode', () {
    test('defaults to mpv and round-trips through Hive', () async {
      final container = boot();
      expect((await playerSettings(container)).pipMode, PipMode.mpv);

      await container
          .read(playerSettingsProvider.notifier)
          .setPipMode(PipMode.ios);
      expect((await playerSettings(container)).pipMode, PipMode.ios);
      expect(
        storage.getPlayerSetting<String>('player_pip_mode'),
        'ios',
        reason: 'stored by enum name, like the engine choice',
      );

      // A fresh container over the same box reads it back.
      final reopened = boot();
      expect((await playerSettings(reopened)).pipMode, PipMode.ios);
    });

    test('an unknown stored name reads back as mpv', () async {
      await storage.setPlayerSetting('player_pip_mode', 'holographic');
      final container = boot();
      expect((await playerSettings(container)).pipMode, PipMode.mpv);
    });

    test('copyWith carries the mode', () {
      const settings = PlayerSettings();
      expect(settings.pipMode, PipMode.mpv);
      expect(settings.copyWith(pipMode: PipMode.ios).pipMode, PipMode.ios);
      expect(settings.copyWith().pipMode, PipMode.mpv);
    });
  });

  group('Seek gesture', () {
    test('Seek is a Left/Right gesture choice and round-trips', () async {
      final container = boot();
      final notifier = container.read(playerSettingsProvider.notifier);

      await notifier.setLeftGesture(PlayerGesture.seek);
      await notifier.setRightGesture(PlayerGesture.seek);
      final settings = await playerSettings(container);
      expect(settings.leftGesture, PlayerGesture.seek);
      expect(settings.rightGesture, PlayerGesture.seek);
      expect(storage.getPlayerSetting<String>('player_gesture_left'), 'seek');
      expect(storage.getPlayerSetting<String>('player_gesture_right'), 'seek');
    });

    test('the Seek label is the design preview’s word', () {
      expect(getGestureLabel(PlayerGesture.seek, l10n), 'Seek');
    });
  });

  group('Subtitle Default options', () {
    test('English, Forced only and Same as audio round-trip', () async {
      final container = boot();
      final notifier = container.read(playerSettingsProvider.notifier);

      for (final value in [
        SubtitleDefault.english,
        SubtitleDefault.forcedOnly,
        SubtitleDefault.sameAsAudio,
      ]) {
        await notifier.setSubtitleDefault(value);
        expect((await playerSettings(container)).subtitleDefault, value);
        expect(
          storage.getPlayerSetting<String>('player_subtitle_default'),
          value.name,
        );
      }
    });

    test('the labels are the design preview’s words', () {
      expect(subtitleDefaultLabel(SubtitleDefault.auto, l10n), 'Auto');
      expect(subtitleDefaultLabel(SubtitleDefault.off, l10n), l10n.off);
      expect(subtitleDefaultLabel(SubtitleDefault.english, l10n), 'English');
      expect(
        subtitleDefaultLabel(SubtitleDefault.forcedOnly, l10n),
        'Forced only',
      );
      expect(
        subtitleDefaultLabel(SubtitleDefault.sameAsAudio, l10n),
        'Same as audio',
      );
    });
  });

  group('GitHub proxy choice', () {
    test('the legacy toggle migrates: on means jsDelivr', () async {
      await storage.setGithubProxyEnabled(true);
      final container = boot();
      expect(
        container.read(generalSettingsProvider).githubProxy,
        GithubProxyOption.jsdelivr,
      );
    });

    test('the legacy toggle off migrates to None', () async {
      await storage.setGithubProxyEnabled(false);
      final container = boot();
      expect(
        container.read(generalSettingsProvider).githubProxy,
        GithubProxyOption.none,
      );
    });

    test('a stored choice wins over the legacy toggle', () async {
      await storage.setGithubProxyOption('ghproxy');
      await storage.setGithubProxyEnabled(false);
      final container = boot();
      expect(
        container.read(generalSettingsProvider).githubProxy,
        GithubProxyOption.ghproxy,
      );
    });

    test('setGithubProxy stores the choice, the URL and the toggle', () async {
      final container = boot();
      await container
          .read(generalSettingsProvider.notifier)
          .setGithubProxy(
            GithubProxyOption.custom,
            customUrl: 'https://gh-proxy.com',
          );

      final settings = container.read(generalSettingsProvider);
      expect(settings.githubProxy, GithubProxyOption.custom);
      expect(settings.githubProxyCustomUrl, 'https://gh-proxy.com');
      expect(settings.githubProxyEnabled, isTrue);
      expect(storage.getGithubProxyOption(), 'custom');
      expect(storage.getGithubProxyCustomUrl(), 'https://gh-proxy.com');
      expect(storage.isGithubProxyEnabled(), isTrue);

      await container
          .read(generalSettingsProvider.notifier)
          .setGithubProxy(GithubProxyOption.none);
      expect(container.read(generalSettingsProvider).githubProxyEnabled, isFalse);
      expect(storage.isGithubProxyEnabled(), isFalse);
    });

    test('the row label names the choice', () {
      expect(
        githubProxyLabel(const GeneralSettings()),
        'None',
      );
      expect(
        githubProxyLabel(
          const GeneralSettings(githubProxy: GithubProxyOption.jsdelivr),
        ),
        'jsDelivr',
      );
      expect(
        githubProxyLabel(
          const GeneralSettings(githubProxy: GithubProxyOption.ghproxy),
        ),
        'ghproxy',
      );
      expect(
        githubProxyLabel(
          const GeneralSettings(
            githubProxy: GithubProxyOption.custom,
            githubProxyCustomUrl: 'https://gh-proxy.com',
          ),
        ),
        'Custom · https://gh-proxy.com',
      );
      expect(
        githubProxyLabel(
          const GeneralSettings(githubProxy: GithubProxyOption.custom),
        ),
        'Custom…',
      );
    });
  });

  group('applyGithubProxy', () {
    const raw =
        'https://raw.githubusercontent.com/sezkc16/tojiscripts/main/scripts.json';

    test('None leaves the URL alone', () {
      expect(applyGithubProxy(raw, GithubProxyOption.none), raw);
    });

    test('jsDelivr rewrites raw.githubusercontent.com, as the old toggle did', () {
      expect(
        applyGithubProxy(raw, GithubProxyOption.jsdelivr),
        'https://cdn.jsdelivr.net/gh/sezkc16/tojiscripts@main/scripts.json',
      );
      // Anything else is untouched.
      expect(
        applyGithubProxy(
          'https://github.com/sezkc16/tojiscripts/releases/download/v1/x.zip',
          GithubProxyOption.jsdelivr,
        ),
        'https://github.com/sezkc16/tojiscripts/releases/download/v1/x.zip',
      );
    });

    test('ghproxy prefixes the whole URL', () {
      expect(
        applyGithubProxy(raw, GithubProxyOption.ghproxy),
        'https://ghproxy.com/$raw',
      );
    });

    test('Custom prefixes the viewer’s base URL', () {
      expect(
        applyGithubProxy(raw, GithubProxyOption.custom, 'https://gh-proxy.com'),
        'https://gh-proxy.com/$raw',
      );
      expect(
        applyGithubProxy(raw, GithubProxyOption.custom, 'https://gh-proxy.com/'),
        'https://gh-proxy.com/$raw',
        reason: 'a trailing slash on the base must not double up',
      );
    });

    test('Custom with no URL behaves as None', () {
      expect(applyGithubProxy(raw, GithubProxyOption.custom, ''), raw);
      expect(applyGithubProxy(raw, GithubProxyOption.custom, '   '), raw);
    });
  });

  group('download directory', () {
    test('copyWith can clear the custom directory', () {
      const withDir = GeneralSettings(downloadDirectory: '/tmp/x');
      expect(
        withDir.copyWith(clearDownloadDirectory: true).downloadDirectory,
        isNull,
      );
      expect(withDir.copyWith().downloadDirectory, '/tmp/x');
      expect(
        withDir.copyWith(downloadDirectory: '/tmp/y').downloadDirectory,
        '/tmp/y',
      );
    });
  });

  group('download segments per file', () {
    test('the default is 8, and 16 round-trips', () async {
      expect(storage.getDownloadChunks(), 8);
      final container = boot();
      expect(container.read(generalSettingsProvider).downloadChunks, 8);

      await container
          .read(generalSettingsProvider.notifier)
          .setDownloadChunks(16);
      expect(container.read(generalSettingsProvider).downloadChunks, 16);
      expect(storage.getDownloadChunks(), 16);
    });

    test('values above 16 clamp to 16, below 1 clamp to 1', () async {
      await storage.setDownloadChunks(99);
      expect(storage.getDownloadChunks(), 16);
      await storage.setDownloadChunks(0);
      expect(storage.getDownloadChunks(), 1);
    });
  });
}
