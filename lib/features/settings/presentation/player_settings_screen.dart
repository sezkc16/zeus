import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/device_info_provider.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/stream_quality_sorter.dart';

import 'package:zorox/l10n/generated/app_localizations.dart';

import 'player_settings_provider.dart';
import 'widgets/settings_dialogs.dart';
import 'widgets/settings_widgets.dart';
import 'widgets/subtitle_appearance_settings.dart';

/// Sub-screen for configuring all video playback, gestures, display, and quality preferences.
///
/// Visual language is the design preview's Player screen: dark cards,
/// CAPS gold section headers, emoji icon tiles, values right-aligned —
/// not the fork's gold line icons with the value under the title.
class PlayerSettingsScreen extends ConsumerWidget {
  final bool isEmbedded;

  const PlayerSettingsScreen({super.key, this.isEmbedded = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final profile = ref.watch(deviceProfileProvider).asData?.value;

    final playerSettings =
        ref.watch(playerSettingsProvider).asData?.value ??
        const PlayerSettings();

    // Whether this device has a touchscreen, which is the only thing the four
    // gesture rows below depend on: a swipe, a drag and a double-tap are the
    // one input that genuinely does not exist on a remote, a keyboard or a
    // mouse, so they are the one control the app is allowed to hide.
    //
    // A hardware fact, therefore, and asked of hardware: the mobile operating
    // systems, minus the leanback boxes and Apple TVs that run them without a
    // touchscreen. `DeviceProfile.isTv` is the single authority for "this is a
    // television"; the geometric guess in `ResponsiveContext` that used to be
    // OR-ed in here called every landscape Android phone a television and took
    // all four rows away while the gestures kept firing underneath them, so
    // the viewer could no longer switch off a gesture that was still happening.
    // Window shape must never reach this decision - the phone in landscape and
    // the phone in portrait are the same phone.
    final platform = Theme.of(context).platform;
    final isTouchDevice =
        (platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS) &&
        profile?.isTv != true;

    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: ListView(
            // Vertical only; SettingsGroup owns the horizontal inset.
            padding: const EdgeInsets.symmetric(
              vertical: LayoutConstants.spacingSm,
            ).copyWith(bottom: LayoutConstants.shellBottomContentPadding(context)),
            children: [
              SettingsGroup(
                title: l10n.playback,
                children: [
                  SettingsTile(
                    emoji: '▶️',
                    title: l10n.defaultPlayer,
                    value: getPlayerDisplayName(
                      playerSettings.preferredPlayer,
                      l10n,
                    ),
                    onTap: () => showDefaultPlayerDialog(
                      context,
                      ref,
                      playerSettings.preferredPlayer,
                    ),
                  ),
                  // Player Engine (libmpv Golden / libVLC): which engine
                  // plays the next video. libmpv is the Golden player;
                  // libVLC is the only engine that could do PiP on iOS
                  // before +28. Takes effect on the next play.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.playerEngine,
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SegmentedButton<PlayerEngine>(
                          segments: [
                            ButtonSegment<PlayerEngine>(
                              value: PlayerEngine.mpv,
                              label: Text(l10n.playerEngineMpv),
                            ),
                            ButtonSegment<PlayerEngine>(
                              value: PlayerEngine.vlc,
                              label: Text(l10n.playerEngineVlc),
                            ),
                          ],
                          selected: {playerSettings.playerEngine},
                          onSelectionChanged: (selection) {
                            final engine = selection.firstOrNull;
                            if (engine == null) return;
                            ref
                                .read(playerSettingsProvider.notifier)
                                .setPlayerEngine(engine);
                          },
                          style: _segmentedStyle(context),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          playerSettings.playerEngine == PlayerEngine.mpv
                              ? 'libmpv · ${l10n.playerEngineMpvDetail}'
                              : 'libVLC · ${l10n.playerEngineVlcDetail}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                  // Picture-in-Picture (iOS only): the mode the player
                  // uses, and the master switch. Android mpv PiP already
                  // works on the hardware renderer, so there is nothing to
                  // choose there. mpv is the +28 software-renderer bridge;
                  // iOS is the system's own PiP, which the libVLC engine
                  // already uses — on the mpv engine there is no system
                  // path, so iOS mode leaves the mpv player on the hardware
                  // renderer with no PiP button. Takes effect on the next
                  // play, like the engine choice.
                  if (platform == TargetPlatform.iOS) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Picture-in-Picture',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          SegmentedButton<PipMode>(
                            segments: [
                              ButtonSegment<PipMode>(
                                value: PipMode.mpv,
                                label: Text(l10n.pipModeMpv),
                              ),
                              ButtonSegment<PipMode>(
                                value: PipMode.ios,
                                label: Text(l10n.pipModeIos),
                              ),
                            ],
                            selected: {playerSettings.pipMode},
                            onSelectionChanged: (selection) {
                              final mode = selection.firstOrNull;
                              if (mode == null) return;
                              ref
                                  .read(playerSettingsProvider.notifier)
                                  .setPipMode(mode);
                            },
                            style: _segmentedStyle(context),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            playerSettings.pipMode == PipMode.mpv
                                ? 'mpv bridge · PiP on the mpv engine (software renderer)'
                                : 'System PiP · libVLC engine; mpv keeps hardware rendering',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                    SettingsTile(
                      emoji: '⧉',
                      title: 'Enable PiP',
                      subtitle: 'Keep playing in a floating window',
                      trailing: Switch(
                        value: playerSettings.iosMpvPip,
                        onChanged: (val) => ref
                            .read(playerSettingsProvider.notifier)
                            .setIosMpvPip(val),
                      ),
                      onTap: () => ref
                          .read(playerSettingsProvider.notifier)
                          .setIosMpvPip(!playerSettings.iosMpvPip),
                    ),
                  ],
                  if (isTouchDevice) ...[
                    SettingsTile(
                      emoji: '👈',
                      title: l10n.leftGesture,
                      value: getGestureLabel(
                        playerSettings.leftGesture,
                        l10n,
                      ),
                      onTap: () => showGestureDialog(
                        context,
                        ref,
                        true,
                        playerSettings.leftGesture,
                      ),
                    ),
                    SettingsTile(
                      emoji: '👉',
                      title: l10n.rightGesture,
                      value: getGestureLabel(
                        playerSettings.rightGesture,
                        l10n,
                      ),
                      onTap: () => showGestureDialog(
                        context,
                        ref,
                        false,
                        playerSettings.rightGesture,
                      ),
                    ),
                    SettingsTile(
                      emoji: '⏩',
                      title: l10n.doubleTapToSeek,
                      trailing: Switch(
                        value: playerSettings.doubleTapEnabled,
                        onChanged: (val) => ref
                            .read(playerSettingsProvider.notifier)
                            .setDoubleTapEnabled(val),
                      ),
                      onTap: () => ref
                          .read(playerSettingsProvider.notifier)
                          .setDoubleTapEnabled(
                            !playerSettings.doubleTapEnabled,
                          ),
                    ),
                    SettingsTile(
                      emoji: '↔️',
                      title: l10n.swipeToSeek,
                      subtitle: 'Full width = 90 seconds',
                      trailing: Switch(
                        value: playerSettings.swipeSeekEnabled,
                        onChanged: (val) => ref
                            .read(playerSettingsProvider.notifier)
                            .setSwipeSeekEnabled(val),
                      ),
                      onTap: () => ref
                          .read(playerSettingsProvider.notifier)
                          .setSwipeSeekEnabled(
                            !playerSettings.swipeSeekEnabled,
                          ),
                    ),
                    // Auto Skip (v2.9.4): skips the opening and the ending
                    // automatically, like anime/dramas. Title is a plain
                    // English literal, the same as 'Maximum volume' below.
                    SettingsTile(
                      emoji: '⏭️',
                      title: 'Auto Skip',
                      subtitle: 'AnimeSkip & IntroDB segments',
                      trailing: Switch(
                        value: playerSettings.autoSkip,
                        onChanged: (val) => ref
                            .read(playerSettingsProvider.notifier)
                            .setAutoSkip(val),
                      ),
                      onTap: () => ref
                          .read(playerSettingsProvider.notifier)
                          .setAutoSkip(!playerSettings.autoSkip),
                    ),
                  ],
                  SettingsTile(
                    emoji: '↩️',
                    title: l10n.seekDuration,
                    value: formatSeekDuration(
                      playerSettings.seekDuration,
                      l10n,
                    ),
                    onTap: () => showDurationDialog(
                      context,
                      ref,
                      playerSettings.seekDuration,
                    ),
                  ),
                  SettingsTile(
                    emoji: '📶',
                    title: l10n.networkBuffer,
                    // The buffer setting is MB-based (the +55 fix: no cap,
                    // cache-secs 3600, demuxer-max-bytes 768 MiB). The
                    // preview shows a duration ("120s") but the app's
                    // setting is a size — the value shown is the real MB
                    // setting, and the behaviour is unchanged. Auto keeps
                    // its explanation: the size is picked per video from
                    // its bitrate and this device's memory.
                    value: playerSettings.bufferOverrideMb == null
                        ? 'Auto'
                        : formatNetworkBuffer(playerSettings.bufferOverrideMb!),
                    subtitle: playerSettings.bufferOverrideMb == null
                        ? l10n.networkBufferAutoHint
                        : null,
                    onTap: () => showNetworkBufferDialog(
                      context,
                      ref,
                      playerSettings.bufferOverrideMb,
                    ),
                  ),
                  SettingsTile(
                    emoji: '🖥️',
                    title: l10n.defaultResizeMode,
                    value: getResizeModeLabel(
                      playerSettings.defaultResizeMode,
                      l10n,
                    ),
                    isLast: true,
                    onTap: () => showResizeDialog(
                      context,
                      ref,
                      playerSettings.defaultResizeMode,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: LayoutConstants.spacingLg),
              SettingsGroup(
                title: l10n.audioSubtitlesAndQuality,
                children: [
                  SettingsTile(
                    emoji: '🔊',
                    title: l10n.audioLanguage,
                    value: preferredAudioLanguageLabel(
                      playerSettings.preferredAudioLanguage,
                      l10n,
                    ),
                    onTap: () => showPreferredAudioLanguageDialog(
                      context,
                      ref,
                      playerSettings.preferredAudioLanguage,
                    ),
                  ),
                  SettingsTile(
                    emoji: '💬',
                    title: l10n.subtitleDefault,
                    value: subtitleDefaultLabel(
                      playerSettings.subtitleDefault,
                      l10n,
                    ),
                    onTap: () => showSubtitleDefaultDialog(
                      context,
                      ref,
                      playerSettings.subtitleDefault,
                    ),
                  ),
                  if (_switchReachesDecoder(context))
                    SettingsTile(
                      emoji: '⚡',
                      title: l10n.hardwareDecoding,
                      subtitle: playerSettings.hardwareDecoding
                          ? '${l10n.enabled} (${l10n.recommended})'
                          : l10n.disabled,
                      trailing: Switch(
                        value: playerSettings.hardwareDecoding,
                        onChanged: (val) => ref
                            .read(playerSettingsProvider.notifier)
                            .setHardwareDecoding(val),
                      ),
                      onTap: () => ref
                          .read(playerSettingsProvider.notifier)
                          .setHardwareDecoding(
                            !playerSettings.hardwareDecoding,
                          ),
                    ),
                  SettingsTile(
                    emoji: '🔉',
                    title: 'Maximum volume',
                    value: playerSettings.maxVolumePercent <= 100
                        ? '100%'
                        : '${playerSettings.maxVolumePercent}%',
                    onTap: () =>
                        showMaxVolumeDialog(context, ref, playerSettings),
                  ),
                  // The pair splits on metered vs unmetered, not on Wi-Fi:
                  // Ethernet, a VPN tunnel and no link at all take this one.
                  SettingsTile(
                    emoji: '📡',
                    title: l10n.unmeteredQualityPreference,
                    subtitle: 'Wi-Fi / unlimited data',
                    value: qualityPreferenceLabel(
                      playerSettings.wifiQuality,
                      l10n,
                    ),
                    onTap: () => showQualityDialog(
                      context,
                      ref,
                      title: l10n.unmeteredQualityPreference,
                      current: playerSettings.wifiQuality,
                      onChanged: ref
                          .read(playerSettingsProvider.notifier)
                          .setWifiQuality,
                    ),
                  ),
                  SettingsTile(
                    emoji: '📱',
                    title: l10n.mobileQualityPreference,
                    subtitle: 'Cellular data',
                    value: qualityPreferenceLabel(
                      playerSettings.mobileQuality,
                      l10n,
                    ),
                    onTap: () => showQualityDialog(
                      context,
                      ref,
                      title: l10n.mobileQualityPreference,
                      current: playerSettings.mobileQuality,
                      onChanged: ref
                          .read(playerSettingsProvider.notifier)
                          .setMobileQuality,
                    ),
                  ),
                  SettingsTile(
                    emoji: '🎚️',
                    title: 'Quality Filter Mode',
                    value: _qualityFilterModeLabel(
                      playerSettings.qualityFilterMode,
                    ),
                    onTap: () => showQualityFilterModeDialog(
                      context,
                      ref,
                      current: playerSettings.qualityFilterMode,
                      onChanged: ref
                          .read(playerSettingsProvider.notifier)
                          .setQualityFilterMode,
                    ),
                  ),
                  SettingsTile(
                    emoji: '🎛️',
                    title: l10n.playerControls,
                    subtitle: l10n.playerControlsSubtitle,
                    isLast: true,
                    onTap: () => showPlayerControlsDialog(context, ref),
                  ),
                ],
              ),
              const SizedBox(height: LayoutConstants.spacingLg),
              SubtitleAppearanceGroup(settings: playerSettings),
            ],
          ),
        ),
      ),
    );

    if (isEmbedded) {
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
        title: Text(l10n.player),
      ),
      body: content,
    );
  }
}

