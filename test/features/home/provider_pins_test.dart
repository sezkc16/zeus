import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/extensions/base_provider.dart';
import 'package:zorox/core/extensions/extension_manager.dart';
import 'package:zorox/core/providers/device_info_provider.dart';
import 'package:zorox/features/extensions/providers/extensions_controller.dart';
import 'package:zorox/features/home/presentation/home_provider.dart';
import 'package:zorox/features/home/presentation/home_screen.dart';
import 'package:zorox/features/home/presentation/home_state.dart';
import 'package:zorox/features/home/presentation/provider_pins.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// Enough rows to overflow the dialog so the list can actually fling.
const int _providerCount = 40;

class _FakeProvider extends SkyStreamProvider {
  final int index;
  _FakeProvider(this.index);

  @override
  String get packageName => 'fake.provider.$index';
  @override
  String get name => 'Provider $index';
  @override
  String get mainUrl => 'https://fake.test/$index';
  @override
  String get version => '1.0.0';
  @override
  List<String> get languages => const ['en'];
  @override
  Set<ProviderType> get supportedTypes =>
      index.isEven ? {ProviderType.movie} : {ProviderType.series};

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

/// The real notifiers reach for Hive-backed storage on every write; these
/// keep the state transitions and drop the persistence.
class _FakeHomeFilter extends HomeFilter {
  @override
  ProviderType? build() => null;

  @override
  Future<void> setFilter(ProviderType? type) async {
    state = type;
  }
}

class _FakeActiveProvider extends ActiveProvider {
  @override
  SkyStreamProvider? build() => null;

  @override
  Future<void> set(SkyStreamProvider? provider) async {
    state = provider;
  }
}

class _FakeHomeData extends HomeData {
  @override
  HomeState build() => const HomeNoProvider();
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

class _Host extends StatelessWidget {
  final VoidCallback onClosed;
  const _Host({required this.onClosed});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () async {
          await showProviderSelectorDialog(
            context,
            providers: List.generate(_providerCount, _FakeProvider.new),
            activeProvider: null,
          );
          onClosed();
        },
        child: const Text('open'),
      ),
    ),
  );
}

/// An in-memory pin store.
class _Pins {
  _Pins([List<String> initial = const []]) : value = List.of(initial);
  List<String> value;
  int writes = 0;
  ProviderPinsStore get store => ProviderPinsStore(
    read: () => value,
    write: (v) async {
      value = List.of(v);
      writes++;
    },
  );
}

Future<ProviderContainer> _pumpHost(
  WidgetTester tester, {
  required VoidCallback onClosed,
  required _Pins pins,
  bool reducedMotion = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      providerPinsStoreProvider.overrideWithValue(pins.store),
      homeFilterProvider.overrideWith(_FakeHomeFilter.new),
      activeProviderProvider.overrideWith(_FakeActiveProvider.new),
      homeDataProvider.overrideWith(_FakeHomeData.new),
      extensionsControllerProvider.overrideWith(_FakeExtensionsController.new),
      deviceProfileProvider.overrideWithValue(
        const AsyncValue.data(DeviceProfile()),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reducedMotion),
          child: child!,
        ),
        home: _Host(onClosed: onClosed),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return container;
}

List<String> _order(List<_FakeProvider> list) => [
  for (final p in list) p.packageName,
];

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

