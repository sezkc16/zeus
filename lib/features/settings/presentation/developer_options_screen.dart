import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import 'dart:async';

import '../../../shared/widgets/text_input_dialog.dart';
import '../../../core/network/clearance/clearance.dart';
import '../../../core/utils/layout_constants.dart';
import '../../extensions/providers/extensions_controller.dart';
import '../../../core/storage/settings_repository.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/providers/device_info_provider.dart';
import '../../../core/router/app_router.dart';
import 'widgets/settings_widgets.dart';
import '../../player/domain/qoe_log.dart';

import 'package:zorox/l10n/generated/app_localizations.dart';

import '../../../core/services/notification_service.dart';

import 'package:flutter/foundation.dart';

class DeveloperOptionsScreen extends ConsumerStatefulWidget {
  final bool isEmbedded;

  const DeveloperOptionsScreen({super.key, this.isEmbedded = false});

  @override
  ConsumerState<DeveloperOptionsScreen> createState() =>
      _DeveloperOptionsScreenState();
}

class _DeveloperOptionsScreenState
    extends ConsumerState<DeveloperOptionsScreen> {
  bool _devLoadAssets = false;

  /// Read from the flag app start set from storage, so this screen opens
  /// without a storage read of its own.
  bool _qoeLog = QoeLog.writeToAppLog;

  @override
  void initState() {
    super.initState();
    _devLoadAssets = ref.read(settingsRepositoryProvider).getDevLoadAssets();
  }

  @override
  Widget build(BuildContext context) {
    final deviceAsync = ref.watch(deviceProfileProvider);

    final l10n = AppLocalizations.of(context)!;
    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: ListView(
            // Vertical only; SettingsGroup owns the horizontal inset. No
            // nav pill on the Settings branch, so the bottom is the safe
            // area plus a small gap (the helper clears a pill if one shows).
            padding: const EdgeInsets.symmetric(vertical: 8).copyWith(
              bottom: LayoutConstants.pillFreeBottomContentPadding(context),
            ),
            children: [
              SettingsGroup(
                title: l10n.debugTools,
                children: [
                  SettingsTile(
                    icon: Icons.video_file_rounded,
                    title: l10n.playLocalVideo,
                    subtitle: l10n.playLocalVideoSubtitle,
                    onTap: () => _pickLocalVideo(context),
                  ),
                  SettingsTile(
                    icon: Icons.link_rounded,
                    title: l10n.streamUrl,
                    subtitle: l10n.streamUrlSubtitle,
                    onTap: () => _showStreamUrlDialog(
                      context,
                      deviceAsync.asData?.value.isTv ?? false,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.stream,
                    title: l10n.streamTorrent,
                    subtitle: l10n.streamTorrentSubtitle,
                    onTap: () => _pickTorrentFile(context),
                  ),
                  if (kDebugMode)
                    SettingsTile(
                      icon: Icons.folder_copy_rounded,
                      title: l10n.loadPluginFromAssets,
                      subtitle: _devLoadAssets ? l10n.enabled : l10n.disabled,
                      isLast: true,
                      trailing: Switch(
                        value: _devLoadAssets,
                        onChanged: (val) => _toggleAssetLoading(context, val),
                      ),
                      onTap: () =>
                          _toggleAssetLoading(context, !_devLoadAssets),
                    ),
                ],
              ),
              SettingsGroup(
                title: l10n.diagnostics,
                children: [
                  SettingsTile(
                    icon: Icons.bug_report_rounded,
                    title: l10n.viewLogs,
                    subtitle: l10n.viewLogsSubtitle,
                    onTap: () {
                      if (kDebugMode) {
                        unawaited(const AppLogsRoute().push<void>(context));
                      } else {
                        ref
                            .read(notificationServiceProvider)
                            .showInfo(
                              'Log tracking requires a debug build to work',
                              title: 'Developer Options',
                              icon: Icons.developer_mode_rounded,
                            );
                      }
                    },
                  ),
                  SettingsTile(
                    icon: Icons.verified_user_rounded,
                    title: 'Turnstile test',
                    subtitle:
                        'Opens Cloudflare\u2019s Turnstile demo in the app browser — tick its checkbox to check this browser can pass Turnstile at all',
                    onTap: () => _openTurnstileTest(context),
                  ),
                  SettingsTile(
                    icon: Icons.timeline_rounded,
                    title: l10n.devQoeLog,
                    subtitle: l10n.devQoeLogSubtitle,
                    isLast: true,
                    trailing: Switch(value: _qoeLog, onChanged: _setQoeLog),
                    onTap: () => _setQoeLog(!_qoeLog),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (widget.isEmbedded) {
      return content;
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              const SettingsRoute().go(context);
            }
          },
        ),
        title: Text(l10n.developerOptions),
      ),
      body: content,
    );
  }

  Future<void> _toggleAssetLoading(BuildContext context, bool newValue) async {
    if (!kDebugMode) {
      ref
          .read(notificationServiceProvider)
          .showError(
            AppLocalizations.of(context)!.debugOnlyFeature,
            title: 'Developer Options',
            icon: Icons.developer_mode_rounded,
          );
      return;
    }

    Future<void> handleDevLoadAssetsChanged(bool? newValue) async {
      if (newValue == null) return;
      await ref.read(settingsRepositoryProvider).setDevLoadAssets(newValue);
      if (context.mounted) {
        setState(() {
          _devLoadAssets = newValue;
        });
      }
    }

    await handleDevLoadAssetsChanged(newValue);

    await ref
        .read(extensionsControllerProvider.notifier)
        .loadInstalledPlugins();
  }

  /// Turns the QoE log's app-log lines on or off, at once and for later
  /// launches.
  Future<void> _setQoeLog(bool enabled) async {
    QoeLog.writeToAppLog = enabled;
    setState(() => _qoeLog = enabled);
    await ref.read(settingsRepositoryProvider).setDevQoeLog(enabled);
  }

  /// Opens Cloudflare's official Turnstile demo page in the check sheet
  /// (b124): the same browser the resolver uses, so ticking its
  /// checkbox answers whether this browser can pass Turnstile at all —
  /// a CineCloud-only failure looks different from a browser that
  /// cannot complete any Turnstile challenge. The sheet stays until
  /// the person closes it; the demo page itself says pass or fail.
  Future<void> _openTurnstileTest(BuildContext context) async {
    final clearance = Clearance.instance;
    if (!clearance.isReady) return;
    final solver = clearance.solver;
    final page = await solver.borrowPage();
    try {
      await page.load('https://demo.turnstile.workers.dev/');
      await solver.showSheet(
        page: page,
        site: 'demo.turnstile.workers.dev',
        cleared: Completer<void>().future,
      );
    } catch (_) {
      // The page failed to load: nothing to show.
    } finally {
      await page.dispose();
    }
  }

  Future<void> _pickLocalVideo(BuildContext context) async {
    final picked = await FilePicker.pickFile(type: FileType.video);

    if (picked?.path != null && context.mounted) {
      final path = picked!.path!;
      final name = picked.name;

      unawaited(
        PlayerRoute(
          $extra: PlayerRouteExtra(
            item: MultimediaItem(
              title: name,
              url: path,
              posterUrl: '',
              provider: AppLocalizations.of(context)!.local,
              episodes: [Episode(name: name, url: path, posterUrl: '')],
            ),
            videoUrl: path,
          ),
        ).push<void>(context),
      );
    }
  }

  Future<void> _showStreamUrlDialog(BuildContext context, bool isTv) async {
    final l10n = AppLocalizations.of(context)!;
    final url = await TextInputDialog.show(
      context,
      title: l10n.streamUrl,
      hintText: l10n.enterVideoUrlHint,
      confirmLabel: l10n.play,
      // Start focus on Play so a remote press acts immediately.
      autofocusField: false,
    );
    if (url == null || url.isEmpty || !context.mounted) return;

    String title = l10n.networkStream;
    try {
      final uri = Uri.parse(url);
      if (uri.pathSegments.isNotEmpty) {
        title = uri.pathSegments.last;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('DeveloperOptionsScreen: URI parse error: $e');
      }
    }

    await PlayerRoute(
      $extra: PlayerRouteExtra(
        item: MultimediaItem(
          title: title,
          url: url, // Unique URL for history
          posterUrl: '',
          provider: l10n.remote,
          episodes: [Episode(name: title, url: url, posterUrl: '')],
        ),
        videoUrl: url,
      ),
    ).push<void>(context);
  }

  Future<void> _pickTorrentFile(BuildContext context) async {
    final picked = await FilePicker.pickFile(type: FileType.any);

    if (picked?.path != null && context.mounted) {
      final path = picked!.path!;
      final name = picked.name;

      unawaited(
        PlayerRoute(
          $extra: PlayerRouteExtra(
            item: MultimediaItem(
              title: name,
              url: path,
              posterUrl: '',
              provider: AppLocalizations.of(context)!.torrent,
              episodes: [Episode(name: name, url: path, posterUrl: '')],
            ),
            videoUrl: path,
          ),
        ).push<void>(context),
      );
    }
  }
}
