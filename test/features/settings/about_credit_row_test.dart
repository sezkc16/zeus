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
import 'package:zorox/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// Settings → About (public 1.0.1): Developer, the "Based on SkyStream"
/// credit, Telegram, Version — in that order — and the version shown
/// alone. The credit row is the one place the app names the project it is
/// based on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory dir;
  late StorageService storage;
  final launched = <String>[];

  setUp(() async {
    launched.clear();
    dir = Directory.systemTemp.createTempSync('about');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (call) async {
        if (call.method == 'launch') {
          launched.add('${(call.arguments as Map)['url']}');
        }
        return true;
      },
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
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      null,
    );
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pumpAbout(WidgetTester tester, {String version = '1.0.1 +74'}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            SettingsRepository(storage),
          ),
          appThemeModeProvider.overrideWithValue(ThemeMode.dark),
          generalSettingsProvider.overrideWithValue(const GeneralSettings()),
          appVersionProvider.overrideWith((ref) async => version),
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
    await tester.scrollUntilVisible(
      find.text('Zeus for iOS'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  testWidgets('the credit row sits between Developer and Telegram', (
    tester,
  ) async {
    await pumpAbout(tester);
    final row = find.byKey(const ValueKey('about-based-on'));
    expect(row, findsOneWidget);
    expect(find.text('Based on SkyStream'), findsOneWidget);
    expect(find.text('Open source · GPL v3'), findsOneWidget);
    // Same row widget as its neighbours, with the chevron.
    final tile = tester.widget<SettingsTile>(row);
    expect(tile.reicon, Reicon.branchUp);
    expect(tile.showChevron, isTrue);
    expect(tile.onTap, isNotNull);

    final developer = tester.getTopLeft(find.text('Legion')).dy;
    final credit = tester.getTopLeft(find.text('Based on SkyStream')).dy;
    final telegram = tester.getTopLeft(find.text('Telegram')).dy;
    final version = tester.getTopLeft(find.text('Zeus for iOS')).dy;
    expect(developer, lessThan(credit));
    expect(credit, lessThan(telegram));
    expect(telegram, lessThan(version));
  });

  testWidgets('it is the only place Settings names the project', (
    tester,
  ) async {
    await pumpAbout(tester);
    // The credit row and, since build 67, the Telegram row's subtitle.
    expect(find.textContaining('SkyStream'), findsNWidgets(2));
    expect(find.textContaining('skystream'), findsNothing);
  });

  testWidgets('tapping it opens the project page', (tester) async {
    await pumpAbout(tester);
    await tester.tap(find.text('Based on SkyStream'));
    await tester.pump();
    expect(kBasedOnProjectUrl, 'https://github.com/akashdh11/skystream');
    expect(launched, ['https://github.com/akashdh11/skystream']);
  });

  testWidgets('Telegram opens the SkyStream community chat', (tester) async {
    await pumpAbout(tester);
    expect(find.text('SkyStream community chat'), findsOneWidget);
    await tester.tap(find.text('Telegram'));
    await tester.pump();
    expect(kTelegramChatUrl, 'https://t.me/skystream7chat');
    expect(launched, ['https://t.me/skystream7chat']);
    expect(find.textContaining('coming soon'), findsNothing);
  });

  testWidgets('Version shows 1.0.1 alone, no build suffix', (tester) async {
    await pumpAbout(tester);
    expect(find.text('1.0.1'), findsOneWidget);
    expect(find.textContaining('+71'), findsNothing);
  });

  test('aboutVersionLabel drops the build suffix and nothing else', () {
    expect(aboutVersionLabel('1.0.1 +74'), '1.0.1');
    expect(aboutVersionLabel('1.0.1'), '1.0.1');
    expect(aboutVersionLabel('1.2.3 +1.2.3'), '1.2.3');
  });

  test('the app is 1.0.1 build 74', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('\nversion: 1.0.1+74\n'),
    );
  });
}
