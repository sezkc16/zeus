/// The Premium Golden player overlay for the mpv engine.
///
/// The stock chrome ([VlcPlayerControls]) replaced by the gold design the
/// user asked for (ChatGPT spec + mockup): black #080808 with champagne
/// gold #D4AF37, dark top/bottom gradients, a thin golden seekbar, rounded
/// floating buttons, 200–300 ms fades.
///
/// Layout (mockup + spec):
///   * top bar — Back, title + season/episode line, audio/subtitle,
///     Episodes (series only), More;
///   * centre — Rewind 10 s, Play/Pause (gold circle), Forward 10 s
///     (hidden while a right-side hold is down — the hold shows no label
///     at all: the viewer asked for the "2x" pill to go too);
///   * bottom — golden seekbar with current/total time, then Previous,
///     Next (series), subtitle, volume, speed chip, lock, aspect, rotate.
///
/// Gestures (same as the stock chrome, restyled):
///   * single tap shows/hides the chrome (3 s auto-hide, owned by
///     [ChromeVisibilityController]);
///   * double-tap left/right seeks ∓10 s;
///   * long-press on the RIGHT half holds 2x until release (the saved
///     speed is restored exactly — 1.5x comes back as 1.5x);
///   * pinch zooms the picture (the screen's [videoScale]);
///   * vertical swipe on the RIGHT half changes the volume, on the LEFT
///     half the screen brightness — a full screen height is the whole
///     range. A small gold rail shows the level and fades after the swipe
///     ends. A horizontal swipe seeks (+43, the stock chrome's rule:
///     90 s per full width): right forward, left back, a pill showing
///     the target time while the finger is down, the seek landing on
///     release. A pinch still zooms.
///
/// Everything is wired to the real engine through the adapter: no
/// placeholder buttons. No Cast button — mpv/media_kit has no cast in
/// this app, and a dead one is worse than none. PiP is Android-only: the
/// screen passes `onEnterPip` where PiP exists (button in the top bar),
/// nothing on iOS — mpv renders through a Metal texture there. The
/// drawers (Episodes, Subtitle Style, Audio, Sources) slide in from the
/// right over the video.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../../core/domain/entity/multimedia_item.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import '../../../skip/data/skip_service.dart';
import '../../domain/skip_segments.dart';
import '../../domain/sleep_timer.dart';
import '../../domain/step_seek.dart';
import '../player_brightness.dart';
import '../vlc/chrome_visibility_controller.dart';
import '../vlc/panel/player_panel_data.dart';
import '../vlc/transient_overlay.dart';
import 'golden_drawer.dart';
import 'golden_episodes_drawer.dart';
import 'golden_options_drawer.dart';
import 'golden_video_drawer.dart';
import 'mpv_vlc_controller.dart';
import 'seek_band.dart';
import 'golden_player_theme.dart';
import 'golden_sleep_timer.dart';
import 'golden_subtitle_style_drawer.dart';

/// The seek step for the ±10 s buttons and the double-tap, per the spec.
const Duration _kGoldenSeekStep = Duration(seconds: 10);

/// Which right-side drawer is open, if any.
enum _GoldenDrawerKind { none, episodes, subtitleStyle, audio, sources, video }

/// The axis a single-finger pan has committed to, if any.
///
/// Decided once, from the down point, so a diagonal swipe is one gesture
/// or the other — never both, and never a rail that becomes a seek.
enum _GoldenPanAxis { none, horizontal, vertical }

/// Which vertical rail a pan is driving: the mpv volume (right third), the
/// screen brightness (left third), or the subtitle position (centre third,
/// +25).
enum _GoldenRailKind { volume, brightness, subtitle, seek }

/// The subtitle raise a centre-third vertical slide lands on: [travel] is
/// the share of the screen's height the finger moved, upward positive, and
/// a full screen of travel is the whole raise range — the same rule the
/// volume and brightness rails use. Held to [kSubtitleRaises]' range.
double subtitleRaiseAfterSlide(double startRaise, double travel) {
  return (startRaise + travel * kSubtitleRaises.last)
      .clamp(kSubtitleRaises.first, kSubtitleRaises.last)
      .toDouble();
}

/// The playhead a horizontal swipe-seek lands on (+43): [dxShare] is the
/// share of the screen's width the finger moved, rightward positive.
/// A full screen of travel is 90 s — the stock chrome's rule (see its
/// _updateSwipeSeek in vlc_player_controls.dart), so a short swipe
/// moves a little and a long swipe moves a lot, on a film of any
/// length. Right seeks forward, left seeks back. Held to [0,
/// duration]. Pure, so it is unit-tested.
Duration swipeSeekTarget(Duration start, Duration duration, double dxShare) {
  if (duration <= Duration.zero) return start;
  final targetMs = start.inMilliseconds + (dxShare * 90000).round();
  if (targetMs <= 0) return Duration.zero;
  if (targetMs >= duration.inMilliseconds) return duration;
  return Duration(milliseconds: targetMs);
}

/// "2:36" / "1:04:12": the swipe-seek pill's time, the stock chrome's
/// shape.
String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// The pinch zoom's range (v18): the picture never shrinks below half
/// size or grows past 3x. The screen's Transform clamps to the same
/// range (see `_kMinZoom` / `_kMaxZoom` in `mpv_player_screen.dart`), so
/// the notifier and the render can never disagree.
const double kVideoScaleMin = 0.5;

/// The pinch zoom's range (v18): see [kVideoScaleMin].
const double kVideoScaleMax = 3.0;

/// A zoom inside the pinch range: held there, so a wild gesture lands on
/// an end rather than outside it. Pure, so it is unit-tested.
double clampVideoScale(double scale) =>
    scale.clamp(kVideoScaleMin, kVideoScaleMax).toDouble();

/// The zoom a pinch lands on: [startScale] is the zoom when the pinch
/// started and [gestureScale] is the fingers' distance relative to the
/// gesture's start — over 1.0 while spreading apart (zoom in), under 1.0
/// while pinching in (zoom out). Held to the pinch range. Pure, so it is
/// unit-tested.
double videoScaleAfterPinch(double startScale, double gestureScale) =>
    clampVideoScale(startScale * gestureScale);

/// The zoom a raw two-finger pinch lands on (+34): [startScale] is the
/// zoom when the pinch started, [startSpan] is the fingers' distance
/// then, and [currentSpan] is their distance now. The span ratio is the
/// gesture scale, so spreading apart zooms in and pinching in zooms out,
/// held to the pinch range. A start span under 1 px (two fingers on the
/// same point) is treated as 1 px, so the ratio can never explode. Pure,
/// so it is unit-tested.
double rawPinchScale(double startScale, double startSpan, double currentSpan) {
  final double span = startSpan < 1.0 ? 1.0 : startSpan;
  return videoScaleAfterPinch(startScale, currentSpan / span);
}

class GoldenPlayerControls extends ConsumerStatefulWidget {
  const GoldenPlayerControls({
    required this.controller,
    required this.chrome,
    required this.title,
    required this.onBack,
    required this.panelData,
    required this.settings,
    required this.settingsNotifier,
    required this.onPickEpisode,
    required this.onPickSource,
    this.bufferedFraction,
    this.downloadedFraction,
    this.episodeLine,
    this.subtitle,
    this.onNextEpisode,
    this.onPreviousEpisode,
    this.onAudioPicked,
    this.onSubtitlePicked,
    this.episodeProgress,
    this.episodeDuration,
    this.hasSubtitles,
    this.fit = VlcVideoFit.contain,
    this.onFitChanged,
    this.videoScale,
    this.onRotate,
    this.isLive = false,
    this.skipSegments = const <SkipSegment>[],
    this.onSkipOutro,
    this.locked,
    this.lockAvailable = true,
    this.onEnterPip,
    this.onVideoPresetChanged,
    this.onPictureChanged,
    this.videoIsHdr,
    this.sleepTimer,
    this.onDrawerChanged,
    super.key,
  });

  /// The screen's sleep timer (v7). Non-null: the Video drawer carries
  /// the "Sleep timer" picker and the bottom bar shows the remaining
  /// time while one is armed. Null: neither renders.
  final SleepTimer? sleepTimer;

  /// A drawer opened or closed (build 86): the open drawer's width in
  /// logical pixels, 0 when none is open. The screen shifts the caption
  /// left by it, so a caption is never hidden behind a drawer — see
  /// `mpvSubtitleViewConfiguration`'s `drawerWidth`. Fires for ANY
  /// drawer, not only Subtitle style: every drawer hides the caption's
  /// right half the same way.
  final ValueChanged<double>? onDrawerChanged;

  /// The mpv-backed controller (the adapter).
  final VlcPlayerController controller;

  /// Fraction of the media fetched ahead of the playhead.
  final ValueListenable<double>? bufferedFraction;

  /// Build 107: fraction of the film the temp download holds (0..1),
  /// or null when no temp download is running. Drawn as a gold band
  /// under the buffered band: everything under it seeks instantly from
  /// the local temp file.
  final ValueListenable<double>? downloadedFraction;

  /// Owns the auto-hide clock; the screen lends it here.
  final ChromeVisibilityController chrome;

  /// The title line, and the season/episode + source lines under it.
  final String title;
  final String? episodeLine;
  final String? subtitle;

  final VoidCallback? onBack;

  /// Non-null only when a next / previous episode exists.
  final VoidCallback? onNextEpisode;
  final VoidCallback? onPreviousEpisode;

  /// The screen's published data (episodes, sources, current indexes).
  final ValueListenable<PanelData> panelData;

  /// The saved subtitle settings, live, and their writer.
  final ValueListenable<PlayerSettings> settings;
  final PlayerSettingsNotifier settingsNotifier;

  /// Episode / source picks, wired to the screen's real loaders.
  final ValueChanged<Episode> onPickEpisode;
  final ValueChanged<int> onPickSource;

  /// Remembered across failover by the screen.
  final ValueChanged<VlcTrackDescription>? onAudioPicked;
  final ValueChanged<int?>? onSubtitlePicked;

  /// Per-episode progress and length, for the Episodes drawer.
  final EpisodeProgressLookup? episodeProgress;
  final GoldenEpisodeDuration? episodeDuration;

  /// Whether this media has a subtitle to pick; the CC button hides
  /// without one.
  final ValueListenable<bool>? hasSubtitles;

  /// The video fit, owned by the screen.
  final VlcVideoFit fit;
  final ValueChanged<VlcVideoFit>? onFitChanged;

