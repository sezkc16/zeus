/// The owner's repo as its own "Zeus" section: the same TojiX repo.json,
/// shown as "Zeus Repo" above the "Zeus (SkyStream)" section — and NOT in
/// the CloudStream section, which keeps only the official repository.
/// The repo stays in the CloudStream store (the .cs3 install / update
/// flow runs through it); only its display grouping moved, so an
/// installed Anikoto keeps working and updating.
library;

// A test's ProviderScope is its root scope; the rule only recognises one
// passed to runApp.
// ignore_for_file: riverpod_lint/scoped_providers_should_specify_dependencies

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/cloudstream/cloudstream_models.dart';
import 'package:zorox/core/cloudstream/cloudstream_repository.dart';
import 'package:zorox/core/extensions/base_provider.dart';
import 'package:zorox/core/extensions/extension_manager.dart';
import 'package:zorox/core/extensions/models/extension_plugin.dart';
import 'package:zorox/features/extensions/providers/extensions_controller.dart';
import 'package:zorox/features/extensions/screens/extensions_screen.dart';
import 'package:zorox/features/extensions/widgets/cloudstream_plugin_section.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

const String _tojiXUrl =
    'https://raw.githubusercontent.com/sezkc16/TojiX/main/repo.json';
const String _officialUrl =
    'https://raw.githubusercontent.com/recloudstream/extensions/master/repo.json';
const String _otherUrl = 'https://example.com/repo.json';

/// A CloudStream store that is already loaded, holding [state]: the real
/// one never finishes loading in the harness (its SharedPreferences /
/// engine-host work has no test backing).
class _LoadedCloudStream extends CloudStreamRepository {
  _LoadedCloudStream(this._state);

  final CloudStreamState _state;

  @override
  CloudStreamState build() => _state;
}

CsRepository _repo(String url, String name) =>
    CsRepository(url: url, name: name);

Widget _hosted(Widget child, CloudStreamState csState) => ProviderScope(
  overrides: [
    cloudStreamRepositoryProvider.overrideWith(
      () => _LoadedCloudStream(csState),
    ),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

class _MockExtensionsController extends ExtensionsController {
  _MockExtensionsController(this._initial);

  final ExtensionsState _initial;

  @override
  ExtensionsState build() => _initial;

  @override
  Future<void> ensureInitialized() async {}
}

class _MockExtensionManager extends ExtensionManager {
  @override
  List<SkyStreamProvider> build() => [];

  @override
  List<PluginSubProvider> getProvidersForPlugin(ExtensionPlugin plugin) =>
      [];

  @override
  Future<List<PluginSettingDefinition>> getSettingsForPlugin(
    ExtensionPlugin plugin,
  ) async => [];
}

void main() {
  group('displayNameFor', () {
    test('the owner repo is "Zeus Repo", not its manifest name', () {
      expect(
        CloudStreamRepository.displayNameFor(_repo(_tojiXUrl, 'TojiX Repo')),
        'Zeus Repo',
      );
    });

    test('the official repository stays "CloudStream"', () {
      expect(
        CloudStreamRepository.displayNameFor(
          _repo(_officialUrl, 'CloudStream Repo'),
        ),
        'CloudStream',
      );
    });

    test('any other repository keeps its manifest name', () {
      expect(
        CloudStreamRepository.displayNameFor(_repo(_otherUrl, 'Some Repo')),
        'Some Repo',
      );
    });

    test('isZeusRepository only matches the owner URL', () {
      expect(CloudStreamRepository.isZeusRepository(_tojiXUrl), isTrue);
      expect(CloudStreamRepository.isZeusRepository(_officialUrl), isFalse);
      expect(CloudStreamRepository.isZeusRepository(_otherUrl), isFalse);
    });
  });

  group('ZeusRepositorySection', () {
    testWidgets('shows the Zeus header and the Zeus Repo card', (tester) async {
      await tester.pumpWidget(
        _hosted(
          const ZeusRepositorySection(),
          CloudStreamState(
            isLoading: false,
            repositories: [_repo(_tojiXUrl, 'TojiX Repo')],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Zeus'), findsOneWidget);
      expect(find.text('Zeus Repo'), findsOneWidget);
      expect(find.text('TojiX Repo'), findsNothing);
    });

    testWidgets('hides entirely when the repository is not stored', (
      tester,
    ) async {
      await tester.pumpWidget(
        _hosted(
          const ZeusRepositorySection(),
          const CloudStreamState(isLoading: false),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Zeus'), findsNothing);
      expect(find.text('Zeus Repo'), findsNothing);
    });
  });

  group('CloudStreamRepositoriesSection', () {
    testWidgets('lists the official repository, never the owner repo', (
      tester,
    ) async {
      await tester.pumpWidget(
        _hosted(
          const CloudStreamRepositoriesSection(showAddRow: false),
          CloudStreamState(
            isLoading: false,
            repositories: [
              _repo(_tojiXUrl, 'TojiX Repo'),
              _repo(_officialUrl, 'CloudStream Repo'),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The section header plus the official repository's card.
      expect(find.text('CloudStream'), findsNWidgets(2));
      expect(find.text('Zeus Repo'), findsNothing);
      expect(find.text('TojiX Repo'), findsNothing);
    });
  });

  testWidgets(
    'Extensions screen: Zeus Repo above Zeus (SkyStream), TojiX gone',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      final empty = ExtensionsSuccess(
        repositories: const [],
        installedPlugins: const [],
        availablePlugins: const {},
        availableUpdates: const {},
        installingPlugins: const {},
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            extensionsControllerProvider.overrideWith(
              () => _MockExtensionsController(empty),
            ),
            extensionManagerProvider.overrideWith(
              () => _MockExtensionManager(),
            ),
            cloudStreamRepositoryProvider.overrideWith(
              () => _LoadedCloudStream(
                const CloudStreamState(
                  isLoading: false,
                  repositories: [
                    CsRepository(url: _tojiXUrl, name: 'TojiX Repo'),
                  ],
                ),
              ),
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ExtensionsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Zeus Repo'), findsOneWidget);
      expect(find.text('Zeus (SkyStream)'), findsOneWidget);
      expect(find.text('TojiX Repo'), findsNothing);
      // No .sky repositories stored: the SkyStream section's empty state
      // names SkyStream now, not Zeus (the Zeus Repo sits above it).
      expect(find.text('No SkyStream repos yet'), findsOneWidget);

      // The Zeus Repo card sits above the SkyStream header.
      final zeusRepo = tester.getTopLeft(find.text('Zeus Repo'));
      final skyHeader = tester.getTopLeft(find.text('Zeus (SkyStream)'));
      expect(zeusRepo.dy, lessThan(skyHeader.dy));
    },
  );
}
