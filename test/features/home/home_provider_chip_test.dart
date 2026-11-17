/// Choosing a plugin on Home (v5; v6 moved it under the logo as a plain
/// text line): the header line opens the Select
/// Provider dialog; picking a provider there switches the whole Home feed
/// to that plugin's home page. The v4 pill row and its "For You" pill are
/// gone.
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
import 'package:zorox/core/providers/device_info_provider.dart';
import 'package:zorox/features/extensions/providers/extensions_controller.dart';
import 'package:zorox/features/home/presentation/home_screen.dart';
import 'package:zorox/features/home/presentation/widgets/home_provider_chip.dart';
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

/// Keeps the pick's `invalidate(homeDataProvider)` off the network, and
/// counts the rebuilds: a pick must re-fetch Home.
class _FakeHomeData extends HomeData {
  static int builds = 0;

  @override
  HomeState build() {
    builds++;
    return const HomeNoProvider();
  }
}

class _FakeHomeFilter extends HomeFilter {
  @override
  ProviderType? build() => null;

  @override
  Future<void> setFilter(ProviderType? type) async {
    state = type;
  }
}

class _FakeExtensionsController extends ExtensionsController {
  @override
  ExtensionsState build() => const ExtensionsSuccess(
    installedPlugins: [],
    repositories: [],
    availablePlugins: {},
    availableUpdates: {},
  );

  @override
  Future<void> ensureInitialized() async {}
}

ProviderContainer _container({
  required List<SkyStreamProvider> installed,
  SkyStreamProvider? active,
}) {
  final container = ProviderContainer(
    overrides: [
      extensionManagerProvider.overrideWith(
        () => _FakeExtensionManager(installed),
      ),
      activeProviderProvider.overrideWith(() => _FakeActiveProvider(active)),
      homeDataProvider.overrideWith(_FakeHomeData.new),
      homeFilterProvider.overrideWith(_FakeHomeFilter.new),
      extensionsControllerProvider.overrideWith(_FakeExtensionsController.new),
      deviceProfileProvider.overrideWithValue(
        const AsyncValue.data(DeviceProfile()),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The chip, wired the way Home wires it: a tap opens the dialog over
/// every installed provider.
class _ChipHost extends ConsumerWidget {
  const _ChipHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(
      bottom: homeProviderChipVisible(ref)
          ? HomeProviderChipBar(
              onTap: () => showProviderSelectorDialog(
                context,
                providers: ref.read(extensionManagerProvider),
                activeProvider: ref.read(activeProviderProvider),
              ),
            )
          : null,
    ),
    body: Consumer(
      builder: (context, ref, _) {
        // Keeps homeData alive, as Home does.
        ref.watch(homeDataProvider);
        return const SizedBox.shrink();
      },
    ),
  );
}

/// Home's v6 header, wired the way Home wires it: logo + name on the
/// toolbar row, search + settings on the right, the provider line as the
/// AppBar's `bottom` (a second line under the logo).
class _HeaderHost extends ConsumerWidget {
  const _HeaderHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(
      centerTitle: false,
      bottom: homeProviderChipVisible(ref)
          ? HomeProviderChipBar(onTap: () {})
          : null,
      title: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(key: Key('logo'), width: 28, height: 28),
          SizedBox(width: 8),
          Text('Zeus'),
        ],
      ),
      actions: const [
        Padding(
          padding: EdgeInsets.only(right: 12),
          child: CircleAvatar(key: Key('search'), radius: 18),
        ),
        Padding(
          padding: EdgeInsets.only(right: 16),
          child: CircleAvatar(key: Key('gear'), radius: 18),
        ),
      ],
    ),
    body: const SizedBox.shrink(),
  );
}

