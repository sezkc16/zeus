import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app_lock/app_lock_passcode_flow.dart';
import '../../app_lock/app_lock_provider.dart';
import '../data/zeus_profile.dart';
import '../data/zeus_profile_photos_notifier.dart';
import '../data/zeus_profiles_notifier.dart';
import 'profile_photo_picker.dart';
import 'profile_pin_screen.dart';
import 'zeus_profile_avatar.dart';

/// Add a profile: a name, a palette colour, and a 4-digit PIN (required
/// — every profile has one).
///
/// Two steps: name + colour, then the PIN pad (typed twice). The caller
/// ([onCreated]) creates the profile — for the picker's "+" tile that is
/// a plain create; for the first profile it is the migration, which also
/// moves the current Continue Watching / My List into it. The screen
/// stays up (with the reason) when creation fails.
///
/// For the first profile there is no way out of this screen: a logged-in
/// account has profiles, and the first one needs its PIN before the app
/// can be used. (Logging out is the way back, from Settings — the gate
/// never offers it over the picker.)
class ZeusProfileCreateScreen extends ConsumerStatefulWidget {
  const ZeusProfileCreateScreen({
    required this.isFirstProfile,
    required this.onCreated,
    this.onCancel,
    super.key,
  });

  final bool isFirstProfile;

  /// Creates the profile from the collected name, colour and PIN.
  /// Returns the created profile, or null when creation failed; the
  /// screen shows the profiles/account error and stays up on null.
  /// (Build 110: the created profile is returned so a photo picked on
  /// this screen can be saved against its id.)
  final Future<ZeusProfile?> Function(String name, String color, String pin)
  onCreated;

  /// Shows a Cancel button when set (the "+" tile). The first profile
  /// has none.
  final VoidCallback? onCancel;

  @override
  ConsumerState<ZeusProfileCreateScreen> createState() =>
      _ZeusProfileCreateScreenState();
}

class _ZeusProfileCreateScreenState
    extends ConsumerState<ZeusProfileCreateScreen> {
  late final TextEditingController _nameController;
  String _color = kZeusProfileDefaultColor;
  bool _pinStep = false;
  bool _busy = false;
  String? _error;
  int _padKey = 0;

  /// A photo picked for the new profile (build 110): saved against the
  /// created profile's id in [_submit]. Null means the colour/initial
  /// avatar.
  XFile? _pendingPhoto;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.isFirstProfile ? kZeusProfileDefaultName : '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profilesError = ref.watch(
      zeusProfilesProvider.select((s) => s.error),
    );
    final error = _error ?? profilesError;

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (_pinStep)
                    IconButton(
                      key: const ValueKey('profile-create-back'),
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _pinStep = false;
                              _error = null;
                            }),
                    )
                  else if (widget.onCancel != null)
                    IconButton(
                      key: const ValueKey('profile-create-cancel'),
                      icon: const Icon(Icons.close_rounded),
                      onPressed: widget.onCancel,
                    ),
                  Expanded(
                    child: Text(
                      widget.isFirstProfile
                          ? 'Create your first profile'
                          : 'Add profile',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                widget.isFirstProfile
                    ? 'Your current Continue Watching and My List move into this profile.'
                    : 'Each profile has its own Continue Watching and My List.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              if (!_pinStep) ...[
                // Photo (build 110): tap the avatar to pick from the
                // gallery or take a photo. Local-only, saved on submit.
                Center(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      GestureDetector(
                        onTap: _pickPhoto,
                        child: ZeusProfileAvatar(
                          // A preview profile: the id is empty (no
                          // profile exists yet), so the avatar shows the
                          // pending photo, else the colour/initial.
                          profile: ZeusProfile(
                            id: '',
                            name: _nameController.text.trim(),
                            color: _color,
                            pinRecord: '',
                            createdAt: DateTime.now(),
                            updatedAt: DateTime.now(),
                          ),
                          photoPath: _pendingPhoto?.path,
                        ),
                      ),
                      Positioned(
                        right: -4,
                        bottom: -4,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.scaffoldBackgroundColor,
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
                if (_pendingPhoto != null)
                  TextButton(
                    onPressed: () => setState(() => _pendingPhoto = null),
                    child: const Text('Remove photo'),
                  ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('profile-create-name'),
                  controller: _nameController,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 20,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                  onChanged: (_) {
                    // The avatar preview's initial follows the name.
                    setState(() => _error = null);
                  },
                  onSubmitted: (_) => _continue(),
                ),
                const SizedBox(height: 24),
                Text(
                  'Colour',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    for (final entry in kZeusProfileColors.entries)
                      _ColourSwatch(
                        key: ValueKey('profile-color-${entry.key}'),
                        color: entry.value,
                        selected: _color == entry.key,
                        onTap: () => setState(() => _color = entry.key),
                      ),
                  ],
                ),
                const SizedBox(height: 32),
                FilledButton(
                  key: const ValueKey('profile-create-continue'),
                  onPressed: _continue,
                  child: const Text('Continue'),
                ),
              ] else ...[
                Text(
                  'Set a 4-digit PIN for ${_nameController.text.trim().isEmpty ? 'this profile' : _nameController.text.trim()}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                AppLockPasscodeFlow(
                  key: ValueKey('profile-create-pin-$_padKey'),
                  controller: ref.read(appLockControllerProvider),
                  kind: AppLockPasscodeFlowKind.profilePinCreate,
                  strings: ZeusProfilePinStrings(defaultTargetPlatform),
                  onProfilePinCreated: _submit,
                  onCancel: widget.onCancel != null && !_busy
                      ? widget.onCancel
                      : null,
                ),
                if (_busy) ...[
                  const SizedBox(height: 8),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
              if (error != null) ...[
                const SizedBox(height: 16),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _continue() {
    final error = zeusProfileNameError(_nameController.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _error = null;
      _pinStep = true;
    });
  }

  Future<void> _pickPhoto() async {
    final picked = await pickZeusProfilePhoto(context, ref);
    if (picked != null && mounted) {
      setState(() => _pendingPhoto = picked);
    }
  }

  Future<void> _submit(String pin) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final profile = await widget.onCreated(
      _nameController.text.trim(),
      _color,
      pin,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (profile == null) {
      // The caller put the reason in the profiles/account error; keep
      // the pad up so the PIN can be typed again.
      setState(() {
        _error ??= 'Could not create the profile. Try again.';
        _padKey++;
      });
      return;
    }
    // A photo picked on this screen is saved against the new id.
    if (_pendingPhoto != null) {
      await ref
          .read(zeusProfilePhotosProvider.notifier)
          .savePhoto(profile.id, _pendingPhoto!);
    }
    // On success the gate moves on (the picker, or straight into the
    // profile) and this screen is gone.
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
