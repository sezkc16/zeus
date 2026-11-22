import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zorox/core/providers/device_info_provider.dart';
import 'package:zorox/core/storage/settings_repository.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/core/theme/theme_provider.dart';
import 'package:zorox/features/player/domain/qoe_log.dart';
import 'package:zorox/features/settings/presentation/app_version_provider.dart';
import 'package:zorox/features/settings/presentation/cache_provider.dart';
import 'package:zorox/features/settings/presentation/developer_options_provider.dart';
import 'package:zorox/features/settings/presentation/developer_options_screen.dart';
import 'package:zorox/features/settings/presentation/general_settings_provider.dart';
import 'package:zorox/features/settings/presentation/settings_screen.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// Answers the settings screens' reads without a storage stack, and keeps
/// what the Developer Options switch writes. (The real StorageService over
/// Hive hangs the test isolate here — see the b107 Hive.close() note — so
/// this file never opens a box.)
class _Settings extends SettingsRepository {
  _Settings() : super(StorageService());

  bool devQoeLog = false;
  final List<bool> qoeWrites = <bool>[];

  @override
  String? getThemeMode() => null;

  @override
  String? getThemeVariant() => null;

  @override
  String? getAccentColor() => null;

  @override
  bool getDevLoadAssets() => false;

  @override
  bool getDevQoeLog() => devQoeLog;

  @override
  Future<void> setDevQoeLog(bool enabled) async {
    devQoeLog = enabled;
    qoeWrites.add(enabled);
  }
}

/// Settings > App Data & Developer > Developer Options (b125): the row
/// opens the Developer Options screen, while the trailing Switch alone
/// flips the flag. b124 shipped the screen with no way to reach it —
/// the row only toggled, DeveloperOptionsRoute was referenced nowhere,
/// and the Turnstile test tile inside it was unreachable (the user
/// proved it on video: tapping the row only flipped the toggle).
void main() {
  tearDown(() => QoeLog.writeToAppLog = false);

  late _Settings settings;
  late GoRouter router;

  setUp(() {
    settings = _Settings();
    router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const SettingsScreen()),
        // DeveloperOptionsRoute's full path: '/settings/developer'
        // (nested under SettingsRoute) — the row's .go() lands here.
        GoRoute(
          path: '/settings/developer',
          builder: (_, _) => const DeveloperOptionsScreen(),
        ),
      ],
    );
  });

  tearDown(() => router.dispose());

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          appThemeModeProvider.overrideWithValue(ThemeMode.dark),
          generalSettingsProvider.overrideWithValue(const GeneralSettings()),
          appVersionProvider.overrideWith((ref) async => '2.8.1 +1'),
          cacheSizeProvider.overrideWith((ref) async => 0),
          deviceProfileProvider.overrideWithValue(
            const AsyncValue.data(DeviceProfile()),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> scrollToRow(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('Developer Options'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  testWidgets('tapping the row opens the Developer Options screen', (
    tester,
  ) async {
    await pumpSettings(tester);
    await scrollToRow(tester);
    expect(find.text('Developer Options'), findsOneWidget);
    await tester.tap(find.text('Developer Options'));
    await tester.pumpAndSettle();
    // The screen itself, with the Turnstile test tile that was
    // unreachable before this fix.
    await tester.scrollUntilVisible(
      find.text('Turnstile test'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.text('Turnstile test'), findsOneWidget);
    // The Settings row is gone (its subtitle only exists there — the
    // Developer Options screen's own header shares the row's title).
    expect(find.text('Logs, QoE stats overlay, debug info'), findsNothing);
  });

  testWidgets('tapping the Switch flips the flag and stays on Settings', (
    tester,
  ) async {
    await pumpSettings(tester);
    await scrollToRow(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.text('Developer Options')),
    );
    expect(container.read(developerOptionsProvider), isFalse);
    final toggle = find.descendant(
      of: find.ancestor(
        of: find.text('Developer Options'),
        matching: find.byType(ListTile),
      ),
      matching: find.byType(Switch),
    );
    await tester.tap(toggle);
    await tester.pump();
    expect(container.read(developerOptionsProvider), isTrue);
    expect(settings.qoeWrites, <bool>[true]);
    // Still on Settings: no navigation happened.
    expect(find.text('Turnstile test'), findsNothing);
    expect(find.text('Developer Options'), findsOneWidget);
  });
}
