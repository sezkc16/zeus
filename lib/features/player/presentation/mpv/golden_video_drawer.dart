/// The golden "Video" drawer: a right-side sliding panel, one scrolling
/// list (v9, design A):
///
/// 1. **Sleep timer** — as in v7, when the screen has one.
/// 2. **PICTURE** — Brightness, Contrast and Saturation sliders, each
///    −50…+50, 0 by default, with a Reset button on the header. They are
///    applied live while dragging ([onPictureChanged] — the screen sets
///    mpv's `brightness` / `contrast` / `saturation`) and persisted when
///    the drag ends (global, not per title). They work on every video,
///    SDR included.
/// 3. **HDR** — on an SDR video, one info card and no options; on an HDR
///    video (PQ or HLG, read by the screen from mpv's `video-params/gamma`)
///    two radio cards: "Bright" (tone-mapping clip — the default, the
///    behaviour every install already had) and "Balanced" (bt.2390).
///
/// The HDR choice is the stock [PlayerSettings.videoOutputPreset]
/// (Bright = `nativeEdr`, Balanced = `sdrToneMapped`) — no second store —
/// and the screen applies it to the live mpv instance through
/// [onPresetPicked]. The old Native EDR / SDR tone mapped / Compatibility
/// / Custom names and Custom's selectors are gone; a stored old value is
/// migrated on read (see `migrateVideoOutputPreset`).
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

/// The three PICTURE values, as the drawer reports them while dragging.
typedef PictureValues = ({int brightness, int contrast, int saturation});

class GoldenVideoDrawer extends ConsumerStatefulWidget {
  const GoldenVideoDrawer({
    required this.settings,
    required this.onPresetPicked,
    required this.onClose,
    this.sleepTimer,
    this.showPresets = true,
    this.isHdr,
    this.onPictureChanged,
    super.key,
  });

  /// The player's sleep timer (v7). Non-null: the drawer opens with a
  /// "Sleep timer" section at the top. Null: no section.
  final SleepTimer? sleepTimer;

  /// Whether PICTURE and HDR render. False where the live apply does not
  /// exist (Android): the drawer then only carries the sleep timer.
  final bool showPresets;

  /// The saved settings, live. The drawer rebuilds from this, so the
  /// selected card follows a pick at once.
  final ValueListenable<PlayerSettings> settings;

  /// The screen applies the HDR pick to the live mpv instance at once;
  /// the caller also persists it through the settings notifier.
  final ValueChanged<VideoOutputPreset> onPresetPicked;

  /// Whether the playing video is HDR: true shows the two HDR cards,
  /// false the "This video is SDR" card. Null — the listenable itself or
  /// its value, when the screen could not tell — shows the two cards: a
  /// working control is never hidden on a guess.
  final ValueListenable<bool?>? isHdr;

  /// The screen applies the three PICTURE values to the live mpv
  /// instance, on every drag tick and on Reset. Persisting is the
  /// drawer's own job (on drag end), through the settings notifier.
  final ValueChanged<PictureValues>? onPictureChanged;

  /// Closes the drawer (overlay close, never a Navigator pop).
  final VoidCallback onClose;

  @override
  ConsumerState<GoldenVideoDrawer> createState() => _GoldenVideoDrawerState();
}

class _GoldenVideoDrawerState extends ConsumerState<GoldenVideoDrawer> {
  late int _brightness;
  late int _contrast;
  late int _saturation;

  @override
  void initState() {
    super.initState();
    final current = widget.settings.value;
    _brightness = current.pictureBrightness;
    _contrast = current.pictureContrast;
    _saturation = current.pictureSaturation;
  }

  void _report() => widget.onPictureChanged?.call((
    brightness: _brightness,
    contrast: _contrast,
    saturation: _saturation,
  ));

  PlayerSettingsNotifier? get _notifier {
    try {
      return ref.read(playerSettingsProvider.notifier);
    } catch (_) {
      return null;
    }
  }

