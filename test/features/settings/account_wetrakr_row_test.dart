import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/services/notification_service.dart';
import 'package:zorox/core/storage/secure_token_storage.dart';
import 'package:zorox/core/storage/settings_repository.dart';
import 'package:zorox/features/settings/presentation/account_settings_screen.dart';
import 'package:zorox/features/settings/presentation/player_settings_provider.dart';
import 'package:zorox/features/tracking/data/wetrakr_service.dart';
import 'package:zorox/features/tracking/presentation/tracking_auth_provider.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

import 'account_settings_tracking_login_test.dart'
    show NoTokens, QuietSettings, RecordingNotifications;

class _Trackers extends TrackingAuth {
  _Trackers(this.wetrakr);
  final bool wetrakr;

  @override
  Future<Map<String, bool>> build() async => <String, bool>{
    'simkl': false,
    'trakt': false,
    'wetrakr': wetrakr,
    'mal': false,
    'anilist': false,
  };
}

/// The WeTrakr row under TRACKING & SYNC: there only in a build that
/// carries the client id, and saying whether the person is connected.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required bool configured,
    bool signedIn = false,
  }) async {
    // Tall enough for the lazy list to build the tracking rows.
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationServiceProvider.overrideWithValue(
            RecordingNotifications(),
          ),
          secureTokenStorageProvider.overrideWithValue(NoTokens()),
          settingsRepositoryProvider.overrideWithValue(QuietSettings()),
          playerSettingsProvider.overrideWithBuild(
            (_, _) => const PlayerSettings(),
          ),
          trackingAuthProvider.overrideWith(() => _Trackers(signedIn)),
          wetrakrConfiguredProvider.overrideWithValue(configured),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AccountSettingsScreen(isEmbedded: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const row = ValueKey('account-wetrakr');

  testWidgets('with the client id: a WeTrakr row, offering to connect', (
    tester,
  ) async {
    await pump(tester, configured: true);
    expect(find.byKey(row), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(row), matching: find.text('WeTrakr')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(row), matching: find.text('Connect')),
      findsOneWidget,
    );
  });

  testWidgets('signed in: the row says it is active', (tester) async {
    await pump(tester, configured: true, signedIn: true);
    expect(
      find.descendant(of: find.byKey(row), matching: find.text('Active')),
      findsOneWidget,
    );
  });

  testWidgets('a build without the client id has no WeTrakr row', (
    tester,
  ) async {
    await pump(tester, configured: false);
    expect(find.byKey(row), findsNothing);
    expect(find.text('WeTrakr'), findsNothing);
    // The other trackers are untouched.
    expect(find.text('Trakt'), findsOneWidget);
  });
}
