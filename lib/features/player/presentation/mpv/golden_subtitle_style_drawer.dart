/// The golden "Subtitle style" drawer: a right-side sliding panel with
/// every subtitle setting, matching the mockup's rows.
///
/// All settings live in the ONE stock [PlayerSettings] model and its
/// notifier — no second store — and on mpv they apply LIVE: the caption is
/// a Flutter TextStyle rebuilt from the settings, so a change restyles the
/// on-video caption at once, no re-open needed. (That is the mpv difference
/// from libVLC, where Bold/Font/Opacity/Encoding wait for the next player
/// open; here they do not.)
///
/// Rows (mockup order): track, text size, text colour, font, bold,
/// background, outline, position, auto-adjust, manual slider, text
/// opacity, encoding, reset. The gold accent is the active/selected state
/// throughout.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../settings/presentation/player_settings_provider.dart';
import '../../../settings/presentation/widgets/subtitle_appearance_settings.dart';
import '../../domain/subtitle_search_target.dart';
import '../vlc/panel/player_subtitle_search_page.dart';
import 'golden_drawer.dart';
import 'golden_player_theme.dart';
import 'mpv_subtitle_style.dart';

/// Gold is a spec colour, not one of the stock offered colours, so it is
/// added here and written through the same [setSubtitleColor].
const int _kGoldSubtitleColor = 0xFFD4AF37;

/// The colour choices, in the spec's order, then the rest of the stock list.
const List<int> _kGoldenSubtitleColors = <int>[
  0xFFFFFFFF, // White
  0xFFFFEB3B, // Yellow
  _kGoldSubtitleColor, // Gold
  0xFF4DD0E1, // Cyan
  0xFF81C784, // Green
  0xFFE040FB, // Magenta
  0xFFEF5350, // Red
  0xFF000000, // Black
];

class GoldenSubtitleStyleDrawer extends StatefulWidget {
  const GoldenSubtitleStyleDrawer({
    required this.settings,
    required this.notifier,
    required this.controller,
    required this.onClose,
    this.onSubtitlePicked,
    this.subtitleTarget,
    this.previewSubtitle,
    super.key,
  });

  /// The saved settings, live. The drawer rebuilds from this.
  final ValueListenable<PlayerSettings> settings;

  /// Writes the settings (and persists them).
  final PlayerSettingsNotifier notifier;

  /// The engine, for the subtitle track list.
  final VlcPlayerController controller;

  /// Closes the drawer (overlay close, never a Navigator pop).
  final VoidCallback onClose;

  /// Remembered across failover by the screen: the track id the viewer
  /// picked, so the next source re-applies it.
  final ValueChanged<int?>? onSubtitlePicked;

  /// What the online search is about (the screen's title/ids/episode).
  /// Null where the catalogue knows nothing of this media, and then the
  /// engine's title seeds the search instead.
  final SubtitleSearchTarget? subtitleTarget;

  /// The caption line on screen right now (build 86), for the Manual
  /// slider's mini-preview: the preview shows the caption the viewer is
  /// actually moving. Null or empty where no caption is showing, and the
  /// preview falls back to a sample line in the current style.
  final String? previewSubtitle;

  @override
  State<GoldenSubtitleStyleDrawer> createState() =>
      _GoldenSubtitleStyleDrawerState();
}

