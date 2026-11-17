import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../app_lock/app_lock_provider.dart';
import '../../../app_lock/app_lock_strings.dart';
import '../app_lock_settings_screen.dart';
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
      reicon: Reicon.layout,
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

/// Settings → General → App lock (v1.0.1): opens the lock's own page
/// (passcode, Face ID / fingerprint). Shows On / Off at the right. The
/// wording under the title follows the platform: Face ID on iOS, face or
/// fingerprint on Android.
class AppLockSettingsTile extends ConsumerWidget {
  const AppLockSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appLockControllerProvider);
    final strings = AppLockStrings.current();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SettingsTile(
        key: const ValueKey('settings-app-lock'),
        reicon: Reicon.faceScanSquare,
        title: strings.title,
        subtitle: strings.rowSubtitle,
        value: controller.enabled ? strings.on : strings.off,
        onTap: () => unawaited(
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const AppLockSettingsScreen(),
            ),
          ),
        ),
      ),
    );
  }
}
