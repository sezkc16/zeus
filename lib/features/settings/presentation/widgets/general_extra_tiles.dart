import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/app_snack_bar.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../app_lock/app_lock_controller.dart';
import '../../../app_lock/app_lock_provider.dart';
import '../home_rows_settings_screen.dart';
import 'settings_widgets.dart';

/// Settings → General → Home rows (v7): opens the screen that reorders and
/// hides the rows of the source Home is showing.
class HomeRowsSettingsTile extends StatelessWidget {
  const HomeRowsSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SettingsTile(
      key: const ValueKey('settings-home-rows'),
      emoji: '🧱',
      title: l10n.homeRowsTitle,
      subtitle: l10n.homeRowsSubtitle,
      onTap: () => unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const HomeRowsSettingsScreen(),
          ),
        ),
      ),
    );
  }
}

/// Settings → General → App lock (Face ID) (v7): off by default. Turning it
/// on asks for Face ID / the passcode once; without a successful answer it
/// stays off and says why.
class AppLockSettingsTile extends ConsumerWidget {
  const AppLockSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final controller = ref.watch(appLockControllerProvider);

    Future<void> change(bool on) async {
      final messenger = ScaffoldMessenger.of(context);
      final result = await controller.setEnabled(
        on,
        reason: l10n.appLockEnableReason,
      );
      final message = switch (result) {
        AppLockChange.done => null,
        AppLockChange.unavailable => l10n.appLockUnavailable,
        AppLockChange.notVerified => l10n.appLockNotVerified,
      };
      if (message != null) {
        messenger.showSnackBar(appSnackBar(content: Text(message)));
      }
    }

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SettingsTile(
        key: const ValueKey('settings-app-lock'),
        emoji: '🔒',
        title: l10n.appLockTitle,
        subtitle: l10n.appLockSubtitle,
        trailing: Switch(
          key: const ValueKey('settings-app-lock-switch'),
          value: controller.enabled,
          onChanged: (on) => unawaited(change(on)),
        ),
        onTap: () => unawaited(change(!controller.enabled)),
      ),
    );
  }
}