  /// The pinch zoom's value, owned by the screen.
  final ValueNotifier<double>? videoScale;

  /// Flips the handset the other way. Non-null on a phone/tablet.
  final VoidCallback? onRotate;

  final bool isLive;

  /// Intro/outro bands, usually empty.
  final List<SkipSegment> skipSegments;
  final VoidCallback? onSkipOutro;

  /// Whether the screen is locked; the lock button only shows where
  /// [lockAvailable] is true (a touch form factor).
  final ValueNotifier<bool>? locked;
  final bool lockAvailable;

  /// Enters picture-in-picture. Non-null where PiP exists; the
  /// button renders only when this is non-null and the `showPip` setting
  /// is on — the same gate as the stock chrome. Null on TV, and on iOS
  /// when the mpv PiP setting is off (see the screen's `_pipAvailable`).
  final VoidCallback? onEnterPip;

  /// Applies a Video output preset to the live mpv instance (+57).
  /// Non-null on iOS (the Video panel is iOS mpv only); null on Android,
  /// where the button never renders. The drawer persists the choice
  /// through [settingsNotifier] itself — this only applies it live.
  final ValueChanged<VideoOutputPreset>? onVideoPresetChanged;

  /// Applies the Video panel's PICTURE sliders to the live mpv instance
  /// (v9), on every drag tick. iOS mpv only, like the preset.
  final ValueChanged<PictureValues>? onPictureChanged;

  /// Whether the playing video is HDR (v9): the Video panel shows its
  /// two HDR choices only then. Null value: the screen could not tell.
  final ValueListenable<bool?>? videoIsHdr;

  @override
  ConsumerState<GoldenPlayerControls> createState() =>
      _GoldenPlayerControlsState();
}