void main() {
  group('orderProvidersWithPins', () {
    final all = List.generate(5, _FakeProvider.new);

    test('no pins: the list is returned as it came', () {
      expect(identical(orderProvidersWithPins(all, const []), all), isTrue);
    });

    test('pinned first in pin order, then the rest in their order', () {
      final out = orderProvidersWithPins(all, const [
        'fake.provider.3',
        'fake.provider.1',
      ]);
      expect(_order(out), [
        'fake.provider.3',
        'fake.provider.1',
        'fake.provider.0',
        'fake.provider.2',
        'fake.provider.4',
      ]);
    });

    test('a pin whose plugin is gone is ignored, duplicates count once', () {
      final out = orderProvidersWithPins(all, const [
        'removed.plugin',
        'fake.provider.2',
        'fake.provider.2',
      ]);
      expect(_order(out).first, 'fake.provider.2');
      expect(out, hasLength(5));
      expect(
        identical(orderProvidersWithPins(all, const ['removed.plugin']), all),
        isTrue,
      );
    });
  });

  group('togglePin', () {
    test('adds at the end, removes when already pinned', () {
      expect(togglePin(const ['a'], 'b'), ['a', 'b']);
      expect(togglePin(const ['a', 'b'], 'a'), ['b']);
    });

    test('keeps at most kMaxProviderPins, dropping the oldest', () {
      final many = [for (var i = 0; i < kMaxProviderPins; i++) 'p$i'];
      final out = togglePin(many, 'new');
      expect(out, hasLength(kMaxProviderPins));
      expect(out.first, 'p1');
      expect(out.last, 'new');
    });
  });

  group('ProviderPins notifier', () {
    test('reads the store, toggles and writes back', () async {
      final pins = _Pins(['x']);
      final container = ProviderContainer(
        overrides: [providerPinsStoreProvider.overrideWithValue(pins.store)],
      );
      addTearDown(container.dispose);
      expect(container.read(providerPinsProvider), ['x']);
      await container.read(providerPinsProvider.notifier).toggle('y');
      expect(container.read(providerPinsProvider), ['x', 'y']);
      expect(pins.value, ['x', 'y']);
      await container.read(providerPinsProvider.notifier).toggle('x');
      expect(pins.value, ['y']);
    });

    test('a store that cannot be read means no pins, and a failed write '
        'keeps the pin for the session', () async {
      final container = ProviderContainer(
        overrides: [
          providerPinsStoreProvider.overrideWithValue(
            ProviderPinsStore(
              read: () => throw StateError('no box'),
              write: (_) async => throw StateError('no box'),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(providerPinsProvider), isEmpty);
      await container.read(providerPinsProvider.notifier).toggle('a');
      expect(container.read(providerPinsProvider), ['a']);
    });
  });

  group('Select Provider dialog', () {
    testWidgets('an unpinned row shows no pin at all; None has none', (
      tester,
    ) async {
      await _pumpHost(tester, onClosed: () {}, pins: _Pins());
      expect(find.byIcon(Icons.push_pin), findsNothing);
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(
        find.byKey(const ValueKey('provider-pin-fake.provider.0')),
        findsNothing,
      );
      // None is the first row.
      expect(_top(tester, 'None'), lessThan(_top(tester, 'Provider 0')));
    });

    testWidgets('press and hold pins, saves, moves the row up - and does '
        'not select or close; hold again unpins', (tester) async {
      var closed = false;
      final pins = _Pins();
      final container = await _pumpHost(
        tester,
        onClosed: () => closed = true,
        pins: pins,
      );
      expect(
        _top(tester, 'Provider 2'),
        greaterThan(_top(tester, 'Provider 1')),
      );

      await tester.longPress(find.text('Provider 2'));
      await tester.pumpAndSettle();

      expect(closed, isFalse);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(container.read(activeProviderProvider), isNull);
      expect(pins.value, ['fake.provider.2']);
      // Pinned row: right under None, above every other provider.
      expect(_top(tester, 'None'), lessThan(_top(tester, 'Provider 2')));
      expect(_top(tester, 'Provider 2'), lessThan(_top(tester, 'Provider 0')));
      final pin = find.byKey(const ValueKey('provider-pin-fake.provider.2'));
      expect(pin, findsOneWidget);
      final icon = tester.widget<Icon>(pin);
      expect(icon.icon, Icons.push_pin);
      expect(icon.color, Theme.of(tester.element(pin)).colorScheme.primary);
      // Only the pinned row carries a pin.
      expect(find.byIcon(Icons.push_pin), findsOneWidget);

      // Hold again: unpinned, icon gone, back to its old place.
      await tester.longPress(find.text('Provider 2'));
      await tester.pumpAndSettle();
      expect(closed, isFalse);
      expect(pins.value, isEmpty);
      expect(find.byIcon(Icons.push_pin), findsNothing);
      expect(
        _top(tester, 'Provider 2'),
        greaterThan(_top(tester, 'Provider 1')),
      );
      expect(container.read(activeProviderProvider), isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the pin on a pinned row is display only: a tap on it is a '
        'tap on the row', (tester) async {
      var closed = false;
      final pins = _Pins(['fake.provider.1']);
      final container = await _pumpHost(
        tester,
        onClosed: () => closed = true,
        pins: pins,
      );
      await tester.tap(
        find.byKey(const ValueKey('provider-pin-fake.provider.1')),
      );
      await tester.pumpAndSettle();
      expect(pins.value, ['fake.provider.1']);
      expect(closed, isTrue);
      expect(
        container.read(activeProviderProvider)?.packageName,
        'fake.provider.1',
      );
    });

    testWidgets('holding None does nothing; rows say Pin / Unpin to a '
        'screen reader', (tester) async {
      var closed = false;
      final pins = _Pins(['fake.provider.1']);
      await _pumpHost(tester, onClosed: () => closed = true, pins: pins);
      await tester.longPress(find.text('None'));
      await tester.pumpAndSettle();
      expect(closed, isFalse);
      expect(pins.value, ['fake.provider.1']);
      Semantics hold(String name) =>
          tester.widget<Semantics>(find.byKey(ValueKey('provider-hold-$name')));
      expect(
        hold('fake.provider.1').properties.hintOverrides?.onLongPressHint,
        'Unpin',
      );
      expect(
        hold('fake.provider.0').properties.hintOverrides?.onLongPressHint,
        'Pin',
      );
    });

    testWidgets('the row slides to its new place; reduced motion jumps', (
      tester,
    ) async {
      await _pumpHost(tester, onClosed: () {}, pins: _Pins());
      final settledTop = _top(tester, 'Provider 0');
      await tester.longPress(find.text('Provider 3'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      // Mid-slide: Provider 3 is on its way up, not yet at the top slot.
      expect(_top(tester, 'Provider 3'), greaterThan(settledTop));
      await tester.pumpAndSettle();
      expect(_top(tester, 'Provider 3'), settledTop);
    });

    testWidgets('reduced motion: the row is at its new place at once', (
      tester,
    ) async {
      await _pumpHost(
        tester,
        onClosed: () {},
        pins: _Pins(),
        reducedMotion: true,
      );
      final settledTop = _top(tester, 'Provider 0');
      await tester.longPress(find.text('Provider 3'));
      await tester.pump();
      expect(_top(tester, 'Provider 3'), settledTop);
      await tester.pumpAndSettle();
    });

    testWidgets('saved pins open first in pin order; a removed plugin\'s pin '
        'is ignored; tapping the row still selects', (tester) async {
      var closed = false;
      final container = await _pumpHost(
        tester,
        onClosed: () => closed = true,
        pins: _Pins(['gone.plugin', 'fake.provider.5', 'fake.provider.1']),
      );
      expect(_top(tester, 'Provider 5'), lessThan(_top(tester, 'Provider 1')));
      expect(_top(tester, 'Provider 1'), lessThan(_top(tester, 'Provider 0')));

      await tester.tap(find.text('Provider 5'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(
        container.read(activeProviderProvider)?.packageName,
        'fake.provider.5',
      );
    });

    testWidgets('a long name shrinks to fit and is never ellipsized', (
      tester,
    ) async {
      await _pumpHost(tester, onClosed: () {}, pins: _Pins());
      final name = tester.widget<Text>(find.text('Provider 0'));
      expect(name.overflow, isNull);
      expect(name.maxLines, 1);
      expect(
        find.ancestor(
          of: find.text('Provider 0'),
          matching: find.byType(FittedBox),
        ),
        findsOneWidget,
      );
    });
  });
}
