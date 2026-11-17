/// Settings' Extensions group, in the owner's order: CloudStream (.cs3),
/// Nuvio, Stremio. The Zeus repo lives on the Plugins screen's own Zeus
/// section (not in the CloudStream section), and there is no BETA marker
/// any more — the v3 restyle dropped the old ZoroX Providers row and the
/// CloudStream BETA flag with it.
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
  testWidgets('the extensions come in the owner\'s order', (tester) async {
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

    final group = find.byWidgetPredicate(
      (w) => w is SettingsGroup && w.title == 'Extensions',
    );
    final tiles = tester
        .widgetList<SettingsTile>(
          find.descendant(of: group, matching: find.byType(SettingsTile)),
        )
        .toList();
    expect(tiles.map((t) => t.title), [
      'CloudStream Repos (.cs3)',
      'Nuvio Plugins',
      'Stremio Add-ons',
    ]);
    // The first tile leads to the Plugins screen, where the owner's repo
    // is the Zeus Repo (same TojiX repo.json) in its own Zeus section.
    expect(tiles.first.subtitle, 'Zeus repo & official CloudStream repo');
    expect(
      tiles.where((t) => t.isBeta),
      isEmpty,
      reason: 'no extension row is marked BETA any more',
    );
    expect(tiles.last.isLast, isTrue, reason: 'the card closes on Stremio');
    expect(find.text('BETA'), findsNothing);
  });
}