class _GoldenPlayerControlsState extends ConsumerState<GoldenPlayerControls>
    with WidgetsBindingObserver {
  _GoldenDrawerKind _drawer = _GoldenDrawerKind.none;

  /// The speed a 2x hold restores, or null when no hold is down.
  double? _speedBeforeBoost;

  /// Whether the 2x pill is up.
  bool _boosting = false;

  /// The centre play/pause flash, shown briefly after a centre
  /// double-tap (see [_showCenterFlash]): the icon of the state the
  /// player is moving into, or null when no flash is up.
  IconData? _centerFlashIcon;
  Timer? _centerFlashTimer;

  /// Step-seek coalescing (build 86): rapid ±10 s taps accumulate into
  /// ONE seek to the final target, instead of one seek per tap — each
  /// exact seek re-seeks the engine, so three quick taps cost three
  /// seeks. The chain counts from the running target (the engine's
  /// published position lags the seek by a round trip), and the one seek
  /// is a keyframe seek (see [MpvVlcController.seekToKeyframe]): it lands
  /// on the keyframe at or before the target instead of decoding forward
  /// seconds of 4K to the exact frame. An absolute seek — scrubber,
  /// swipe, rail, skip — rebases the chain (see [_rebaseSeekChain]).
  late final StepSeekCoalescer _stepSeeks;

  /// The step-seek badge ("+20s" / "−10s"), shown at once on every tap
  /// so the tap feels instant while the one seek is still 150 ms away,
  /// or null when no badge is up. Same pill shape as the swipe-seek
  /// preview, centred.
  String? _stepSeekLabel;
  Timer? _stepSeekLabelTimer;

  /// A seekbar drag in flight, and its preview target.
  bool _seeking = false;
  Duration _seekPreview = Duration.zero;

  /// A horizontal swipe-seek in flight (+43), and the playhead it
  /// counts from: the preview is measured from here, not accumulated,
  /// so it can never drift. The seek itself lands on release (see
  /// [_commitSwipeSeek]); a pinch mid-swipe cancels it instead (see
  /// [_cancelSwipeSeek]).
  bool _swipeSeeking = false;
  Duration _swipeSeekStart = Duration.zero;

  /// Pinch state, for the zoom.
  bool _pinching = false;
  double _pinchStartScale = 1.0;

  /// The raw two-finger pinch (+34): the pointers the Listener is
  /// tracking, bypassing the gesture arena entirely. A Listener receives
  /// every pointer event unconditionally, so a pinch cannot lose the
  /// arena to the long-press deadline (500 ms) or to the first finger
  /// winning alone as a pan — the two ways the +33 arena pinch died on
  /// the phone (the user's video showed the subtitle rail while he was
  /// pinching: his spread was read as a centre-third vertical swipe).
  /// The scale recognizer stays for the single-finger pan only; while a
  /// raw pinch is in flight it is suppressed (see [_suppressScale]).
  final Map<int, Offset> _touches = <int, Offset>{};

  /// True while two fingers are down and the raw pinch owns the zoom.
  bool _rawPinching = false;

  /// While true, the scale recognizer's handlers do nothing — the raw
  /// pinch owns the gesture, so the arena's pan must not also run.
  bool _suppressScale = false;

  /// True once a two-finger pinch has started in this touch sequence, so
  /// the tap and double-tap recognizers do not fire when the pinch ends
  /// (a pinch's lift is not a tap, and not a seek).
  bool _pinchConsumed = false;

  /// The fingers' distance and the zoom when the raw pinch started.
  double _rawPinchStartSpan = 1.0;
  double _rawPinchStartScale = 1.0;

  // -- vertical swipe rails (volume right / brightness left / subtitles
  // centre) + the horizontal swipe-seek -----------------------------------
  //
  // One scale recognizer owns the single-finger pan and the pinch together
  // (the stock chrome's shape): the axis is decided once, from the down
  // point, and a clearly vertical pan becomes a rail. Right third = the
  // mpv volume, left third = the screen brightness, through the same seam
  // the stock chrome uses ([PlatformPlayerBrightness]); the centre third
  // slides the subtitle up and down (+25). A clearly horizontal pan is
  // the swipe-seek instead (+43): right forward, left back, 90 s per
  // full screen width — the stock chrome's rule — anywhere on the video,
  // because no other gesture uses a horizontal pan. The subtitle keeps
  // its centre-third vertical slide, so a pan is one axis or the other,
  // never both, and the seek and the rails cannot fight each other.
  _GoldenPanAxis _panAxis = _GoldenPanAxis.none;

  /// The down point the pan's travel is measured from, landed by a
  /// Listener before any arena resolution (the scale recognizer spends
  /// its slop first, so its own start would drop the first travel).
  Offset? _panAnchor;
  double? _panAnchorLocalX;

  /// The rail in flight, or null when no rail is down.
  _GoldenRailKind? _dragRail;

  /// The level the swipe counts from, and the running level as the travel
  /// lands: volume 0..100, brightness 0..1, subtitle raise 0..0.2.
  double _dragStart = 0;

  /// Whether the start level has been read. The brightness read is async,
  /// so a flick's travel waits here ([_dragPending]) and lands once the
  /// read does, rather than being dropped.
  bool _dragReady = false;
  double _dragPending = 0;
  int _dragId = 0;

  /// The screen's brightness, mirrored from the last read. The app's
  /// brightness is a process-wide override, so leaving the player gives
  /// the screen back to the system's level (see [dispose]).
  double _brightness = 0.5;
  bool _brightnessOverridden = false;
  late final PlayerBrightness _brightnessControl = PlatformPlayerBrightness();

  /// The volume / brightness rail. Written on every drag update, same rule
  /// as the stock chrome: the rail owns its own hide timer, so the drag
  /// writes never rebuild the overlay.
  final TransientValue<_GoldenRailData> _rail =
      TransientValue<_GoldenRailData>();

  /// Rails are a touch gesture: the stock chrome has none on desktop, and
  /// neither does this one.
  static bool get _isTouch => switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.android => true,
    _ => false,
  };

  bool get _locked => widget.locked?.value ?? false;

  bool get _isSeries => widget.panelData.value.episodes.isNotEmpty;

  // -- transport ------------------------------------------------------------

  void _togglePlay() {
    final value = widget.controller.value;
    if (value.isPlaying) {
      unawaited(widget.controller.pause());
    } else {
      unawaited(widget.controller.play());
    }
    widget.chrome.poke();
  }

  /// Seeks relative to the current position, clamped at both ends because
  /// seekTo rejects a negative position and overshooting the end would trip the
  /// end-of-media handler.
  ///
  /// Build 86: rapid taps coalesce (see [StepSeekCoalescer]). A second step
  /// inside 150 ms counts from the first step's target, not from the position
  /// the engine last published, and no seek is sent until the taps stop — one
  /// keyframe seek to the final target instead of one per tap. The badge shows
  /// the chain's accumulated offset at once, so the tap feels instant.
  void _seekBy(Duration delta) {
    final value = widget.controller.value;
    if (!value.isSeekable || value.duration <= Duration.zero) return;
    _stepSeeks.step(
      position: value.position,
      delta: delta,
      duration: value.duration,
    );
    widget.chrome.keepAlive();
  }

  /// The step-seek badge: the chain's cumulative offset ("+20s" /
  /// "−10s"), shown at once and held 700 ms, the centre flash's own
  /// length, so a run of taps keeps one badge up that reads the whole
  /// chain.
  void _showStepSeekBadge(Duration offset) {
    final seconds = offset.inSeconds;
    final label = seconds < 0 ? '${seconds}s' : '+${seconds}s';
    _stepSeekLabelTimer?.cancel();
    setState(() => _stepSeekLabel = label);
    _stepSeekLabelTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() => _stepSeekLabel = null);
    });
  }

  /// Adopts [target] as the position the next relative step counts from.
  ///
  /// Every absolute seek the controls can see — a scrubber drag, a swipe
  /// release, a rail drag, the skip button — moves playback somewhere the
  /// chain knows nothing about, and the engine will not publish it for a
  /// round trip, so the next step would count from a stale position. A
  /// pending debounced step seek is cancelled outright: the absolute seek
  /// is the truth now, and sending the stale step after it would jump the
  /// film back. The seek that just happened becomes the base.
  void _rebaseSeekChain(Duration target) => _stepSeeks.rebase(target);

  void _doubleTap(double dx) {
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    // Zones are thirds, not halves: the centre third toggles play/pause
    // and the outer thirds seek ±10s, so a double-tap near the middle
    // never seeks when the viewer meant to pause (and a seek near the
    // edge never pauses when the viewer meant to skip).
    if (dx >= width / 3 && dx <= 2 * width / 3) {
      _togglePlayWithFlash();
      return;
    }
    _seekBy(dx >= width / 2 ? _kGoldenSeekStep : -_kGoldenSeekStep);
  }

  /// Locked double-tap: only the outer thirds seek (±10s) — the same
  /// zones as unlocked, so a pocket that double-taps the right side
  /// still skips ahead. The centre third does nothing (play/pause stays
  /// locked), and there is no centre flash: a locked tap must not look
  /// like a control, and the +10s/−10s pop-up is gone by the +14 rule.
  void _doubleTapLocked(double dx) {
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    if (dx >= width / 3 && dx <= 2 * width / 3) return;
    _seekBy(dx > 2 * width / 3 ? _kGoldenSeekStep : -_kGoldenSeekStep);
  }

  /// Centre double-tap: pause if playing, resume if paused, and flash
  /// the state the player is moving into, so the tap is seen as well
  /// as felt. The flash is the centre button's own look — a dark
  /// translucent circle with a white icon — so it reads as one control.
  void _togglePlayWithFlash() {
    final wasPlaying = widget.controller.value.isPlaying;
    _togglePlay();
    _showCenterFlash(
      wasPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
    );
  }

  void _showCenterFlash(IconData icon) {
    _centerFlashTimer?.cancel();
    setState(() => _centerFlashIcon = icon);
    _centerFlashTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() => _centerFlashIcon = null);
    });
  }

  // -- 2x hold ---------------------------------------------------------------

  /// Holds playback at double speed while the finger is down on the RIGHT
  /// half. Live streams are excluded (nothing ahead to race towards).
  /// The saved speed is restored exactly on release.
  void _startSpeedBoost(double dx) {
    if (widget.isLive || _speedBeforeBoost != null) return;
    final width = context.size?.width ?? 0;
    if (width <= 0 || dx < width / 2) return;
    final value = widget.controller.value;
    if (!value.isPlaying) return;
    _speedBeforeBoost = value.playbackSpeed;
    unawaited(widget.controller.setPlaybackSpeed(2.0));
    setState(() => _boosting = true);
  }

  void _endSpeedBoost() {
    final previous = _speedBeforeBoost;
    if (previous == null) return;
    _speedBeforeBoost = null;
    unawaited(widget.controller.setPlaybackSpeed(previous));
    if (mounted) setState(() => _boosting = false);
  }

  // -- pinch zoom + vertical swipe rails -----------------------------------

  /// Lands the pan's anchor and tracks the raw two-finger pinch (+34):
  /// a [Listener] reports the pointer's down immediately, before any
  /// arena resolution. The tap recognizer's `onTapDown` cannot do this —
  /// it only fires once the tap has won the arena, and a pan's tap never
  /// does. The anchor is only taken on a fresh touch sequence, so a
  /// second finger landing mid-gesture cannot move it.
  ///
  /// The pinch lives here, not in the scale recognizer: when the second
  /// finger lands, the raw pinch takes over the zoom ([_rawPinching]),
  /// the scale recognizer is suppressed ([_suppressScale]) so its pan
  /// cannot also run, and any 2x hold or rail in flight ends. The zoom
  /// is the fingers' distance ratio from the pinch's start
  /// ([rawPinchScale]), so it cannot be stolen by the long-press
  /// deadline or by the first finger winning alone as a pan.
  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    // A fresh touch sequence.
    if (_touches.isEmpty) {
      _pinchConsumed = false;
      _panAnchor = event.position;
      _panAnchorLocalX = event.localPosition.dx;
    }
    _touches[event.pointer] = event.position;
    if (_touches.length == 2) {
      _suppressScale = true;
      _pinchConsumed = true;
      _pinching = false;
      _panAxis = _GoldenPanAxis.none;
      _railDragEnd();
      _cancelSwipeSeek();
      _endSpeedBoost();
      _rawPinching = true;
      _rawPinchStartScale = widget.videoScale?.value ?? 1.0;
      final points = _touches.values.toList();
      _rawPinchStartSpan = (points[0] - points[1]).distance;
      if (_rawPinchStartSpan < 1.0) {
        _rawPinchStartSpan = 1.0;
      }
      if (kDebugMode) {
        debugPrint(
          '[ZOOM] start scale=$_rawPinchStartScale '
          'span=$_rawPinchStartSpan',
        );
      }
    }
  }

  /// The raw pinch's move (+34): the fingers' distance against the
  /// pinch's start span is the zoom. Only while two fingers are down;
  /// a pinch that wound down to one finger stays suppressed until every
  /// finger lifts, so the remainder can never become a brightness,
  /// volume or subtitle swipe.
  void _onPointerMove(PointerMoveEvent event) {
    if (!_touches.containsKey(event.pointer)) return;
    _touches[event.pointer] = event.position;
    if (!_rawPinching || _touches.length != 2) return;
    final notifier = widget.videoScale;
    if (notifier == null) return;
    final points = _touches.values.toList();
    final span = (points[0] - points[1]).distance;
    final nextScale = rawPinchScale(
      _rawPinchStartScale,
      _rawPinchStartSpan,
      span,
    );
    if (nextScale != notifier.value) {
      notifier.value = nextScale;
      if (kDebugMode) {
        debugPrint(
          '[ZOOM] two fingers '
          'scale=${nextScale.toStringAsFixed(2)}',
        );
      }
    }
  }

  /// One finger of a touch sequence left: forget it. When fewer than two
  /// fingers remain the raw pinch is over, and when none remain the
  /// suppression lifts and the pan anchor goes with the gesture, so the
  /// remainder of a pinch can never turn into a swipe.
  void _finishPointer(int pointer) {
    _touches.remove(pointer);
    if (_touches.length < 2) {
      _rawPinching = false;
    }
    if (_touches.isEmpty) {
      _suppressScale = false;
      _panAxis = _GoldenPanAxis.none;
      _panAnchor = null;
      _panAnchorLocalX = null;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _finishPointer(event.pointer);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _finishPointer(event.pointer);
  }

  /// Clears the raw-pinch state: a lock toggle swaps the gesture layer
  /// while fingers are down, so the Listener stops hearing pointer-ups
  /// and stale pointers would otherwise suppress the scale recognizer
  /// after unlock. +52: a backgrounding does the same (see
  /// [didChangeAppLifecycleState]) — so this also drops the consumed
  /// flag and the pan anchor: without them the next tap still reads as
  /// a pinch's lift (the tap gate is [_pinchConsumed]) and the next pan
  /// still measures from a dead down point.
  void _clearRawPinchState() {
    _touches.clear();
    _rawPinching = false;
    _suppressScale = false;
    _pinchConsumed = false;
    _pinching = false;
    _panAnchor = null;
    _panAnchorLocalX = null;
    _panAxis = _GoldenPanAxis.none;
  }

  /// Drops a touch sequence the app's backgrounding interrupted (+52):
  /// the finger that started the Home swipe never sends its pointer-up,
  /// so the Listener's [_touches] keeps a stale pointer and the next
  /// tap reads as a second finger — a phantom pinch that gates the tap
  /// off (see [didChangeAppLifecycleState]). Ends any rail, swipe-seek
  /// or 2x hold the sequence owned, the same way a second finger
  /// landing ends them in [_onPointerDown].
  void _clearInterruptedGesture() {
    _clearRawPinchState();
    _railDragEnd();
    _cancelSwipeSeek();
    _endSpeedBoost();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stepSeeks = StepSeekCoalescer(
      onCommit: (target) {
        // One keyframe seek to the final target (see
        // [MpvVlcController.seekToKeyframe]); an exact seek where the
        // controller cannot take the command.
        final controller = widget.controller;
        if (controller is MpvVlcController) {
          unawaited(controller.seekToKeyframe(target));
        } else {
          unawaited(controller.seekTo(target));
        }
      },
      onStep: _showStepSeekBadge,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // +52: a Home swipe (or the app switcher, or a lock) interrupts
    // the touch sequence in flight — the finger that started the swipe
    // never sends its pointer-up, because iOS suspends the app
    // mid-gesture, so the Listener never hears the end. The stale
    // pointer stays in [_touches], and the next tap's pointer-down
    // then reads as the SECOND finger of a pinch: [_pinchConsumed]
    // goes true and the tap (and double-tap, and long-press) is gated
    // off forever — the video plays but nothing answers a touch,
    // until something unmounts this widget (a PiP open does, which is
    // why a second Home → return "fixed" it on the phone, 2026-11-16).
    // A backgrounding ends every touch sequence by definition, so drop
    // the interrupted gesture here. `paused`/`hidden` only: a transient
    // `inactive` (Control Center, a call) still delivers the pointer's
    // end, so its gestures are left alone.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _clearInterruptedGesture();
    }
  }

  /// The single-finger pan (+34: the pinch moved to the Listener — see
  /// [_onPointerDown] — because the arena lost it to the long-press
  /// deadline and to the first finger winning alone; the scale
  /// recognizer now owns the pan only, and stays suppressed while a raw
  /// pinch is in flight).
  ///
  /// Why one recognizer, and not a separate drag pair: the scale
  /// recognizer used to live under the video, below this detector's drag
  /// recognizers, and the two raced in the gesture arena for the same
  /// first finger. One recognizer cannot race itself: while it tracks one
  /// finger its focal movement is the pan. The tap, the double-tap seek
  /// and the long-press boost stay on separate recognizers in the same
  /// detector — a tap moves nowhere and a hold moves nowhere, so neither
  /// can steal a pan that moves, and a swipe that moves wins the arena
  /// before the long-press timer fires.
  void _onScaleStart(ScaleStartDetails d) {
    if (_suppressScale) return;
    // A stale pan from an end the framework never delivered — an
    // interrupted pointer — is cleared here, so the next gesture does not
    // inherit a rail or a swipe-seek.
    _railDragEnd();
    _cancelSwipeSeek();
    _panAxis = _GoldenPanAxis.none;
    if (d.pointerCount >= 2) {
      _pinching = true;
      _pinchStartScale = widget.videoScale?.value ?? 1.0;
      // A pinch is deliberate, not a hold: a 2x boost goes away with it.
      _endSpeedBoost();
      return;
    }
    // One finger. A pinch that wound down to one finger restarts here as a
    // pan, from where the finger is now — not from where it went down,
    // which the pinch already spent.
    final bool wasPinching = _pinching;
    _pinching = false;
    if (wasPinching || _panAnchor == null) {
      _panAnchor = d.focalPoint;
      _panAnchorLocalX = d.localFocalPoint.dx;
    }
    // Otherwise the anchor is the down point the Listener recorded, which
    // is what the first update measures the pan's travel from.
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (kDebugMode) {
      debugPrint(
        '[ARENA] count=${d.pointerCount} '
        'scale=${d.scale.toStringAsFixed(3)}',
      );
    }
    if (_suppressScale) return;
    if (d.pointerCount >= 2) {
      // A second finger landed mid-pan: the pan is cancelled, not
      // committed. A rail already applies live, so ending it is only
      // hiding it on its clock. A swipe-seek commits nothing either.
      if (!_pinching) {
        _pinching = true;
        _pinchStartScale = widget.videoScale?.value ?? 1.0;
        _railDragEnd();
        _cancelSwipeSeek();
        _endSpeedBoost();
      }
      final notifier = widget.videoScale;
      if (notifier == null) return;
      // details.scale is the fingers' distance relative to the gesture's
      // start — under 1.0 while pinching in — so this falls as well as
      // rises.
      final double scale = videoScaleAfterPinch(_pinchStartScale, d.scale);
      if (scale != notifier.value) notifier.value = scale;
      return;
    }
    if (_pinching || d.pointerCount != 1) return;
    if (_panAxis == _GoldenPanAxis.none) {
      // The pan's travel is measured from the anchor — the down point —
      // not from the scale recognizer's start: the recognizer spends the
      // first pixels crossing its own slop before it starts. Measuring
      // from the anchor keeps the rail's first travel the same, so a
      // short drag still moves the level. The travel is derived from two
      // points, never accumulated, so it can never be counted twice.
      final Offset anchor = _panAnchor ?? d.focalPoint;
      final Offset travel = d.focalPoint - anchor;
      if (travel.distance < 10) return;
      _panAxis = travel.dx.abs() >= travel.dy.abs()
          ? _GoldenPanAxis.horizontal
          : _GoldenPanAxis.vertical;
      if (_panAxis == _GoldenPanAxis.vertical) {
        unawaited(_beginRail(_panAnchorLocalX ?? d.localFocalPoint.dx));
        // The rail is incremental: this update applies the whole travel
        // since the down point in one go, and the updates that follow it
        // each apply only their own.
        _updateRail(travel.dy);
      } else {
        // The horizontal swipe is the swipe-seek (+43): right forward,
        // left back. Like the vertical rail, this update applies the
        // whole travel since the down point in one go, and the updates
        // that follow it each apply only their own.
        _beginSwipeSeek();
        _updateSwipeSeek(travel.dx);
      }
      return;
    }
    if (_panAxis == _GoldenPanAxis.vertical) {
      _updateRail(d.focalPointDelta.dy);
    } else if (_panAxis == _GoldenPanAxis.horizontal) {
      // Measured from the anchor every time, never accumulated: the
      // preview is absolute from the swipe's start.
      final anchor = _panAnchor ?? d.focalPoint;
      _updateSwipeSeek(d.focalPoint.dx - anchor.dx);
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_suppressScale) return;
    if (d.pointerCount >= 2) {
      // More than one pointer is still down: the pan just ended because a
      // second finger landed, and the gesture carries on as a pinch.
      _pinching = true;
      _pinchStartScale = widget.videoScale?.value ?? 1.0;
      _railDragEnd();
      _cancelSwipeSeek();
      _endSpeedBoost();
      _panAxis = _GoldenPanAxis.none;
      return;
    }
    if (_pinching) {
      // The pinch wound down to one finger (or none): the scale sticks
      // where it left it, re-clamped here so the settled value is always
      // inside the range. One finger remaining carries on as a pan from
      // here, so the axis is undecided again rather than committed.
      _pinching = false;
      final notifier = widget.videoScale;
      if (notifier != null) {
        final double settled = clampVideoScale(notifier.value);
        if (settled != notifier.value) notifier.value = settled;
      }
      _panAxis = _GoldenPanAxis.none;
      // The gesture is over (or winding down to a pan the restart
      // re-anchors): the anchor must not outlive it.
      _panAnchor = null;
      _panAnchorLocalX = null;
      return;
    }
    // The last pointer lifted: the pan commits. A rail in flight hides
    // on its clock; a swipe-seek in flight lands on release. The axis
    // stays horizontal or vertical for the gesture's life, so a rail
    // can only be in flight on its own axis.
    if (_dragRail != null) {
      _railDragEnd();
    }
    if (_swipeSeeking) {
      _commitSwipeSeek();
    }
    _panAxis = _GoldenPanAxis.none;
    _panAnchor = null;
    _panAnchorLocalX = null;
  }

  /// Starts a horizontal swipe-seek (+43): the playhead the swipe
  /// counts from, and the preview it shows. Only on touch, only when
  /// the setting is on and the input is seekable — the stock chrome's
  /// guards (see its _beginSwipeSeek). The preview is the seekbar's
  /// own ([_seeking]/[_seekPreview]), so the bottom bar follows it
  /// while the chrome is up, and the centre pill (see [build]) shows
  /// it while the chrome is not.
  void _beginSwipeSeek() {
    if (!_isTouch || widget.isLive || !widget.settings.value.swipeSeekEnabled) {
      return;
    }
    final value = widget.controller.value;
    if (!value.isSeekable || value.duration <= Duration.zero) return;
    _swipeSeeking = true;
    _swipeSeekStart = value.position;
    setState(() {
      _seeking = true;
      _seekPreview = value.position;
    });
    widget.chrome.poke(hold: true);
  }

  /// Moves the swipe-seek's preview: [totalDx] is the finger's travel
  /// in logical pixels since the down point, rightward positive —
  /// measured from the anchor every time, never accumulated, so the
  /// preview can never drift. Nothing is sought yet: the release does
  /// that (see [_commitSwipeSeek]), so a swipe that becomes a pinch
  /// commits nothing.
  void _updateSwipeSeek(double totalDx) {
    if (!_swipeSeeking) return;
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    final duration = widget.controller.value.duration;
    if (duration <= Duration.zero) return;
    final preview = swipeSeekTarget(_swipeSeekStart, duration, totalDx / width);
    if (preview != _seekPreview) {
      setState(() => _seekPreview = preview);
    }
  }

  /// Lands a swipe-seek on release: seeks to the preview, then lets
  /// the chrome go. The seek is the controller's own, so a seek past
  /// the end or before the start cannot happen — the preview was
  /// already clamped there.
  void _commitSwipeSeek() {
    if (!_swipeSeeking) return;
    _swipeSeeking = false;
    final target = _seekPreview;
    setState(() => _seeking = false);
    widget.chrome.release();
    // Build 86: an absolute seek cancels a pending debounced step seek
    // and becomes the chain's base.
    _rebaseSeekChain(target);
    unawaited(widget.controller.seekTo(target));
    widget.chrome.keepAlive();
  }

  /// Drops a swipe-seek without seeking: a second finger turned the
  /// gesture into a pinch, or a new gesture superseded a stale one the
  /// framework never ended. The preview is discarded, so nothing jumps.
  void _cancelSwipeSeek() {
    if (!_swipeSeeking) return;
    _swipeSeeking = false;
    if (mounted) setState(() => _seeking = false);
    widget.chrome.release();
  }

  /// The swipe-seek pill's text: the delta from where the swipe began
  /// and the target time — "+62s (3:38)", the stock chrome's toast
  /// shape — so the finger's travel reads at a glance.
  String get _swipeSeekLabel {
    final diffSeconds = (_seekPreview - _swipeSeekStart).inSeconds;
    final target = _formatDuration(_seekPreview);
    return diffSeconds < 0
        ? '${diffSeconds}s ($target)'
        : '+${diffSeconds}s ($target)';
  }

  /// Starts a vertical rail from the down point's third: brightness on the
  /// left third, volume on the right third, subtitle position in the centre
  /// third (+25). [localX] is the finger's x in this detector's
  /// coordinates, which is what decides the third.
  ///
  /// The outer thirds follow the Left/Right Gesture setting, as the VLC
  /// controls do: a side set to Seek slides the playhead instead of its
  /// level, and a side set to None starts no rail at all — a viewer who
  /// switched a gesture off must not find it still firing underneath them.
  /// The centre third is always the subtitle slide: no gesture setting
  /// covers it.
  Future<void> _beginRail(double localX) async {
    if (!_isTouch) {
      _dragRail = null;
      return;
    }
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    final settings = widget.settings.value;
    _GoldenRailKind? kindFor(PlayerGesture gesture, _GoldenRailKind level) {
      return switch (gesture) {
        PlayerGesture.seek => _GoldenRailKind.seek,
        PlayerGesture.none => null,
        _ => level,
      };
    }

    final _GoldenRailKind? kind;
    if (localX < width / 3) {
      kind = kindFor(settings.leftGesture, _GoldenRailKind.brightness);
    } else if (localX > 2 * width / 3) {
      kind = kindFor(settings.rightGesture, _GoldenRailKind.volume);
    } else {
      kind = _GoldenRailKind.subtitle;
    }
    if (kind == null) {
      _dragRail = null;
      return;
    }
    // A seek rail on a live or unseekable input is no rail, as the
    // horizontal swipe-seek gets none.
    if (kind == _GoldenRailKind.seek &&
        (widget.isLive || !widget.controller.value.isSeekable)) {
      _dragRail = null;
      return;
    }
    final id = ++_dragId;
    _dragRail = kind;
    _dragReady = false;
    _dragPending = 0;
    // The subtitle rail and the volume read synchronously: the raise is
    // the settings' own value, the volume the controller's own. Brightness
    // is read as each swipe starts, as the stock chrome does: the level
    // can have moved with no word to the player — Control Center or the
    // notification shade move the brightness. A platform with no answer
    // carries on from the mirrored one.
    if (kind == _GoldenRailKind.subtitle) {
      _dragStart = widget.settings.value.subtitleRaise;
    } else if (kind == _GoldenRailKind.volume) {
      _dragStart = widget.controller.value.volume.toDouble();
    } else if (kind == _GoldenRailKind.seek) {
      // Seconds, not a 0..1 level: the travel adds seconds to it, and the
      // running target is what the next update counts from.
      _dragStart = widget.controller.value.position.inMilliseconds / 1000.0;
    } else {
      final level = await _brightnessControl.read();
      if (!mounted || id != _dragId) return;
      if (level != null) _brightness = level;
      _dragStart = _brightness;
    }
    _dragReady = true;
    final pending = _dragPending;
    _dragPending = 0;
    // A flick can end before the read lands: its travel still counts, and
    // the rail then keeps its own clock.
    if (pending != 0) {
      _railTravel(kind, pending, live: _dragRail == kind);
    }
  }

  /// A full screen height of travel covers the whole range.
  ///
  /// [primaryDelta] is the finger's vertical travel since the last update.
  void _updateRail(double primaryDelta) {
    final kind = _dragRail;
    if (kind == null) return;
    final height = context.size?.height ?? 0;
    if (height <= 0) return;

    final travel = -primaryDelta / height;
    if (!_dragReady) {
      _dragPending += travel;
      return;
    }
    _railTravel(kind, travel);
  }

  /// Moves the swipe's level by [travel], a share of the screen's height,
  /// and applies it. Not [live]: the finger has already lifted, so the
  /// rail hides on its own clock.
  void _railTravel(_GoldenRailKind kind, double travel, {bool live = true}) {
    switch (kind) {
      case _GoldenRailKind.subtitle:
        // The subtitle slides on the same rule as the other rails: a full
        // screen of travel is the whole raise range. The raise is
        // persisted through the settings, so it survives reopening, and
        // the Style tab's Position dropdown and the centre-third
        // vertical slide read the same value.
        final raise = subtitleRaiseAfterSlide(_dragStart, travel);
        _dragStart = raise;
        unawaited(widget.settingsNotifier.setSubtitleRaise(raise));
        _rail.show(
          _GoldenRailData(
            icon: Icons.closed_caption_rounded,
            value: raise / kSubtitleRaises.last,
            label: '${(raise / kSubtitleRaises.last * 100).round()}%',
            onLeft: false,
          ),
          hideAfter: live ? null : const Duration(milliseconds: 900),
        );
      case _GoldenRailKind.volume:
        // The Golden player's volume is 0..100, matching its volume sheet;
        // no boost past 100% on a swipe.
        final level = (_dragStart + travel * 100).clamp(0.0, 100.0);
        _dragStart = level;
        unawaited(widget.controller.setVolume(level.round()));
        _rail.show(
          _GoldenRailData(
            icon: _volumeIcon(level),
            value: level / 100,
            label: '${level.round()}%',
            onLeft: false,
          ),
          hideAfter: live ? null : const Duration(milliseconds: 900),
        );
      case _GoldenRailKind.seek:
        // A full screen of travel is 90 seconds — the same scale the
        // horizontal swipe-seek uses per full width, and the VLC seek rail's
        // — so the two seek gestures agree with each other. _dragStart is
        // the running target in seconds, so a run of updates adds up
        // instead of re-seeking from a stale position.
        final duration = widget.controller.value.duration;
        final total = duration.inMilliseconds / 1000.0;
        final target = (_dragStart + travel * 90).clamp(0.0, total);
        _dragStart = target;
        // Build 86: a rail drag is an absolute seek — it cancels a
        // pending debounced step seek and becomes the chain's base.
        _rebaseSeekChain(Duration(milliseconds: (target * 1000).round()));
        unawaited(
          widget.controller.seekTo(
            Duration(milliseconds: (target * 1000).round()),
          ),
        );
        _rail.show(
          _GoldenRailData(
            icon: Icons.fast_forward_rounded,
            value: total > 0 ? target / total : 0,
            label: _formatDuration(
              Duration(milliseconds: (target * 1000).round()),
            ),
            onLeft: false,
          ),
          hideAfter: live ? null : const Duration(milliseconds: 900),
        );
      case _GoldenRailKind.brightness:
        _dragStart = (_dragStart + travel).clamp(0.0, 1.0);
        _brightness = _dragStart;
        _brightnessOverridden = true;
        _brightnessControl.set(_brightness);
        _rail.show(
          _GoldenRailData(
            icon: _brightnessIcon(_brightness),
            value: _brightness,
            label: '${(_brightness * 100).round()}%',
            onLeft: true,
          ),
          hideAfter: live ? null : const Duration(milliseconds: 500),
        );
    }
  }

  static IconData _volumeIcon(double level) {
    if (level <= 0) return Icons.volume_off_rounded;
    if (level < 50) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  static IconData _brightnessIcon(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (clamped < 0.33) return Icons.brightness_5_rounded;
    if (clamped < 0.67) return Icons.brightness_6_rounded;
    return Icons.brightness_7_rounded;
  }

  void _railDragEnd() {
    _dragRail = null;
    _rail.clearAfter(const Duration(milliseconds: 1500));
  }

  // -- drawers ----------------------------------------------------------------

  void _openDrawer(_GoldenDrawerKind kind) {
    if (_drawer == kind) return;
    final wasOpen = _drawer != _GoldenDrawerKind.none;
    setState(() => _drawer = kind);
    // Build 86: the screen shifts the caption left by the drawer's
    // width while it is open. Only on a change of openness: switching
    // from one drawer to another keeps the same width, so the caption
    // does not re-shift.
    if (!wasOpen) {
      widget.chrome.poke(hold: true);
      widget.onDrawerChanged?.call(
        goldenDrawerWidth(MediaQuery.sizeOf(context).width),
      );
    }
  }

  void _closeDrawer() {
    if (_drawer == _GoldenDrawerKind.none) return;
    setState(() => _drawer = _GoldenDrawerKind.none);
    widget.chrome.release();
    widget.onDrawerChanged?.call(0);
  }

  // -- fit / speed / volume ----------------------------------------------------

  void _cycleFit() {
    final next = switch (widget.fit) {
      VlcVideoFit.contain => VlcVideoFit.cover,
      VlcVideoFit.cover => VlcVideoFit.fill,
      _ => VlcVideoFit.contain,
    };
    widget.onFitChanged?.call(next);
    widget.chrome.poke();
  }

  Future<void> _pickSpeed() async {
    final current = widget.controller.value.playbackSpeed;
    final picked = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _SpeedSheet(current: current),
    );
    if (picked == null) return;
    await widget.controller.setPlaybackSpeed(picked);
    widget.chrome.poke();
  }

  Future<void> _pickVolume() async {
    final current = widget.controller.value.volume;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _VolumeSheet(current: current),
    );
    if (picked == null) return;
    await widget.controller.setVolume(picked);
    widget.chrome.poke();
  }

  // -- skip --------------------------------------------------------------------

  void _onSkipSegment(SkipSegment segment) {
    if (segment.type == SkipType.outro && widget.onSkipOutro != null) {
      widget.onSkipOutro!.call();
      return;
    }
    // Build 86: a skip is an absolute seek — it cancels a pending
    // debounced step seek and becomes the chain's base.
    final skipTarget = Duration(milliseconds: (segment.endTime * 1000).round());
    _rebaseSeekChain(skipTarget);
    unawaited(widget.controller.seekTo(skipTarget));
    widget.chrome.poke();
  }

  // -- build -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final settings =
        ref.watch(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    final doubleTapEnabled = settings.doubleTapEnabled;

    return ValueListenableBuilder<bool>(
      valueListenable: widget.chrome,
      builder: (context, chromeVisible, _) {
        final lockedNotifier = widget.locked;
        if (lockedNotifier == null) {
          return _buildStack(
            context,
            chromeVisible: chromeVisible,
            isLocked: false,
            doubleTapEnabled: doubleTapEnabled,
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: lockedNotifier,
          builder: (context, isLocked, _) => _buildStack(
            context,
            chromeVisible: chromeVisible,
            isLocked: isLocked,
            doubleTapEnabled: doubleTapEnabled,
          ),
        );
      },
    );
  }

  Widget _buildStack(
    BuildContext context, {
    required bool chromeVisible,
    required bool isLocked,
    required bool doubleTapEnabled,
  }) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // The gesture layer: tap toggles the chrome, double-tap seeks
        // on the outer thirds and toggles play/pause in the centre
        // third, long-press (right half) holds 2x, pinch zooms,
        // vertical swipe rails volume (right) / brightness (left) /
        // subtitle (centre), and a horizontal swipe seeks (right
        // forward, left back, 90 s per full width).
        // Locked, only a bare tap and the outer-third double-tap seek
        // survive — the tap asks to see the unlock chip, the double-tap
        // skips ±10s; nothing else answers a finger.
        if (isLocked)
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.chrome.poke,
            onDoubleTapDown: doubleTapEnabled
                ? (d) => _doubleTapLocked(d.localPosition.dx)
                : null,
          )
        else
          // The Listener lands the pan's anchor (see [_onPointerDown]):
          // it reports the pointer's down immediately, before any arena
          // resolution, which no recognizer on this detector can do.
          // +34: it also tracks the two-finger pinch itself, because
          // the scale recognizer lost the arena to the long-press
          // deadline and to the first finger winning alone as a pan.
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                if (!_pinchConsumed) {
                  widget.chrome.toggle();
                }
              },
              onDoubleTapDown: doubleTapEnabled
                  ? (d) {
                      if (!_pinchConsumed) {
                        _doubleTap(d.localPosition.dx);
                      }
                    }
                  : null,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onScaleEnd: _onScaleEnd,
              onLongPressStart: (d) {
                if (!_pinchConsumed && !_suppressScale) {
                  _startSpeedBoost(d.localPosition.dx);
                }
              },
              onLongPressEnd: (_) => _endSpeedBoost(),
              onLongPressCancel: _endSpeedBoost,
            ),
          ),

        // The volume / brightness rail, while a vertical swipe is down,
        // then fading on its own clock. Over the video, chrome or not.
        TransientOverlay<_GoldenRailData>(
          value: _rail,
          builder: (context, data) => _GoldenRail(data: data),
        ),

        // The swipe-seek preview (+43): the target time while a
        // horizontal swipe is choosing where to land, as "+62s
        // (3:38)", the stock chrome's toast shape. Over the video,
        // chrome or not: the seekbar's own preview only shows while
        // the chrome is up.
        if (_swipeSeeking)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _swipeSeekLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),

        // The step-seek badge (build 86): the coalesced chain's offset
        // ("+20s" / "−10s") the moment a ±10 s tap lands, so the tap
        // feels instant while the one seek is still 150 ms away. Same
        // pill shape as the swipe-seek preview, centred, over the video,
        // chrome or not.
        if (_stepSeekLabel != null)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _stepSeekLabel!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),

        // Buffering spinner, over the video, chrome or not.
        ValueListenableBuilder<VlcPlayerValue>(
          valueListenable: widget.controller,
          builder: (context, value, _) {
            if (!value.isStalled) return const SizedBox.shrink();
            return Center(
              child: SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                  color: GoldenPlayerColors.accent(context),
                  strokeWidth: 3,
                ),
              ),
            );
          },
        ),

        // The centre play/pause flash, briefly after a centre
        // double-tap. Same dark translucent circle as the centre button.
        AnimatedOpacity(
          opacity: _centerFlashIcon == null ? 0.0 : 1.0,
          duration: GoldenPlayerMotion.fast,
          child: _centerFlashIcon == null
              ? const SizedBox.shrink()
              : Center(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _centerFlashIcon,
                      size: 36,
                      color: GoldenPlayerColors.textPrimary,
                    ),
                  ),
                ),
        ),

        // Top + bottom chrome, fading together in 250 ms.
        AnimatedOpacity(
          opacity: chromeVisible && !isLocked ? 1.0 : 0.0,
          duration: GoldenPlayerMotion.normal,
          child: IgnorePointer(
            ignoring: !chromeVisible || isLocked,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // Top gradient + bar.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: GoldenPlayerColors.topScrim,
                    ),
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
                        child: _TopBar(
                          title: widget.title,
                          episodeLine: widget.episodeLine,
                          subtitle: widget.subtitle,
                          onBack: widget.onBack,
                          hasSubtitles: widget.hasSubtitles,
                          isSeries: _isSeries,
                          onOpenSubtitleStyle: () =>
                              _openDrawer(_GoldenDrawerKind.subtitleStyle),
                          onOpenEpisodes: () =>
                              _openDrawer(_GoldenDrawerKind.episodes),
                          onOpenAudioSources: () =>
                              _openDrawer(_GoldenDrawerKind.audio),
                          onOpenSources: () =>
                              _openDrawer(_GoldenDrawerKind.sources),
                          onPickSpeed: _pickSpeed,
                          onCycleFit: _cycleFit,
                          onRotate: widget.onRotate,
                          // Same gate as the stock chrome: the button
                          // renders only when the screen offers PiP and
                          // the `showPip` setting is on.
                          onEnterPip:
                              widget.onEnterPip != null &&
                                  widget.settings.value.showPip
                              ? widget.onEnterPip
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
                // Centre transport + bottom bar (live values).
                ValueListenableBuilder<VlcPlayerValue>(
                  valueListenable: widget.controller,
                  builder: (context, value, _) {
                    return Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        // Centre: −10 s, play/pause, +10 s.
                        if (!_boosting)
                          Center(
                            child: _CentreTransport(
                              // Build 73: a film that is buffering is
                              // a playing film (the spinner says it is
                              // waiting) — it must not show the play
                              // icon as if the viewer had paused it.
                              isPlaying:
                                  value.isPlaying ||
                                  value.state == VlcPlaybackState.buffering,
                              onTogglePlay: _togglePlay,
                              onRewind: () => _seekBy(-_kGoldenSeekStep),
                              onForward: () => _seekBy(_kGoldenSeekStep),
                            ),
                          ),
                        // Bottom gradient + bar.
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            decoration: const BoxDecoration(
                              gradient: GoldenPlayerColors.bottomScrim,
                            ),
                            child: SafeArea(
                              top: false,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  28,
                                  12,
                                  10,
                                ),
                                child: _BottomBar(
                                  controller: widget.controller,
                                  bufferedFraction: widget.bufferedFraction,
                                  downloadedFraction: widget.downloadedFraction,
                                  isLive: widget.isLive,
                                  seeking: _seeking,
                                  seekPreview: _seekPreview,
                                  onSeekStart: (_) {
                                    setState(() => _seeking = true);
                                    widget.chrome.poke(hold: true);
                                  },
                                  onSeekUpdate: (target) {
                                    setState(() => _seekPreview = target);
                                  },
                                  onSeekEnd: (target) async {
                                    // Build 86: a scrub is an absolute
                                    // seek — it cancels a pending debounced
                                    // step seek and becomes the chain's
                                    // base.
                                    _rebaseSeekChain(target);
                                    await widget.controller.seekTo(target);
                                    if (mounted) {
                                      setState(() => _seeking = false);
                                    }
                                    widget.chrome.release();
                                  },
                                  onPreviousEpisode: widget.onPreviousEpisode,
                                  onNextEpisode: widget.onNextEpisode,
                                  hasSubtitles: widget.hasSubtitles,
                                  onOpenSubtitleStyle: () => _openDrawer(
                                    _GoldenDrawerKind.subtitleStyle,
                                  ),
                                  onOpenAudioSources: () =>
                                      _openDrawer(_GoldenDrawerKind.audio),
                                  onOpenSources: () =>
                                      _openDrawer(_GoldenDrawerKind.sources),
                                  // Video output presets (+57): the
                                  // button renders only where the screen
                                  // offers a live preset apply (iOS mpv);
                                  // null on Android.
                                  sleepTimer: widget.sleepTimer,
                                  onOpenVideo:
                                      widget.onVideoPresetChanged != null ||
                                          widget.sleepTimer != null
                                      ? () =>
                                            _openDrawer(_GoldenDrawerKind.video)
                                      : null,
                                  onPickVolume: _pickVolume,
                                  // While a 2x hold is down, the chip shows
                                  // the speed the hold will restore (1x) —
                                  // never "2x": the viewer asked for no
                                  // "2x" written anywhere during a hold.
                                  speed:
                                      _speedBeforeBoost ?? value.playbackSpeed,
                                  onPickSpeed: _pickSpeed,
                                  locked: _locked,
                                  lockAvailable: widget.lockAvailable,
                                  onToggleLock: () {
                                    // A lock toggle mid-touch swaps the
                                    // gesture layer, so the Listener
                                    // stops hearing pointer-ups: clear
                                    // the raw-pinch state or a stale
                                    // pinch would suppress the scale
                                    // recognizer after unlock (+34).
                                    _clearRawPinchState();
                                    widget.locked?.value = !(_locked);
                                    widget.chrome.poke();
                                  },
                                  fit: widget.fit,
                                  onCycleFit: _cycleFit,
                                  onRotate: widget.onRotate,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                // Skip intro/outro chip, above the bottom bar.
                ValueListenableBuilder<VlcPlayerValue>(
                  valueListenable: widget.controller,
                  builder: (context, value, _) {
                    final segment = segmentAt(
                      widget.skipSegments,
                      value.position,
                    );
                    if (segment == null) return const SizedBox.shrink();
                    final isOutro = segment.type == SkipType.outro;
                    final label = isOutro ? 'Next Episode' : 'Skip Intro';
                    return Positioned(
                      right: 16,
                      bottom: 108,
                      child: GoldenPill(
                        filled: true,
                        onTap: () => _onSkipSegment(segment),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(label),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.skip_next_rounded,
                              size: 16,
                              color: Colors.black,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),

        // Locked: the unlock chip, the only control on screen.
        if (isLocked)
          Center(
            child: AnimatedOpacity(
              opacity: chromeVisible ? 1.0 : 0.0,
              duration: GoldenPlayerMotion.normal,
              // The IgnorePointer is load-bearing, as in the stock chrome
              // (+25): `AnimatedOpacity` at zero paints nothing but still
              // hit-tests, so without it an invisible pill would sit in
              // the middle of a locked screen and the first tap meant to
              // show the pill would unlock instead.
              child: IgnorePointer(
                ignoring: !chromeVisible,
                child: GoldenPill(
                  filled: true,
                  onTap: () {
                    widget.locked?.value = false;
                    widget.chrome.poke();
                  },
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.lock_open_rounded, size: 16),
                      SizedBox(width: 6),
                      Text('Tap to unlock'),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // A drawer over the video (280 ms both ways), in two parts so
        // they never move together: the scrim FADES in place — a scrim
        // that slid with the panel read as a dark curtain sweeping
        // right-to-left across the video — and only the panel SLIDES in
        // from the right. The scrim is keyed by open/closed, so switching
        // drawers keeps it steady instead of fading it out and back in.
        AnimatedSwitcher(
          duration: GoldenPlayerMotion.drawer,
          switchInCurve: GoldenPlayerMotion.curve,
          switchOutCurve: GoldenPlayerMotion.curve,
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: _drawer == _GoldenDrawerKind.none
              ? const SizedBox.shrink(key: ValueKey<String>('scrim-none'))
              : GoldenDrawerScrim(
                  key: const ValueKey<String>('scrim-open'),
                  onClose: _closeDrawer,
                ),
        ),
        AnimatedSwitcher(
          duration: GoldenPlayerMotion.drawer,
          switchInCurve: GoldenPlayerMotion.curve,
          switchOutCurve: GoldenPlayerMotion.curve,
          transitionBuilder: (child, animation) {
            final offset = Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(animation);
            return SlideTransition(position: offset, child: child);
          },
          child: _drawer == _GoldenDrawerKind.none
              ? const SizedBox.shrink(key: ValueKey<String>('none'))
              : _buildDrawer(context),
        ),
      ],
    );
  }

  Widget _buildDrawer(BuildContext context) {
    final kind = _drawer;
    final data = widget.panelData.value;
    switch (kind) {
      case _GoldenDrawerKind.episodes:
        return GoldenEpisodesDrawer(
          key: ValueKey<_GoldenDrawerKind>(kind),
          episodes: data.episodes,
          currentEpisode: data.currentEpisode,
          onPick: (episode) {
            _closeDrawer();
            widget.onPickEpisode(episode);
          },
          onClose: _closeDrawer,
          episodeProgress: widget.episodeProgress,
          episodeDuration: widget.episodeDuration,
        );
      case _GoldenDrawerKind.subtitleStyle:
        return GoldenSubtitleStyleDrawer(
          key: ValueKey<_GoldenDrawerKind>(kind),
          settings: widget.settings,
          notifier: widget.settingsNotifier,
          controller: widget.controller,
          onClose: _closeDrawer,
          onSubtitlePicked: widget.onSubtitlePicked,
          subtitleTarget: widget.panelData.value.subtitleTarget,
          // Build 86: the live caption line, for the Manual slider's
          // mini-preview — the preview shows the caption the viewer is
          // actually moving, in the current style.
          previewSubtitle: widget.subtitle,
        );
      case _GoldenDrawerKind.audio:
        return GoldenAudioDrawer(
          key: ValueKey<_GoldenDrawerKind>(kind),
          controller: widget.controller,
          onClose: _closeDrawer,
          onAudioPicked: widget.onAudioPicked,
        );
      case _GoldenDrawerKind.sources:
        return GoldenSourcesDrawer(
          key: ValueKey<_GoldenDrawerKind>(kind),
          panelData: widget.panelData,
          onClose: _closeDrawer,
          onPickSource: (index) {
            _closeDrawer();
            widget.onPickSource(index);
          },
        );
      case _GoldenDrawerKind.video:
        // Video output presets (+57): the drawer persists the pick
        // through the settings notifier and the screen applies it to
        // the live mpv instance at once, so the picture changes on
        // the current video. The notifier set is unawaited — the Hive
        // write completes in the background and the drawer rebuilds
        // from the live settings value.
        return GoldenVideoDrawer(
          key: ValueKey<_GoldenDrawerKind>(kind),
          settings: widget.settings,
          sleepTimer: widget.sleepTimer,
          showPresets: widget.onVideoPresetChanged != null,
          isHdr: widget.videoIsHdr,
          onPictureChanged: widget.onPictureChanged,
          onPresetPicked: (preset) {
            unawaited(widget.settingsNotifier.setVideoOutputPreset(preset));
            widget.onVideoPresetChanged?.call(preset);
          },
          onClose: _closeDrawer,
        );
      case _GoldenDrawerKind.none:
        return const SizedBox.shrink();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // A drawer left open holds the chrome; a dispose must not leave the
    // hold standing on the screen's controller.
    if (_drawer != _GoldenDrawerKind.none) {
      widget.chrome.release();
    }
    // A 2x hold left down restores its speed without a setState — the
    // widget is going away, so there is nothing to repaint.
    final previous = _speedBeforeBoost;
    if (previous != null) {
      _speedBeforeBoost = null;
      unawaited(widget.controller.setPlaybackSpeed(previous));
    }
    _centerFlashTimer?.cancel();
    // Build 86: a pending step seek must never fire after dispose.
    _stepSeeks.dispose();
    _stepSeekLabelTimer?.cancel();
    // Application brightness is a process-wide override, so leaving the
    // player gives the screen back to the system's level.
    if (_brightnessOverridden) _brightnessControl.reset();
    _rail.dispose();
    super.dispose();
  }
}

/// What a vertical swipe's rail shows: the icon, the level 0..1 of the
/// track, the text above it (e.g. `70%`), and which edge it sits on.
class _GoldenRailData {
  const _GoldenRailData({
    required this.icon,
    required this.value,
    required this.label,
    required this.onLeft,
  });

  final IconData icon;
  final double value;
  final String label;
  final bool onLeft;
}

/// The vertical volume / brightness rail, shown while a swipe is down.
///
/// Kept deliberately dumb: it renders a value someone else owns. The
/// gesture that changes it, the engine call and the timer that hides it
/// all live in the controls, so this cannot become a second owner of
/// player state. No pill, no border: just the gold bar floating straight
/// over the video, the number on top and the icon at the bottom — the
/// viewer asked for the dark background to go. Both rails share this
/// widget, so volume (right) and brightness (left) match.
class _GoldenRail extends StatelessWidget {
  const _GoldenRail({required this.data});

  final _GoldenRailData data;

  static const double _trackHeight = 132;

  @override
  Widget build(BuildContext context) {
    final filled = data.value.clamp(0.0, 1.0);
    // The device's safe-area inset on this side: 59pt on the Dynamic
    // Island side of an iPhone 15 Pro Max in landscape, 0 where there is
    // no cutout. The fixed 24 alone put the rail under the island.
    final safe = MediaQuery.paddingOf(context);
    return Align(
      alignment: data.onLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Padding(
        // 24 inside the chrome's side inset, plus the safe area — so the
        // rail sits clear of a notch or camera cutout on either side, on
        // every device, with no hardcoded phone value. Which side the
        // island is on flips with rotation, and the padding follows it.
        padding: EdgeInsets.only(
          left: data.onLeft ? 24 + safe.left : 0,
          right: data.onLeft ? 0 : 24 + safe.right,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              data.label,
              style: const TextStyle(
                color: GoldenPlayerColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: 6,
              height: _trackHeight,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Stack(
                  children: [
                    const Positioned.fill(
                      child: ColoredBox(color: Color(0xFF3A352E)),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: _trackHeight * filled,
                      child: ColoredBox(
                          color: GoldenPlayerColors.accent(context)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Icon(data.icon, color: GoldenPlayerColors.accentHighlight(context), size: 20),
          ],
        ),
      ),
    );
  }
}

/// The top bar: Back, title + lines, subtitle style, Episodes, More.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.episodeLine,
    required this.subtitle,
    required this.onBack,
    required this.hasSubtitles,
    required this.isSeries,
    required this.onOpenSubtitleStyle,
    required this.onOpenEpisodes,
    required this.onOpenAudioSources,
    required this.onOpenSources,
    required this.onPickSpeed,
    required this.onCycleFit,
    required this.onRotate,
    required this.onEnterPip,
  });

  final String title;
  final String? episodeLine;
  final String? subtitle;
  final VoidCallback? onBack;
  final ValueListenable<bool>? hasSubtitles;
  final bool isSeries;
  final VoidCallback onOpenSubtitleStyle;
  final VoidCallback onOpenEpisodes;
  final VoidCallback onOpenAudioSources;
  final VoidCallback onOpenSources;
  final VoidCallback onPickSpeed;
  final VoidCallback onCycleFit;
  final VoidCallback? onRotate;

  /// Non-null when the screen offers PiP and the `showPip`
  /// setting is on; the button is absent otherwise.
  final VoidCallback? onEnterPip;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        GoldenIconButton(
          icon: Icons.arrow_back_rounded,
          onPressed: onBack,
          tooltip: 'Back',
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: GoldenPlayerColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              if (episodeLine != null) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  episodeLine!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GoldenPlayerColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ] else if (subtitle != null) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GoldenPlayerColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (isSeries)
          GoldenIconButton(
            icon: Icons.list_rounded,
            onPressed: onOpenEpisodes,
            tooltip: 'Episodes',
          ),
        if (isSeries) const SizedBox(width: 8),
        // Picture-in-picture (`showPip` on): the same
        // icon and gate as the stock chrome.
        if (onEnterPip != null)
          GoldenIconButton(
            icon: Icons.picture_in_picture_alt_rounded,
            onPressed: onEnterPip,
            tooltip: 'Picture-in-picture',
          ),
        if (onEnterPip != null) const SizedBox(width: 8),
      ],
    );
  }
}

/// The centre transport: −10 s, play/pause (gold circle), +10 s.
class _CentreTransport extends StatelessWidget {
  const _CentreTransport({
    required this.isPlaying,
    required this.onTogglePlay,
    required this.onRewind,
    required this.onForward,
  });

  final bool isPlaying;
  final VoidCallback onTogglePlay;
  final VoidCallback onRewind;
  final VoidCallback onForward;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _CentreSeekButton(icon: Icons.replay_10_rounded, onPressed: onRewind),
        const SizedBox(width: 28),
        // The play/pause button, the same dark translucent circle as the
        // ±10 s seek buttons — no gold fill, so it reads as one row.
        SizedBox(
          width: 72,
          height: 72,
          child: Material(
            color: Colors.black.withValues(alpha: 0.45),
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTogglePlay,
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 36,
                color: GoldenPlayerColors.textPrimary,
              ),
            ),
          ),
        ),
        const SizedBox(width: 28),
        _CentreSeekButton(icon: Icons.forward_10_rounded, onPressed: onForward),
      ],
    );
  }
}

class _CentreSeekButton extends StatelessWidget {
  const _CentreSeekButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 52,
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Icon(icon, size: 28, color: GoldenPlayerColors.textPrimary),
        ),
      ),
    );
  }
}

