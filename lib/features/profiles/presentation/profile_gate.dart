import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../account/data/zorox_account_notifier.dart';
import '../../../core/router/app_router.dart';
import '../data/zeus_profile.dart';
import '../data/zeus_profiles_notifier.dart';
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
/// It shows the picker when: logged in **and** the profile list is
/// non-empty **and** no profile is active for this cold start.
/// (Logged-out users never see it.) When the server has no profiles yet
/// it shows the first-profile setup instead, and the migration runs from
/// there.
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

  bool _playerOnTop() {
    try {
      return playerRouteIsOnTop(widget.router);
    } catch (_) {
      // Unknown: assume it is, and leave playback alone.
      return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(zoroxAccountProvider);
    final profiles = ref.watch(zeusProfilesProvider);

    // Logged out (or the account changed under us): the gate's own
    // state belongs to the old session. Clear it after this frame.
    if (!account.loggedIn && (_pinFor != null || _creating)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _pinFor = null;
          _creating = false;
        });
      });
    }

    Widget? overlay;
    if (account.loggedIn && !_playerOnTop()) {
      // A profile deleted on another device must not keep its PIN pad up.
      final pinFor = _pinFor != null &&
              profiles.profiles.any((p) => p.id == _pinFor!.id)
          ? _pinFor
          : null;
      if (profiles.needsDefaultPin && !profiles.loading) {
        overlay = ZeusProfileCreateScreen(
          key: const ValueKey('profile-gate-first'),
          isFirstProfile: true,
          onCreated: (name, color, pin) async {
            final profile = await ref
                .read(zoroxAccountProvider.notifier)
                .completeZeusProfileMigration(
                  name: name,
                  color: color,
                  pin: pin,
                );
            return profile != null;
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
              return true;
            }
            return false;
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

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (overlay != null) Positioned.fill(child: overlay),
      ],
    );
  }
}
