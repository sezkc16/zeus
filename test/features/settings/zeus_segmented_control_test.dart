/// The iOS-style sliding segmented control (1.0.1) on Player Engine and
/// Picture-in-Picture: a rounded track with an accent pill, no checkmark,
/// every label on one line, and the same options and persistence as the
/// outlined control it replaced.
///
/// App Theme used this control too until build 102, when the Olympus Noir
/// redesign replaced it with the theme cards (Obsidian / Aurora /
/// Imperial + "More themes" chips) — the App Theme group below covers
/// those cards instead.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/providers/device_info_provider.dart';
import 'package:zorox/core/services/notification_service.dart';
import 'package:zorox/core/storage/secure_token_storage.dart';
import 'package:zorox/core/storage/settings_repository.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/core/theme/app_theme.dart';
import 'package:zorox/core/theme/theme_variant.dart';
import 'package:zorox/features/settings/presentation/app_version_provider.dart';
import 'package:zorox/features/settings/presentation/cache_provider.dart';
import 'package:zorox/features/settings/presentation/general_settings_provider.dart';
import 'package:zorox/features/settings/presentation/player_settings_provider.dart';
import 'package:zorox/features/settings/presentation/player_settings_screen.dart';
import 'package:zorox/features/settings/presentation/settings_screen.dart';
import 'package:zorox/features/settings/presentation/widgets/olympus_theme_cards.dart';
import 'package:zorox/features/settings/presentation/widgets/zeus_segmented_control.dart';
import 'package:zorox/features/tracking/presentation/tracking_auth_provider.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// A repository that remembers the theme in memory instead of in a box.
class _MemorySettings extends SettingsRepository {
  _MemorySettings() : super(StorageService());

  String? variant;
  String? lastDark;
  String? mode;

  @override
  String? getThemeVariant() => variant;
  @override
  Future<void> saveThemeVariant(String name) async => variant = name;
  @override
  String? getLastDarkThemeVariant() => lastDark;
  @override
  Future<void> saveLastDarkThemeVariant(String name) async => lastDark = name;
  @override
  String? getThemeMode() => mode;
  @override
  Future<void> saveThemeMode(String mode) async => this.mode = mode;

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
  @override
  bool getDevQoeLog() => false;
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

void _phone(WidgetTester tester, {double width = 393}) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, 2400);
  tester.view.padding = FakeViewPadding.zero;
  tester.view.viewInsets = FakeViewPadding.zero;
  addTearDown(tester.view.reset);
}

Future<void> _pumpSettings(
  WidgetTester tester,
  _MemorySettings settings, {
  double width = 393,
}) async {
  _phone(tester, width: width);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // Never initialised: nothing here may touch a box.
        storageServiceProvider.overrideWithValue(StorageService()),
        settingsRepositoryProvider.overrideWithValue(settings),
        secureTokenStorageProvider.overrideWithValue(_NoTokens()),
        notificationServiceProvider.overrideWithValue(NotificationService()),
        trackingAuthProvider.overrideWith(_SignedOutTrackers.new),
        generalSettingsProvider.overrideWithValue(const GeneralSettings()),
        playerSettingsProvider.overrideWithBuild(
          (_, _) => const PlayerSettings(),
        ),
        deviceProfileProvider.overrideWith(
          (ref) => const DeviceProfile(isDesktopOS: true),
        ),
        appVersionProvider.overrideWith((ref) async => '1.0.1 +66'),
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

Future<void> _pumpPlayer(
  WidgetTester tester, {
  required TargetPlatform platform,
  double width = 393,
}) async {
  _phone(tester, width: width);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceProfileProvider.overrideWithValue(
          const AsyncValue.data(DeviceProfile()),
        ),
        playerSettingsProvider.overrideWithBuild(
          (_, _) => const PlayerSettings(),
        ),
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

/// Every label inside [control] is laid out on a single line, whole, and
/// stays inside its own segment.
void _expectSingleLine(WidgetTester tester, Finder control) {
  final labels = find.descendant(of: control, matching: find.byType(Text));
  expect(labels, findsWidgets);
  final count = labels.evaluate().length;
  final track = tester.getRect(
    find.descendant(of: control, matching: find.byType(Stack)).first,
  );
  final segmentWidth = track.width / count;
  for (final element in labels.evaluate()) {
    final text = (element.widget as Text).data;
    final finder = find.descendant(
      of: find.byWidget(element.widget),
      matching: find.byType(RichText),
    );
    final paragraph = tester.renderObject<RenderParagraph>(finder);
    // One line: exactly as tall as a single line of this text, and as wide
    // as the whole text wants to be.
    final oneLine = TextPainter(
      text: paragraph.text,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    expect(
      paragraph.size.height,
      closeTo(oneLine.height, 0.01),
      reason: '"$text" wraps',
    );
    expect(
      paragraph.size.width,
      closeTo(oneLine.width, 0.01),
      reason: '"$text" is cut',
    );
    expect(paragraph.didExceedMaxLines, isFalse, reason: '"$text" is cut');
    // On screen (after any scale-down) it fits its segment.
    expect(
      tester.getRect(finder).width,
      lessThanOrEqualTo(segmentWidth),
      reason: '"$text" overflows its segment',
    );
  }
}

Widget _bare({
  required String selected,
  required ValueChanged<String> onChanged,
  ThemeData? theme,
  bool reduceMotion = false,
}) {
  return MaterialApp(
    theme: theme,
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: ZeusSegmentedControl<String>(
              segments: const [
                ZeusSegment(value: 'a', label: 'Alpha'),
                ZeusSegment(value: 'b', label: 'Beta'),
                ZeusSegment(value: 'c', label: 'Gamma'),
              ],
              selected: selected,
              onChanged: onChanged,
            ),
          ),
        ),
      ),
    ),
  );
}

