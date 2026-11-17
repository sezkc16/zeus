// A test's ProviderScope is its root scope; the rule only recognises one
// passed to runApp.
// ignore_for_file: riverpod_lint/scoped_providers_should_specify_dependencies

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/cloudstream/cloudstream_models.dart';
import 'package:zorox/core/cloudstream/cloudstream_repository.dart';
import 'package:zorox/shared/focus/app_focus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zorox/features/extensions/screens/extensions_screen.dart';
import 'package:zorox/features/extensions/providers/extensions_controller.dart';
import 'package:zorox/core/extensions/extension_manager.dart';
import 'package:zorox/core/extensions/models/extension_plugin.dart';
import 'package:zorox/core/extensions/models/extension_repository.dart';
import 'package:zorox/core/extensions/base_provider.dart';
import 'package:zorox/shared/widgets/cards_wrapper.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// A CloudStream store that is already loaded: the real one never finishes
/// loading in the harness (its SharedPreferences / engine-host work has no
/// test backing), so its section shows the endlessly-morphing loading
/// spinner and pumpAndSettle never completes. The tests below are about the
/// ZoroX extension system's UI and focus, not the CloudStream load.
class _LoadedCloudStream extends CloudStreamRepository {
  @override
  CloudStreamState build() => const CloudStreamState(isLoading: false);
}

/// The single scroll is taller than the default 800x600 test viewport, so
/// rows below the fold are not built yet (a ListView builds lazily) and a
/// tap on one of them misses. A tall viewport makes the whole screen
/// visible, so no test has to scroll first. The framework resets the view
/// between tests, so nothing has to restore it.
void _tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
}

/// Starts the Plugins tab on [segment] — the tests about the repository
/// cards and the Add Repository field live under "Add Plugins" (v5).
class _StartOn extends PluginsSegmentNotifier {
  _StartOn(this.segment);
  final PluginsSegment segment;

  @override
  PluginsSegment build() => segment;
}

/// A CloudStream store with the given repositories already stored.
class _StoredCloudStream extends CloudStreamRepository {
  _StoredCloudStream(this._state);
  final CloudStreamState _state;

  @override
  CloudStreamState build() => _state;
}

class MockExtensionsController extends ExtensionsController {
  final ExtensionsState initialState;
  MockExtensionsController(this.initialState);

  @override
  ExtensionsState build() => initialState;

  @override
  Future<void> ensureInitialized() async {}
}

/// A controller the test can push new states through, to stand in for a
/// repository finishing its install.
class MutableExtensionsController extends ExtensionsController {
  MutableExtensionsController(this._initial);
  final ExtensionsState _initial;

  @override
  ExtensionsState build() => _initial;

  @override
  Future<void> ensureInitialized() async {}

  void push(ExtensionsState next) => state = next;
}

class MockExtensionManager extends ExtensionManager {
  @override
  List<SkyStreamProvider> build() => [];

  @override
  List<PluginSubProvider> getProvidersForPlugin(ExtensionPlugin plugin) => [];

  @override
  Future<List<PluginSettingDefinition>> getSettingsForPlugin(
    ExtensionPlugin plugin,
  ) async => [];
}