/// The bottom bar: golden seekbar + times, then the utility row.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.controller,
    required this.bufferedFraction,
    this.downloadedFraction,
    required this.isLive,
    required this.seeking,
    required this.seekPreview,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.hasSubtitles,
    required this.onOpenSubtitleStyle,
    required this.onOpenAudioSources,
    required this.onOpenSources,
    required this.onPickVolume,
    required this.speed,
    required this.onPickSpeed,
    required this.locked,
    required this.lockAvailable,
    required this.onToggleLock,
    required this.fit,
    required this.onCycleFit,
    required this.onRotate,
    this.onOpenVideo,
    this.sleepTimer,
  });

  /// The sleep timer, for the remaining-time badge (v7). Null: no badge.
  final SleepTimer? sleepTimer;

  final VlcPlayerController controller;
  final ValueListenable<double>? bufferedFraction;

  /// Build 107: fraction of the film the temp download holds. Null
  /// when no temp download is running.
  final ValueListenable<double>? downloadedFraction;
  final bool isLive;
  final bool seeking;
  final Duration seekPreview;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<Duration> onSeekUpdate;
  final ValueChanged<Duration> onSeekEnd;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;
  final ValueListenable<bool>? hasSubtitles;
  final VoidCallback onOpenSubtitleStyle;
  final VoidCallback onOpenAudioSources;
  final VoidCallback onOpenSources;

  /// Opens the Video output-preset drawer (+57). Null where the panel
  /// does not exist (Android) — the button never renders then.
  final VoidCallback? onOpenVideo;

  final VoidCallback onPickVolume;
  final double speed;
  final VoidCallback onPickSpeed;
  final bool locked;
  final bool lockAvailable;
  final VoidCallback onToggleLock;
  final VlcVideoFit fit;
  final VoidCallback onCycleFit;
  final VoidCallback? onRotate;

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    final duration = value.duration;
    final canSeek = !isLive && value.isSeekable && duration > Duration.zero;
    final position = seeking ? seekPreview : value.position;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // Seekbar + times.
        Row(
          children: <Widget>[
            SizedBox(
              width: 52,
              child: Text(
                goldenFormatTime(position),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: GoldenPlayerColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: canSeek
                  ? _GoldenSeekBar(
                      controller: controller,
                      bufferedFraction: bufferedFraction,
                      downloadedFraction: downloadedFraction,
                      position: position,
                      duration: duration,
                      onSeekStart: onSeekStart,
                      onSeekUpdate: onSeekUpdate,
                      onSeekEnd: onSeekEnd,
                    )
                  : const _LiveBadge(),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 52,
              child: Text(
                goldenFormatTime(duration),
                style: const TextStyle(
                  color: GoldenPlayerColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Utility row.
        Row(
          children: <Widget>[
            if (onPreviousEpisode != null)
              GoldenIconButton(
                icon: Icons.skip_previous_rounded,
                onPressed: onPreviousEpisode,
                tooltip: 'Previous episode',
                size: 38,
              ),
            if (onNextEpisode != null) ...<Widget>[
              const SizedBox(width: 6),
              GoldenIconButton(
                icon: Icons.skip_next_rounded,
                onPressed: onNextEpisode,
                tooltip: 'Next episode',
                size: 38,
              ),
            ],
            // Sleep timer (v7): the time left, only while one is armed.
            // A tap opens the drawer the picker lives in.
            // v9: the buttons after this sit flush right, always. The
            // badge used to be a Flexible beside a Spacer — the two split
            // the free width, the badge used a sliver of its half, and
            // the unused rest pushed the buttons to the middle whenever a
            // timer was armed. One Expanded now owns all the free width.
            GoldenBottomRowGap(sleepTimer: sleepTimer, onTap: onOpenVideo),
            _SubtitleButton(
              hasSubtitles: hasSubtitles,
              onPressed: onOpenSubtitleStyle,
            ),
            const SizedBox(width: 6),
            // Audio, straight from the bottom bar — the same drawer the
            // top-right More menu opens. Sources sits beside it, as its
            // own button and its own drawer.
            GoldenIconButton(
              icon: Icons.audiotrack_rounded,
              onPressed: onOpenAudioSources,
              tooltip: 'Audio',
              size: 38,
            ),
            const SizedBox(width: 6),
            GoldenIconButton(
              icon: Icons.dns_rounded,
              onPressed: onOpenSources,
              tooltip: 'Sources',
              size: 38,
            ),
            const SizedBox(width: 6),
            // Video output presets (+57), beside Sources — the panel the
            // Infuse screenshot shows. iOS mpv only: onOpenVideo is null
            // on Android, and the button never renders then.
            if (onOpenVideo != null)
              GoldenIconButton(
                icon: Icons.tune_rounded,
                onPressed: onOpenVideo!,
                tooltip: 'Video',
                size: 38,
              ),
            const SizedBox(width: 6),
            GoldenIconButton(
              icon: Icons.volume_up_rounded,
              onPressed: onPickVolume,
              tooltip: 'Volume',
              size: 38,
            ),
            const SizedBox(width: 6),
            GoldenPill(
              onTap: onPickSpeed,
              child: Text('${_formatSpeed(speed)}x'),
            ),
            const SizedBox(width: 6),
            if (lockAvailable)
              GoldenIconButton(
                icon: locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                onPressed: onToggleLock,
                active: locked,
                tooltip: locked ? 'Unlock' : 'Lock',
                size: 38,
              ),
            if (lockAvailable) const SizedBox(width: 6),
            GoldenIconButton(
              icon: _fitIcon(fit),
              onPressed: onCycleFit,
              tooltip: 'Aspect ratio',
              size: 38,
            ),
          ],
        ),
      ],
    );
  }

  static String _formatSpeed(double speed) {
    final text = speed.toStringAsFixed(2);
    return text.endsWith('00')
        ? text.substring(0, text.length - 3)
        : (text.endsWith('0') ? text.substring(0, text.length - 1) : text);
  }

  static IconData _fitIcon(VlcVideoFit fit) => switch (fit) {
    VlcVideoFit.cover => Icons.crop_rounded,
    VlcVideoFit.fill => Icons.fit_screen_rounded,
    _ => Icons.aspect_ratio_rounded,
  };
}

/// The stretch of the bottom utility row between the episode buttons on
/// the left and the option buttons on the right (v9). It owns all the
/// free width, so the option buttons always sit flush right; the
/// sleep-timer badge, when one is armed, rides at its left end.
class GoldenBottomRowGap extends StatelessWidget {
  const GoldenBottomRowGap({super.key, this.sleepTimer, this.onTap});

  final SleepTimer? sleepTimer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final timer = sleepTimer;
    return Expanded(
      child: timer == null
          ? const SizedBox.shrink()
          : Align(
              alignment: AlignmentDirectional.centerStart,
              child: GoldenSleepTimerBadge(timer: timer, onTap: onTap),
            ),
    );
  }
}

class _SubtitleButton extends StatelessWidget {
  const _SubtitleButton({required this.hasSubtitles, required this.onPressed});

  final ValueListenable<bool>? hasSubtitles;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final hasSubs = hasSubtitles;
    if (hasSubs == null) {
      return GoldenIconButton(
        icon: Icons.closed_caption_outlined,
        onPressed: onPressed,
        tooltip: 'Subtitles',
        size: 38,
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: hasSubs,
      builder: (context, has, _) => has
          ? GoldenIconButton(
              icon: Icons.closed_caption_outlined,
              onPressed: onPressed,
              tooltip: 'Subtitles',
              size: 38,
            )
          : const SizedBox.shrink(),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: <Widget>[
        Icon(Icons.circle, size: 8, color: Color(0xFFEF5350)),
        SizedBox(width: 6),
        Text(
          'LIVE',
          style: TextStyle(
            color: GoldenPlayerColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

/// The thin golden seekbar: buffered band behind a gold Slider.
class _GoldenSeekBar extends StatelessWidget {
  const _GoldenSeekBar({
    required this.controller,
    required this.bufferedFraction,
    this.downloadedFraction,
    required this.position,
    required this.duration,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
  });

  final VlcPlayerController controller;
  final ValueListenable<double>? bufferedFraction;

  /// Build 107: fraction of the film the temp download holds. Null
  /// when no temp download is running.
  final ValueListenable<double>? downloadedFraction;
  final Duration position;
  final Duration duration;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<Duration> onSeekUpdate;
  final ValueChanged<Duration> onSeekEnd;

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds.toDouble();
    final valueMs = position.inMilliseconds
        .clamp(0, duration.inMilliseconds)
        .toDouble();
    final buffered = bufferedFraction;
    final downloaded = downloadedFraction;
    return SizedBox(
      height: 28,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // Build 107: downloaded band, under the buffered band. Gold:
          // everything under it seeks instantly from the local temp
          // file. Drawn the same way as the buffered band (inside the
          // track's inset, same width rule), so the two agree about
          // where the film is.
          if (downloaded != null)
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: kSeekBandTrackInset,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return ValueListenableBuilder<double>(
                      valueListenable: downloaded,
                      builder: (context, fraction, _) {
                        final width = seekBandWidth(
                          trackWidth: constraints.maxWidth,
                          bandFraction: fraction,
                          positionFraction: totalMs > 0 ? valueMs / totalMs : 0,
                        );
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: width,
                            height: 6,
                            decoration: BoxDecoration(
                              color: GoldenPlayerColors.accent(context).withValues(
                                alpha: 0.45,
                              ),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          // Buffered band, under the slider's track. Build 72: drawn
          // inside the track's own inset (it used to span the full box,
          // so it ended up to 14 px short and a small buffer hid under
          // the thumb), a little brighter and taller than the 4 px
          // track. Build 76: its end is the real end of the buffer —
          // no minimum length past the thumb.
          if (buffered != null)
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: kSeekBandTrackInset,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return ValueListenableBuilder<double>(
                      valueListenable: buffered,
                      builder: (context, fraction, _) {
                        final width = seekBandWidth(
                          trackWidth: constraints.maxWidth,
                          bandFraction: fraction,
                          positionFraction: totalMs > 0 ? valueMs / totalMs : 0,
                        );
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: width,
                            height: 6,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.62),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: GoldenPlayerColors.accent(context),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.18),
              thumbColor: GoldenPlayerColors.accentHighlight(context),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayColor: GoldenPlayerColors.accent(context).withValues(alpha: 0.2),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: totalMs > 0 ? valueMs : 0,
              min: 0,
              max: totalMs > 0 ? totalMs : 1,
              onChangeStart: onSeekStart,
              onChanged: (v) => onSeekUpdate(Duration(milliseconds: v.round())),
              onChangeEnd: (v) => onSeekEnd(Duration(milliseconds: v.round())),
            ),
          ),
        ],
      ),
    );
  }
}

/// The speed picker: a gold bottom sheet with speed chips.
class _SpeedSheet extends StatelessWidget {
  const _SpeedSheet({required this.current});

  final double current;

  static const List<double> _speeds = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
    3.0,
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: GoldenPlayerColors.backgroundSecondary,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(GoldenPlayerRadii.drawer),
          topRight: Radius.circular(GoldenPlayerRadii.drawer),
        ),
        border: Border(top: GoldenPlayerColors.drawerBorder),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text(
                'Playback speed',
                style: TextStyle(
                  color: GoldenPlayerColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final speed in _speeds)
                    GoldenPill(
                      filled: (speed - current).abs() < 0.01,
                      onTap: () => Navigator.of(context).pop(speed),
                      child: Text('${_BottomBar._formatSpeed(speed)}x'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The volume picker: a gold bottom sheet with a slider.
class _VolumeSheet extends StatefulWidget {
  const _VolumeSheet({required this.current});

  final int current;

  @override
  State<_VolumeSheet> createState() => _VolumeSheetState();
}

class _VolumeSheetState extends State<_VolumeSheet> {
  late double _volume;

  @override
  void initState() {
    super.initState();
    _volume = widget.current.clamp(0, 100).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: GoldenPlayerColors.backgroundSecondary,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(GoldenPlayerRadii.drawer),
          topRight: Radius.circular(GoldenPlayerRadii.drawer),
        ),
        border: Border(top: GoldenPlayerColors.drawerBorder),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Text(
                    'Volume',
                    style: TextStyle(
                      color: GoldenPlayerColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_volume.round()}%',
                    style: TextStyle(
                      color: GoldenPlayerColors.accentHighlight(context),
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: GoldenPlayerColors.accent(context),
                  inactiveTrackColor: Colors.white.withValues(alpha: 0.18),
                  thumbColor: GoldenPlayerColors.accentHighlight(context),
                  overlayColor: GoldenPlayerColors.accent(context).withValues(alpha: 0.2),
                ),
                child: Slider(
                  value: _volume,
                  min: 0,
                  max: 100,
                  divisions: 20,
                  onChanged: (v) => setState(() => _volume = v),
                  onChangeEnd: (v) => Navigator.of(context).pop(v.round()),
                ),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.of(context).pop(0),
                child: Text(
                  'Mute',
                  style: TextStyle(
                    color: GoldenPlayerColors.accentHighlight(context),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
