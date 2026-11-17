import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/layout_constants.dart';
import '../../../core/theme/theme_variant.dart';
import '../../../core/theme/theme_provider.dart';

import 'widgets/settings_widgets.dart';
import 'widgets/general_extra_tiles.dart';
import 'widgets/settings_dialogs.dart';
import 'widgets/accent_color_picker.dart';
import 'widgets/zeus_segmented_control.dart';
import 'full_screen_mode_provider.dart';
import 'general_settings_provider.dart';
import 'app_version_provider.dart';
import 'developer_options_provider.dart';

import 'package:zorox/l10n/generated/app_localizations.dart';

import '../../../core/providers/locale_provider.dart';
import '../../../core/router/app_router.dart';
import 'cache_provider.dart';

class SettingsScreen extends ConsumerWidget {
  final String? initialCategory;
  const SettingsScreen({super.key, this.initialCategory});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    final versionAsync = ref.watch(appVersionProvider);
    final themeVariant = ref.watch(themeVariantProvider);
    final generalSettings = ref.watch(generalSettingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settings),
        // The bottom pill is hidden on this branch (the preview hides it
        // on Settings), so the AppBar carries the way back to Home — the
        // branch has nothing to pop, so this goes to Home explicitly.
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => const HomeRoute().go(context),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: ListView(
              // Vertical only. SettingsGroup already insets its title and its
              // card by spacingMd, so a horizontal inset here would be paid
              // for twice and the cards would sit further in than on the
              // Accounts screen, which never added one.
              padding: const EdgeInsets.symmetric(
                vertical: LayoutConstants.spacingSm,
              ).copyWith(bottom: LayoutConstants.pillFreeBottomContentPadding(context)),
              children: [
                _buildGeneralSettingsGroup(
                  context,
                  ref,
                  l10n,
                  themeVariant,
                  generalSettings,
                ),
                // 1.0.1: no Extensions group here any more. The owner asked
                // for all four rows to go ("hum toh plugin section se sab
                // manage karsakte") — .cs3 repos, Nuvio plugins and Stremio
                // add-ons are added and removed on the Plugins tab. "Search
                // in plugins" went with them and has no other entry point,
                // so Search asks every installed source again (see
                // effectiveSearchDisabledSources).
                const SizedBox(height: LayoutConstants.spacingLg),
                _buildAppDataSettingsGroup(context, ref, l10n),
                const SizedBox(height: LayoutConstants.spacingLg),
                _buildAboutSettingsGroup(context, ref, l10n, versionAsync),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGeneralSettingsGroup(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    ZoroxThemeVariant themeVariant,
    GeneralSettings generalSettings,
  ) {
    final fullScreenModeEnabled = ref.watch(fullScreenModeProvider);
    return SettingsGroup(
      title: l10n.general,
      children: [
        // App Theme as one segmented control — the design preview's
        // "App Theme" block: Midnight | Arena Gold | Frost | Liquid Glass.
        // Picking a variant flips the mode to match its brightness, and
        // the Dark Mode toggle below flips it back the other way — the
        // two stay in sync through the variant (see ThemeVariant).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.appTheme,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              ZeusSegmentedControl<ZoroxThemeVariant>(
                segments: [
                  for (final variant in ZoroxThemeVariant.values)
                    ZeusSegment<ZoroxThemeVariant>(
                      value: variant,
                      label: variant.label,
                    ),
                ],
                selected: themeVariant,
                onChanged: (variant) => ref
                    .read(themeVariantProvider.notifier)
                    .setVariant(variant),
              ),
            ],
          ),
        ),
        // Dark Mode (v4): the on/off switch under the variant picker, so
        // Liquid Glass works on all of them — the glass pill nav renders
        // in every variant and both modes, its frost adapting to
        // brightness. The variant stays the single source of truth, so
        // the toggle and the picker stay in sync both ways: picking a
        // dark variant turns it on, picking Frost turns it off, flipping
        // it off goes to Frost, flipping it on returns to the last dark
        // variant (Liquid Glass if none was ever picked).
        SettingsTile(
          reicon: Reicon.moon,
          title: 'Dark Mode',
          subtitle: 'Dark backgrounds, light text',
          trailing: Switch(
            value: ref.watch(appThemeModeProvider) == ThemeMode.dark,
            onChanged: (val) => ref
                .read(themeVariantProvider.notifier)
                .setDarkMode(val),
          ),
          onTap: () async {
            final isDark =
                ref.read(appThemeModeProvider) == ThemeMode.dark;
            await ref
                .read(themeVariantProvider.notifier)
                .setDarkMode(!isDark);
          },
        ),
        // Accent color (Gold by default, 8 presets) — the preview's
        // swatch row, right under the theme control.
        const AccentColorPicker(),
        SettingsTile(
          reicon: Reicon.globe,
          title: l10n.language,
          subtitle: 'App & metadata language',
          value: l10n.languageName,
          onTap: () =>
              showLanguageDialog(context, ref, ref.read(localeProvider)),
        ),
        SettingsTile(
          reicon: Reicon.home2,
          title: l10n.defaultHomeScreen,
          subtitle: 'Tab shown on launch',
          value: getHomeScreenLabel(generalSettings.defaultHomeScreen, l10n),
          onTap: () => showDefaultHomeScreenDialog(
            context,
            ref,
            generalSettings.defaultHomeScreen,
          ),
        ),
        const HomeRowsSettingsTile(),
        const AppLockSettingsTile(),
        SettingsTile(
          reicon: Reicon.history,
          title: l10n.recordWatchHistory,
          subtitle: 'Keep Continue Watching & progress',
          trailing: Switch(
            value: generalSettings.watchHistoryEnabled,
            onChanged: (val) => ref
                .read(generalSettingsProvider.notifier)
                .setWatchHistoryEnabled(val),
          ),
          onTap: () => ref
              .read(generalSettingsProvider.notifier)
              .setWatchHistoryEnabled(!generalSettings.watchHistoryEnabled),
        ),
        SettingsTile(
          reicon: Reicon.text,
          title: l10n.titlePosition,
          subtitle: 'Where titles sit on posters',
          value: getTitlePositionLabel(generalSettings.titlePosition, l10n),
          onTap: () => showTitlePositionDialog(
            context,
            ref,
            generalSettings.titlePosition,
          ),
        ),
        // Only shown where it means something. A phone, a tablet and a
        // television are already the size they are going to be; only a
        // desktop has a window that can change.
        if (_supportsFullScreenMode(context))
          SettingsTile(
            icon: Icons.tv_rounded,
            title: l10n.fullScreenMode,
            subtitle: l10n.fullScreenModeSubtitle,
            trailing: Switch(
              value: fullScreenModeEnabled,
              onChanged: (val) =>
                  ref.read(fullScreenModeProvider.notifier).setEnabled(val),
            ),
            onTap: () => ref
                .read(fullScreenModeProvider.notifier)
                .setEnabled(!fullScreenModeEnabled),
          ),
        SettingsTile(
          reicon: Reicon.playCircle,
          title: l10n.player,
          subtitle: 'Engine, gestures, subtitles, quality',
          onTap: () => const PlayerSettingsRoute().go(context),
        ),
        SettingsTile(
          reicon: Reicon.userCircle,
          title: '${l10n.accounts}, ${l10n.network} & ${l10n.downloads}',
          subtitle: 'Trakt, Simkl, subtitle accounts, DNS, downloads',
          isLast: true,
          onTap: () => const AccountSettingsRoute().go(context),
        ),
      ],
    );
  }

  Widget _buildAppDataSettingsGroup(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    final developerOptionsEnabled = ref.watch(developerOptionsProvider);
    return SettingsGroup(
      title: '${l10n.appData} & ${l10n.developer}',
      children: [
        if (!kIsWeb)
          SettingsTile(
            reicon: Reicon.broom,
            title: l10n.clearCache,
            subtitle: ref
                .watch(cacheSizeProvider)
                .when(
                  data: (bytes) =>
                      'Posters & temporary files • ${_formatBytes(bytes)}',
                  loading: () => l10n.calculating,
                  error: (_, _) => l10n.clearCacheSubtitle,
                ),
            onTap: () => showClearCacheDialog(context, ref),
          ),
        SettingsTile(
          reicon: Reicon.rotateLeft,
          title: l10n.resetDataKeepExtensions,
          subtitle: 'Reset settings & library, keep extensions',
          onTap: () => showResetDataDialog(context, ref),
        ),
        SettingsTile(
          reicon: Reicon.triangleWarning,
          title: l10n.factoryReset,
          subtitle: 'Erase everything and start fresh',
          danger: true,
          onTap: () => showFactoryResetDialog(context, ref),
        ),
        // The preview shows Developer Options as a gold toggle (OFF by
        // default) — it turns the QoE stats overlay and debug logging on.
        // The Developer Options screen still holds the rest of the tools.
        SettingsTile(
          reicon: Reicon.terminalSquare,
          title: l10n.developerOptions,
          subtitle: 'Logs, QoE stats overlay, debug info',
          isLast: true,
          trailing: Switch(
            value: developerOptionsEnabled,
            onChanged: (val) => ref
                .read(developerOptionsProvider.notifier)
                .setEnabled(val),
          ),
          onTap: () => ref
              .read(developerOptionsProvider.notifier)
              .setEnabled(!developerOptionsEnabled),
        ),
      ],
    );
  }

  Widget _buildAboutSettingsGroup(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    AsyncValue<String> versionAsync,
  ) {
    return SettingsGroup(
      title: l10n.about,
      children: [
        SettingsTile(
          reicon: Reicon.code,
          title: l10n.developer,
          subtitle: 'Legion',
          trailing: const SizedBox.shrink(),
          onTap: () => showDeveloperDialog(context),
        ),
        // v9 (public 1.0.0): the credit GPL v3 asks for, at the user's
        // request — the one place the app names the project it is based
        // on. Opens the project page in the browser.
        SettingsTile(
          key: const ValueKey('about-based-on'),
          reicon: Reicon.branchUp,
          title: 'Based on SkyStream',
          subtitle: 'Open source · GPL v3',
          onTap: () => unawaited(openBasedOnProject()),
        ),
        // 1.0.1 (build 67): at the user's request the Telegram row opens
        // SkyStream's community chat. It is SkyStream's chat, not a Zeus
        // channel, and the subtitle says so. (Discord was removed from
        // About at the user's request, 2026-11-17.)
        SettingsTile(
          key: const ValueKey('about-telegram'),
          reicon: Reicon.send,
          title: 'Telegram',
          subtitle: 'SkyStream community chat',
          onTap: () => unawaited(openTelegramChat()),
        ),
        // v5: the "Open-source licences" row was removed from About at the
        // user's request (2026-11-17). The LICENSE file and the licence
        // texts registered with Flutter stay in the app bundle.
        SettingsTile(
          reicon: Reicon.infoCircle,
          title: l10n.version,
          subtitle: 'Zeus for iOS',
          value: versionAsync.when(
            // The version alone ("1.0.0"), never the build suffix.
            data: aboutVersionLabel,
            loading: () => l10n.loading,
            error: (err, stack) => l10n.unknown,
          ),
          showChevron: false,
          isLast: true,
        ),
      ],
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex++;
  }
  final value = unitIndex == 0
      ? size.toStringAsFixed(0)
      : size.toStringAsFixed(1);
  return '$value ${units[unitIndex]}';
}

