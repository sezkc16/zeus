import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/matte_glass_pill.dart';
import '../../account/data/zorox_account_notifier.dart';
import '../data/zeus_profile.dart';
import '../data/zeus_profiles_notifier.dart';
import 'manage_profiles_screen.dart';
import 'profile_create_screen.dart';
import 'profile_pin_screen.dart';
import 'zeus_profile_avatar.dart';

/// Opens the profile switcher as a SMALL Liquid Glass dropdown
/// anchored top-right just below the Home header avatar (build 117,
/// shrunk further in build 118): the same 3 rows the user approved —
/// profile rows, Add account, Manage accounts — in a compact card,
/// no title, with the blurred Home showing through the glass.
/// This replaces the build-116 centered dialog (whose 0.78-alpha card
/// was a solid dark slab, not glass, and whose text/icons were too
/// big). Build 118 shrinks the card to ~175pt wide (the build-117
/// card was ~300pt — the user: "aur chota karo") and uses white
/// foreground text/icons, because the card is a dark glass: the
/// theme's dark onSurface text on light themes washed out on it.
/// Build 122 removed the Settings row (user: "profile click se setting
/// hatao") — Settings moved back to the gear beside the search icon
/// in the Home header (HomeHeaderActions).
///
/// Used by the Home avatar tile and the Settings → Accounts "Switch
/// profile" row. The barrier is transparent, so the Home stays sharp
/// outside the card; tap outside (or the active profile) to dismiss.
/// The PIN / create / manage steps still open as full-screen pages
/// above the dropdown, so Back returns to the list.
Future<void> showZeusProfileSwitcher(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, _, _) => const ZeusProfileSwitchDialog(),
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
          alignment: Alignment.topRight,
          child: child,
        ),
      );
    },
  );
}

class ZeusProfileSwitchDialog extends ConsumerStatefulWidget {
  const ZeusProfileSwitchDialog({super.key});

  @override
  ConsumerState<ZeusProfileSwitchDialog> createState() =>
      _ZeusProfileSwitchDialogState();
}

