/// The golden "Video" drawer: a right-side sliding panel with the output
/// presets, Infuse-style (+57).
///
/// Four presets, in the screenshot's order and words: Native EDR, SDR tone
/// mapped, Compatibility, Custom. A tap applies the preset at once — the
/// picture changes on the current video, no re-open — and persists it, so
/// the next open starts on the same preset. Reset tuning goes back to
/// Native EDR, the default (the behaviour every install already had).
/// Close dismisses the panel (overlay close, never a Navigator pop).
///
/// The preset itself is the ONE stock [PlayerSettings.videoOutputPreset]
/// and its notifier — no second store — and the screen applies it to the
/// live mpv instance through the drawer's [onPresetPicked] callback (the
/// drawer only persists + reports; the screen owns the player).
///
/// Custom shows its advanced values below the presets: a tone-mapping
/// selector and a target-peak selector, wired to the stored
/// [PlayerSettings.videoCustomToneMapping] /
/// [PlayerSettings.videoCustomTargetPeak] through the settings notifier.
/// Picking a value persists it and re-applies Custom to the live mpv
/// instance at once, like picking any other preset — the setter is
/// awaited first, so the screen reads the fresh stored value when it
/// applies. With nothing stored, Custom behaves as Native EDR (clip,
/// target peak auto), and the tiles show those effective values as
/// selected.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../settings/presentation/player_settings_provider.dart';
import '../../domain/sleep_timer.dart';
import 'golden_drawer.dart';
import 'golden_player_theme.dart';
import 'golden_sleep_timer.dart';

class GoldenVideoDrawer extends ConsumerWidget {
  const GoldenVideoDrawer({
    required this.settings,
    required this.onPresetPicked,
    required this.onClose,
    this.sleepTimer,
    this.showPresets = true,
    super.key,
  });

  /// The player's sleep timer (v7). Non-null: the drawer opens with a
  /// "Sleep timer" section above the presets. Null: no section, the
  /// drawer is exactly the +57 one.
  final SleepTimer? sleepTimer;

  /// Whether the output presets render. False where the live preset
  /// apply does not exist (Android): the drawer then only carries the
  /// sleep timer.
  final bool showPresets;

  /// The saved settings, live. The drawer rebuilds from this, so the
  /// checkmark follows a pick at once.
  final ValueListenable<PlayerSettings> settings;

  /// The screen applies the pick to the live mpv instance at once; the
  /// caller also persists it through the settings notifier before
  /// calling this.
  final ValueChanged<VideoOutputPreset> onPresetPicked;

  /// Closes the drawer (overlay close, never a Navigator pop).
  final VoidCallback onClose;

  /// Persists a Custom tone-mapping pick, then re-applies Custom to the
  /// live mpv instance: the setter is awaited first, so the screen reads
  /// the fresh stored value when [onPresetPicked] makes it apply Custom
  /// (see `_applyVideoOutputPreset` in `mpv_player_screen.dart`).
  Future<void> _pickToneMapping(WidgetRef ref, String value) async {
    await ref
        .read(playerSettingsProvider.notifier)
        .setVideoCustomToneMapping(value);
    onPresetPicked(VideoOutputPreset.custom);
  }