/// The segmented-control style shared by the engine and PiP pickers: the
/// selected segment is solid gold with dark text, the rest are dark.
ButtonStyle _segmentedStyle(BuildContext context) {
  return ButtonStyle(
    textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
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
  );
}

/// Whether the hardware-decoding switch reaches a decoder on this platform.
///
/// Android only, and the reason is the same one [hardwareDecodeAvailable]
/// encodes — this is its UI half, so the row is offered exactly where the
/// switch decides something.
///
/// The preference goes out as an instance-level `--avcodec-hw`. Windows and
/// Linux render through libVLC's vmem callbacks, and
/// `libvlc_video_set_callbacks` sets `avcodec-hw = "none"` on the media player
/// as it installs them; `var_Inherit` stops at the first object holding the
/// variable, and the media player sits below the instance, so the option never
/// arrives and both decode in software whichever way the switch is set. iOS
/// and macOS decode on VideoToolbox, a standalone module in VLC 3 rather than
/// an avcodec accelerator, so `avcodec-hw` has no authority over it and the
/// hardware path is there either way.
///
/// Shown anyway, the row would report "Enabled" over a software decoder on
/// Windows and Linux and "Disabled" over a hardware one on Darwin — the app
/// stating something untrue about itself. Hiding it is not a feature withheld:
/// there is no choice to make.
///
/// Read through [ThemeData.platform] rather than dart:io so a test can state
/// which device it is pretending to be, matching `_supportsFullScreenMode` in
/// settings_screen.dart.
bool _switchReachesDecoder(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.android;

String _qualityFilterModeLabel(QualityFilterMode mode) {
  switch (mode) {
    case QualityFilterMode.any:
      return 'Show all (sort only)';
    case QualityFilterMode.atOrAbove:
      return 'Hide sources below preference';
    case QualityFilterMode.atOrBelow:
      return 'Hide sources above preference';
  }
}
