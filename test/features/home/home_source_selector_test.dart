/// The Home source pills (v4): one pill per installed plugin, "For You"
/// first; a tap switches the whole Home feed to that plugin's home page.
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/cloudstream/cloudstream_engine.dart';
import 'package:zorox/core/cloudstream/cloudstream_models.dart';
import 'package:zorox/core/cloudstream/cloudstream_provider.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/extensions/base_provider.dart';
import 'package:zorox/core/extensions/extension_manager.dart';
import 'package:zorox/core/extensions/models/extension_plugin.dart';
import 'package:zorox/features/home/presentation/home_provider.dart';
import 'package:zorox/features/home/presentation/home_state.dart';
import 'package:zorox/features/home/presentation/widgets/home_source_selector.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

class _FakeProvider extends SkyStreamProvider {
  _FakeProvider(this.name);

  @override
  final String name;

  @override
  String get packageName => 'fake.${name.toLowerCase()}';
  @override
  String get mainUrl => 'https://fake.test';
  @override
  String get version => '1.0.0';
  @override
  List<String> get languages => const ['en'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.movie};

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) => throw UnimplementedError();
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

/// A real .cs3 provider, built without an engine: only its identity
/// (plugin name, plugin key, provider name) matters here.
CloudStreamProvider _csProvider({
  required String pluginName,
  required String pluginKey,
  required String providerName,
}) => CloudStreamProvider(
  plugin: CsInstalledPlugin(
    info: CsPluginInfo(
      internalName: pluginName.toLowerCase(),
      name: pluginName,
      url: '',
      repositoryUrl: '',
    ),
    filePath: '/tmp/$pluginName.cs3',
  ),
  pluginKey: pluginKey,
  info: CsProviderInfo(name: providerName, hasMainPage: true),
  host: CloudStreamEngineHost(),
);

/// The real notifier reaches for storage on every write; this keeps the
/// state transition and drops the persistence.
class _FakeActiveProvider extends ActiveProvider {
  _FakeActiveProvider(this._initial);

  final SkyStreamProvider? _initial;

  @override
  SkyStreamProvider? build() => _initial;

  @override
  Future<void> set(SkyStreamProvider? provider) async {
    state = provider;
  }
}

class _FakeExtensionManager extends ExtensionManager {
  _FakeExtensionManager(this._providers);

  final List<SkyStreamProvider> _providers;

  @override
  List<SkyStreamProvider> build() => _providers;

  @override
  Future<void> reloadPlugin(ExtensionPlugin plugin) async {}
}

/// Keeps the tap's `invalidate(homeDataProvider)` off the network: the
/// selector's job is the pill and the provider switch, not the fetch.
class _FakeHomeData extends HomeData {
  @override
  HomeState build() => const HomeNoProvider();
}

void main() {
  group('homeSources', () {
    test('no plugins means only For You', () {
      final sources = homeSources(const [], forYouLabel: 'For You');
      expect(sources.map((s) => s.label).toList(), ['For You']);
      expect(sources.single.provider, isNull);
    });

    test('one pill per plugin, sorted by plugin name', () {
      final sources = homeSources([
        _csProvider(
          pluginName: 'HDHub4u',
          pluginKey: 'toji/hdhub4u',
          providerName: 'HDHub4u',
        ),
        _csProvider(
          pluginName: 'Anikoto',
          pluginKey: 'toji/anikoto',
          providerName: 'Anikoto',
        ),
      ], forYouLabel: 'For You');
      expect(
        sources.map((s) => s.label).toList(),
        ['For You', 'Anikoto', 'HDHub4u'],
      );
    });

    test('a plugin with several providers still gets one pill', () {
      final zeta = _csProvider(
        pluginName: 'Multi',
        pluginKey: 'toji/multi',
        providerName: 'Zeta',
      );
      final alpha = _csProvider(
        pluginName: 'Multi',
        pluginKey: 'toji/multi',
        providerName: 'Alpha',
      );
      final sources = homeSources([zeta, alpha], forYouLabel: 'For You');
      expect(sources.map((s) => s.label).toList(), ['For You', 'Multi']);
      // The pill activates the first provider by name, deterministically.
      expect(sources.last.provider, same(alpha));
    });

    test('a non-CloudStream provider gets a pill of its own', () {
      final other = _FakeProvider('Legacy');
      final sources = homeSources([other], forYouLabel: 'For You');
      expect(sources.map((s) => s.label).toList(), ['For You', 'Legacy']);
      expect(sources.last.provider, same(other));
    });

    test('a plugin pill matches any of its own providers', () {
      final first = _csProvider(
        pluginName: 'Multi',
        pluginKey: 'toji/multi',
        providerName: 'Alpha',
      );
      final second = _csProvider(
        pluginName: 'Multi',
        pluginKey: 'toji/multi',
        providerName: 'Beta',
      );
      final sources = homeSources([first, second], forYouLabel: 'For You');
      // The dialog can leave the second sub-provider active; the pill
      // must still read as selected.
      expect(sources.last.matches(second), isTrue);
      expect(sources.last.matches(first), isTrue);
      expect(sources.first.matches(first), isFalse);
      expect(sources.first.matches(null), isTrue);
    });
  });

  group('HomeSourceSelector', () {
    Future<ProviderContainer> pumpSelector(
      WidgetTester tester, {
      required List<SkyStreamProvider> installed,
      SkyStreamProvider? active,
    }) async {
      final container = ProviderContainer(
        overrides: [
          extensionManagerProvider.overrideWith(
            () => _FakeExtensionManager(installed),
          ),
          activeProviderProvider.overrideWith(
            () => _FakeActiveProvider(active),
          ),
          homeDataProvider.overrideWith(_FakeHomeData.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: HomeSourceSelector()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('tapping a plugin pill makes it the active provider', (
      tester,
    ) async {
      final anikoto = _csProvider(
        pluginName: 'Anikoto',
        pluginKey: 'toji/anikoto',
        providerName: 'Anikoto',
      );
      final container = await pumpSelector(
        tester,
        installed: [
          anikoto,
          _csProvider(
            pluginName: 'HDHub4u',
            pluginKey: 'toji/hdhub4u',
            providerName: 'HDHub4u',
          ),
        ],
      );

      expect(find.text('For You'), findsOneWidget);
      expect(find.text('Anikoto'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('For You')).style?.fontWeight,
        FontWeight.w700,
        reason: 'For You starts selected: no plugin active yet',
      );

      await tester.tap(find.text('Anikoto'));
      await tester.pumpAndSettle();

      expect(container.read(activeProviderProvider), same(anikoto));
      expect(
        tester.widget<Text>(find.text('Anikoto')).style?.fontWeight,
        FontWeight.w700,
        reason: 'the tapped pill reads as selected',
      );
      expect(
        tester.widget<Text>(find.text('For You')).style?.fontWeight,
        FontWeight.w600,
        reason: 'For You is no longer selected',
      );
    });

    testWidgets('tapping For You clears the active provider', (
      tester,
    ) async {
      final anikoto = _csProvider(
        pluginName: 'Anikoto',
        pluginKey: 'toji/anikoto',
        providerName: 'Anikoto',
      );
      final container = await pumpSelector(
        tester,
        installed: [anikoto],
        active: anikoto,
      );

      await tester.tap(find.text('For You'));
      await tester.pumpAndSettle();

      expect(container.read(activeProviderProvider), isNull);
    });

    testWidgets('no plugins means only the For You pill', (tester) async {
      await pumpSelector(tester, installed: const []);

      expect(find.text('For You'), findsOneWidget);
      expect(find.text('Anikoto'), findsNothing);
    });
  });
}
