import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/settings/presentation/general_settings_provider.dart';
import 'package:zorox/features/settings/presentation/widgets/settings_dialogs.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// The general settings, without Hive underneath them.
class _FakeGeneralSettings extends GeneralSettingsNotifier {
  _FakeGeneralSettings(this._settings);

  GeneralSettings _settings;

  @override
  GeneralSettings build() => _settings;

  @override
  Future<void> setGithubProxy(
    GithubProxyOption option, {
    String? customUrl,
  }) async {
    _settings = _settings.copyWith(
      githubProxy: option,
      githubProxyCustomUrl:
          customUrl?.trim() ?? _settings.githubProxyCustomUrl,
    );
    state = _settings;
  }

  @override
  Future<void> setDownloadDirectory(String? path) async {
    _settings = _settings.copyWith(
      downloadDirectory: path,
      clearDownloadDirectory: path == null,
    );
    state = _settings;
  }
}

/// The GitHub Proxy and Download Location dialogs.
void main() {
  late _FakeGeneralSettings fake;

  Future<void> pumpDialogOpener(
    WidgetTester tester, {
    required TargetPlatform platform,
    required void Function(BuildContext, WidgetRef) open,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    fake = _FakeGeneralSettings(const GeneralSettings());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [generalSettingsProvider.overrideWith(() => fake)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: Builder(
              builder: (context) => Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => open(context, ref),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  group('showGithubProxyDialog', () {
    testWidgets('offers None, jsDelivr, ghproxy and Custom', (tester) async {
      await pumpDialogOpener(
        tester,
        platform: TargetPlatform.iOS,
        open: (context, ref) => showGithubProxyDialog(context, ref),
      );

      expect(find.text('GitHub Proxy'), findsOneWidget);
      expect(find.text('None'), findsOneWidget);
      expect(find.text('jsDelivr'), findsOneWidget);
      expect(find.text('ghproxy'), findsOneWidget);
      expect(find.text('Custom…'), findsOneWidget);
    });

    testWidgets('picking ghproxy saves the choice and closes', (tester) async {
      await pumpDialogOpener(
        tester,
        platform: TargetPlatform.iOS,
        open: (context, ref) => showGithubProxyDialog(context, ref),
      );

      await tester.tap(find.text('ghproxy'));
      await tester.pumpAndSettle();

      expect(fake._settings.githubProxy, GithubProxyOption.ghproxy);
      expect(find.text('GitHub Proxy'), findsNothing);
    });

    testWidgets('Custom reveals a URL field that saves with the choice', (
      tester,
    ) async {
      await pumpDialogOpener(
        tester,
        platform: TargetPlatform.iOS,
        open: (context, ref) => showGithubProxyDialog(context, ref),
      );

      await tester.tap(find.text('Custom…'));
      await tester.pumpAndSettle();
      expect(find.text('Custom proxy URL'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField).last,
        'https://gh-proxy.com',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(fake._settings.githubProxy, GithubProxyOption.custom);
      expect(fake._settings.githubProxyCustomUrl, 'https://gh-proxy.com');
      expect(find.text('GitHub Proxy'), findsNothing);
    });
  });

  group('showDownloadLocationDialog', () {
    testWidgets('off iOS there are no presets, only the picker row', (
      tester,
    ) async {
      await pumpDialogOpener(
        tester,
        platform: TargetPlatform.android,
        open: (context, ref) =>
            showDownloadLocationDialog(context, ref, fake._settings),
      );

      expect(find.text('Download Location'), findsOneWidget);
      expect(find.text('Target Directory'), findsOneWidget);
      expect(find.text('System Downloads/ZoroX'), findsOneWidget);
      expect(find.text('On My iPhone › ZoroX'), findsNothing);
      expect(find.text('Files › Downloads'), findsNothing);
    });
  });
}
