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
/// Custom uses the stored advanced values; with none stored it behaves
/// as Native EDR, and the note under it says the advanced controls
/// follow — there is no fake advanced section here.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../settings/presentation/player_settings_provider.dart';
import 'golden_drawer.dart';
import 'golden_player_theme.dart';

class GoldenVideoDrawer extends StatelessWidget {
  const GoldenVideoDrawer({
    required this.settings,
    required this.onPresetPicked,
    required this.onClose,
    super.key,
  });

  /// The saved settings, live. The drawer rebuilds from this, so the
  /// checkmark follows a pick at once.
  final ValueListenable<PlayerSettings> settings;

  /// The screen applies the pick to the live mpv instance at once; the
  /// caller also persists it through the settings notifier before
  /// calling this.
  final ValueChanged<VideoOutputPreset> onPresetPicked;

  /// Closes the drawer (overlay close, never a Navigator pop).
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
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
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 14, 4, 0),
                child: Text(
                  'Advanced tuning controls follow in a later build — '
                  'Custom uses your stored values for now.',
                  style: TextStyle(
                    color: GoldenPlayerColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
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
      (VideoOutputPreset.custom, 'Custom', 'Use your advanced values below.'),
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
