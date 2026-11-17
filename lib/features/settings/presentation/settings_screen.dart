import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/layout_constants.dart';
import '../../../core/theme/theme_variant.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/services/notification_service.dart';

import 'widgets/settings_widgets.dart';
import 'widgets/general_extra_tiles.dart';
import 'widgets/settings_dialogs.dart';
import 'widgets/accent_color_picker.dart';
import 'full_screen_mode_provider.dart';
import 'general_settings_provider.dart';
import 'app_version_provider.dart';
import 'developer_options_provider.dart';

import 'package:zorox/l10n/generated/app_localizations.dart';

import '../../../core/providers/locale_provider.dart';
import '../../../core/router/app_router.dart';
import 'cache_provider.dart';
import 'search_plugins_screen.dart';
import '../../search/domain/search_plugin_filter.dart';

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
              ).copyWith(bottom: LayoutConstants.shellBottomContentPadding(context)),
              children: [
                _buildGeneralSettingsGroup(
                  context,
                  ref,
                  l10n,
                  themeVariant,
                  generalSettings,
                ),
                const SizedBox(height: LayoutConstants.spacingLg),
                SettingsGroup(
                  title: l10n.extensions,
                  children: [
                    // The design preview's Extensions card: CloudStream
                    // Repos (.cs3) first, then Nuvio and Stremio. No
                    // SkyStream Repos row — the user said nothing
                    // SkyStream-related, and the preview's Extensions card
                    // has no SkyStream row either.
                    SettingsTile(
                      emoji: '🧩',
                      title: 'CloudStream Repos (.cs3)',
                      subtitle: 'Zeus repo & official CloudStream repo',
                      onTap: () => const ExtensionsRoute().go(context),
                    ),
                    SettingsTile(
                      emoji: '🔌',
                      title: 'Nuvio Plugins',
                      subtitle: 'Manage installed Nuvio plugins',
                      onTap: () => const NuvioPluginsRoute().go(context),
                    ),
                    SettingsTile(
                      emoji: '🧲',
                      title: 'Stremio Add-ons',
                      subtitle: 'Manage installed Stremio add-ons',
                      onTap: () => const AddonsRoute().go(context),
                    ),
                    // v7: which plugins and add-ons Search asks.
                    SettingsTile(
                      key: const ValueKey('settings-search-in-plugins'),
                      emoji: '🔎',
                      title: l10n.searchInPlugins,
                      subtitle: l10n.searchInPluginsSubtitle,
                      value: ref.watch(searchDisabledSourcesProvider).isEmpty
                          ? l10n.searchInPluginsAll
                          : l10n.searchInPluginsOff(
                              ref.watch(searchDisabledSourcesProvider).length,
                            ),
                      isLast: true,
                      onTap: () => SearchPluginsScreen.open(context),
                    ),
                  ],
                ),
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
              SegmentedButton<ZoroxThemeVariant>(
                segments: [
                  for (final variant in ZoroxThemeVariant.values)
                    ButtonSegment<ZoroxThemeVariant>(
                      value: variant,
                      label: Text(variant.label),
                    ),
                ],
                selected: {themeVariant},
                onSelectionChanged: (selection) {
                  final variant = selection.firstOrNull;
                  if (variant == null) return;
                  ref
                      .read(themeVariantProvider.notifier)
                      .setVariant(variant);
                },
                style: ButtonStyle(
                  textStyle: WidgetStateProperty.all(
                    const TextStyle(fontSize: 12),
                  ),
                  backgroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.selected)) {
                      return Theme.of(context).colorScheme.primary;
                    }
                    return null;
                  }),
                  foregroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.selected)) {
                      return Theme.of(context).colorScheme.onPrimary;
                    }
                    return null;
                  }),
                ),
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
          emoji: '🌙',
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
          emoji: '🌐',
          title: l10n.language,
          subtitle: 'App & metadata language',
          value: l10n.languageName,
          onTap: () =>
              showLanguageDialog(context, ref, ref.read(localeProvider)),
        ),
        SettingsTile(
          emoji: '🏠',
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
          emoji: '🕘',
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
          emoji: '🔤',
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
          emoji: '▶️',
          title: l10n.player,
          subtitle: 'Engine, gestures, subtitles, quality',
          onTap: () => const PlayerSettingsRoute().go(context),
        ),
        SettingsTile(
          emoji: '👤',
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
            emoji: '🧹',
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
          emoji: '↺',
          title: l10n.resetDataKeepExtensions,
          subtitle: 'Reset settings & library, keep extensions',
          onTap: () => showResetDataDialog(context, ref),
        ),
        SettingsTile(
          emoji: '⚠️',
          title: l10n.factoryReset,
          subtitle: 'Erase everything and start fresh',
          danger: true,
          onTap: () => showFactoryResetDialog(context, ref),
        ),
        // The preview shows Developer Options as a gold toggle (OFF by
        // default) — it turns the QoE stats overlay and debug logging on.
        // The Developer Options screen still holds the rest of the tools.
        SettingsTile(
          emoji: '🛠️',
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
          emoji: '👨‍💻',
          title: l10n.developer,
          subtitle: 'Legion',
          trailing: const SizedBox.shrink(),
          onTap: () => showDeveloperDialog(context),
        ),
        // The Telegram row is shown per the design, but it does NOT
        // link to SkyStream's server (the invite the fork shipped) —
        // tapping it says "coming soon" until Zeus has its own
        // community link. (Discord was removed from About at the
        // user's request, 2026-11-17.)
        SettingsTile(
          emoji: '✈️',
          title: 'Telegram',
          subtitle: 'Updates & support channel',
          onTap: () => _showCommunityComingSoon(context, ref, 'Telegram'),
        ),
        // v5: the "Open-source licences" row was removed from About at the
        // user's request (2026-11-17). The LICENSE file and the licence
        // texts registered with Flutter stay in the app bundle.
        SettingsTile(
          emoji: '🏷️',
          title: l10n.version,
          subtitle: 'Zeus for iOS',
          value: versionAsync.when(
            data: (v) => v,
            loading: () => l10n.loading,
            error: (err, stack) => l10n.unknown,
          ),
          showChevron: false,
          isLast: true,
        ),
      ],
    );
  }

  void _showCommunityComingSoon(
    BuildContext context,
    WidgetRef ref,
    String name,
  ) {
    ref.read(notificationServiceProvider).showInfo(
      '$name community links are coming soon.',
      title: name,
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
