// Build 115: the profile switcher sheet ends with Settings — the Home
// header gear is gone, so Add account, Manage accounts and Settings all
// live in the sheet, matching the user's reference.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/profiles/data/zeus_profile.dart';
import 'package:zorox/features/profiles/data/zeus_profile_photos_notifier.dart';
import 'package:zorox/features/profiles/data/zeus_profiles_notifier.dart';
import 'package:zorox/features/profiles/presentation/profile_picker_screen.dart';

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
  Future<void> pumpPicker(
    WidgetTester tester, {
    VoidCallback? onManage,
    VoidCallback? onSettings,
  }) {
    final state = ZeusProfilesState(
      profiles: [
        _profile(id: 'p1', name: 'Suresh'),
        _profile(id: 'p2', name: 'MM'),
      ],
      activeProfileId: 'p1',
      fetched: true,
    );
    return tester.pumpWidget(
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
          home: ZeusProfilePickerScreen(
            onSelect: (_) {},
            onCreate: () {},
            highlightProfileId: 'p1',
            onManage: onManage,
            onSettings: onSettings,
          ),
        ),
      ),
    );
  }

  testWidgets('Settings row shows at the bottom, with Add and Manage', (
    tester,
  ) async {
    var tapped = false;
    await pumpPicker(
      tester,
      onManage: () {},
      onSettings: () => tapped = true,
    );
    await tester.pumpAndSettle();

    // All three sheet rows are visible: Add (the "+" tile), Manage,
    // and the new Settings row.
    expect(find.byKey(const ValueKey('profile-add-tile')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-manage-link')), findsOneWidget);
    final settingsRow = find.byKey(const ValueKey('profile-settings-row'));
    expect(settingsRow, findsOneWidget);
    expect(
      find.descendant(of: settingsRow, matching: find.text('Settings')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: settingsRow,
        matching: find.byIcon(Icons.settings_outlined),
      ),
      findsOneWidget,
    );
    // The row sits below the Manage link.
    final manageY = tester
        .getTopLeft(find.byKey(const ValueKey('profile-manage-link')))
        .dy;
    final settingsY = tester.getTopLeft(settingsRow).dy;
    expect(settingsY, greaterThan(manageY));

    await tester.tap(settingsRow);
    expect(tapped, isTrue);
  });

  testWidgets('no Settings row when onSettings is null (cold-start gate)', (
    tester,
  ) async {
    await pumpPicker(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('profile-settings-row')), findsNothing);
    // The profiles themselves still show.
    expect(find.text('Suresh'), findsOneWidget);
    expect(find.text('MM'), findsOneWidget);
  });
}
