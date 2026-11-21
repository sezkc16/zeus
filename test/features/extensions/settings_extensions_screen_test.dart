// Settings → Extensions (b121): four SEPARATE tabs, one per source —
// SkyStream, CloudStream, Nuvio, Stremio — each managing only its own
// source. A plugin installed in one tab never appears in another tab.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/addons/data/addon_repository.dart';
import 'package:zorox/core/cloudstream/cloudstream_repository.dart';
import 'package:zorox/core/extensions/base_provider.dart';
import 'package:zorox/core/extensions/extension_manager.dart';
import 'package:zorox/core/extensions/models/extension_plugin.dart';
import 'package:zorox/core/extensions/models/extension_repository.dart';
import 'package:zorox/features/addons/presentation/addon_providers.dart';
import 'package:zorox/features/extensions/providers/extensions_controller.dart';
import 'package:zorox/features/extensions/screens/settings_extensions_screen.dart';
import 'package:zorox/core/nuvio/data/nuvio_repository.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

class _MockExtensionsController extends ExtensionsController {
  _MockExtensionsController(this._state);

  final ExtensionsState _state;

  @override
  ExtensionsState build() => _state;

  @override
  Future<void> ensureInitialized() async {}
}

/// A CloudStream store that is already loaded: the real one never
/// finishes loading in the harness.
class _LoadedCloudStream extends CloudStreamRepository {
  @override
  CloudStreamState build() => const CloudStreamState(isLoading: false);
}

class _NoNuvio extends NuvioRepository {
  @override
  NuvioState build() => const NuvioState(isLoading: false, repos: []);
}

class _EmptyAddons extends AddonRepository {
  @override
  AddonsState build() => const AddonsState(addons: [], isLoading: false);
}

/// The plugin-check bar reads the extension manager, which reads the
/// storage layer in the real app — stub it out, as the Extensions
/// screen tests do.
class _NoExtensionManager extends ExtensionManager {
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

ExtensionsSuccess _oneInstalledOneRepo() {
  final installed = ExtensionPlugin(
    packageName: 'com.test.sky',
    name: 'Test Sky Plugin',
    repositoryId: 'test',
    repositoryUrl: 'https://example.com/repo.json',
    sourceUrl: 'https://example.com/plugin.sky',
    version: 1,
    authors: ['Tester'],
    description: 'A test SkyStream plugin',
  );
  final listed = ExtensionPlugin(
    packageName: 'com.test.sky',
    name: 'Test Sky Plugin',
    repositoryId: 'test',
    repositoryUrl: 'https://example.com/repo.json',
    sourceUrl: 'https://example.com/plugin.sky',
    version: 2,
    authors: ['Tester'],
    description: 'A test SkyStream plugin',
  );
  return ExtensionsSuccess(
    repositories: [
      ExtensionRepository(
        name: 'Test Sky Repo',
        url: 'https://example.com/repo.json',
        pluginLists: [],
      ),
    ],
    installedPlugins: [installed],
    availablePlugins: {
      'https://example.com/repo.json': [listed],
    },
    availableUpdates: {'com.test.sky': listed},
    installingPlugins: {},
  );
}

Future<void> _pumpScreen(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        extensionsControllerProvider.overrideWith(
          () => _MockExtensionsController(_oneInstalledOneRepo()),
        ),
        cloudStreamRepositoryProvider.overrideWith(_LoadedCloudStream.new),
        extensionManagerProvider.overrideWith(_NoExtensionManager.new),
        nuvioRepositoryProvider.overrideWith(_NoNuvio.new),
        addonRepositoryProvider.overrideWith(_EmptyAddons.new),
        addonHealthProvider.overrideWith(
          (ref) async => const <String, AddonHealth>{},
        ),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SettingsExtensionsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('four separate tabs, SkyStream first', (tester) async {
    await _pumpScreen(tester);

    // All four tabs are there, each its own source.
    for (final label in ['SkyStream', 'CloudStream', 'Nuvio', 'Stremio']) {
      expect(find.text(label), findsOneWidget, reason: '$label tab');
    }
    // The SkyStream tab opens first: its own installed plugin, its own
    // repository, and its own add row — and nothing from the other
    // sources.
    expect(find.text('Test Sky Plugin'), findsWidgets);
    expect(find.text('Test Sky Repo'), findsOneWidget);
    expect(find.text('Add Repository'), findsOneWidget);
    expect(find.text('Nuvio Scrapers'), findsNothing);
    expect(find.text('Add-ons Management'), findsNothing);
  });

  testWidgets('each tab shows only its own source', (tester) async {
    await _pumpScreen(tester);

    // CloudStream: its own empty state, not the SkyStream plugin.
    await tester.tap(find.text('CloudStream'));
    await tester.pumpAndSettle();
    expect(find.text('No CloudStream repos yet'), findsOneWidget);
    expect(find.text('Test Sky Plugin'), findsNothing);
    expect(find.text('Test Sky Repo'), findsNothing);

    // Nuvio: its own view, not the other sources.
    await tester.tap(find.text('Nuvio'));
    await tester.pumpAndSettle();
    expect(find.text('Nuvio Scrapers'), findsOneWidget);
    expect(find.text('Test Sky Plugin'), findsNothing);
    expect(find.text('No CloudStream repos yet'), findsNothing);

    // Stremio: its own management card, not the other sources.
    await tester.tap(find.text('Stremio'));
    await tester.pumpAndSettle();
    expect(find.text('Add-ons Management'), findsOneWidget);
    expect(find.text('Nuvio Scrapers'), findsNothing);
    expect(find.text('Test Sky Plugin'), findsNothing);

    // Back to SkyStream: its own content is still there.
    await tester.tap(find.text('SkyStream'));
    await tester.pumpAndSettle();
    expect(find.text('Test Sky Plugin'), findsWidgets);
    expect(find.text('Add-ons Management'), findsNothing);
  });
}
