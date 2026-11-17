import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:zorox/core/storage/settings_repository.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/core/theme/theme_provider.dart';
import 'package:zorox/features/settings/presentation/app_version_provider.dart';
import 'package:zorox/features/settings/presentation/cache_provider.dart';
import 'package:zorox/features/settings/presentation/general_settings_provider.dart';
import 'package:zorox/features/settings/presentation/settings_screen.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// Zeus is GPL-3.0. The "Open-source licences" row was removed from
/// Settings' About group at the user's request (v5); the LICENSE file and
/// the licence texts stay in the bundle.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory dir;
  late StorageService storage;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('licences');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    storage = StorageService();
    await storage.init();
  });

  tearDown(() async {
    await Hive.close();
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            SettingsRepository(storage),
          ),
          appThemeModeProvider.overrideWithValue(ThemeMode.dark),
          generalSettingsProvider.overrideWithValue(const GeneralSettings()),
          appVersionProvider.overrideWith((ref) async => '2.8.1 +1'),
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
  }

  testWidgets('About has no Open-source licences row (v5)', (tester) async {
    await pumpSettings(tester);
    final version = find.text('Zeus for iOS');
    await tester.scrollUntilVisible(
      version,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    // About is Developer, Telegram and Version only.
    expect(find.text('Telegram'), findsOneWidget);
    expect(version, findsOneWidget);
    expect(find.text('Open-source licences'), findsNothing);
    expect(
      find.text('Zeus is free software under the GNU GPL v3'),
      findsNothing,
    );
  });

  test('the licence text still ships with the app', () {
    expect(File('LICENSE').existsSync(), isTrue);
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('- LICENSE'),
      reason: 'LICENSE stays a bundled asset',
    );
  });
}
