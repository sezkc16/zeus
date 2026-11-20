import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/notification_service.dart';
import '../../app_lock/app_lock_passcode_flow.dart';
import '../../app_lock/app_lock_provider.dart';
import '../../account/data/zorox_account_notifier.dart';
import '../data/zeus_profile.dart';
import '../data/zeus_profiles_notifier.dart';
import 'profile_create_screen.dart';
import 'profile_photo_picker.dart';
import 'profile_pin_screen.dart';
import 'zeus_profile_avatar.dart';

/// Manage profiles (Build 2): the list, and one profile's edit screen —
/// rename, recolour, change PIN, delete.
///
/// Change PIN and delete are the guarded actions: logged in, the account
/// password is asked first (the server verifies it); logged out
/// (local-only profile), the profile's own PIN is confirmed first
/// through the PIN pad. The last profile can never be deleted, and
/// deleting the active profile switches to the first remaining one.
class ZeusManageProfilesScreen extends ConsumerWidget {
  const ZeusManageProfilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(zeusProfilesProvider);
    final canAddMore = profiles.profiles.length < kZeusProfileMaxCount;

    return Scaffold(
      appBar: AppBar(title: const Text('Manage profiles')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final profile in profiles.profiles)
            Card(
              child: ListTile(
                key: ValueKey('manage-profile-${profile.id}'),
                leading: ZeusProfileAvatar(profile: profile, size: 48),
                title: Text(profile.name),
                subtitle: const Text('PIN set'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) =>
                        ZeusProfileEditScreen(profileId: profile.id),
                  ),
                ),
              ),
            ),
          if (canAddMore)
            Card(
              child: ListTile(
                key: const ValueKey('manage-add-profile'),
                leading: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(48 * 0.22),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      width: 1.5,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.add_rounded, size: 26),
                ),
                title: const Text('Add profile'),
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => ZeusProfileCreateScreen(
                      isFirstProfile: false,
                      onCancel: () => Navigator.of(context).pop(),
                      onCreated: (name, color, pin) async {
                        final created = await ref
                            .read(zeusProfilesProvider.notifier)
                            .createZeusProfile(
                              name: name,
                              color: color,
                              pin: pin,
                            );
                        if (created != null && context.mounted) {
                          // The create screen never pops itself; the
                          // caller removes it on success.
                          Navigator.of(context).pop();
                        }
                        return created;
                      },
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          Text(
            'Each profile has its own Continue Watching and My List. '
            'Deleting a profile also deletes its history, My List and photo.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class ZeusProfileEditScreen extends ConsumerStatefulWidget {
  const ZeusProfileEditScreen({required this.profileId, super.key});

  final String profileId;

  @override
  ConsumerState<ZeusProfileEditScreen> createState() =>
      _ZeusProfileEditScreenState();
}

class _ZeusProfileEditScreenState extends ConsumerState<ZeusProfileEditScreen> {
  late final TextEditingController _nameController;
  String _color = kZeusProfileDefaultColor;
  bool _busy = false;
  bool _deleting = false;
  String? _error;
  int _padKey = 0;

  /// The new-PIN pad is up, after the auth gate passed.
  bool _changingPin = false;

  /// The account password collected by the auth gate (logged in only);
  /// null for a local-only profile. Cleared after the PIN change.
  String? _confirmedPassword;

  @override
  void initState() {
    super.initState();
    final profile = _currentProfile(ref.read(zeusProfilesProvider));
    _nameController = TextEditingController(text: profile?.name ?? '');
    _color = profile?.color ?? kZeusProfileDefaultColor;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  ZeusProfile? _currentProfile(ZeusProfilesState state) {
    for (final p in state.profiles) {
      if (p.id == widget.profileId) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(zeusProfilesProvider);
    final profile = _currentProfile(profiles);
    final account = ref.watch(zoroxAccountProvider);

    // Deleted on another device (or just now): leave.
    if (profile == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    final isLastProfile = profiles.profiles.length <= 1;
    final nameChanged = _nameController.text.trim() != profile.name;
    final colorChanged = _color != profile.color;
    final error = _error ?? profiles.error;

    return Scaffold(
      appBar: AppBar(title: Text(profile.name)),
      body: _changingPin
          ? _buildChangePin(context, profile)
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                // Photo (build 110): tap the avatar to pick a new one
                // from the gallery, take one, or remove it. Local-only.
                Center(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      GestureDetector(
                        onTap: () => pickZeusProfilePhoto(
                          context,
                          ref,
                          profileId: profile.id,
                        ),
                        child: ZeusProfileAvatar(profile: profile),
                      ),
                      Positioned(
                        right: -4,
                        bottom: -4,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              width: 2,
                            ),
                          ),
                          child: const Icon(
                            Icons.camera_alt_rounded,
                            size: 15,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    'Tap the photo to change it',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('profile-edit-name'),
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 20,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                    // Rebuild so Save enables when the name changes.
                    setState(() {});
                  },
                ),
                const SizedBox(height: 24),
                Text(
                  'Colour',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    for (final entry in kZeusProfileColors.entries)
                      _ColourSwatch(
                        key: ValueKey('profile-edit-color-${entry.key}'),
                        color: entry.value,
                        selected: _color == entry.key,
                        onTap: () => setState(() => _color = entry.key),
                      ),
                  ],
                ),
                const SizedBox(height: 32),
                FilledButton(
                  key: const ValueKey('profile-edit-save'),
                  onPressed: _busy || (!nameChanged && !colorChanged)
                      ? null
                      : () => _save(profile),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    error,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 32),
                const Divider(),
                ListTile(
                  key: const ValueKey('profile-edit-change-pin'),
                  leading: const Icon(Icons.key_rounded),
                  title: const Text('Change PIN'),
                  subtitle: Text(
                    account.loggedIn
                        ? 'Needs your Zeus account password'
                        : 'Needs this profile’s current PIN',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _busy ? null : _startChangePin,
                ),
                ListTile(
                  key: const ValueKey('profile-edit-delete'),
                  leading: Icon(
                    Icons.delete_rounded,
                    color: isLastProfile
                        ? Theme.of(context).disabledColor
                        : Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    'Delete profile',
                    style: TextStyle(
                      color: isLastProfile
                          ? Theme.of(context).disabledColor
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                  subtitle: isLastProfile
                      ? const Text('You need at least one profile.')
                      : Text(
                          'Also deletes ${profile.name}’s history and My List.',
                        ),
                  trailing: _deleting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  onTap: (_busy || _deleting || isLastProfile)
                      ? null
                      : () => _delete(profile),
                ),
              ],
            ),
    );
  }

  Widget _buildChangePin(BuildContext context, ZeusProfile profile) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(child: ZeusProfileAvatar(profile: profile)),
        const SizedBox(height: 16),
        Text(
          'Choose a new 4-digit PIN for ${profile.name}',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        AppLockPasscodeFlow(
          key: ValueKey('profile-edit-pin-$_padKey'),
          controller: ref.read(appLockControllerProvider),
          kind: AppLockPasscodeFlowKind.profilePinCreate,
          strings: ZeusProfilePinStrings(defaultTargetPlatform),
          onProfilePinCreated: _submitNewPin,
          onCancel: _busy
              ? null
              : () => setState(() {
                  _changingPin = false;
                  _confirmedPassword = null;
                  _padKey++;
                }),
        ),
        if (_busy) ...[
          const SizedBox(height: 8),
          const Center(child: CircularProgressIndicator()),
        ],
      ],
    );
  }

  Future<void> _save(ZeusProfile profile) async {
    final nameError = zeusProfileNameError(_nameController.text);
    if (nameError != null) {
      setState(() => _error = nameError);
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await ref
        .read(zeusProfilesProvider.notifier)
        .updateZeusProfile(
          profileId: profile.id,
          name: _nameController.text.trim(),
          color: _color,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      setState(
        () =>
            _error = ref.read(zeusProfilesProvider).error ?? 'Could not save.',
      );
      return;
    }
    ref
        .read(notificationServiceProvider)
        .showSuccess('Profile updated.', title: 'Profiles');
  }

  /// The auth gate for Change PIN / Delete: the account password when
  /// logged in (the server verifies it), the profile's own PIN when
  /// logged out (local-only — there is no account password). Returns
  /// the collected account password, or null for a local profile.
  /// Null means the gate was cancelled.
  Future<String?> _passAuthGate(ZeusProfile profile) async {
    final loggedIn = ref.read(zoroxAccountProvider).loggedIn;
    if (loggedIn) {
      return _askAccountPassword();
    }
    // Local-only: confirm the profile's own PIN on its pad. The pad
    // must not switch the profile — it only proves the PIN.
    var confirmed = false;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (routeContext) => ZeusProfilePinScreen(
          profile: profile,
          switchOnUnlock: false,
          onUnlocked: () {
            confirmed = true;
            Navigator.of(routeContext).pop();
          },
          onBack: () => Navigator.of(routeContext).pop(),
        ),
      ),
    );
    return confirmed ? '' : null;
  }

  Future<String?> _askAccountPassword() async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Account password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter your Zeus account password to continue.'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Account password',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => Navigator.of(context).pop(controller.text),
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
    if (password == null || password.isEmpty) return null;
    return password;
  }

  Future<void> _startChangePin() async {
    final profiles = ref.read(zeusProfilesProvider);
    final profile = _currentProfile(profiles);
    if (profile == null) return;
    final password = await _passAuthGate(profile);
    if (password == null || !mounted) return;
    setState(() {
      _confirmedPassword = password.isEmpty ? null : password;
      _changingPin = true;
      _padKey++;
    });
  }

  Future<void> _submitNewPin(String pin) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await ref
        .read(zeusProfilesProvider.notifier)
        .updateZeusProfilePin(
          profileId: widget.profileId,
          newPin: pin,
          accountPassword: _confirmedPassword,
        );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _changingPin = false;
      _confirmedPassword = null;
      _padKey++;
    });
    if (!ok) {
      setState(
        () => _error =
            ref.read(zeusProfilesProvider).error ?? 'Could not change the PIN.',
      );
      return;
    }
    ref
        .read(notificationServiceProvider)
        .showSuccess('PIN changed.', title: 'Profiles');
  }

  Future<void> _delete(ZeusProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${profile.name}?'),
        content: Text(
          'This also deletes ${profile.name}’s Continue Watching and '
          'My List, on this device and in the cloud, and its photo on '
          'this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final password = await _passAuthGate(profile);
    if (password == null || !mounted) return;
    setState(() {
      _deleting = true;
      _error = null;
    });
    final ok = await ref
        .read(zeusProfilesProvider.notifier)
        .deleteZeusProfile(
          profileId: profile.id,
          accountPassword: password.isEmpty ? null : password,
        );
    if (!mounted) return;
    setState(() => _deleting = false);
    if (!ok) {
      setState(
        () => _error =
            ref.read(zeusProfilesProvider).error ?? 'Could not delete.',
      );
      return;
    }
    ref
        .read(notificationServiceProvider)
        .showSuccess(
          '${profile.name} deleted.',
          title: 'Profiles',
          icon: Icons.check_circle_rounded,
        );
    if (mounted) Navigator.of(context).pop();
  }
}

class _ColourSwatch extends StatelessWidget {
  const _ColourSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: selected ? Border.all(color: Colors.white, width: 3) : null,
          boxShadow: selected
              ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8)]
              : null,
        ),
        child: selected
            ? const Icon(Icons.check_rounded, color: Colors.white, size: 22)
            : null,
      ),
    );
  }
}
