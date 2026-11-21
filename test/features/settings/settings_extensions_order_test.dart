/// Settings has an Extensions group again since b121. The owner asked
/// for it back (2026-11-22 ~04:01): four SEPARATE sub-sections, one per
/// source — SkyStream, CloudStream, Nuvio, Stremio — each managing only
/// its own plugins and repos. The 1.0.1 removal ("hum toh plugin section
/// se sab manage karsakte") no longer holds: the Home plugin section is
/// troublesome ("bohot dikkat horha"). The four sections live inside the
/// Extensions screen, so Settings carries ONE "Extensions" row — the old
/// four top-level rows are still gone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/providers/device_info_provider.dart';
import 'package:zorox/core/services/notification_service.dart';
import 'package:zorox/core/storage/secure_token_storage.dart';
import 'package:zorox/core/storage/settings_repository.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/core/theme/theme_provider.dart';
import 'package:zorox/features/settings/presentation/app_version_provider.dart';
import 'package:zorox/features/settings/presentation/cache_provider.dart';
import 'package:zorox/features/settings/presentation/general_settings_provider.dart';
import 'package:zorox/features/settings/presentation/player_settings_provider.dart';
import 'package:zorox/features/settings/presentation/settings_screen.dart';
import 'package:zorox/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:zorox/features/tracking/presentation/tracking_auth_provider.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// Enough of a repository to render the screen, and nothing that touches a
/// box: [StorageService] here is never initialised.
class _QuietSettings extends SettingsRepository {
  _QuietSettings() : super(StorageService());

  @override
  bool isWatchHistoryEnabled() => true;
  @override
  String getDefaultHomeScreen() => '/home';
  @override
  bool isGithubProxyEnabled() => false;
  @override
  bool? getFullScreenMode() => false;
  @override
  Future<void> setFullScreenMode(bool enabled) async {}
  @override
  bool isAnimeSkipIntegrationEnabled() => false;
  @override
  bool isIntroDbIntegrationEnabled() => false;
  @override
  bool getDevLoadAssets() => false;
  // The theme variant is read when the Settings screen builds (the
  // variant picker + Dark Mode toggle read it); the box is never
  // initialised here, so no variant was ever picked — the default.
  @override
  String? getThemeVariant() => null;
  // Same for the developer-options switch (the App Data group reads it);
  // its default is off.
  @override
  bool getDevQoeLog() => false;
  // Same for the accent picker (the App Theme section reads it); no
  // accent was ever picked, so the default applies.
  @override
  String? getAccentColor() => null;
}

class _NoTokens extends SecureTokenStorage {
  _NoTokens() : super(StorageService());

  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _SignedOutTrackers extends TrackingAuth {
  @override
  Future<Map<String, bool>> build() async => const <String, bool>{
    'simkl': false,
    'trakt': false,
    'mal': false,
    'anilist': false,
  };
}

void main() {
  testWidgets('Settings has one Extensions group (b121)', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(_QuietSettings()),
          secureTokenStorageProvider.overrideWithValue(_NoTokens()),
          notificationServiceProvider.overrideWithValue(NotificationService()),
          trackingAuthProvider.overrideWith(_SignedOutTrackers.new),
          appThemeModeProvider.overrideWithValue(ThemeMode.dark),
          generalSettingsProvider.overrideWithValue(const GeneralSettings()),
          playerSettingsProvider.overrideWithBuild(
            (_, _) => const PlayerSettings(),
          ),
          deviceProfileProvider.overrideWith(
            (ref) => const DeviceProfile(isDesktopOS: true),
          ),
          appVersionProvider.overrideWith((ref) async => '1.0.0 +1'),
          cacheSizeProvider.overrideWith((ref) async => 0),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsScreen(),
        ),
      ),
    );
    await tester.pump();

    // One Extensions group, with the single row that opens the four
    // separate per-source sections.
    expect(
      find.byWidgetPredicate(
        (w) => w is SettingsGroup && w.title == 'Extensions',
      ),
      findsOneWidget,
    );
    expect(find.text('Extensions'), findsWidgets);
    expect(
      find.text('SkyStream, CloudStream, Nuvio & Stremio'),
      findsOneWidget,
    );
    // The old four top-level rows are still gone: they live inside the
    // Extensions screen now, not in Settings.
    for (final title in [
      'CloudStream Repos (.cs3)',
      'Nuvio Plugins',
      'Stremio Add-ons',
      'Search in plugins',
    ]) {
      expect(find.text(title), findsNothing, reason: '$title is gone');
    }
    // The groups around it are still there, in order.
    final titles = tester
        .widgetList<SettingsGroup>(find.byType(SettingsGroup))
        .map((g) => g.title)
        .toList();
    expect(titles, contains('Extensions'));
    expect(titles.length, greaterThanOrEqualTo(3));
    expect(find.text('BETA'), findsNothing);
  });
}