class _GoldenSubtitleStyleDrawerState
    extends State<GoldenSubtitleStyleDrawer> {
  List<VlcTrackDescription> _tracks = const <VlcTrackDescription>[];
  int _trackRevision = -1;

  /// Monotonic token for [getSubtitleTracks] flights: a refresh that
  /// started earlier must never overwrite a newer one. A tap bumps the
  /// track revision, so several refreshes can be in flight at once while
  /// the HLS list settles; without the token a stale snapshot (the
  /// pre-tap list) could swap in after the fresh one and the rows would
  /// ghost/overlap for a frame.
  int _refreshToken = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _refreshTracks();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final revision = widget.controller.value.trackRevision;
    if (revision != _trackRevision) {
      _refreshTracks();
    } else if (mounted) {
      // The track list is the same but the ACTIVE track changed (a pick, or
      // the screen's auto-select): repaint so the dropdown shows the
      // current track instead of the stale "Off".
      setState(() {});
    }
  }

  Future<void> _refreshTracks() async {
    final token = ++_refreshToken;
    final revision = widget.controller.value.trackRevision;
    final tracks = await widget.controller.getSubtitleTracks();
    if (!mounted || token != _refreshToken) return;
    // Guard against an engine that reports one id twice: two rows with
    // one key make Flutter reuse the wrong element and the rows
    // ghost/overlap on rebuild. First occurrence wins.
    final seenIds = <int>{};
    final deduped = tracks
        .where((track) => seenIds.add(track.id))
        .toList(growable: false);
    // The merged snapshot is stable across a tap: when the new list has
    // the same ids in the same order, keep the same list object and only
    // repaint the selection — swapping the list would rebuild every row
    // element and could ghost/overlap for a frame.
    var sameList = _tracks.length == deduped.length;
    if (sameList) {
      for (var i = 0; i < deduped.length; i++) {
        if (_tracks[i].id != deduped[i].id) {
          sameList = false;
          break;
        }
      }
    }
    setState(() {
      _trackRevision = revision;
      if (!sameList) _tracks = deduped;
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final drawerWidth = goldenDrawerWidth(width);
    return GoldenDrawer(
      title: 'Subtitle style',
      width: drawerWidth,
      onClose: widget.onClose,
      child: ValueListenableBuilder<PlayerSettings>(
        valueListenable: widget.settings,
        builder: (context, settings, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: <Widget>[
              // The subtitle tracks as rows, like the Audio panel: tap a
              // row to pick it, Off to turn subtitles off. No preview box,
              // no dropdown — the selected row shows a filled radio + gold
              // highlight, so the current track reads at a glance.
              const GoldenSectionLabel('Subtitle'),
              _SubtitleTrackTile(
                key: const ValueKey('off'),
                label: 'Off',
                selected:
                    widget.controller.value.activeSubtitleTrackId == null,
                onTap: () => _pickTrack(null),
              ),
              for (final track in _tracks)
                _SubtitleTrackTile(
                  // A stable key per track id: the list is re-read on every
                  // track-revision bump while an HLS master settles, and
                  // without keys the rows are rebuilt from scratch and the
                  // list flickers/jumps under the viewer's finger while
                  // scrolling. With keys, a row that is still there keeps
                  // its place.
                  key: ValueKey(track.id),
                  label: track.name,
                  selected:
                      track.id ==
                      widget.controller.value.activeSubtitleTrackId,
                  onTap: () => _pickTrack(track.id),
                ),
              if (_tracks.isEmpty) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No subtitle tracks on this source.',
                    style: TextStyle(
                      color: GoldenPlayerColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ),
                // Re-read the track list from the engine — only here,
                // when nothing loaded at all. A Retry row under a live
                // list rides up and down as tracks arrive and reads as
                // flicker; a failed load is the one case it helps.
                _ActionRow(
                  key: const ValueKey('subtitle-retry'),
                  icon: Icons.refresh_rounded,
                  label: 'Retry',
                  onTap: _refreshTracks,
                ),
              ],
              const GoldenSectionLabel('Subtitle options'),
              _ActionRow(
                icon: Icons.file_open_outlined,
                label: 'Load subtitle file',
                onTap: () => unawaited(_loadFromDevice()),
              ),
              _ActionRow(
                icon: Icons.search_rounded,
                label: 'Search online',
                onTap: () => unawaited(_searchOnline(context)),
              ),
              const GoldenSectionLabel('Style'),
              _StepperRow(
                icon: Icons.format_size_rounded,
                label: 'Text size',
                value: '${settings.subtitleSize.round()}',
                onDecrease: settings.subtitleSize.round() > 10
                    ? () => widget.notifier.setSubtitleSize(
                          settings.subtitleSize - 1,
                        )
                    : null,
                onIncrease: settings.subtitleSize.round() < 80
                    ? () => widget.notifier.setSubtitleSize(
                          settings.subtitleSize + 1,
                        )
                    : null,
              ),
              _DropdownRow<int>(
                icon: Icons.palette_outlined,
                label: 'Text colour',
                valueLabel: _colorName(settings.subtitleColor),
                colorDot: Color(settings.subtitleColor),
                options: _kGoldenSubtitleColors,
                optionLabel: (argb) => _colorName(argb),
                isSelected: (argb) => argb == settings.subtitleColor,
                onSelected: (argb) =>
                    widget.notifier.setSubtitleColor(argb),
              ),
              _DropdownRow<SubtitleFont>(
                icon: Icons.text_fields_rounded,
                label: 'Font',
                valueLabel: subtitleFontLabelOf(settings.subtitleFont),
                options: SubtitleFont.values,
                optionLabel: subtitleFontLabelOf,
                isSelected: (font) => font == settings.subtitleFont,
                onSelected: (font) =>
                    widget.notifier.setSubtitleFont(font),
              ),
              _ToggleRow(
                icon: Icons.format_bold_rounded,
                label: 'Bold',
                value: settings.subtitleBold,
                onChanged: (bold) =>
                    widget.notifier.setSubtitleBold(bold),
              ),
              _DropdownRow<String>(
                icon: Icons.crop_square_rounded,
                label: 'Background',
                valueLabel: _backgroundName(settings),
                options: const <String>['Off', 'Black', 'Transparent black'],
                optionLabel: (name) => name,
                isSelected: (name) => name == _backgroundName(settings),
                onSelected: (name) => _setBackground(name),
              ),
              _DropdownRow<SubtitleOutline>(
                icon: Icons.font_download_outlined,
                label: 'Outline',
                valueLabel: _outlineName(settings.subtitleOutline),
                options: SubtitleOutline.values,
                optionLabel: _outlineName,
                isSelected: (outline) =>
                    outline == settings.subtitleOutline,
                onSelected: (outline) =>
                    widget.notifier.setSubtitleOutline(outline),
              ),
              _PositionRow(
                settings: settings,
                onPosition: (raise) =>
                    widget.notifier.setSubtitleRaise(raise),
              ),
              _ToggleRow(
                key: const ValueKey('subtitle-auto-adjust'),
                icon: Icons.auto_awesome_rounded,
                label: 'Auto-Adjust',
                value: settings.subtitleAutoAdjust,
                onChanged: (auto) =>
                    widget.notifier.setSubtitleAutoAdjust(auto),
              ),
              // Hidden while Auto-Adjust is on (+27): the automatic
              // position owns the caption then, and a slider that does
              // nothing would lie. The reference app greys it out; this
              // drawer hides the row entirely, so the list never shows a
              // dead control.
              if (!settings.subtitleAutoAdjust)
                _SliderRow(
                  key: const ValueKey('subtitle-manual-slider'),
                  settings: settings,
                  onRaise: (raise) =>
                      widget.notifier.setSubtitleRaise(raise),
                  previewSubtitle: widget.previewSubtitle,
                  screenHeight: MediaQuery.sizeOf(context).height,
                ),
              _StepperRow(
                icon: Icons.opacity_rounded,
                label: 'Text opacity',
                value:
                    '${(settings.subtitleTextOpacity * 100).round()}%',
                onDecrease: settings.subtitleTextOpacity > 0.25
                    ? () => widget.notifier.setSubtitleTextOpacity(
                          settings.subtitleTextOpacity - 0.25,
                        )
                    : null,
                onIncrease: settings.subtitleTextOpacity < 1.0
                    ? () => widget.notifier.setSubtitleTextOpacity(
                          settings.subtitleTextOpacity + 0.25,
                        )
                    : null,
              ),
              _DropdownRow<String>(
                icon: Icons.code_rounded,
                label: 'Encoding',
                valueLabel: _encodingName(settings.subtitleEncoding),
                options: kSubtitleEncodings,
                optionLabel: _encodingName,
                isSelected: (encoding) =>
                    encoding == settings.subtitleEncoding,
                onSelected: (encoding) =>
                    widget.notifier.setSubtitleEncoding(encoding),
              ),
              const SizedBox(height: 20),
              _ResetButton(
                onPressed: () =>
                    widget.notifier.resetSubtitleSettings(),
              ),
              const SizedBox(height: 12),
              const Text(
                'Changes apply to the caption at once on this player — '
                'no need to reopen it.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: GoldenPlayerColors.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickTrack(int? id) async {
    if (id == null) {
      await widget.controller.disableSubtitle();
    } else {
      await widget.controller.setSubtitleTrack(id);
    }
    widget.onSubtitlePicked?.call(id);
  }

  /// Puts a subtitle file from the device on screen. The mpv adapter
  /// hands it to the engine as a side-car and bumps the track revision,
  /// so the list re-reads and the file shows as a row.
  Future<void> _loadFromDevice() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa', 'sub'],
    );
    final path = picked?.path;
    if (path == null) return;
    try {
      await widget.controller.addSubtitle(Uri.file(path));
    } on VlcPlayerException catch (_) {
      // A file the engine will not take. Absorbed like the stock panel:
      // the list is about to say the track is not there.
    }
  }

  /// Opens the online subtitle search as a full-screen page over the
  /// player. A result it picks goes straight to the engine (no onFile,
  /// so the page hands the downloaded file to `addSubtitle` itself),
  /// and closing it returns to this drawer.
  Future<void> _searchOnline(BuildContext context) async {
    final given = widget.subtitleTarget;
    final seed = given ?? await _searchSeed();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => SubtitleSearchPage(
          controller: widget.controller,
          target: seed,
          onDone: () => Navigator.of(context).pop(),
        ),
      ),
    );
    // A pick lands as a track revision, which the listener re-reads;
    // a back-out leaves the list as it was.
    if (mounted) unawaited(_refreshTracks());
  }

  /// The screen's target when it has one; otherwise the engine's title
  /// alone, so a local file keeps its filename as the seed.
  Future<SubtitleSearchTarget?> _searchSeed() async {
    try {
      final title = (await widget.controller.getMediaInfo()).title;
      return SubtitleSearchTarget(title: title ?? '');
    } catch (_) {
      // A seed is a convenience; an engine that will not answer is not a
      // reason to refuse to open the search.
      return null;
    }
  }

  String _colorName(int argb) {
    if (argb == _kGoldSubtitleColor) return 'Gold';
    // The stock labels are localised; the golden drawer is English-first
    // (the user's language), so the stock English names are used via a
    // small map rather than threading localizations through.
    return switch (argb) {
      0xFFFFFFFF => 'White',
      0xFFFFEB3B => 'Yellow',
      0xFF4DD0E1 => 'Cyan',
      0xFF81C784 => 'Green',
      0xFFE040FB => 'Magenta',
      0xFFEF5350 => 'Red',
      0xFF000000 => 'Black',
      0xFF303030 => 'Dark grey',
      _ =>
        '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
    };
  }

  String _backgroundName(PlayerSettings settings) {
    final opacity = settings.subtitleBackgroundOpacity;
    if (opacity <= 0) return 'Off';
    if (opacity >= 0.99) return 'Black';
    return 'Transparent black';
  }

  Future<void> _setBackground(String name) async {
    switch (name) {
      case 'Off':
        await widget.notifier.setSubtitleBackgroundOpacity(0);
      case 'Black':
        await widget.notifier.setSubtitleBackground(0xFF000000, 1.0);
      case 'Transparent black':
        await widget.notifier.setSubtitleBackground(0xFF000000, 0.5);
    }
  }

  String _outlineName(SubtitleOutline outline) => switch (outline) {
    SubtitleOutline.none => 'Off',
    SubtitleOutline.thin => 'Thin',
    SubtitleOutline.normal => 'Medium',
    SubtitleOutline.thick => 'Thick',
  };

  String _encodingName(String encoding) =>
      encoding.isEmpty ? 'Auto' : encoding;
}

/// The font names, in English (the drawer is English-first).
String subtitleFontLabelOf(SubtitleFont font) => switch (font) {
  SubtitleFont.standard => 'Default',
  SubtitleFont.serif => 'Serif',
  SubtitleFont.monospace => 'Monospace',
  SubtitleFont.netflix => 'Netflix',
};

/// One subtitle track row, like the Audio panel: a filled radio + gold
/// highlight on the selected track, tap to pick it.
class _SubtitleTrackTile extends StatelessWidget {
  const _SubtitleTrackTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
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
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 11,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? GoldenPlayerColors.accent(context).withValues(alpha: 0.12)
                  : GoldenPlayerColors.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(GoldenPlayerRadii.card),
              border: Border.all(
                color: selected
                    ? GoldenPlayerColors.accent(context)
                    : Colors.transparent,
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
                  child: Text(
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
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A simple tappable action row (Retry, Load subtitle file, Search
/// online): gold icon + label, compact like the track rows.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
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
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 11,
            ),
            decoration: BoxDecoration(
              color: GoldenPlayerColors.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(GoldenPlayerRadii.card),
            ),
            child: Row(
              children: <Widget>[
                Icon(icon, size: 20, color: GoldenPlayerColors.accent(context)),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: const TextStyle(
                    color: GoldenPlayerColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
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

/// A − / value / + stepper row.
class _StepperRow extends StatelessWidget {
  const _StepperRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20, color: GoldenPlayerColors.accent(context)),
          const SizedBox(width: 12),
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
          _StepButton(icon: Icons.remove_rounded, onPressed: onDecrease),
          SizedBox(
            width: 52,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: GoldenPlayerColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ),
          _StepButton(icon: Icons.add_rounded, onPressed: onIncrease),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: Material(
        color: GoldenPlayerColors.surface,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Icon(
            icon,
            size: 18,
            color: onPressed == null
                ? GoldenPlayerColors.textSecondary.withValues(alpha: 0.4)
                : GoldenPlayerColors.accentHighlight(context),
          ),
        ),
      ),
    );
  }
}

/// A label + dropdown row (PopupMenu, gold menu).
class _DropdownRow<T> extends StatelessWidget {
  const _DropdownRow({
    required this.icon,
    required this.label,
    required this.valueLabel,
    required this.options,
    required this.optionLabel,
    required this.isSelected,
    required this.onSelected,
    this.colorDot,
  });

  final IconData icon;
  final String label;
  final String valueLabel;
  final List<T> options;
  final String Function(T value) optionLabel;
  final bool Function(T value) isSelected;
  final ValueChanged<T> onSelected;
  final Color? colorDot;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20, color: GoldenPlayerColors.accent(context)),
          const SizedBox(width: 12),
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
          PopupMenuButton<T>(
            onSelected: onSelected,
            color: GoldenPlayerColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(GoldenPlayerRadii.card),
              side: const BorderSide(color: GoldenPlayerColors.divider),
            ),
            itemBuilder: (context) => <PopupMenuEntry<T>>[
              for (final option in options)
                PopupMenuItem<T>(
                  value: option,
                  child: Text(
                    optionLabel(option),
                    style: TextStyle(
                      color: isSelected(option)
                          ? GoldenPlayerColors.accentHighlight(context)
                          : GoldenPlayerColors.textPrimary,
                      fontWeight: isSelected(option)
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 7,
              ),
              decoration: BoxDecoration(
                color: GoldenPlayerColors.surface,
                borderRadius: BorderRadius.circular(
                  GoldenPlayerRadii.pill,
                ),
                border: Border.all(color: GoldenPlayerColors.divider),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (colorDot != null) ...<Widget>[
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: colorDot,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white24,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    valueLabel,
                    style: const TextStyle(
                      color: GoldenPlayerColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: GoldenPlayerColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A label + gold switch row.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20, color: GoldenPlayerColors.accent(context)),
          const SizedBox(width: 12),
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
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: GoldenPlayerColors.accentHighlight(context),
            activeTrackColor: GoldenPlayerColors.accent(context).withValues(
              alpha: 0.5,
            ),
            inactiveThumbColor: GoldenPlayerColors.textSecondary,
            inactiveTrackColor: GoldenPlayerColors.surface,
          ),
        ],
      ),
    );
  }
}

/// Position: Bottom / Middle / Top.
///
/// The stock model is a lift in [0, 0.2] of the picture's height, so the
/// three positions are the ends and the middle of that range (0 / 0.1 /
/// 0.2). Fine adjustment is the Manual slider below and the swipe on the
/// video, not buttons: a horizontal swipe lifts the caption to the right
/// and drops it to the left, and the centre-third vertical slide does the
/// same up and down (+25/+26) — the fiddly −10/−5/+5/+10 pills are gone.
class _PositionRow extends StatelessWidget {
  const _PositionRow({
    required this.settings,
    required this.onPosition,
  });

  final PlayerSettings settings;
  final ValueChanged<double> onPosition;

  static const List<(String, double)> _positions = <(String, double)>[
    ('Bottom', 0.0),
    ('Middle', 0.1),
    ('Top', 0.2),
  ];

  double get _base {
    // Nearest position, ties toward the lower one.
    var best = _positions.first.$2;
    var bestDistance = double.infinity;
    for (final (_, value) in _positions) {
      final distance = (settings.subtitleRaise - value).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = value;
      }
    }
    return best;
  }

  String get _positionName {
    for (final (name, value) in _positions) {
      if (value == _base) return name;
    }
    return 'Bottom';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.vertical_align_bottom_rounded,
            size: 20,
            color: GoldenPlayerColors.accent(context),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Position',
              style: TextStyle(
                color: GoldenPlayerColors.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
          PopupMenuButton<double>(
            onSelected: onPosition,
            color: GoldenPlayerColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                GoldenPlayerRadii.card,
              ),
              side: const BorderSide(
                color: GoldenPlayerColors.divider,
              ),
            ),
            itemBuilder: (context) => <PopupMenuEntry<double>>[
              for (final (name, value) in _positions)
                PopupMenuItem<double>(
                  value: value,
                  child: Text(
                    name,
                    style: TextStyle(
                      color: value == _base
                          ? GoldenPlayerColors.accentHighlight(context)
                          : GoldenPlayerColors.textPrimary,
                      fontWeight: value == _base
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 7,
              ),
              decoration: BoxDecoration(
                color: GoldenPlayerColors.surface,
                borderRadius: BorderRadius.circular(
                  GoldenPlayerRadii.pill,
                ),
                border: Border.all(
                  color: GoldenPlayerColors.divider,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    _positionName,
                    style: const TextStyle(
                      color: GoldenPlayerColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: GoldenPlayerColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Manual slider's 0–100% for a raise in [0, 0.2]: 0% is the bottom
/// edge, 100% the top of the range. Pure, so it is unit-tested.
double subtitleRaiseToSliderPercent(double raise) =>
    raise.clamp(0.0, kSubtitleRaises.last) / kSubtitleRaises.last * 100;

/// The raise a Manual slider percent means: the inverse of
/// [subtitleRaiseToSliderPercent]. Held to the range, so a drag past
/// either end lands on the end.
double subtitleRaiseFromSliderPercent(double percent) =>
    percent.clamp(0.0, 100.0) / 100 * kSubtitleRaises.last;

/// Manual: a slider for the fine position, 0–100% of the raise range
/// [0, 0.2] (+27). Dragging moves the caption live — the slider writes
/// through `setSubtitleRaise`, which is also what the swipes write, so
/// the caption, the Position dropdown and the slider can never disagree.
/// Hidden while Auto-Adjust is on: the automatic position owns the
/// caption then, and a slider that does nothing would lie. The reset
/// button puts the caption back at the bottom edge.
///
/// Build 86: a live mini-preview under the slider, so the movement is
/// visible even while the drawer covers the video's right half. The
/// preview shows the caption line on screen now (or a sample line) in
/// the current style — same size, colour, opacity — at the same relative
/// raise inside a video-like box, plus an up/down readout (percent and
/// the lift in screen pixels) that updates live as the slider moves.
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    super.key,
    required this.settings,
    required this.onRaise,
    required this.previewSubtitle,
    required this.screenHeight,
  });

  final PlayerSettings settings;
  final ValueChanged<double> onRaise;

  /// The caption line on screen now, or null for the sample line.
  final String? previewSubtitle;

  /// The landscape screen height, the frame the raise is a share of.
  final double screenHeight;

  /// The preview box's height: tall enough for the largest caption step
  /// at the top of the raise range.
  static const double _previewHeight = 96;

  /// Where the preview caption sits from the preview box's bottom: the
  /// on-video bottom padding (16px base + the raise's share of the
  /// screen height) scaled to the preview, so the preview shows the
  /// caption at the same relative raise as the video.
  double get _previewBottom {
    if (screenHeight <= 0) return 4;
    final onVideo = kMpvSubtitlePaddingBottom +
        settings.subtitleRaise.clamp(0.0, 0.5) * screenHeight;
    return onVideo * _previewHeight / screenHeight;
  }

  @override
  Widget build(BuildContext context) {
    final percent = subtitleRaiseToSliderPercent(settings.subtitleRaise);
    final liftPx = (settings.subtitleRaise.clamp(0.0, 0.5) * screenHeight)
        .round();
    final line = (previewSubtitle ?? '').trim().isEmpty
        ? 'Subtitle preview'
        : previewSubtitle!.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.height_rounded,
                size: 20,
                color: GoldenPlayerColors.accent(context),
              ),
              const SizedBox(width: 12),
              const Text(
                'Manual',
                style: TextStyle(
                  color: GoldenPlayerColors.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: GoldenPlayerColors.accentHighlight(context),
                    inactiveTrackColor: GoldenPlayerColors.divider,
                    thumbColor: GoldenPlayerColors.accentHighlight(context),
                    overlayColor: GoldenPlayerColors.accent(context).withValues(
                      alpha: 0.2,
                    ),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                    trackHeight: 4,
                  ),
                  child: Slider(
                    value: percent,
                    min: 0,
                    max: 100,
                    onChanged: (value) =>
                        onRaise(subtitleRaiseFromSliderPercent(value)),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 36,
                child: Text(
                  '${percent.round()}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: GoldenPlayerColors.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.restart_alt_rounded, size: 20),
                color: GoldenPlayerColors.textSecondary,
                tooltip: 'Back to the bottom edge',
                onPressed: settings.subtitleRaise > 0
                    ? () => onRaise(0.0)
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 6),
          // The live preview: the caption at its current raise, in the
          // current style, inside a dark video-like box. Rebuilt from
          // the settings on every slider tick, so it glides with the
          // finger exactly as the on-video caption does.
          Container(
            height: _previewHeight,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(
                GoldenPlayerRadii.card,
              ),
              border: Border.all(color: GoldenPlayerColors.divider),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: _previewBottom,
                  child: Text(
                    line,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: mpvSubtitleTextStyle(settings),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            liftPx <= 0
                ? '0% · at the bottom edge'
                : '↑ ${percent.round()}% · $liftPx px up',
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: GoldenPlayerColors.textSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _ResetButton extends StatelessWidget {
  const _ResetButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(
        Icons.restart_alt_rounded,
        size: 20,
        color: GoldenPlayerColors.accent(context),
      ),
      label: Text(
        'Reset subtitle style',
        style: TextStyle(
          color: GoldenPlayerColors.accentHighlight(context),
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
      ),
    );
  }
}
