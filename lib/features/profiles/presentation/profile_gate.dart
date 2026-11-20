import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../account/data/zorox_account_notifier.dart';
import '../../../core/router/app_router.dart';
import '../data/zeus_profile.dart';
import '../data/zeus_profiles_notifier.dart';
import 'legacy_move_dialog.dart';
import 'profile_create_screen.dart';
import 'profile_picker_screen.dart';
import 'profile_pin_screen.dart';

/// Puts the profile picker over the whole app: the picker (or the PIN
/// pad, or the first-profile setup) while no profile is active, and
/// nothing once one is.
///
/// Sits in `MaterialApp.router`'s builder, between `UpdatePromptHost`
/// and `AppLockGate`, so the app lock wraps it and paints over it: app
/// unlock first, then profile pick. Follows the `AppLockGate` pattern
/// exactly — a `Stack` over the app, stands down over the player, and
/// the app itself is always built underneath.
///
/// It shows the picker when: the profile list is non-empty **and** no
/// profile is active for this cold start — logged in (the account's
/// list) or logged out (the device's local-only list, Build 2). When
/// the list is empty it shows the first-profile setup instead, and the
/// migration runs from there (server migration when logged in, local
/// migration when logged out).
class ProfileGate extends ConsumerStatefulWidget {
  const ProfileGate({required this.router, required this.child, super.key});

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<ProfileGate> createState() => _ProfileGateState();
}

class _ProfileGateState extends ConsumerState<ProfileGate> {
  /// The profile the PIN pad is open for, or null for the picker.
  ZeusProfile? _pinFor;

  /// The create screen is open (the picker's "+" tile).
  bool _creating = false;

  /// The §9-case-3 move prompt was shown this run (Build 2): a Skip
  /// defers it to the next app start, not to the next frame.
  bool _movePromptShown = false;

  bool _playerOnTop() {
    try {
      return playerRouteIsOnTop(widget.router);
    } catch (_) {
      // Unknown: assume it is, and leave playback alone.
      return true;
    }
  }

  /// After a profile is open, ask once per run whether the device's
  /// legacy (pre-profile) data should move into it — design §9 case 3.
  /// Only when logged in with server profiles: local-only users migrate
  /// their legacy data through the first-profile setup instead.
  void _maybeShowMovePrompt() {
    if (_movePromptShown) return;
    final account = ref.read(zoroxAccountProvider);
    final profiles = ref.read(zeusProfilesProvider);
    final active = profiles.activeProfile;
    if (!account.loggedIn ||
        profiles.localMode ||
        !profiles.legacyDataPendingMove ||
        active == null ||
        _playerOnTop()) {
      return;
    }
    _movePromptShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(showZeusLegacyMoveDialog(context, ref, targetProfile: active));
    });
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(zoroxAccountProvider);
    final profiles = ref.watch(zeusProfilesProvider);

    Widget? overlay;
    // Build 2: the gate runs logged out too (local-only profiles). The
    // picker only shows once the list for the current mode is loaded:
    // the server list after login, the local list after
    // [refreshLocalZeusProfiles] — before that, a stale server cache
    // must never flash the wrong picker at a logged-out user.
    final listReady = account.loggedIn || profiles.localMode;
    if (listReady && !_playerOnTop()) {
      // A profile deleted on another device must not keep its PIN pad up.
      final pinFor =
          _pinFor != null && profiles.profiles.any((p) => p.id == _pinFor!.id)
          ? _pinFor
          : null;
      if (profiles.needsDefaultPin && !profiles.loading) {
        overlay = ZeusProfileCreateScreen(
          key: const ValueKey('profile-gate-first'),
          isFirstProfile: true,
          onCreated: (name, color, pin) async {
            if (account.loggedIn) {
              final profile = await ref
                  .read(zoroxAccountProvider.notifier)
                  .completeZeusProfileMigration(
                    name: name,
                    color: color,
                    pin: pin,
                  );
              return profile;
            }
            // Local-only (Build 2): no account, so the first profile is
            // made on this device and the legacy data moves into it.
            final profile = await ref
                .read(zeusProfilesProvider.notifier)
                .completeLocalProfileMigration(
                  name: name,
                  color: color,
                  pin: pin,
                );
            return profile;
          },
        );
      } else if (pinFor != null) {
        overlay = ZeusProfilePinScreen(
          key: ValueKey('profile-gate-pin-${pinFor.id}'),
          profile: pinFor,
          onUnlocked: () {
            if (mounted) setState(() => _pinFor = null);
          },
          onBack: () {
            if (mounted) setState(() => _pinFor = null);
          },
        );
      } else if (_creating) {
        overlay = ZeusProfileCreateScreen(
          key: const ValueKey('profile-gate-create'),
          isFirstProfile: false,
          onCancel: () {
            if (mounted) setState(() => _creating = false);
          },
          onCreated: (name, color, pin) async {
            final profile = await ref
                .read(zeusProfilesProvider.notifier)
                .createZeusProfile(name: name, color: color, pin: pin);
            if (profile != null && mounted) {
              setState(() => _creating = false);
            }
            return profile;
          },
        );
      } else if (profiles.profiles.isNotEmpty &&
          profiles.activeProfileId == null) {
        overlay = ZeusProfilePickerScreen(
          key: const ValueKey('profile-gate-picker'),
          onSelect: (profile) {
            if (mounted) setState(() => _pinFor = profile);
          },
          onCreate: () {
            if (mounted) setState(() => _creating = true);
          },
        );
      }
    }

    if (overlay == null) _maybeShowMovePrompt();

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (overlay != null) Positioned.fill(child: overlay),
      ],
    );
  }
}
