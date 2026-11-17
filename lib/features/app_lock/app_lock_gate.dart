import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../l10n/generated/app_localizations.dart';
import 'app_lock_controller.dart';
import 'app_lock_passcode_flow.dart';
import 'app_lock_provider.dart';

/// Puts the app lock over the whole app: the lock screen while locked, and a
/// plain cover while the app is not in front (the app switcher's snapshot).
///
/// Sits in `MaterialApp.router`'s builder, around the Navigator. The app
/// itself is always built underneath - the first frame is not held back -
/// and nothing here touches its layout: [child] stays the first child of a
/// Stack and the lock is painted over it.
///
/// Stands down over the player: with the player route on top it neither
/// locks nor covers, so a playing video and Picture-in-Picture are left
/// alone (see [AppLockController]).
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({required this.router, required this.child, super.key});

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  late final AppLockController _controller;
  int _promptedGeneration = -1;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(appLockControllerProvider);
    _controller.isPlayerActive = _playerOnTop;
    _controller.addListener(_onChanged);
    widget.router.routerDelegate.addListener(_onRoute);
    WidgetsBinding.instance.addObserver(this);
    _maybePrompt();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.router.routerDelegate.removeListener(_onRoute);
    _controller.removeListener(_onChanged);
    super.dispose();
  }

  bool _playerOnTop() {
    try {
      return playerRouteIsOnTop(widget.router);
    } catch (_) {
      return false;
    }
  }

  void _onRoute() => _controller.onPlayerActivityChanged();

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    _maybePrompt();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _controller.onLifecycle(state);

  /// Asks once each time the app locks, when it is in front. A failed
  /// attempt does not ask again by itself: the Unlock button does.
  void _maybePrompt() {
    if (!_controller.locked ||
        _controller.authenticating ||
        _promptedGeneration == _controller.lockGeneration) {
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    _promptedGeneration = _controller.lockGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.locked) return;
      unawaited(_unlock());
    });
  }

  Future<void> _unlock() async {
    final reason =
        AppLocalizations.of(context)?.appLockUnlockReason ?? 'Unlock Zeus';
    if (_controller.usesPasscode) {
      // The app's own passcode is set: only the biometric prompt comes up
      // by itself (when switched on); the number pad is the other way in.
      if (_controller.biometricEnabled) {
        await _controller.unlockWithBiometric(reason);
      }
      return;
    }
    // Lock switched on before custom passcodes: the device's own prompt.
    await _controller.unlock(reason);
  }

  @override
  Widget build(BuildContext context) {
    final locked = _controller.locked;
    final covered = _controller.covered;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (locked || covered)
          Positioned.fill(
            child: locked && _controller.usesPasscode
                ? Material(
                    key: const ValueKey('app-lock-cover'),
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: SafeArea(
                      child: AppLockPasscodeFlow(
                        key: ValueKey(
                          'app-lock-pad-${_controller.lockGeneration}',
                        ),
                        controller: _controller,
                        kind: AppLockPasscodeFlowKind.unlock,
                        showLogo: true,
                      ),
                    ),
                  )
                : _LockCover(
                    key: const ValueKey('app-lock-cover'),
                    showUnlock: locked,
                    busy: _controller.authenticating,
                    failed: _controller.lastAttemptFailed,
                    onUnlock: () => unawaited(_unlock()),
                  ),
          ),
      ],
    );
  }
}

/// The opaque page over the app: the Zeus logo and name, and while locked
/// the Unlock button.
class _LockCover extends StatelessWidget {
  const _LockCover({
    required this.showUnlock,
    required this.busy,
    required this.failed,
    required this.onUnlock,
    super.key,
  });

  final bool showUnlock;
  final bool busy;
  final bool failed;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/ic_launcher_foreground.png',
                width: 96,
                height: 96,
              ),
              const SizedBox(height: 12),
              Text(
                l10n?.appTitle ?? 'Zeus',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (showUnlock) ...[
                const SizedBox(height: 28),
                FilledButton.icon(
                  key: const ValueKey('app-lock-unlock'),
                  onPressed: busy ? null : onUnlock,
                  icon: const Icon(Icons.lock_open_rounded),
                  label: Text(l10n?.unlock ?? 'Unlock'),
                ),
                if (failed) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n?.appLockStillLocked ?? '',
                    key: const ValueKey('app-lock-failed'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