  void _reset() {
    setState(() {
      _brightness = 0;
      _contrast = 0;
      _saturation = 0;
    });
    _report();
    final notifier = _notifier;
    if (notifier == null) return;
    unawaited(notifier.setPictureBrightness(0));
    unawaited(notifier.setPictureContrast(0));
    unawaited(notifier.setPictureSaturation(0));
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final drawerWidth = width * 0.85 > 400 ? 400.0 : width * 0.85;
    return GoldenDrawer(
      title: 'Video',
      width: drawerWidth,
      onClose: widget.onClose,
      child: ValueListenableBuilder<PlayerSettings>(
        valueListenable: widget.settings,
        builder: (context, current, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: <Widget>[
              if (widget.sleepTimer != null)
                GoldenSleepTimerSection(timer: widget.sleepTimer!),
              if (widget.showPresets) ...<Widget>[
                Row(
                  children: <Widget>[
                    const Expanded(child: GoldenSectionLabel('Picture')),
                    TextButton(
                      key: const ValueKey('video-picture-reset'),
                      onPressed: _reset,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        'Reset',
                        style: TextStyle(
                          color: GoldenPlayerColors.accent(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                _PictureSlider(
                  key: const ValueKey('video-picture-brightness'),
                  label: 'Brightness',
                  value: _brightness,
                  onChanged: (v) {
                    setState(() => _brightness = v);
                    _report();
                  },
                  onChangeEnd: (v) =>
                      unawaited(_notifier?.setPictureBrightness(v)),
                ),
                _PictureSlider(
                  key: const ValueKey('video-picture-contrast'),
                  label: 'Contrast',
                  value: _contrast,
                  onChanged: (v) {
                    setState(() => _contrast = v);
                    _report();
                  },
                  onChangeEnd: (v) =>
                      unawaited(_notifier?.setPictureContrast(v)),
                ),
                _PictureSlider(
                  key: const ValueKey('video-picture-saturation'),
                  label: 'Saturation',
                  value: _saturation,
                  onChanged: (v) {
                    setState(() => _saturation = v);
                    _report();
                  },
                  onChangeEnd: (v) =>
                      unawaited(_notifier?.setPictureSaturation(v)),
                ),
                const GoldenSectionLabel('HDR'),
                _HdrSection(
                  isHdr: widget.isHdr,
                  active: current.videoOutputPreset,
                  onPicked: widget.onPresetPicked,
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// How a PICTURE value reads at the slider's right: "0", "+10", "-5".
String pictureValueLabel(int value) => value > 0 ? '+$value' : '$value';

/// One PICTURE slider: label left, value right, the slider below.
class _PictureSlider extends StatelessWidget {
  const _PictureSlider({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    super.key,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      decoration: BoxDecoration(
        color: GoldenPlayerColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(GoldenPlayerRadii.card),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: GoldenPlayerColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              Text(
                pictureValueLabel(value),
                style: TextStyle(
                  color: GoldenPlayerColors.accentHighlight(context),
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: GoldenPlayerColors.accent(context),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.18),
              thumbColor: GoldenPlayerColors.accentHighlight(context),
              overlayColor: GoldenPlayerColors.accent(context).withValues(alpha: 0.2),
            ),
            child: Slider(
              min: kPictureMin.toDouble(),
              max: kPictureMax.toDouble(),
              divisions: kPictureMax - kPictureMin,
              value: clampPictureValue(value).toDouble(),
              onChanged: (v) => onChanged(clampPictureValue(v)),
              onChangeEnd: (v) => onChangeEnd(clampPictureValue(v)),
            ),
          ),
        ],
      ),
    );
  }
}

/// The HDR section's body: the SDR info card, or the two HDR cards.
class _HdrSection extends StatelessWidget {
  const _HdrSection({
    required this.isHdr,
    required this.active,
    required this.onPicked,
  });

  final ValueListenable<bool?>? isHdr;
  final VideoOutputPreset active;
  final ValueChanged<VideoOutputPreset> onPicked;

  @override
  Widget build(BuildContext context) {
    final listenable = isHdr;
    if (listenable == null) return _cards();
    return ValueListenableBuilder<bool?>(
      valueListenable: listenable,
      builder: (context, hdr, _) => hdr == false ? _sdrCard() : _cards(),
    );
  }

  Widget _sdrCard() => Container(
    key: const ValueKey('video-hdr-sdr-info'),
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    decoration: BoxDecoration(
      color: GoldenPlayerColors.surface.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(GoldenPlayerRadii.card),
    ),
    child: const Text(
      'This video is SDR. HDR options appear only on HDR videos.',
      style: TextStyle(color: GoldenPlayerColors.textSecondary, fontSize: 13),
    ),
  );

  Widget _cards() {
    // Anything that is not Balanced reads as Bright — the default, and
    // what a legacy value the load did not see would behave as.
    final balanced = active == VideoOutputPreset.sdrToneMapped;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _VideoPresetTile(
          key: const ValueKey('video-hdr-bright'),
          label: 'Bright',
          detail: 'Punchy highlights',
          selected: !balanced,
          onTap: () => onPicked(VideoOutputPreset.nativeEdr),
        ),
        _VideoPresetTile(
          key: const ValueKey('video-hdr-balanced'),
          label: 'Balanced',
          detail: 'Softer highlights, more detail',
          selected: balanced,
          onTap: () => onPicked(VideoOutputPreset.sdrToneMapped),
        ),
      ],
    );
  }
}

/// One preset row: radio + label + subtitle, gold when selected — the
/// same tile the Audio and Sources drawers use, in this file so the
/// drawer stays self-contained.
class _VideoPresetTile extends StatelessWidget {
  const _VideoPresetTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.detail,
    super.key,
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
                  ? GoldenPlayerColors.accent(context).withValues(alpha: 0.12)
                  : GoldenPlayerColors.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(GoldenPlayerRadii.card),
              border: Border.all(
                color: selected ? GoldenPlayerColors.accent(context) : Colors.transparent,
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
                      ? GoldenPlayerColors.accent(context)
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
                              ? GoldenPlayerColors.accentHighlight(context)
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
