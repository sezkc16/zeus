import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/zeus_profile.dart';
import '../data/zeus_profiles_notifier.dart';
import 'zeus_profile_avatar.dart';

/// The Netflix-style "Who's watching?" picker: a grid of avatar tiles,
/// a "+" tile to add a profile (up to 5), each profile's own Continue
/// Watching / My List behind its PIN.
///
/// The gate paints this over the app at cold start (logged in, profiles
/// known, none active yet). Tapping a tile asks for that profile's PIN;
/// the picker itself never opens a profile.
class ZeusProfilePickerScreen extends ConsumerWidget {
  const ZeusProfilePickerScreen({
    required this.onSelect,
    required this.onCreate,
    this.highlightProfileId,
    this.onManage,
    super.key,
  });

  final ValueChanged<ZeusProfile> onSelect;
  final VoidCallback onCreate;

  /// The profile to mark as active (a check badge): the switcher shows
  /// it, the cold-start gate has no active profile and leaves it null.
  final String? highlightProfileId;

  /// Shows a "Manage profiles" footer link when set (the switcher). The
  /// cold-start gate leaves it null — there is nothing to manage before
  /// a profile is open.
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(zeusProfilesProvider);
    final canAddMore = state.profiles.length < kZeusProfileMaxCount;

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Text(
                "Who's watching?",
                key: const ValueKey('profile-picker-title'),
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Each profile has its own Continue Watching and My List.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (state.error != null) ...[
                const SizedBox(height: 12),
                Text(
                  state.error!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 32),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 3,
                  mainAxisSpacing: 24,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.8,
                  children: [
                    for (final profile in state.profiles)
                      _PickerTile(
                        key: ValueKey('profile-tile-${profile.id}'),
                        profile: profile,
                        highlighted: profile.id == highlightProfileId,
                        onTap: () => onSelect(profile),
                      ),
                    if (canAddMore)
                      _AddTile(
                        key: const ValueKey('profile-add-tile'),
                        onTap: onCreate,
                      ),
                  ],
                ),
              ),
              if (onManage != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  key: const ValueKey('profile-manage-link'),
                  onPressed: onManage,
                  child: const Text('Manage profiles'),
                ),
              ],
              Text(
                'Max $kZeusProfileMaxCount profiles — each with its own 4-digit PIN.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({
    required this.profile,
    required this.onTap,
    this.highlighted = false,
    super.key,
  });

  final ZeusProfile profile;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              ZeusProfileAvatar(profile: profile),
              if (highlighted)
                Positioned(
                  right: -4,
                  top: -4,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: theme.scaffoldBackgroundColor,
                        width: 2,
                      ),
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            profile.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap, super.key});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(76 * 0.22),
              border: Border.all(
                color: theme.colorScheme.onSurfaceVariant,
                width: 1.5,
              ),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.add_rounded,
              size: 36,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add profile',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
