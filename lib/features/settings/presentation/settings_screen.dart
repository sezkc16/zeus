import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/layout_constants.dart';
import '../../../core/theme/olympus.dart';
import '../../../core/theme/theme_variant.dart';
import '../../../core/theme/theme_provider.dart';

import 'widgets/settings_widgets.dart';
import 'widgets/general_extra_tiles.dart';
import 'widgets/settings_dialogs.dart';
import 'widgets/accent_color_picker.dart';
import 'widgets/olympus_theme_cards.dart';
import '../../../../shared/widgets/olympus_section_header.dart';
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

    // Olympus Noir (build 102): no AppBar — the page carries its own
    // "Personalize Zeus" header at the top of the list, and the bottom
    // pill is hidden on this branch, so the header's back button is the
    // way back to Home (the branch has nothing to pop, so it goes to
    // Home explicitly).
    return Scaffold(
      body: SafeArea(
        top: true,
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: ListView(
                // Vertical only. SettingsGroup already insets its title and its
                // card by spacingMd, so a horizontal inset here would be paid
                // for twice and the cards would sit further in than on the
                // Accounts screen, which never added one.
                padding:
                    const EdgeInsets.symmetric(
                      vertical: LayoutConstants.spacingSm,
                    ).copyWith(
                      bottom: LayoutConstants.pillFreeBottomContentPadding(
                        context,
                      ),
                    ),
                children: [
                  _buildOlympusHeader(context),
                  // The theme cards and the accent swatches are their own
                  // Olympus sections now, above the rows — not inside the
                  // General group any more.
                  const OlympusSectionHeader(title: 'APP THEME'),
                  OlympusThemeCards(
                    current: themeVariant,
                    onChanged: (variant) => ref
                        .read(themeVariantProvider.notifier)
                        .setVariant(variant),
                  ),
                  const SizedBox(height: LayoutConstants.spacingLg),
                  const AccentColorPicker(),
                  const SizedBox(height: LayoutConstants.spacingLg),
                  _buildGeneralSettingsGroup(
                    context,
                    ref,
                    l10n,
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
                  const SizedBox(height: LayoutConstants.spacingLg),
                  _buildZeusFooter(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The Olympus Noir page header: back to Home, "Personalize Zeus"
  /// with its "Your cinema, your rules" line, and a gold bolt.
  Widget _buildOlympusHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => const HomeRoute().go(context),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Personalize Zeus',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Your cinema, your rules',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.65),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // The mockup's gold lightning over the mountain — the closest
          // the app has is a gold bolt with a soft glow.
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kOlympusGold.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: kOlympusGold.withValues(alpha: 0.25),
                  blurRadius: 16,
                ),
              ],
            ),
            child: const Icon(
              Icons.bolt_rounded,
              color: kOlympusGold,
              size: 28,
            ),
          ),
        ],
      ),
    );
  }

  /// The ZEUS footer: gold hairlines either side of the gold bolt and
  /// the letterspaced wordmark.
  Widget _buildZeusFooter(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              color: kOlympusGold.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(width: 12),
          Image.asset(
            'assets/images/ic_launcher_foreground.png',
            width: 20,
            height: 20,
          ),
          const SizedBox(width: 6),
          const Text(
            'ZEUS',
            style: TextStyle(
              color: kOlympusGold,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: 3.0,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: 1,
              color: kOlympusGold.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGeneralSettingsGroup(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    GeneralSettings generalSettings,
  ) {
    final fullScreenModeEnabled = ref.watch(fullScreenModeProvider);
    // Olympus Noir (build 102): no "General" header — the theme cards
    // and accent swatches above this group carry their own headings.
    // The variant picker and the accent picker moved out of the group
    // (they are standalone sections now); the rows stay exactly as
    // they were.
    return SettingsGroup(
      children: [
        // Dark Mode: the on/off switch. On Liquid Glass it only changes
        // the mode (the theme has a dark and a light look). Arena Gold /
        // Midnight / Obsidian are dark only and Frost is light only, so
        // there the switch moves to Frost or back to the last dark
        // variant (see ThemeVariant).
        SettingsTile(
          reicon: Reicon.moon,
          title: 'Dark Mode',
          subtitle: 'Dark backgrounds, light text',
          trailing: Switch(
            value: ref.watch(appThemeModeProvider) == ThemeMode.dark,
            onChanged: (val) =>
                ref.read(themeVariantProvider.notifier).setDarkMode(val),
          ),
          onTap: () async {
            final isDark = ref.read(appThemeModeProvider) == ThemeMode.dark;
            await ref.read(themeVariantProvider.notifier).setDarkMode(!isDark);
          },
        ),
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
            onChanged: (val) =>
                ref.read(developerOptionsProvider.notifier).setEnabled(val),
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