class _ZeusProfileSwitchDialogState
    extends ConsumerState<ZeusProfileSwitchDialog> {
  void _close() {
    if (mounted) Navigator.of(context).pop();
  }

  /// A profile row (not the active one): the PIN pad opens as a
  /// full-screen page above the dialog. On unlock the PIN route and
  /// the dialog both close; Back returns to the dialog list.
  Future<void> _openPin(ZeusProfile profile) async {
    final account = ref.read(zoroxAccountProvider);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ZeusProfilePinScreen(
          profile: profile,
          switchOnUnlock: true,
          onUnlocked: () {
            // The PIN screen already switched the profile; one sync
            // round for it (logged in only), then close. Two pops: the
            // PIN route is on top, the dialog under it.
            if (account.loggedIn) {
              unawaited(
                ref
                    .read(zoroxAccountProvider.notifier)
                    .syncActiveZeusProfile(),
              );
            }
            Navigator.of(context).pop();
            Navigator.of(context).pop();
          },
          onBack: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  /// "Add account": the create form opens above the dialog. On success
  /// the create route closes (the new profile is in the list, its PIN
  /// opens it); on failure the form stays up with the reason. The pop
  /// runs inside onCreated, before it returns the profile — the create
  /// screen's _submit resumes in a microtask first, so a picked photo
  /// is still saved against the new id.
  Future<void> _openCreate() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ZeusProfileCreateScreen(
          isFirstProfile: false,
          onCancel: () => Navigator.of(context).pop(),
          onCreated: (name, color, pin) async {
            final profile = await ref
                .read(zeusProfilesProvider.notifier)
                .createZeusProfile(name: name, color: color, pin: pin);
            if (profile != null && mounted) {
              Navigator.of(context).pop();
            }
            return profile;
          },
        ),
      ),
    );
    // The list may have changed — rebuild to match (the provider watch
    // already does this; the setState is a belt-and-braces).
    if (mounted) setState(() {});
  }

  /// "Manage accounts": the manage screen opens above the dialog.
  Future<void> _openManage() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const ZeusManageProfilesScreen()),
    );
    // The list may have changed (rename/delete) — rebuild to match.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(zeusProfilesProvider);
    final canAddMore = state.profiles.length < kZeusProfileMaxCount;

    // Small dropdown, top-right just below the header avatar — the
    // user drew it there (build 117) and asked for it smaller again
    // (build 118). The card is the app's real glass (MatteGlassCard:
    // composed blur-18 filter + 0.22-alpha surface), so the blurred
    // poster shows THROUGH it; the barrier is transparent, so the
    // rest of the Home stays sharp. The build-116 card (scaffold
    // colour at 0.78 alpha) was effectively solid — never use that
    // shell for glass again.
    //
    // Build 118 size (~185pt wide, ~114pt tall for 1 profile + 2
    // actions): the approved mockup is ~173pt wide with ~13pt text,
    // 17pt icon circles and a ~19pt avatar. bodySmall (12pt) keeps
    // the longest label ("Manage accounts", 121pt in the test font,
    // a little wider in San Francisco) inside the card with room to
    // spare; bodyMedium (14pt) needed ~214pt and forced the
    // build-117 card out to 300pt. 185pt (not 175pt) because the
    // label measures 121pt — at 175pt the row fits with zero margin
    // and would ellipsize on iOS if the font runs wider.
    final topOffset = MediaQuery.of(context).padding.top + 54;
    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: EdgeInsets.only(top: topOffset, right: 12),
        child: SizedBox(
          width: 185,
          child: MatteGlassCard(
            borderRadius: 16,
            child: Material(
              color: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                child: Column(
                  key: const ValueKey('profile-switch-card'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (state.error != null) ...[
                      Text(
                        state.error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    for (final profile in state.profiles)
                      _ProfileRow(
                        key: ValueKey('profile-switch-row-${profile.id}'),
                        profile: profile,
                        active: profile.id == state.activeProfileId,
                        onTap: () {
                          if (profile.id == state.activeProfileId) {
                            // Already on this profile — nothing to switch to.
                            _close();
                            return;
                          }
                          unawaited(_openPin(profile));
                        },
                      ),
                    const Divider(
                      height: 1,
                      color: _kGlassDivider,
                    ),
                    if (canAddMore)
                      _ActionRow(
                        key: const ValueKey('profile-switch-add'),
                        icon: Icons.add_rounded,
                        label: 'Add account',
                        onTap: () => unawaited(_openCreate()),
                      ),
                    if (canAddMore)
                      const Divider(
                        height: 1,
                        color: _kGlassDivider,
                      ),
                    _ActionRow(
                      key: const ValueKey('profile-switch-manage'),
                      icon: Icons.close_rounded,
                      label: 'Manage accounts',
                      onTap: () => unawaited(_openManage()),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The dropdown's foreground on its dark glass: white text, icons and
/// dividers. The theme's onSurface is dark on light themes, and dark
/// text on the dark glass card washed out ("Add account" was barely
/// readable on the white theme). White reads on the dark glass in
/// both themes, matching the other dark-glass surfaces in the app
/// (profile avatars, create/manage screens).
const _kGlassForeground = Colors.white;

/// Thin light divider between the dropdown's rows, for the same
/// reason: the theme divider is dark on light themes and disappears
/// on the dark glass.
const _kGlassDivider = Color(0x40FFFFFF);

/// One profile as a list row: circular avatar, name, and a gold check
/// for the active profile (the picker's check badge colour — the theme
/// primary, gold in Olympus Noir).
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.profile,
    required this.active,
    required this.onTap,
    super.key,
  });

  final ZeusProfile profile;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            ZeusProfileAvatar(profile: profile, size: 20, circular: true),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                profile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _kGlassForeground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (active)
              Icon(
                Icons.check_rounded,
                color: theme.colorScheme.primary,
                size: 14,
              ),
          ],
        ),
      ),
    );
  }
}

/// One action row: the icon in a thin circle outline (the approved
/// design's look — +, ×, gear), then the label.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: _kGlassForeground.withValues(alpha: 0.7),
                  width: 1.25,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: 13,
                color: _kGlassForeground,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _kGlassForeground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
