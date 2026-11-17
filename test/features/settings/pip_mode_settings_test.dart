import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/providers/device_info_provider.dart';
import 'package:zorox/features/settings/presentation/player_settings_provider.dart';
import 'package:zorox/features/settings/presentation/player_settings_screen.dart';
import 'package:zorox/features/settings/presentation/widgets/zeus_segmented_control.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// The Picture-in-Picture section on the Player settings screen (iOS only):
/// the mpv / iOS mode segment and the Enable PiP switch.
///
/// Rendering only — the setters are covered by the Hive round-trip tests in
/// `smaller_gaps_settings_test.dart`.
void main() {
  Future<void> pumpPlayerSettings(
    WidgetTester tester, {
    required TargetPlatform platform,
    PlayerSettings settings = const PlayerSettings(),
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = FakeViewPadding.zero;
    tester.view.viewInsets = FakeViewPadding.zero;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProfileProvider.overrideWithValue(
            const AsyncValue.data(DeviceProfile()),
          ),
          playerSettingsProvider.overrideWithBuild((_, _) => settings),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(platform: platform),
          home: const PlayerSettingsScreen(isEmbedded: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('iOS shows the PiP mode segment and the Enable PiP row', (
    tester,
  ) async {
    await pumpPlayerSettings(tester, platform: TargetPlatform.iOS);

    expect(find.text('Picture-in-Picture'), findsOneWidget);
    final segment = tester.widget<ZeusSegmentedControl<PipMode>>(
      find.byType(ZeusSegmentedControl<PipMode>),
    );
    expect(segment.segments.map((s) => s.value).toList(), [
      PipMode.mpv,
      PipMode.ios,
    ]);
    expect(segment.selected, PipMode.mpv);
    expect(find.text('Enable PiP'), findsOneWidget);
    expect(
      find.text('mpv bridge · PiP on the mpv engine (software renderer)'),
      findsOneWidget,
    );
  });

  testWidgets('iOS mode explains that mpv keeps hardware rendering', (
    tester,
  ) async {
    await pumpPlayerSettings(
      tester,
      platform: TargetPlatform.iOS,
      settings: const PlayerSettings(pipMode: PipMode.ios),
    );

    expect(
      find.text(
        'System PiP · libVLC engine; mpv keeps hardware rendering',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Android shows no PiP section', (tester) async {
    await pumpPlayerSettings(tester, platform: TargetPlatform.android);

    expect(find.text('Picture-in-Picture'), findsNothing);
    expect(find.text('Enable PiP'), findsNothing);
  });
}
