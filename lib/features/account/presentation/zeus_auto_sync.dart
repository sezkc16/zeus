import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../data/zorox_account_notifier.dart';

/// Starts the Zeus account's automatic sync (v9): once on cold start and
/// again each time the app returns to the foreground.
///
/// It draws nothing and blocks nothing — it only tells the account
/// notifier "now would be a good time"; the notifier decides (logged in,
/// switch on, not within 10 minutes of the last one). The one thing only
/// this widget knows is whether the player is on top, and then it does
/// not ask at all: a sync never runs over playback.
class ZeusAutoSync extends ConsumerStatefulWidget {
  const ZeusAutoSync({required this.router, required this.child, super.key});

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<ZeusAutoSync> createState() => _ZeusAutoSyncState();
}

class _ZeusAutoSyncState extends ConsumerState<ZeusAutoSync>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Cold start: building the account provider restores the session,
    // and the notifier syncs once it knows it is logged in.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        ref.read(zoroxAccountProvider);
      } catch (_) {
        // The account must never keep the app from starting.
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool get _playerOnTop {
    try {
      return playerRouteIsOnTop(widget.router);
    } catch (_) {
      // Unknown: assume it is, and leave playback alone.
      return true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    try {
      unawaited(
        ref
            .read(zoroxAccountProvider.notifier)
            .autoSync(playerOnTop: _playerOnTop),
      );
    } catch (_) {
      // Silent by design.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