/// Whether the full screen / windowed choice is offered at all.
///
/// It needs a window to make full screen and a form factor worth overriding,
/// which is the three desktops and nowhere else. A phone, a tablet and an
/// Android TV never see the row, so its subtitle never has to hedge about
/// devices that have no window to speak of. Read through [ThemeData.platform]
/// rather than dart:io so a test can state which device it is pretending to
/// be.
bool _supportsFullScreenMode(BuildContext context) {
  if (kIsWeb) return false;
  return switch (Theme.of(context).platform) {
    TargetPlatform.windows ||
    TargetPlatform.linux ||
    TargetPlatform.macOS => true,
    _ => false,
  };
}

/// The project Zeus is based on; the About credit row opens it.
const String kBasedOnProjectUrl = 'https://github.com/akashdh11/skystream';

/// Opens [kBasedOnProjectUrl] in the browser. Best effort.
Future<void> openBasedOnProject() async {
  try {
    await launchUrl(
      Uri.parse(kBasedOnProjectUrl),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    // No browser to open it in: nothing to do.
  }
}

/// What About shows for the version: the version alone — "1.0.0 +65"
/// reads as "1.0.0".
String aboutVersionLabel(String version) => version.split(' +').first.trim();

/// SkyStream's community chat on Telegram; the About Telegram row opens it.
const String kTelegramChatUrl = 'https://t.me/skystream7chat';

/// Opens [kTelegramChatUrl] in Telegram or the browser. Best effort.
Future<void> openTelegramChat() async {
  try {
    await launchUrl(
      Uri.parse(kTelegramChatUrl),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    // Nothing to open it in: nothing to do.
  }
}