Finder get _pill => find.descendant(
  of: find.byType(ZeusSegmentedControl<String>),
  matching: find.byType(FractionallySizedBox),
);

void main() {
  group('App Theme', () {
    for (final width in [393.0, 320.0]) {
      testWidgets('five themes, cards for three and chips for two, one '
          'checkmark on the current card at $width pt', (tester) async {
        await _pumpSettings(tester, _MemorySettings(), width: width);

        final cards = find.byType(OlympusThemeCards);
        expect(cards, findsOneWidget);
        // The three mockup cards, each on one line, and the two remaining
        // themes as "More themes" chips — nothing was removed.
        for (final label in [
          'Obsidian',
          'Aurora',
          'Imperial',
          'Midnight',
          'Frost',
        ]) {
          expect(find.text(label), findsOneWidget);
        }
        // The fresh-install default is Liquid Glass, so its card —
        // Aurora — wears the one checkmark in the theme section.
        expect(
          find.descendant(
            of: cards,
            matching: find.byIcon(Icons.check_rounded),
          ),
          findsOneWidget,
        );
      });
    }

    testWidgets('a tap selects the variant and saves it', (tester) async {
      final settings = _MemorySettings();
      await _pumpSettings(tester, settings);
      final cards = find.byType(OlympusThemeCards);
      expect(
        tester.widget<OlympusThemeCards>(cards).current,
        ZoroxThemeVariant.liquidGlass,
      );

      await tester.tap(find.text('Midnight'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<OlympusThemeCards>(cards).current,
        ZoroxThemeVariant.midnight,
      );
      expect(settings.variant, 'midnight');
      expect(settings.lastDark, 'midnight');
      expect(settings.mode, 'dark');

      await tester.tap(find.text('Frost'));
      await tester.pumpAndSettle();
      expect(settings.variant, 'frost');
      expect(settings.mode, 'light');
      // The Dark Mode toggle still knows where to go back to.
      expect(settings.lastDark, 'midnight');

      // The new variant saves the same way.
      await tester.tap(find.text('Obsidian'));
      await tester.pumpAndSettle();
      expect(settings.variant, 'obsidian');
      expect(settings.lastDark, 'obsidian');
      expect(settings.mode, 'dark');
    });
  });

  group('Player settings', () {
    testWidgets('engine and PiP use the new control, same left edge and '
        'width, labels on one line', (tester) async {
      await _pumpPlayer(tester, platform: TargetPlatform.iOS);

      final engine = find.byType(ZeusSegmentedControl<PlayerEngine>);
      final pip = find.byType(ZeusSegmentedControl<PipMode>);
      expect(engine, findsOneWidget);
      expect(pip, findsOneWidget);
      expect(find.byType(SegmentedButton<PlayerEngine>), findsNothing);
      expect(find.byType(SegmentedButton<PipMode>), findsNothing);
      _expectSingleLine(tester, engine);
      _expectSingleLine(tester, pip);
      for (final control in [engine, pip]) {
        expect(
          find.descendant(of: control, matching: find.byType(Icon)),
          findsNothing,
        );
      }

      // The track itself: same left edge as the heading, same width.
      Rect track(Finder control) => tester.getRect(
        find.descendant(of: control, matching: find.byType(Stack)).first,
      );
      final engineTrack = track(engine);
      final pipTrack = track(pip);
      expect(engineTrack.width, pipTrack.width);
      expect(engineTrack.left, pipTrack.left);
      expect(
        tester.getTopLeft(find.text('Player Engine')).dx,
        closeTo(engineTrack.left - kZeusSegmentedInset, 0.01),
      );
      expect(
        tester.getTopLeft(find.text('Picture-in-Picture')).dx,
        closeTo(pipTrack.left - kZeusSegmentedInset, 0.01),
      );
    });

    testWidgets('Android keeps the engine control and still has no PiP '
        'selector', (tester) async {
      await _pumpPlayer(tester, platform: TargetPlatform.android);

      expect(find.byType(ZeusSegmentedControl<PlayerEngine>), findsOneWidget);
      expect(find.byType(ZeusSegmentedControl<PipMode>), findsNothing);
    });
  });

  group('the control', () {
    testWidgets('the pill slides to the tapped option', (tester) async {
      var selected = 'a';
      late StateSetter rebuild;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _bare(
              selected: selected,
              onChanged: (value) => rebuild(() => selected = value),
            );
          },
        ),
      );
      final start = tester.getCenter(_pill).dx;

      await tester.tap(find.text('Gamma'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final midway = tester.getCenter(_pill).dx;
      await tester.pumpAndSettle();
      final end = tester.getCenter(_pill).dx;

      expect(selected, 'c');
      expect(midway, greaterThan(start));
      expect(midway, lessThan(end));
      expect(end, closeTo(tester.getCenter(find.text('Gamma')).dx, 0.5));
    });

    testWidgets('with reduced motion the pill jumps', (tester) async {
      var selected = 'a';
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => _bare(
            selected: selected,
            reduceMotion: true,
            onChanged: (value) => setState(() => selected = value),
          ),
        ),
      );

      await tester.tap(find.text('Gamma'));
      await tester.pump();
      await tester.pump();

      expect(
        tester.getCenter(_pill).dx,
        closeTo(tester.getCenter(find.text('Gamma')).dx, 0.5),
      );
    });

    testWidgets('left and right move the selection from the keyboard', (
      tester,
    ) async {
      var selected = 'b';
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => _bare(
            selected: selected,
            onChanged: (value) => setState(() => selected = value),
          ),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(selected, 'c');
      // Already at the end: stays.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(selected, 'c');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(selected, 'a');
    });

    testWidgets('pill wears the accent, its label the on-accent colour, on '
        'every theme and with the White accent', (tester) async {
      const white = Color(0xFFE8EAED);
      final themes = <ThemeData>[
        for (final variant in ZoroxThemeVariant.values)
          variant.isDark
              ? AppTheme.createDarkTheme(null, variant: variant)
              : AppTheme.createLightTheme(null, variant: variant),
        AppTheme.createDarkTheme(
          null,
          seedColor: white,
          variant: ZoroxThemeVariant.midnight,
        ),
        AppTheme.createLightTheme(
          null,
          accent: white,
          variant: ZoroxThemeVariant.frost,
        ),
      ];
      for (final theme in themes) {
        await tester.pumpWidget(
          _bare(selected: 'a', onChanged: (_) {}, theme: theme),
        );
        await tester.pumpAndSettle();
        final scheme = theme.colorScheme;

        final pill = tester.widget<DecoratedBox>(
          find.descendant(of: _pill, matching: find.byType(DecoratedBox)),
        );
        expect((pill.decoration as BoxDecoration).color, scheme.primary);

        Color colourOf(String label) => tester
            .renderObject<RenderParagraph>(
              find.descendant(
                of: find.text(label),
                matching: find.byType(RichText),
              ),
            )
            .text
            .style!
            .color!;
        final selectedLabel = colourOf('Alpha');
        expect(selectedLabel, scheme.onPrimary);
        expect(colourOf('Beta'), scheme.onSurface);
        // Readable: the selected label is clearly lighter or darker than
        // the pill under it.
        expect(
          (selectedLabel.computeLuminance() - scheme.primary.computeLuminance())
              .abs(),
          greaterThan(0.3),
          reason: 'label on pill, ${theme.brightness} ${scheme.primary}',
        );
      }
    });
  });
}
