// ignore_for_file: riverpod_lint/scoped_providers_should_specify_dependencies

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/addons/data/addon_repository.dart';
import 'package:zorox/core/addons/models/addon_manifest.dart';
import 'package:zorox/core/nuvio/data/nuvio_repository.dart';
import 'package:zorox/core/nuvio/models/nuvio_models.dart';
import 'package:zorox/features/extensions/widgets/installed_other_sources.dart';

/// The Plugins tab's Installed segment also lists installed Stremio add-ons
/// and Nuvio repositories (v5), each with a delete action.

class _Addons extends AddonRepository {
  _Addons(this.initial);
  final List<ManagedAddon> initial;
  final removed = <String>[];

  @override
  AddonsState build() => AddonsState(addons: initial, isLoading: false);

  @override
  Future<void> remove(String manifestUrl) async {
    removed.add(manifestUrl);
    state = AddonsState(
      addons: state.addons.where((a) => a.manifestUrl != manifestUrl).toList(),
      isLoading: false,
    );
  }
}

class _Nuvio extends NuvioRepository {
  _Nuvio(this.initial);
  final List<NuvioRepo> initial;
  final removed = <String>[];

  @override
  NuvioState build() => NuvioState(repos: initial, isLoading: false);

  @override
  Future<void> removeRepository(String manifestUrl) async {
    removed.add(manifestUrl);
    state = NuvioState(
      repos: state.repos.where((r) => r.manifestUrl != manifestUrl).toList(),
      isLoading: false,
    );
  }
}

void main() {
  testWidgets('lists installed Stremio add-ons and Nuvio repositories with '
      'version, type line and a working delete', (tester) async {
    final addons = _Addons([
      ManagedAddon(
        manifestUrl: 'https://t.test/manifest.json',
        addedAt: DateTime(2026),
      ),
    ]);
    final nuvio = _Nuvio([
      NuvioRepo(
        manifestUrl: 'https://n.test/manifest.json',
        manifest: const NuvioManifest(
          name: 'All-in-One',
          version: '1.2.0',
          scrapers: [],
        ),
        addedAt: DateTime(2026),
      ),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          addonRepositoryProvider.overrideWith(() => addons),
          nuvioRepositoryProvider.overrideWith(() => nuvio),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: InstalledOtherSources()),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('t.test'), findsOneWidget);
    expect(find.text('Stremio add-on'), findsOneWidget);
    expect(find.text('All-in-One'), findsOneWidget);
    expect(find.text('v1.2.0 · 0 Nuvio providers'), findsOneWidget);

    await tester.tap(
      find.byKey(
        const ValueKey('installed-stremio-delete-https://t.test/manifest.json'),
      ),
    );
    await tester.pump();
    expect(addons.removed, ['https://t.test/manifest.json']);
    expect(find.text('t.test'), findsNothing);

    await tester.tap(
      find.byKey(
        const ValueKey('installed-nuvio-delete-https://n.test/manifest.json'),
      ),
    );
    await tester.pump();
    expect(nuvio.removed, ['https://n.test/manifest.json']);
    expect(find.text('All-in-One'), findsNothing);
  });
}
