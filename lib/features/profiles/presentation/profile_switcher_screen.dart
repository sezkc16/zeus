import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/data/zorox_account_notifier.dart';
import '../data/zeus_profile.dart';
import '../data/zeus_profiles_notifier.dart';
import 'manage_profiles_screen.dart';
import 'profile_create_screen.dart';
import 'profile_picker_screen.dart';
import 'profile_pin_screen.dart';

/// Opens the Netflix-style profile switcher as a full-screen page: the
/// same picker the cold-start gate shows (grid, "+" tile, "Manage
/// profiles"), with the active profile check-marked.
///
/// Used by the Home avatar tile and the Settings → Accounts "Switch
/// profile" row. Unlike the gate it can always be closed (a profile is
/// already active), and after a PIN unlock it runs one sync round for
/// the new profile (logged in only) before closing.
Future<void> showZeusProfileSwitcher(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const ZeusProfileSwitcherScreen(),
    ),
  );
}

class ZeusProfileSwitcherScreen extends ConsumerStatefulWidget {
  const ZeusProfileSwitcherScreen({super.key});

  @override
  ConsumerState<ZeusProfileSwitcherScreen> createState() =>
      _ZeusProfileSwitcherScreenState();
}

class _ZeusProfileSwitcherScreenState
    extends ConsumerState<ZeusProfileSwitcherScreen> {
  /// The profile the PIN pad is open for, or null for the picker.
  ZeusProfile? _pinFor;

  /// The create screen is open (the picker's "+" tile).
  bool _creating = false;

  void _close() {
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _openManage() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => const ZeusManageProfilesScreen(),
      ),
    );
    // The list may have changed (rename/delete) — rebuild to match.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(zeusProfilesProvider);
    final account = ref.watch(zoroxAccountProvider);

    Widget body;
    if (_pinFor != null) {
      final pinFor = _pinFor!;
      body = ZeusProfilePinScreen(
        key: ValueKey('profile-switch-pin-${pinFor.id}'),
        profile: pinFor,
        switchOnUnlock: true,
        onUnlocked: () {
          // The PIN screen already switched the profile; one sync round
          // for it (logged in only), then close. The round runs in the
          // background — the user is already home.
          if (account.loggedIn) {
            unawaited(
              ref
                  .read(zoroxAccountProvider.notifier)
                  .syncActiveZeusProfile(),
            );
          }
          _close();
        },
        onBack: () {
          if (mounted) setState(() => _pinFor = null);
        },
      );
    } else if (_creating) {
      body = ZeusProfileCreateScreen(
        key: const ValueKey('profile-switch-create'),
        isFirstProfile: false,
        onCancel: () {
          if (mounted) setState(() => _creating = false);
        },
        onCreated: (name, color, pin) async {
          final profile = await ref
              .read(zeusProfilesProvider.notifier)
              .createZeusProfile(name: name, color: color, pin: pin);
          if (profile != null && mounted) {
            // Back to the picker: the new tile is there, its PIN opens it.
            setState(() => _creating = false);
            return true;
          }
          return false;
        },
      );
    } else {
      body = ZeusProfilePickerScreen(
        key: const ValueKey('profile-switch-picker'),
        highlightProfileId: profiles.activeProfileId,
        onSelect: (profile) {
          if (profile.id == profiles.activeProfileId) {
            // Already on this profile — nothing to switch to.
            _close();
            return;
          }
          if (mounted) setState(() => _pinFor = profile);
        },
        onCreate: () {
          if (mounted) setState(() => _creating = true);
        },
        onManage: _openManage,
      );
    }

    // The picker, PIN and create screens are full-screen Materials
    // with their own titles and back/close buttons — the switcher only
    // adds a close button over the picker state (the other two already
    // have one). No AppBar: it would double the screens' own titles.
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
        if (_pinFor == null && !_creating)
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 8, top: 8),
                child: IconButton(
                  key: const ValueKey('profile-switch-close'),
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _close,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
