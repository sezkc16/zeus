// Build 118: the profile switcher is a SMALL Liquid Glass dropdown
// anchored top-right just below the header avatar — the 4 rows
// (profiles, Add account, Manage accounts, Settings), no title,
// compact text/icons — not the build-116 centered dialog. Build 118
// shrank the card to ~175pt wide with white foreground text/icons
// (the dark glass washed out the theme's dark text on light themes).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/profiles/data/zeus_profile.dart';
import 'package:zorox/features/profiles/data/zeus_profile_photos_notifier.dart';
import 'package:zorox/features/profiles/data/zeus_profiles_notifier.dart';
import 'package:zorox/features/profiles/presentation/profile_switcher_screen.dart';

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
  Future<void> pumpDialog(
    WidgetTester tester, {
    List<ZeusProfile>? profiles,
  }) async {
    final state = ZeusProfilesState(
      profiles:
          profiles ??
          [_profile(id: 'p1', name: 'Suresh'), _profile(id: 'p2', name: 'MM')],
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
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showZeusProfileSwitcher(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('dropdown shows the 4 rows: profiles, Add, Manage, Settings', (
    tester,
  ) async {
    await pumpDialog(tester);

    // No title in the dropdown (build 117): the 4 rows are the content.
    expect(find.text('Switch account'), findsNothing);
    expect(find.text('Suresh'), findsOneWidget);
    expect(find.text('MM'), findsOneWidget);
    // Only the active profile has the gold check.
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-switch-add')), findsOneWidget);
    expect(find.text('Add account'), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-switch-manage')), findsOneWidget);
    expect(find.text('Manage accounts'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('profile-switch-settings')),
      findsOneWidget,
    );
    expect(find.text('Settings'), findsOneWidget);

    // Small dropdown, top-right just below the header (not centered,
    // not full-screen): the test viewport is 800x600 with no status
    // bar, so the card sits ~54pt from the top, hugs the right edge,
    // and is narrow and short. Build 118 shrank it further (~185pt
    // wide, ~181pt tall here with 2 profiles + 3 actions) from the
    // build-117 ~300pt card.
    final cardRect = tester.getRect(
      find.byKey(const ValueKey('profile-switch-card')),
    );
    expect(cardRect.top, greaterThan(40));
    expect(cardRect.top, lessThan(90));
    expect(cardRect.right, greaterThan(750));
    expect(cardRect.width, lessThanOrEqualTo(190));
    expect(cardRect.height, lessThan(200));
  });

  testWidgets('tapping the active profile closes the dialog', (
    tester,
  ) async {
    await pumpDialog(tester);

    await tester.tap(find.byKey(const ValueKey('profile-switch-row-p1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('profile-switch-card')), findsNothing);
  });

  testWidgets('no Add account row at the 5-profile cap', (tester) async {
    await pumpDialog(
      tester,
      profiles: [
        _profile(id: 'p1', name: 'One'),
        _profile(id: 'p2', name: 'Two'),
        _profile(id: 'p3', name: 'Three'),
        _profile(id: 'p4', name: 'Four'),
        _profile(id: 'p5', name: 'Five'),
      ],
    );

    expect(find.byKey(const ValueKey('profile-switch-add')), findsNothing);
    // The other rows still show.
    expect(find.text('Manage accounts'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });
}
