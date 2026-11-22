import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../profiles/data/zeus_profiles_notifier.dart';
import '../../../profiles/presentation/profile_switcher_screen.dart';
import '../../../profiles/presentation/zeus_profile_avatar.dart';
import '../../../../shared/widgets/cards_wrapper.dart';
import '../delegates/home_search_delegate.dart';

/// The Home AppBar's right-hand actions, left to right: search,
/// settings, profile avatar.
///
/// Build 122 (user 2026-11-22 10:10): "profile click se setting hatao
/// aur search k bagal pr settings icon dalo" — the Settings row is out
/// of the profile dropdown, and the gear lives here again, next to the
/// search button. Build 115 had removed the gear from this row (Settings
/// then lived in the dropdown); the user wants it back beside search.
/// The gear is the search button's twin — same CardsWrapper, same
/// CircleAvatar radius 18 (36pt), same 0.1-alpha onSurface fill, same
/// 18pt icon — so it reads as one row, not a bolt-on. Tapping it opens
/// the same Settings screen the dropdown row used to open
/// (`SettingsRoute().go`); the avatar tile is unchanged (36pt, circular
/// since build 110) and still opens the profile switcher.
class HomeHeaderActions extends ConsumerWidget {
  const HomeHeaderActions({required this.searchFocusNode, super.key});

  /// The widescreen search bar's focus node (Home owns it); the search
  /// button hands focus back to it after the search delegate closes.
  final FocusNode searchFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 1. Search — unchanged (build 2).
        Padding(
          padding: const EdgeInsets.only(right: LayoutConstants.spacingSm),
          child: CardsWrapper(
            key: const ValueKey('home-header-search'),
            focusNode: searchFocusNode,
            onTap: () => unawaited(showHomeSearch(context)),
            borderRadius: BorderRadius.circular(50),
            child: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.1),
              radius: 18,
              child: Icon(
                Icons.search,
                color: Theme.of(context).colorScheme.onSurface,
                size: 18,
              ),
            ),
          ),
        ),

        // 2. Settings — the search button's twin (build 122). Same
        // glass circle, same size; opens the Settings screen.
        Padding(
          padding: const EdgeInsets.only(right: LayoutConstants.spacingSm),
          child: CardsWrapper(
            key: const ValueKey('home-header-settings'),
            onTap: () => const SettingsRoute().go(context),
            borderRadius: BorderRadius.circular(50),
            child: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.1),
              radius: 18,
              child: Icon(
                Icons.settings_outlined,
                color: Theme.of(context).colorScheme.onSurface,
                size: 18,
              ),
            ),
          ),
        ),

        // 3. Active profile's avatar — Netflix-style: tap to switch
        // profiles. Only when a profile is open (logged in or
        // local-only); the gate owns the picker before that.
        // Build 110: exactly the search/settings buttons' size —
        // CircleAvatar radius 18 = 36 pt, and this tile is 36 pt too
        // (measured on his shot: all three render 108x108 px).
        if (ref.watch(zeusProfilesProvider).activeProfile
            case final activeProfile?)
          Padding(
            padding: const EdgeInsets.only(right: LayoutConstants.spacingMd),
            child: CardsWrapper(
              key: const ValueKey('home-header-avatar'),
              onTap: () => showZeusProfileSwitcher(context),
              borderRadius: BorderRadius.circular(50),
              child: ZeusProfileAvatar(
                profile: activeProfile,
                size: 36,
                circular: true,
              ),
            ),
          ),
      ],
    );
  }
}
