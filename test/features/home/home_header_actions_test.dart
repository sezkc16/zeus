// Build 122: the Home header has three actions, left to right —
// search, a settings gear, the profile avatar. The gear moved back
// here from the profile dropdown (user 2026-11-22: "profile click se
// setting hatao aur search k bagal pr settings icon dalo"): it is the
// search button's twin (same glass circle, same 36pt size) and opens
// the same Settings screen the dropdown row used to open.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zorox/features/home/presentation/widgets/home_header_actions.dart';
import 'package:zorox/features/profiles/data/zeus_profile.dart';
import 'package:zorox/features/profiles/data/zeus_profile_photos_notifier.dart';
import 'package:zorox/features/profiles/data/zeus_profiles_notifier.dart';

ZeusProfile _profile({required String id, required String name}) =>
    ZeusProfile(
      id: id,
      name: name,
      color: 'blue',
      pinRecord: 'v1\$100000\$c2FsdA\$aGFzaA',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1795129000000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1795129000000),
    );

class _FixedProfilesNotifier extends ZeusProfilesNotifier {
  _FixedProfilesNotifier(this._state);

  final ZeusProfilesState _state;

  @override
  ZeusProfilesState build() => _state;
}

class _FixedPhotosNotifier extends ZeusProfilePhotosNotifier {
  @override
  Map<String, String> build() => const {};
}

void main() {
  late FocusNode searchFocusNode;
  late GoRouter router;

  setUp(() {
    searchFocusNode = FocusNode();
    router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            appBar: AppBar(
              actions: [
                HomeHeaderActions(searchFocusNode: searchFocusNode),
              ],
            ),
          ),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('Settings page'))),
        ),
      ],
    );
  });

  tearDown(() {
    searchFocusNode.dispose();
    router.dispose();
  });

  Future<void> pumpHeader(WidgetTester tester) async {
    final state = ZeusProfilesState(
      profiles: [_profile(id: 'p1', name: 'Suresh')],
      activeProfileId: 'p1',
      fetched: true,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          zeusProfilesProvider.overrideWith(
            () => _FixedProfilesNotifier(state),
          ),
          zeusProfilePhotosProvider.overrideWith(
            _FixedPhotosNotifier.new,
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('settings gear sits right beside search, same size', (
    tester,
  ) async {
    await pumpHeader(tester);

    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);

    final searchRect = tester.getRect(
      find.byKey(const ValueKey('home-header-search')),
    );
    final settingsRect = tester.getRect(
      find.byKey(const ValueKey('home-header-settings')),
    );
    final avatarRect = tester.getRect(
      find.byKey(const ValueKey('home-header-avatar')),
    );

    // Same row, same size: the gear is the search button's twin.
    expect(settingsRect.width, searchRect.width);
    expect(settingsRect.height, searchRect.height);
    expect(settingsRect.center.dy, closeTo(searchRect.center.dy, 2));

    // Order left to right: search, settings, avatar.
    expect(settingsRect.center.dx, greaterThan(searchRect.center.dx));
    expect(avatarRect.center.dx, greaterThan(settingsRect.center.dx));
    // The gear hugs the search button (one small gap, not a wide one).
    expect(
      settingsRect.left - searchRect.right,
      lessThanOrEqualTo(16),
    );
  });

  testWidgets('tapping the settings gear opens Settings', (tester) async {
    await pumpHeader(tester);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Settings page'), findsOneWidget);
    expect(router.routerDelegate.currentConfiguration.uri.toString(), '/settings');
  });
}
