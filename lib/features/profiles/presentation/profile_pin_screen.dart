import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_lock/app_lock_passcode_flow.dart';
import '../../app_lock/app_lock_provider.dart';
import '../../app_lock/app_lock_strings.dart';
import '../data/zeus_profile.dart';
import '../data/zeus_profiles_notifier.dart';
import 'zeus_profile_avatar.dart';

/// The profile PIN pad's wording: "PIN", not "passcode" — the user sets
/// a profile PIN, and the app lock's "passcode" is a different thing.
class ZeusProfilePinStrings extends AppLockStrings {
  const ZeusProfilePinStrings(super.platform);

  @override
  String get enterPasscode => 'Enter PIN';
  @override
  String get enterNew => 'Choose a 4-digit PIN';
  @override
  String get confirmNew => 'Enter it again';
  @override
  String get mismatch => 'PINs did not match. Try again.';
  @override
  String get wrong => 'Wrong PIN';
  @override
  String tryAgainIn(Duration wait) {
    final s = wait.inSeconds < 1 ? 1 : wait.inSeconds;
    final text = s >= 60
        ? '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}'
        : '$s s';
    return 'Too many wrong tries. Try again in $text';
  }

  @override
  String get forgot => 'Forgot PIN?';
  @override
  String get saveFailed => 'Could not save the PIN. Try again.';
}

/// The 4-digit PIN screen for one profile: avatar + name, the shared
/// number pad, "Forgot PIN?".
///
/// The PIN is checked on this device against the cached record, so it
/// works offline. "Forgot PIN?" asks for the account password, then a new
/// PIN — the server verifies the password before accepting the new
/// record, so a person holding the unlocked device cannot re-lock a
/// profile. After a reset the profile opens straight away: the account
/// password is a stronger proof than the PIN it replaces.
class ZeusProfilePinScreen extends ConsumerStatefulWidget {
  const ZeusProfilePinScreen({
    required this.profile,
    required this.onUnlocked,
    this.onBack,
    super.key,
  });

  final ZeusProfile profile;

  /// Called once the profile is open (PIN right, or PIN just reset).
  final VoidCallback onUnlocked;

  /// Shows a back button when set (the picker); the gate omits it when
  /// there is nowhere to go back to.
  final VoidCallback? onBack;

  @override
  ConsumerState<ZeusProfilePinScreen> createState() =>
      _ZeusProfilePinScreenState();
}

class _ZeusProfilePinScreenState
    extends ConsumerState<ZeusProfilePinScreen> {
  /// Forgot-PIN step: the account password, then a new PIN.
  String? _forgotPassword;
  bool _forgotBusy = false;
  String? _forgotError;
  int _padKey = 0;

  ZeusProfile get _profile => widget.profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profiles = ref.watch(zeusProfilesProvider);
    final notifier = ref.read(zeusProfilesProvider.notifier);

    // A profile that has never been opened on this device has no cached
    // record offline: its PIN cannot be checked until one online open
    // fetches it. (Online, the fetch has already run by the time the
    // picker shows.)
    if (!_profile.hasPinRecord) {
      return _PinScaffold(
        onBack: widget.onBack,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ZeusProfileAvatar(profile: _profile),
            const SizedBox(height: 16),
            Text(
              _profile.name,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'This profile needs one online open first — its PIN is not on this device yet.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    final isResettingPin = _forgotPassword != null;
    return _PinScaffold(
      onBack: widget.onBack,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ZeusProfileAvatar(profile: _profile),
          const SizedBox(height: 16),
          Text(
            _profile.name,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (_forgotError != null) ...[
            const SizedBox(height: 8),
            Text(
              _forgotError!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (profiles.error != null && !isResettingPin) ...[
            const SizedBox(height: 8),
            Text(
              profiles.error!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (isResettingPin)
            AppLockPasscodeFlow(
              key: ValueKey('profile-pin-reset-$_padKey'),
              controller: ref.read(appLockControllerProvider),
              kind: AppLockPasscodeFlowKind.profilePinCreate,
              strings: ZeusProfilePinStrings(defaultTargetPlatform),
              onProfilePinCreated: (pin) =>
                  _resetPin(notifier, _forgotPassword!, pin),
              onCancel: _forgotBusy
                  ? null
                  : () => setState(() {
                      _forgotPassword = null;
                      _forgotError = null;
                      _padKey++;
                    }),
            )
          else
            AppLockPasscodeFlow(
              key: ValueKey('profile-pin-${_profile.id}-$_padKey'),
              controller: ref.read(appLockControllerProvider),
              kind: AppLockPasscodeFlowKind.profilePin,
              strings: ZeusProfilePinStrings(defaultTargetPlatform),
              verifyProfilePin: (pin) =>
                  notifier.checkZeusProfilePin(_profile.id, pin),
              profilePinBlockedFor: () =>
                  notifier.blockedForZeusProfile(_profile.id),
              onForgotProfilePin: () => _askForgotPassword(context),
              onDone: () async {
                await notifier.switchZeusProfile(_profile.id);
                if (mounted) widget.onUnlocked();
              },
            ),
        ],
      ),
    );
  }

  Future<void> _askForgotPassword(BuildContext context) async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forgot PIN?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter your Zeus account password to set a new PIN for this profile.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Account password',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) =>
                  Navigator.of(context).pop(controller.text),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (password == null || password.isEmpty || !mounted) return;
    setState(() {
      _forgotPassword = password;
      _forgotError = null;
      _padKey++;
    });
  }

  Future<void> _resetPin(
    ZeusProfilesNotifier notifier,
    String accountPassword,
    String newPin,
  ) async {
    if (_forgotBusy) return;
    setState(() {
      _forgotBusy = true;
      _forgotError = null;
    });
    final ok = await notifier.updateZeusProfilePin(
      profileId: _profile.id,
      newPin: newPin,
      accountPassword: accountPassword,
    );
    if (!mounted) return;
    setState(() => _forgotBusy = false);
    if (!ok) {
      // Wrong password (or offline): back to the PIN pad with the reason.
      setState(() {
        _forgotPassword = null;
        _forgotError =
            ref.read(zeusProfilesProvider).error ?? 'Could not reset the PIN.';
        _padKey++;
      });
      return;
    }
    // The account password proved ownership: open the profile.
    await notifier.switchZeusProfile(_profile.id);
    if (mounted) widget.onUnlocked();
  }
}

/// The PIN screen's frame: a dark full-screen page with an optional back
/// button, centred content. The gate paints it over the app, like the
/// app lock paints its pad.
class _PinScaffold extends StatelessWidget {
  const _PinScaffold({required this.child, this.onBack});

  final Widget child;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Stack(
          children: [
            if (onBack != null)
              Positioned(
                top: 8,
                left: 8,
                child: IconButton(
                  key: const ValueKey('profile-pin-back'),
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: onBack,
                ),
              ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