Future<void> _pumpHeader(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.physicalSize = const Size(393, 852);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const _HeaderHost(),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: _ChipHost(),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  final anikoto = _csProvider(
    pluginName: 'AnikotoProvider',
    pluginKey: 'anikoto',
    providerName: 'Anikoto',
  );
  final fourK = _csProvider(
    pluginName: 'FourKHDHubProvider',
    pluginKey: 'fourk',
    providerName: '4K HD',
  );

  group('cleanPluginName', () {
    test('drops the class-name suffix', () {
      expect(cleanPluginName('AnikotoProvider'), 'Anikoto');
      expect(cleanPluginName('BollyFlixProvider'), 'BollyFlix');
    });

    test('leaves clean names and a bare suffix alone', () {
      expect(cleanPluginName('Anikoto'), 'Anikoto');
      expect(cleanPluginName('Provider'), 'Provider');
      expect(cleanPluginName(' Movies Drive '), 'Movies Drive');
    });
  });

  group('homeProviderChipLabel', () {
    test('hidden with no plugin installed', () {
      expect(
        homeProviderChipLabel(
          installed: const [],
          active: null,
          selectLabel: 'Select',
        ),
        isNull,
      );
    });

    test('"Select" when plugins are installed and none is active', () {
      expect(
        homeProviderChipLabel(
          installed: [anikoto],
          active: null,
          selectLabel: 'Select',
        ),
        'Select',
      );
    });

    test('the active provider\'s clean name, not the plugin class name', () {
      expect(
        homeProviderChipLabel(
          installed: [anikoto, fourK],
          active: anikoto,
          selectLabel: 'Select',
        ),
        'Anikoto',
      );
    });
  });

  group('Home provider chip + Select Provider dialog', () {
    testWidgets('no plugin installed: no chip', (tester) async {
      await _pump(tester, _container(installed: const []));
      expect(find.byIcon(Icons.extension), findsNothing);
      expect(find.text('Select source'), findsNothing);
    });

    testWidgets('plugins installed, none active: chip reads Select', (
      tester,
    ) async {
      await _pump(tester, _container(installed: [anikoto, fourK]));
      expect(find.text('Select source'), findsOneWidget);
      expect(find.text('For You'), findsNothing);
    });

    testWidgets('active provider: chip reads its clean name', (tester) async {
      await _pump(
        tester,
        _container(installed: [anikoto, fourK], active: anikoto),
      );
      expect(find.text('Anikoto'), findsOneWidget);
      expect(find.text('AnikotoProvider'), findsNothing);
      expect(find.text('Select source'), findsNothing);
    });

    testWidgets('the dialog lists None and clean provider names', (
      tester,
    ) async {
      await _pump(tester, _container(installed: [anikoto, fourK]));
      await tester.tap(find.text('Select source'));
      await tester.pumpAndSettle();

      expect(find.text('Select Provider'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Movies'), findsOneWidget);
      expect(find.text('Series'), findsOneWidget);
      expect(find.text('Anime'), findsOneWidget);
      expect(find.text('None'), findsOneWidget);
      expect(find.text('Anikoto'), findsOneWidget);
      expect(find.text('4K HD'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
      // No plugin class names, no v4 pill label, no upstream branding.
      expect(find.text('AnikotoProvider'), findsNothing);
      expect(find.text('FourKHDHubProvider'), findsNothing);
      expect(find.text('For You'), findsNothing);
      expect(find.textContaining('SkyStream'), findsNothing);
      // "None" is the first row.
      expect(
        tester.getTopLeft(find.text('None')).dy,
        lessThan(tester.getTopLeft(find.text('4K HD')).dy),
      );
    });

    testWidgets('picking a provider closes the dialog and switches Home', (
      tester,
    ) async {
      final container = _container(installed: [anikoto, fourK]);
      await _pump(tester, container);
      final before = _FakeHomeData.builds;
      await tester.tap(find.text('Select source'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anikoto'));
      await tester.pumpAndSettle();

      expect(find.text('Select Provider'), findsNothing);
      expect(container.read(activeProviderProvider), same(anikoto));
      expect(
        _FakeHomeData.builds,
        greaterThan(before),
        reason: 'the pick re-fetches Home for the new provider',
      );
      // The chip now names the provider.
      expect(find.text('Anikoto'), findsOneWidget);
      expect(find.text('Select source'), findsNothing);
    });

    testWidgets('picking None clears the provider (key-free feed)', (
      tester,
    ) async {
      final container = _container(
        installed: [anikoto, fourK],
        active: anikoto,
      );
      await _pump(tester, container);
      await tester.tap(find.text('Anikoto'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('None'));
      await tester.pumpAndSettle();

      expect(find.text('Select Provider'), findsNothing);
      expect(container.read(activeProviderProvider), isNull);
      expect(find.text('Select source'), findsOneWidget);
    });

    testWidgets('Close leaves the selection alone', (tester) async {
      final container = _container(
        installed: [anikoto, fourK],
        active: anikoto,
      );
      await _pump(tester, container);
      await tester.tap(find.text('Anikoto'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expect(find.text('Select Provider'), findsNothing);
      expect(container.read(activeProviderProvider), same(anikoto));
    });
  });

  group('Home header v6: provider line under the logo (design B)', () {
    final longName = _csProvider(
      pluginName: 'LongProvider',
      pluginKey: 'long',
      providerName: 'A Very Long Provider Name That Cannot Possibly Fit Here',
    );

    for (final brightness in Brightness.values) {
      testWidgets('"from <name> v" sits on its own line under the logo, '
          'left-aligned, plain text (${brightness.name})', (tester) async {
        await _pumpHeader(
          tester,
          _container(installed: [anikoto, fourK], active: anikoto),
          brightness: brightness,
        );
        final logo = tester.getRect(find.byKey(const Key('logo')));
        final search = tester.getRect(find.byKey(const Key('search')));
        final gear = tester.getRect(find.byKey(const Key('gear')));
        final from = tester.getRect(find.text('from'));
        final name = tester.getRect(find.text('Anikoto'));
        final chevron = tester.getRect(
          find.byIcon(Icons.keyboard_arrow_down_rounded),
        );
        // Below the whole toolbar row, with a small gap under the logo.
        expect(from.top, greaterThanOrEqualTo(logo.bottom + 5));
        expect(from.top, lessThanOrEqualTo(logo.bottom + 22));
        expect(from.top, greaterThanOrEqualTo(search.bottom));
        expect(from.top, greaterThanOrEqualTo(gear.bottom));
        // Left edge under the logo's left edge; order: from, name, chevron.
        expect(from.left, moreOrLessEquals(logo.left, epsilon: 0.5));
        expect(name.left, greaterThan(from.right));
        expect(chevron.left, greaterThanOrEqualTo(name.right));
        // Inside the AppBar, not clipped.
        final bar = tester.getRect(find.byType(AppBar));
        expect(chevron.bottom, lessThanOrEqualTo(bar.bottom));
        // Search + settings stay on the right of the toolbar row.
        expect(search.left, greaterThan(393 / 2));
        expect(gear.left, greaterThan(search.right));

        // Plain text: the name in the accent colour and bold, "from" and
        // the chevron in the on-surface colour, each with a soft shadow.
        final context = tester.element(find.byType(HomeProviderChipBar));
        final scheme = Theme.of(context).colorScheme;
        final nameStyle = tester.widget<Text>(find.text('Anikoto')).style!;
        final fromStyle = tester.widget<Text>(find.text('from')).style!;
        expect(nameStyle.color, scheme.primary);
        expect(nameStyle.fontWeight, FontWeight.w700);
        expect(fromStyle.color, scheme.onSurface.withValues(alpha: 0.95));
        expect(fromStyle.fontSize, 13);
        expect(fromStyle.shadows, isNotEmpty);
        expect(nameStyle.shadows, isNotEmpty);
        // No pill: no puzzle icon, and nothing in the line paints a fill
        // or a border (the tap wrapper's own box is undecorated at rest).
        expect(find.byIcon(Icons.extension), findsNothing);
        for (final box in tester.widgetList<DecoratedBox>(
          find.descendant(
            of: find.byType(HomeProviderChipBar),
            matching: find.byType(DecoratedBox),
          ),
        )) {
          final decoration = box.decoration as BoxDecoration;
          expect(decoration.color, isNull);
          expect(decoration.border, isNull);
          expect(decoration.gradient, isNull);
          expect(decoration.boxShadow, anyOf(isNull, isEmpty));
        }
        expect(
          find.descendant(
            of: find.byType(HomeProviderChipBar),
            matching: find.byType(ColoredBox),
          ),
          findsNothing,
        );
      });
    }

    testWidgets('the whole line is a 44 px tall tap target', (tester) async {
      var taps = 0;
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: _container(installed: [anikoto], active: anikoto),
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              appBar: AppBar(
                bottom: HomeProviderChipBar(onTap: () => taps++),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final target = tester.getRect(find.byKey(HomeProviderChipBar.tapKey));
      expect(target.height, 44);
      await tester.tap(find.text('from'));
      await tester.tap(find.text('Anikoto'));
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
      // Well below the text, still inside the target.
      await tester.tapAt(Offset(target.left + 30, target.bottom - 3));
      expect(taps, 4);
    });

    testWidgets('a long provider name ellipsizes within 55% of the width', (
      tester,
    ) async {
      await _pumpHeader(
        tester,
        _container(installed: [longName], active: longName),
      );
      final target = tester.getRect(find.byKey(HomeProviderChipBar.tapKey));
      final chevron = tester.getRect(
        find.byIcon(Icons.keyboard_arrow_down_rounded),
      );
      expect(target.width, lessThanOrEqualTo(393 * 0.55 + 0.01));
      expect(chevron.right, lessThanOrEqualTo(393 * 0.55 + 0.01));
      expect(find.text('from'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no plugin installed: one-line header, no provider line', (
      tester,
    ) async {
      await _pumpHeader(tester, _container(installed: const []));
      expect(find.byType(HomeProviderChipBar), findsNothing);
      expect(find.text('from'), findsNothing);
      expect(find.text('Select source'), findsNothing);
      expect(tester.getSize(find.byType(AppBar)).height, kToolbarHeight);
    });

    testWidgets('plugins installed, none active: "Select source" in accent, '
        'no "from"', (tester) async {
      await _pumpHeader(tester, _container(installed: [anikoto]));
      expect(find.byType(HomeProviderChipBar), findsOneWidget);
      expect(find.text('from'), findsNothing);
      final context = tester.element(find.byType(HomeProviderChipBar));
      expect(
        tester.widget<Text>(find.text('Select source')).style!.color,
        Theme.of(context).colorScheme.primary,
      );
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
      final logo = tester.getRect(find.byKey(const Key('logo')));
      expect(
        tester.getRect(find.text('Select source')).left,
        moreOrLessEquals(logo.left, epsilon: 0.5),
      );
    });
  });
}