void main() {
  ExtensionsSuccess emptyWithRepo() => ExtensionsSuccess(
    repositories: [
      ExtensionRepository(
        name: 'Test Repo',
        url: 'https://example.com/repo.json',
        pluginLists: [],
      ),
    ],
    installedPlugins: [],
    availablePlugins: {},
    availableUpdates: {},
    installingPlugins: {},
  );

  ExtensionsSuccess oneInstalled() => ExtensionsSuccess(
    repositories: [
      ExtensionRepository(
        name: 'Test Repo',
        url: 'https://example.com/repo.json',
        pluginLists: [],
      ),
    ],
    installedPlugins: [
      ExtensionPlugin(
        name: 'Installed Plugin',
        version: 1,
        packageName: 'com.example.plugin',
        repositoryId: 'test_repo',
        sourceUrl: 'https://example.com/plugin.js',
      ),
    ],
    availablePlugins: {},
    availableUpdates: {},
    installingPlugins: {},
  );

  /// The screen under [container], so a test can rebuild it from scratch
  /// against the same (app-lifetime) providers.
  Widget hosted(ProviderContainer container, {Key? key}) =>
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ExtensionsScreen(key: key),
        ),
      );

  ProviderContainer containerFor(ExtensionsState state) {
    final container = ProviderContainer(
      overrides: [
        extensionsControllerProvider.overrideWith(
          () => MockExtensionsController(state),
        ),
        extensionManagerProvider.overrideWith(() => MockExtensionManager()),
        cloudStreamRepositoryProvider.overrideWith(() => _LoadedCloudStream()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  const installedKey = ValueKey('plugins-segment-installed');
  const addKey = ValueKey('plugins-segment-add');

  Color? segmentFill(WidgetTester tester, Key key) => tester
      .widget<Material>(
        find
            .descendant(of: find.byKey(key), matching: find.byType(Material))
            .first,
      )
      .color;

  testWidgets('the default segment is Installed, filled with the accent', (
    tester,
  ) async {
    _tallViewport(tester);
    await tester.pumpWidget(hosted(containerFor(oneInstalled())));
    await tester.pumpAndSettle();

    // No TabBar: the two segments are one row under the title + subtitle.
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('Plugins'), findsOneWidget);
    expect(
      find.text('Zeus Repo, CloudStream (.cs3), Nuvio & Stremio'),
      findsOneWidget,
    );
    expect(find.textContaining('TojiX'), findsNothing);
    expect(find.byKey(installedKey), findsOneWidget);
    expect(find.byKey(addKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(installedKey),
        matching: find.text('Installed'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(addKey), matching: find.text('Add Plugins')),
      findsOneWidget,
    );
    // Installed sits left of Add Plugins.
    expect(
      tester.getCenter(find.byKey(installedKey)).dx,
      lessThan(tester.getCenter(find.byKey(addKey)).dx),
    );

    final scheme = Theme.of(tester.element(find.byKey(installedKey))).colorScheme;
    expect(segmentFill(tester, installedKey), scheme.primary);
    expect(segmentFill(tester, addKey), isNot(scheme.primary));

    // Installed shows the installed list only: nothing for adding.
    expect(find.text('Installed Plugin'), findsOneWidget);
    expect(find.text('Installed Extensions'), findsOneWidget);
    expect(find.text('ADD REPOSITORY'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Test Repo'), findsNothing);
    expect(find.text('Zeus (SkyStream)'), findsNothing);
    expect(find.text('MORE SOURCES'), findsNothing);
  });

  testWidgets('Add Plugins shows the Add Repository card and the repository '
      'sections, and hides the installed list', (tester) async {
    _tallViewport(tester);
    final container = ProviderContainer(
      overrides: [
        extensionsControllerProvider.overrideWith(
          () => MockExtensionsController(oneInstalled()),
        ),
        extensionManagerProvider.overrideWith(() => MockExtensionManager()),
        cloudStreamRepositoryProvider.overrideWith(
          () => _StoredCloudStream(
            const CloudStreamState(
              isLoading: false,
              repositories: [
                CsRepository(
                  url:
                      'https://raw.githubusercontent.com/sezkc16/TojiX/main/repo.json',
                  name: 'TojiX Repo',
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(hosted(container));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(addKey));
    await tester.pumpAndSettle();

    final scheme = Theme.of(tester.element(find.byKey(addKey))).colorScheme;
    expect(segmentFill(tester, addKey), scheme.primary);
    expect(segmentFill(tester, installedKey), isNot(scheme.primary));

    // Everything for adding, in the same order as before.
    expect(find.text('ADD REPOSITORY'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add'), findsOneWidget);
    expect(find.text('Zeus'), findsOneWidget);
    expect(find.text('Zeus Repo'), findsOneWidget);
    expect(find.text('Zeus (SkyStream)'), findsOneWidget);
    expect(find.text('Test Repo'), findsOneWidget);
    expect(find.text('CloudStream'), findsWidgets);
    expect(find.text('MORE SOURCES'), findsOneWidget);
    expect(find.text('Nuvio Plugins'), findsOneWidget);
    expect(find.text('Stremio Add-ons'), findsOneWidget);
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('ADD REPOSITORY'), lessThan(top('Zeus Repo')));
    expect(top('Zeus Repo'), lessThan(top('Zeus (SkyStream)')));
    expect(top('Zeus (SkyStream)'), lessThan(top('MORE SOURCES')));

    // ... and the installed list is gone from this segment.
    expect(find.text('Installed Plugin'), findsNothing);
    expect(find.text('Installed Extensions'), findsNothing);

    // Back to Installed: the list returns, the add half leaves.
    await tester.tap(find.byKey(installedKey));
    await tester.pumpAndSettle();
    expect(find.text('Installed Plugin'), findsOneWidget);
    expect(find.text('ADD REPOSITORY'), findsNothing);
  });

  testWidgets("the empty Installed state's button switches to Add Plugins", (
    tester,
  ) async {
    _tallViewport(tester);
    final container = containerFor(emptyWithRepo());
    await tester.pumpWidget(hosted(container));
    await tester.pumpAndSettle();

    expect(find.text('No Extensions Installed'), findsOneWidget);
    expect(
      find.text('Open Add Plugins to add a repository and install extensions.'),
      findsOneWidget,
    );
    expect(find.text('ADD REPOSITORY'), findsNothing);
    expect(find.text('Test Repo'), findsNothing);

    const button = ValueKey('plugins-empty-add-button');
    expect(find.byKey(button), findsOneWidget);
    await tester.tap(find.byKey(button));
    await tester.pumpAndSettle();

    expect(container.read(pluginsSegmentProvider), PluginsSegment.add);
    expect(find.text('No Extensions Installed'), findsNothing);
    expect(find.text('ADD REPOSITORY'), findsOneWidget);
    expect(find.text('Test Repo'), findsOneWidget);
  });

  testWidgets('the segment choice is remembered when the screen is rebuilt', (
    tester,
  ) async {
    _tallViewport(tester);
    final container = containerFor(oneInstalled());
    await tester.pumpWidget(hosted(container, key: const ValueKey('first')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(addKey));
    await tester.pumpAndSettle();
    expect(find.text('ADD REPOSITORY'), findsOneWidget);

    // The screen leaves the tree entirely (another tab) ...
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SizedBox.shrink()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionsScreen), findsNothing);

    // ... and a brand-new screen (new State) opens on the same segment.
    await tester.pumpWidget(hosted(container, key: const ValueKey('second')));
    await tester.pumpAndSettle();
    expect(find.text('ADD REPOSITORY'), findsOneWidget);
    expect(find.text('Installed Plugin'), findsNothing);
    final scheme = Theme.of(tester.element(find.byKey(addKey))).colorScheme;
    expect(segmentFill(tester, addKey), scheme.primary);
  });

  testWidgets('both segments keep the bottom clearance for the nav pill', (
    tester,
  ) async {
    await tester.pumpWidget(hosted(containerFor(oneInstalled())));
    await tester.pumpAndSettle();
    EdgeInsetsGeometry? padding() =>
        tester.widget<ListView>(find.byType(ListView)).padding;
    // Outside the shell the minimum (100) applies; inside it the shell's
    // inflated MediaQuery padding (156) does — same call in both segments.
    expect((padding()! as EdgeInsets).bottom, 100);
    await tester.tap(find.byKey(addKey));
    await tester.pumpAndSettle();
    expect((padding()! as EdgeInsets).bottom, 100);
  });

  // "Kartoons-style" plugin login: an installed .cs3 plugin's own settings
  // screen (where its "Get Login Code" lives) opens from the tune button on
  // its row. The Installed segment reuses the same tile, so the button —
  // same gate (hasSettings == true), same key — sits beside delete.
  testWidgets('an installed .cs3 plugin with settings keeps its tune button '
      'in the Installed segment; one without does not', (tester) async {
    _tallViewport(tester);
    CsInstalledPlugin cs(String name, bool? hasSettings) => CsInstalledPlugin(
      info: CsPluginInfo(
        internalName: name,
        name: name,
        url: 'https://example.com/$name.cs3',
        repositoryUrl: 'https://example.com/repo.json',
        version: 3,
      ),
      filePath: '/tmp/$name.cs3',
      hasSettings: hasSettings,
    );
    final container = ProviderContainer(
      overrides: [
        extensionsControllerProvider.overrideWith(
          () => MockExtensionsController(emptyWithRepo()),
        ),
        extensionManagerProvider.overrideWith(() => MockExtensionManager()),
        cloudStreamRepositoryProvider.overrideWith(
          () => _StoredCloudStream(
            CloudStreamState(
              isLoading: false,
              installed: [
                cs('KartoonsProvider', true),
                cs('AnikotoProvider', false),
                cs('UnknownProvider', null),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(hosted(container));
    await tester.pumpAndSettle();

    // Installed is the default segment, and all three rows are in it.
    expect(container.read(pluginsSegmentProvider), PluginsSegment.installed);
    expect(find.text('KartoonsProvider'), findsOneWidget);
    expect(find.text('AnikotoProvider'), findsOneWidget);
    expect(find.text('UnknownProvider'), findsOneWidget);
    expect(find.text('No Extensions Installed'), findsNothing);

    // The settings (login) button: only where the plugin has settings.
    final tune = find.byKey(const ValueKey('cs3_settings_KartoonsProvider'));
    expect(tune, findsOneWidget);
    expect(
      find.descendant(of: tune, matching: find.byIcon(Icons.tune_rounded)),
      findsOneWidget,
    );
    expect(tester.widget<IconButton>(tune).onPressed, isNotNull);
    expect(
      find.byKey(const ValueKey('cs3_settings_AnikotoProvider')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('cs3_settings_UnknownProvider')),
      findsNothing,
    );
    expect(find.byIcon(Icons.tune_rounded), findsOneWidget);

    // Delete stays on every row, the tune button to its left.
    for (final name in ['KartoonsProvider', 'AnikotoProvider', 'UnknownProvider']) {
      expect(find.byKey(ValueKey('cs3_uninstall_$name')), findsOneWidget);
    }
    expect(
      tester.getCenter(tune).dx,
      lessThan(
        tester
            .getCenter(
              find.byKey(const ValueKey('cs3_uninstall_KartoonsProvider')),
            )
            .dx,
      ),
    );
  });

  group('plugin row focus affordance', _focusAffordanceTests);
  group('under a thumb or a mouse', _touchTests);
  group('TV dead ends', _tvDeadEndTests);
}

// ---------------------------------------------------------------------------
// Under a thumb or a mouse: focus moves, and nothing may show it.
// ---------------------------------------------------------------------------

void _touchTests() {
  testWidgets('a repository card never lights up for focus a tap or the code '
      'put there', (WidgetTester tester) async {
    // The report: rings round the repositories at random on a phone and a
    // Mac, used with nothing but a finger and a mouse. Focus does land on the
    // cards under a pointer - a header tapped to expand it, a node focused by
    // code written for the remote - and the card lit up for any of it.
    _tallViewport(tester);
    await tester.pumpWidget(_app(
        _oneRepository(),
        visibility: true,
        segment: PluginsSegment.add,
      ),
    );
    await tester.pumpAndSettle();
    final theme = Theme.of(tester.element(find.text('Test Repo')));

    // The single scroll is taller than the test viewport, so scroll the
    // card (and then its row) into view first — off-screen rows are not
    // built yet.
    await tester.tap(find.text('Test Repo'));
    await tester.pumpAndSettle();
    await _focusOn(tester, find.text('Test Repo'));

    final card = _cardDecoration(
      tester,
      find.text('Test Repo'),
      theme.colorScheme.surface,
    );
    expect(
      (card.border! as Border).top.color,
      isNot(theme.colorScheme.primary),
    );
    expect((card.border! as Border).top.width, 1.0);
    expect(card.boxShadow, isNull);

    // A row inside, focused the same way, draws nothing either.
    final rowB = find.ancestor(
      of: find.text('Plugin B'),
      matching: find.byType(ListTile),
    );
    await _focusOn(
      tester,
      find.descendant(of: rowB, matching: find.byIcon(Icons.download)),
    );
    expect(_rowLayers(tester, find.text('Plugin B')).ring, isNull);
    expect(_rowLayers(tester, find.text('Plugin B')).glow, isNull);
  });
}

// ---------------------------------------------------------------------------
// Focus affordance: the ROW the user is on, not the card that contains it.
// ---------------------------------------------------------------------------

/// The two decoration layers a focused plugin row is supposed to draw around
/// itself: the accent glow (a BoxShadow, painted behind) and the accent ring
/// plus tint (a border and a fill, painted behind the row's text).
///
/// Both are looked up by walking the Container ancestors of the row's own
/// title, so the assertions are about the row, never about the section card —
/// the card is an AnimatedContainer, a different type, and it is deliberately
/// not matched here.
({BoxDecoration? glow, BoxDecoration? ring}) _rowLayers(
  WidgetTester tester,
  Finder rowTitle,
) {
  BoxDecoration? ring;
  BoxDecoration? glow;
  for (final container in tester.widgetList<Container>(
    find.ancestor(of: rowTitle, matching: find.byType(Container)),
  )) {
    final decoration = container.decoration;
    if (decoration is! BoxDecoration) continue;
    // Matched on the recipe's own signature, not on position in the tree: an
    // AnimatedContainer builds a plain Container, so the section card itself
    // turns up in this walk and must not be mistaken for the row. Only the
    // row strokes its border outside the box, and the two shadows differ in
    // spread (the card's is not zero).
    final border = decoration.border;
    if (border is Border &&
        border.top.strokeAlign == BorderSide.strokeAlignOutside) {
      ring ??= decoration;
    }
    final shadow = decoration.boxShadow;
    if (shadow != null &&
        shadow.length == 1 &&
        shadow.single.spreadRadius == 0) {
      glow ??= decoration;
    }
  }
  return (glow: glow, ring: ring);
}

/// The section/repository card that encloses [inner].
BoxDecoration _cardDecoration(
  WidgetTester tester,
  Finder inner,
  Color surface,
) {
  final cards = tester
      .widgetList<AnimatedContainer>(
        find.ancestor(of: inner, matching: find.byType(AnimatedContainer)),
      )
      .map((c) => c.decoration)
      .whereType<BoxDecoration>()
      .where((d) => d.color == surface)
      .toList();
  expect(
    cards,
    hasLength(1),
    reason: 'expected exactly one _FocusableCard above $inner',
  );
  return cards.single;
}

/// Moves real focus onto the control [finder] points at, the way a D-pad
/// would, by asking for the nearest enclosing focus node.
Future<void> _focusOn(WidgetTester tester, Finder finder) async {
  final node = Focus.maybeOf(
    tester.element(finder),
    createDependency: false,
  );
  expect(node, isNotNull, reason: 'nothing focusable at $finder');
  node!.requestFocus();
  // Two frames: FocusManager applies the change in a microtask, so the first
  // pump is what delivers onFocusChange and the second is what paints it.
  await tester.pump();
  await tester.pump();
}

ExtensionsSuccess _twoInstalled() => ExtensionsSuccess(
  repositories: const [],
  installedPlugins: [
    ExtensionPlugin(
      name: 'Plugin A',
      version: 1,
      packageName: 'com.example.a',
      repositoryId: 'test_repo',
      sourceUrl: 'https://example.com/a.js',
    ),
    ExtensionPlugin(
      name: 'Plugin B',
      version: 1,
      packageName: 'com.example.b',
      repositoryId: 'test_repo',
      sourceUrl: 'https://example.com/b.js',
    ),
  ],
  availablePlugins: const {},
  availableUpdates: const {},
  installingPlugins: const {},
);

/// The screen under a provider scope. [visibility] installs the app's own
/// input-aware focus rule over it, the way the app's root does, for the tests
/// that are about which input is driving.
Widget _app(
  ExtensionsState state, {
  bool visibility = false,
  PluginsSegment segment = PluginsSegment.installed,
}) => ProviderScope(
  overrides: [
    pluginsSegmentProvider.overrideWith(() => _StartOn(segment)),
    extensionsControllerProvider.overrideWith(
      () => MockExtensionsController(state),
    ),
    extensionManagerProvider.overrideWith(() => MockExtensionManager()),
    cloudStreamRepositoryProvider.overrideWith(
      () => _LoadedCloudStream(),
    ),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: visibility
        ? const FocusVisibilityScope(child: ExtensionsScreen())
        : const ExtensionsScreen(),
  ),
);

/// One repository, with one plugin to install from it.
ExtensionsSuccess _oneRepository() => ExtensionsSuccess(
  repositories: [
    ExtensionRepository(
      name: 'Test Repo',
      url: 'https://example.com/repo.json',
      pluginLists: const [],
    ),
  ],
  installedPlugins: const [],
  availablePlugins: {
    'https://example.com/repo.json': [
      ExtensionPlugin(
        name: 'Plugin B',
        version: 1,
        packageName: 'com.example.b',
        repositoryId: 'test_repo',
        sourceUrl: 'https://example.com/b.js',
      ),
    ],
  },
  availableUpdates: const {},
  installingPlugins: const {},
);

void _focusAffordanceTests() {
  // The affordance is input-aware: it is drawn for a remote or a keyboard and
  // not for a finger, so a test that means to see it has to say which input
  // it is standing in for. Without this the default on Android resolves to
  // `touch` and every assertion below would be measuring nothing.
  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  testWidgets(
    'focusing one plugin row rings that row and leaves its neighbour plain',
    (WidgetTester tester) async {
      await tester.pumpWidget(_app(_twoInstalled()));
      await tester.pumpAndSettle();

      final scheme = Theme.of(
        tester.element(find.text('Plugin A')),
      ).colorScheme;

      // Nothing focused yet: neither row draws anything.
      expect(_rowLayers(tester, find.text('Plugin A')).ring, isNull);
      expect(_rowLayers(tester, find.text('Plugin B')).ring, isNull);

      final rowB = find.ancestor(
        of: find.text('Plugin B'),
        matching: find.byType(ListTile),
      );
      await _focusOn(
        tester,
        find.descendant(of: rowB, matching: find.byIcon(Icons.delete)),
      );

      final focused = _rowLayers(tester, find.text('Plugin B'));

      // Ring: neutral, the shared width, stroked outside so the row keeps its
      // full content width.
      final ring = focused.ring;
      expect(ring, isNotNull, reason: 'focused row drew no ring');
      final side = (ring!.border! as Border).top;
      expect(
        side.color,
        scheme.onSurface,
        reason: 'a focus ring is neutral; the accent belongs to selection',
      );
      expect(side.width, CardFocusAffordance.ringWidth);
      expect(side.strokeAlign, BorderSide.strokeAlignOutside);

      // Nothing else on that layer: the accent wash that used to sit here
      // recoloured the label the ring is pointing at.
      expect(ring.color, isNull);

      // The lift, on its own layer behind the row, and a plain shadow rather
      // than an accent glow.
      final glow = focused.glow;
      expect(glow, isNotNull, reason: 'focused row drew no lift');
      expect(glow!.boxShadow!.single.color, AppFocus.shadows(focused: true)!.single.color);

      // The neighbour is untouched — this is the whole complaint: from three
      // metres you must be able to tell the fifth row from the fourth.
      expect(_rowLayers(tester, find.text('Plugin A')).ring, isNull);
      expect(_rowLayers(tester, find.text('Plugin A')).glow, isNull);
    },
  );

  testWidgets(
    'the section card stays quiet while a row inside it holds the focus',
    (WidgetTester tester) async {
      await tester.pumpWidget(_app(_twoInstalled()));
      await tester.pumpAndSettle();

      final surface = Theme.of(
        tester.element(find.text('Plugin A')),
      ).colorScheme.surface;

      final rowB = find.ancestor(
        of: find.text('Plugin B'),
        matching: find.byType(ListTile),
      );
      await _focusOn(
        tester,
        find.descendant(of: rowB, matching: find.byIcon(Icons.delete)),
      );

      final card = _cardDecoration(tester, find.text('Plugin B'), surface);
      expect(
        card.boxShadow,
        isNull,
        reason: 'the card around all the plugins glowed for one row of them',
      );
      expect(
        (card.border! as Border).top.width,
        1.0,
        reason: 'the card around all the plugins thickened for one row of them',
      );
    },
  );

  testWidgets(
    'a repository card still lights for its own header, then hands over',
    (WidgetTester tester) async {
      _tallViewport(tester);
      final state = ExtensionsSuccess(
        repositories: [
          ExtensionRepository(
            name: 'Test Repo',
            url: 'https://example.com/repo.json',
            pluginLists: const [],
          ),
        ],
        installedPlugins: const [],
        availablePlugins: {
          'https://example.com/repo.json': [
            ExtensionPlugin(
              name: 'Plugin B',
              version: 1,
              packageName: 'com.example.b',
              repositoryId: 'test_repo',
              sourceUrl: 'https://example.com/b.js',
            ),
          ],
        },
        availableUpdates: const {},
        installingPlugins: const {},
      );

      await tester.pumpWidget(_app(state, segment: PluginsSegment.add));
      await tester.pumpAndSettle();

      final theme = Theme.of(tester.element(find.text('Test Repo')));
      final surface = theme.colorScheme.surface;
      final primary = theme.colorScheme.primary;

      // Expand the repository so its plugin rows exist. The single scroll
      // is taller than the test viewport, so scroll the card into view
      // first — off-screen rows are not built yet.
      await tester.tap(find.text('Test Repo'));
      await tester.pumpAndSettle();

      // The header belongs to the card, so the card is what lights up.
      await _focusOn(tester, find.text('Test Repo'));
      var card = _cardDecoration(tester, find.text('Test Repo'), surface);
      expect((card.border! as Border).top.color, primary);
      expect((card.border! as Border).top.width, 2.0);
      expect(card.boxShadow, isNotNull);

      // Walk down onto a row and the card must hand the affordance over.
      final rowB = find.ancestor(
        of: find.text('Plugin B'),
        matching: find.byType(ListTile),
      );
      await _focusOn(
        tester,
        find.descendant(of: rowB, matching: find.byIcon(Icons.download)),
      );

      card = _cardDecoration(tester, find.text('Plugin B'), surface);
      expect(
        card.boxShadow,
        isNull,
        reason: 'the repository card kept glowing for a row inside it',
      );
      expect((card.border! as Border).top.width, 1.0);
      expect(_rowLayers(tester, find.text('Plugin B')).ring, isNotNull);

      // And back up to the header: the card takes it back.
      await _focusOn(tester, find.text('Test Repo'));
      card = _cardDecoration(tester, find.text('Test Repo'), surface);
      expect(
        card.boxShadow,
        isNotNull,
        reason: 'the card never recovered after a row had the focus',
      );
      expect(_rowLayers(tester, find.text('Plugin B')).ring, isNull);
    },
  );
}


/// The two ways this screen used to throw focus away, and the reason a fresh
/// install read as locked on a television.
///
/// Flutter drops [FocusManager.primaryFocus] to null when the node holding it
/// is disposed, and tells nobody: no listener fires, and `handleKeyMessage`
/// returns early for every key that arrives afterwards. So a screen whose only
/// control destroys itself stops answering the remote completely - not "the
/// button did not highlight" but "no arrow key has anything left to move
/// from". Both paths below do exactly that, and both are on the one journey a
/// first-time viewer has to complete before the app can play anything.
void _tvDeadEndTests() {
  /// Asserts focus is on a real, live control inside the screen body.
  void expectFocusInBody(WidgetTester tester) {
    final primary = FocusManager.instance.primaryFocus;
    expect(primary, isNotNull, reason: 'focus was dropped entirely');
    expect(
      primary,
      isNot(isA<FocusScopeNode>()),
      reason: 'a scope holding focus answers no arrow keys',
    );
    final context = primary!.context;
    expect(context?.mounted, isTrue, reason: 'focused node is not on screen');

    final body = tester.element(find.byType(ListView));
    var inside = false;
    context!.visitAncestorElements((element) {
      if (element != body) return true;
      inside = true;
      return false;
    });
    expect(inside, isTrue, reason: 'focus left the screen body');
  }

  ExtensionsSuccess empty() => const ExtensionsSuccess(
    repositories: [],
    installedPlugins: [],
    availablePlugins: {},
    availableUpdates: {},
    installingPlugins: {},
  );

  ExtensionsSuccess withRepository() => ExtensionsSuccess(
    repositories: [
      ExtensionRepository(
        name: 'Test Repo',
        url: 'https://example.com/repo.json',
        pluginLists: const [],
      ),
    ],
    installedPlugins: const [],
    availablePlugins: const {},
    availableUpdates: const {},
    installingPlugins: const {},
  );

  Widget hostFor(MutableExtensionsController controller) => ProviderScope(
    overrides: [
      // The Add Repository field and rows live under "Add Plugins" (v5).
      pluginsSegmentProvider.overrideWith(() => _StartOn(PluginsSegment.add)),
      extensionsControllerProvider.overrideWith(() => controller),
      extensionManagerProvider.overrideWith(() => MockExtensionManager()),
      cloudStreamRepositoryProvider.overrideWith(
        () => _LoadedCloudStream(),
      ),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ExtensionsScreen(),
    ),
  );

  testWidgets('the add-repository row carries focus into the dialog it opens', (
    tester,
  ) async {
    _tallViewport(tester);
    await tester.pumpWidget(hostFor(MutableExtensionsController(empty())));
    await tester.pumpAndSettle();

    // Focus is on the inline card's field, a live control in the body.
    // (The add row itself is a ListTile inside a _FocusableRow whose
    // Focus cannot request focus, so the field is the control to stand
    // on here.)
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expectFocusInBody(tester);

    // The ZoroX section's add row is the one control that opens a new
    // view (the add-repository dialog); opening it must carry focus
    // into the dialog, not drop it.
    final add = find.widgetWithText(ListTile, 'Add Repository');
    expect(add, findsOneWidget);
    await tester.tap(add);
    await tester.pumpAndSettle();

    // The dialog is open and its field holds the focus.
    expect(find.byType(AlertDialog), findsOneWidget);
    final primary = FocusManager.instance.primaryFocus;
    expect(primary, isNotNull, reason: 'focus was dropped entirely');
    expect(primary!.context?.mounted, isTrue);
  });

  testWidgets('adding the first repository does not strand the remote', (
    tester,
  ) async {
    _tallViewport(tester);
    final controller = MutableExtensionsController(empty());
    await tester.pumpWidget(hostFor(controller));
    await tester.pumpAndSettle();

    // Focus is on the inline card's field, a live control in the body.
    // (The add row itself is a ListTile inside a _FocusableRow whose
    // Focus cannot request focus, so the field is the control to stand
    // on here.)
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expectFocusInBody(tester);

    // The repository lands. The empty "No SkyStream repos yet" text is
    // replaced by the repository card below the field — the field itself
    // stays, and the focus on it must stay live.
    controller.push(withRepository());
    await tester.pumpAndSettle();

    expect(find.text('Test Repo'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Add Repository'), findsOneWidget);
    expectFocusInBody(tester);
  });

  // A repository's address or code is not a word - see CustomTextField.
  testWidgets('the add repository field takes an address', (tester) async {
    final controller = MutableExtensionsController(empty());
    await tester.pumpWidget(hostFor(controller));
    await tester.pumpAndSettle();

    // The preview's inline Add Repository card: its field is the add
    // flow now, not a dialog's.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.keyboardType, TextInputType.url);
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
  });
}
