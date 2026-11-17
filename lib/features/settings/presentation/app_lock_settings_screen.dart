import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/layout_constants.dart';
import '../../../core/widgets/app_snack_bar.dart';
import '../../app_lock/app_lock_controller.dart';
import '../../app_lock/app_lock_passcode_flow.dart';
import '../../app_lock/app_lock_provider.dart';
import '../../app_lock/app_lock_strings.dart';
import 'widgets/settings_widgets.dart';

/// Settings → General → App lock (v1.0.1): the lock's own page.
///
///  * App lock: turning it on asks for a new four-digit passcode (twice);
///    turning it off asks for the current one (or the biometric).
///  * Passcode: set or change it. Changing asks for the current one first.
///  * Unlock with Face ID / face or fingerprint: only shown when the phone
///    has a biometric that apps may use.
///
/// A lock that was switched on before custom passcodes existed keeps
/// working with the phone's own authentication, and this page says so and
/// offers to set a passcode.
class AppLockSettingsScreen extends ConsumerStatefulWidget {
  const AppLockSettingsScreen({super.key});

  @override
  ConsumerState<AppLockSettingsScreen> createState() =>
      _AppLockSettingsScreenState();
}

class _AppLockSettingsScreenState extends ConsumerState<AppLockSettingsScreen> {
  late final AppLockController _controller;
  final AppLockStrings _s = AppLockStrings.current();
  bool _biometricsAvailable = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(appLockControllerProvider);
    unawaited(
      _controller.biometricsAvailable().then((available) {
        if (mounted) setState(() => _biometricsAvailable = available);
      }),
    );
  }

  void _say(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(appSnackBar(content: Text(message)));
  }

  /// Opens the passcode page for [kind]; true when it ended well.
  Future<bool> _flow(AppLockPasscodeFlowKind kind) async {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AppLockPasscodeScreen(
          controller: _controller,
          kind: kind,
          title: _s.title,
        ),
      ),
    );
    return done ?? false;
  }

  /// Proves it is the owner before a change: the passcode page when a
  /// passcode is set, the phone's own prompt for an old-style lock.
  Future<bool> _prove() async {
    if (_controller.usesPasscode) {
      return _flow(AppLockPasscodeFlowKind.verify);
    }
    return _controller.confirmDeviceOwner(_s.confirmReason);
  }

  Future<void> _setMaster(bool on) async {
    if (on == _controller.enabled) return;
    if (on) {
      // On needs a passcode first; saving it switches the lock on.
      if (await _flow(AppLockPasscodeFlowKind.create) && mounted) {
        _say(_s.passcodeSet);
      }
      return;
    }
    if (!await _prove()) return;
    await _controller.setEnabled(false, reason: _s.confirmReason);
  }

  Future<void> _passcode() async {
    if (_controller.usesPasscode) {
      if (await _flow(AppLockPasscodeFlowKind.change) && mounted) {
        _say(_s.passcodeChanged);
      }
      return;
    }
    // An old-style lock: the phone confirms the owner before a passcode is
    // put in front of the app. With the lock off there is nothing to guard.
    if (_controller.enabled &&
        !await _controller.confirmDeviceOwner(_s.confirmReason)) {
      return;
    }
    if (await _flow(AppLockPasscodeFlowKind.create) && mounted) {
      _say(_s.passcodeSet);
    }
  }

  Future<void> _setBiometric(bool on) async {
    if (on && !await _controller.confirmWithBiometric(_s.confirmReason)) {
      return;
    }
    await _controller.setBiometricEnabled(on);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_s.title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              final enabled = _controller.enabled;
              final hasPasscode = _controller.usesPasscode;
              return ListView(
                padding:
                    const EdgeInsets.symmetric(
                      vertical: LayoutConstants.spacingSm,
                    ).copyWith(
                      bottom: LayoutConstants.pillFreeBottomContentPadding(
                        context,
                      ),
                    ),
                children: [
                  SettingsGroup(
                    title: _s.title,
                    children: [
                      SettingsTile(
                        key: const ValueKey('app-lock-master'),
                        reicon: Reicon.shieldLock,
                        title: _s.title,
                        subtitle: _s.masterSubtitle,
                        trailing: Switch(
                          key: const ValueKey('app-lock-master-switch'),
                          value: enabled,
                          onChanged: (on) => unawaited(_setMaster(on)),
                        ),
                        onTap: () => unawaited(_setMaster(!enabled)),
                      ),
                      SettingsTile(
                        key: const ValueKey('app-lock-passcode-row'),
                        reicon: Reicon.key,
                        title: _s.passcodeRow,
                        subtitle: hasPasscode
                            ? _s.changePasscode
                            : _s.setPasscode,
                        onTap: () => unawaited(_passcode()),
                        isLast: !(hasPasscode && _biometricsAvailable),
                      ),
                      if (hasPasscode && _biometricsAvailable)
                        SettingsTile(
                          key: const ValueKey('app-lock-biometric'),
                          reicon: Reicon.faceScanSquare,
                          title: _s.biometricSwitch,
                          subtitle: _s.biometricSubtitle,
                          trailing: Switch(
                            key: const ValueKey('app-lock-biometric-switch'),
                            value: _controller.biometricEnabled,
                            onChanged: (on) => unawaited(_setBiometric(on)),
                          ),
                          onTap: () => unawaited(
                            _setBiometric(!_controller.biometricEnabled),
                          ),
                          isLast: true,
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                    child: Text(
                      enabled && !hasPasscode ? _s.legacyPrompt : _s.footnote,
                      key: ValueKey(
                        enabled && !hasPasscode
                            ? 'app-lock-legacy-prompt'
                            : 'app-lock-footnote',
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A full page around one passcode flow; pops `true` when it ended well.
class AppLockPasscodeScreen extends StatelessWidget {
  const AppLockPasscodeScreen({
    required this.controller,
    required this.kind,
    required this.title,
    super.key,
  });

  final AppLockController controller;
  final AppLockPasscodeFlowKind kind;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: AppLockPasscodeFlow(
          controller: controller,
          kind: kind,
          onDone: () => Navigator.of(context).pop(true),
        ),
      ),
    );
  }
}