  /// Persists a Custom target-peak pick, then re-applies Custom, as
  /// [_pickToneMapping] does.
  Future<void> _pickTargetPeak(WidgetRef ref, String value) async {
    await ref
        .read(playerSettingsProvider.notifier)
        .setVideoCustomTargetPeak(value);
    onPresetPicked(VideoOutputPreset.custom);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final drawerWidth = width * 0.85 > 400 ? 400.0 : width * 0.85;
    return GoldenDrawer(
      title: 'Video',
      width: drawerWidth,
      onClose: onClose,
      child: ValueListenableBuilder<PlayerSettings>(
        valueListenable: settings,
        builder: (context, current, _) {
          final active = current.videoOutputPreset;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: <Widget>[
              if (sleepTimer != null)
                GoldenSleepTimerSection(timer: sleepTimer!),
              if (showPresets) ...<Widget>[
              Row(
                children: <Widget>[
                  const Expanded(child: GoldenSectionLabel('Output preset')),
                  TextButton(
                    onPressed: () =>
                        onPresetPicked(VideoOutputPreset.nativeEdr),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Reset tuning',
                      style: TextStyle(
                        color: GoldenPlayerColors.gold,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              for (final row in _kPresetRows)
                _VideoPresetTile(
                  label: row.$2,
                  detail: row.$3,
                  selected: active == row.$1,
                  onTap: () => onPresetPicked(row.$1),
                ),
              if (active == VideoOutputPreset.custom) ...<Widget>[
                const GoldenSectionLabel('Tone mapping'),
                for (final option in _kToneMappingOptions)
                  _VideoPresetTile(
                    label: option.$2,
                    detail: option.$3,
                    // With nothing stored Custom behaves as Native EDR,
                    // so clip reads as selected; a value this build does
                    // not offer (written by a newer one) selects nothing.
                    selected:
                        (current.videoCustomToneMapping ?? 'clip') ==
                        option.$1,
                    onTap: () =>
                        unawaited(_pickToneMapping(ref, option.$1)),
                  ),
                const GoldenSectionLabel('Target peak'),
                for (final option in _kTargetPeakOptions)
                  _VideoPresetTile(
                    label: option.$2,
                    detail: option.$3,
                    // With nothing stored the peak comes from the video,
                    // so Auto reads as selected.
                    selected:
                        (current.videoCustomTargetPeak ?? 'auto') ==
                        option.$1,
                    onTap: () =>
                        unawaited(_pickTargetPeak(ref, option.$1)),
                  ),
                if (current.videoCustomToneMapping == null &&
                    current.videoCustomTargetPeak == null)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(4, 14, 4, 0),
                    child: Text(
                      'Nothing stored yet — Custom behaves as Native EDR '
                      'until you pick a value.',
                      style: TextStyle(
                        color: GoldenPlayerColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
              ],
            ],
          );
        },
      ),
    );
  }
}

/// The four presets, in the screenshot's order and words.
const List<(VideoOutputPreset, String, String)> _kPresetRows =
    <(VideoOutputPreset, String, String)>[
      (
        VideoOutputPreset.nativeEdr,
        'Native EDR',
        'Best for HDR-capable iPhones and iPads.',
      ),
      (
        VideoOutputPreset.sdrToneMapped,
        'SDR tone mapped',
        'More predictable whites and blacks on SDR-style output.',
      ),
      (
        VideoOutputPreset.compatibility,
        'Compatibility',
        'Closest to the older iOS MPV behavior.',
      ),
      (
        VideoOutputPreset.custom,
        'Custom',
        'Your own tone mapping and target peak.',
      ),
    ];

/// The tone-mapping values Custom offers: the same three the other
/// presets already use (see `videoOutputPresetToneMapping` in
/// `mpv_ios_options.dart`) — clip is Native EDR's, bt.2390 is SDR tone
/// mapped's, auto is Compatibility's. Real mpv `tone-mapping` values;
/// nothing here is invented.
const List<(String, String, String)> _kToneMappingOptions =
    <(String, String, String)>[
      ('clip', 'Clip', 'Hard clip at peak white — as Native EDR.'),
      ('bt.2390', 'BT.2390', 'The reference roll-off — as SDR tone mapped.'),
      ('auto', 'Auto', "mpv's default curve — as Compatibility."),
    ];

/// The target-peak values Custom offers: `auto`, the value every preset
/// already uses, plus peak brightnesses in nits — real mpv `target-peak`
/// values (`auto` picks the peak from the video's TRC).
const List<(String, String, String)> _kTargetPeakOptions =
    <(String, String, String)>[
      ('auto', 'Auto', 'Let mpv pick from the video.'),
      ('100', '100 nits', 'SDR white.'),
      ('200', '200 nits', 'A dim HDR display.'),
      ('400', '400 nits', 'A bright HDR display.'),
      ('1000', '1000 nits', 'A high-peak HDR display.'),
    ];

/// One preset row: radio + label + subtitle, gold when selected — the
/// same tile the Audio and Sources drawers use, in this file so the
/// drawer stays self-contained.
class _VideoPresetTile extends StatelessWidget {
  const _VideoPresetTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.detail,
  });

  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(GoldenPlayerRadii.card),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: selected
                  ? GoldenPlayerColors.gold.withValues(alpha: 0.12)
                  : GoldenPlayerColors.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(GoldenPlayerRadii.card),
              border: Border.all(
                color: selected ? GoldenPlayerColors.gold : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: selected
                      ? GoldenPlayerColors.gold
                      : GoldenPlayerColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? GoldenPlayerColors.goldHighlight
                              : GoldenPlayerColors.textPrimary,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      if (detail != null) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          detail!,
                          style: const TextStyle(
                            color: GoldenPlayerColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
