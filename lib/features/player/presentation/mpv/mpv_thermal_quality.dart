/// Thermal-aware quality: when the phone is hot, drop a heavy stream to a
/// lighter one, and come back when it cools.
///
/// The mechanism (user report 2026-11-15): 4K plays smooth in ZoroX
/// until the phone heats up, then it gets laggy and never recovers —
/// Nuvio does not do this. The likely cause is the VideoToolbox session
/// being invalidated under thermal pressure: without
/// `hwdec-software-fallback` (now set on iOS too, see
/// [mpv_ios_options.dart]) mpv fell to software decode for the rest of
/// the file, burning CPU and making more heat. This governor is the
/// second half: when the OS itself says the phone is serious or critical,
/// drop the 4K stream for the best lighter one, so the decoder has less
/// work and the phone can cool; restore the original when it stays
/// nominal for a minute. A single-file source has no lighter stream to
/// drop to (+33: the 20.96 GB 4K file), so there the governor lightens
/// the render instead — and takes it off on the same 2-nominal-polls
/// rule. The lightening's actuation is split by platform (+34): on iOS
/// the screen caps the render target to 1920x1080 through
/// `VideoController.setSize` (see `mpv_player_screen.dart`); on Android
/// the screen applies the `vf` scale + lavc options below. The split
/// exists because the +33 `vf` lighten was unreliable on iOS: under
/// zero-copy videotoolbox a `vf=scale` forces a GPU→CPU download, a CPU
/// scale and a re-upload (a net loss), `vd-lavc-fast` is MPEG-1/2 and
/// H.264 only (a no-op on the HEVC file), and `vd-lavc-skiploopfilter`
/// is ignored under VideoToolbox hardware decode.
///
/// The governor is pure: it decides, the player screen acts. It keeps
/// the drop episode's state — what it dropped from and to, the nominal
/// streak, and whether the viewer has taken over by hand. A hand pick
/// always stands: the governor never overrides a source the viewer chose
/// while the hot episode lasts.
library;

import 'package:flutter/foundation.dart';

import '../../../../core/providers/thermal_state.dart';

/// What the governor wants the player to do on this tick.
enum ThermalQualityKind {
  /// No change.
  none,

  /// Switch to [ThermalQualityDecision.targetIndex], a lighter stream.
  drop,

  /// Switch back to [ThermalQualityDecision.targetIndex], the stream the
  /// drop left.
  restore,

  /// No switch: tell the viewer the phone is hot and the Quality tab has
  /// lighter streams. Only for an adaptive (HLS) master, which has no
  /// ladder to switch down — mpv's ABR picks the rendition.
  hint,

  /// No stream switch: lighten the render of the stream now playing
  /// (see [ThermalQualityKind.lighten] actuation: the iOS setSize render
  /// cap, or [kThermalLightenProperties] on Android) — the single-file
  /// answer. A single-file direct link has no ladder, so [drop] is
  /// impossible there; the render is lightened instead, and [unlighten]
  /// takes it off when the phone cools.
  lighten,

  /// Remove the render lightening [lighten] put on.
  unlighten,
}

/// The render lightening the governor asks for on a single-file source
/// (see [ThermalQualityKind.lighten]): downscale the video filter chain
/// to 1080p, so the render has a quarter of the pixels to chew. Only for
/// a stream taller than [ThermalQualityGovernor.dropAboveHeight]; a light
/// stream needs no lightening.
///
/// +34: this filter is the ANDROID lighten actuation only. On iOS the
/// screen caps the render target through `VideoController.setSize`
/// instead — a `vf=scale` under zero-copy videotoolbox forces a
/// GPU→CPU download, a CPU scale and a re-upload, which can be a net
/// loss versus the GPU renderer's own downscale.
const String kThermalLightenVf = 'scale=-2:1080';

/// The mpv properties the lighten response sets on Android, as `option →
/// value`, and the values that clear them again. `vd-lavc-skiploopfilter`
/// and `vd-lavc-fast` are a hedge for the case the hardware decoder
/// session is lost and decode is software: harmless while hardware
/// decode is alive, a saving while it is not. `vf` is the part that
/// always helps on Android — it re-inits the filter chain at once, no
/// re-open needed. Verified against mpv's option list: `vf` is a
/// runtime property, `vd-lavc-skiploopfilter` takes
/// none/default/nonref/bidir/nonkey/all, `vd-lavc-fast` is a flag.
///
/// On iOS these properties are NOT applied (+34): `vd-lavc-fast` is
/// MPEG-1/2 and H.264 only (a no-op on the HEVC 4K file),
/// `vd-lavc-skiploopfilter` is ignored under VideoToolbox hardware
/// decode, and `vf=scale` under zero-copy videotoolbox forces the
/// download/scale/re-upload round trip. iOS lightens through the
/// setSize render cap instead (see `mpv_player_screen.dart`).
const Map<String, String> kThermalLightenProperties = <String, String>{
  'vf': kThermalLightenVf,
  'vd-lavc-skiploopfilter': 'all',
  'vd-lavc-fast': 'yes',
};

/// The values that undo [kThermalLightenProperties] on Android: an empty
/// filter chain, and the lavc defaults.
const Map<String, String> kThermalUnlightenProperties = <String, String>{
  'vf': '',
  'vd-lavc-skiploopfilter': 'default',
  'vd-lavc-fast': 'no',
};

/// One tick's decision: [kind] + the stream index to switch to.
/// [targetIndex] is -1 for [ThermalQualityKind.none] and
/// [ThermalQualityKind.hint], which switch nothing.
@immutable
class ThermalQualityDecision {
  const ThermalQualityDecision.none()
    : kind = ThermalQualityKind.none,
      targetIndex = -1;

  const ThermalQualityDecision.drop(this.targetIndex)
    : kind = ThermalQualityKind.drop;

  const ThermalQualityDecision.restore(this.targetIndex)
    : kind = ThermalQualityKind.restore;

  const ThermalQualityDecision.hint()
    : kind = ThermalQualityKind.hint,
      targetIndex = -1;

  /// Lighten the render of the stream now playing (single-file only).
  const ThermalQualityDecision.lighten()
    : kind = ThermalQualityKind.lighten,
      targetIndex = -1;

  /// Take the render lightening off again.
  const ThermalQualityDecision.unlighten()
    : kind = ThermalQualityKind.unlighten,
      targetIndex = -1;

  final ThermalQualityKind kind;
  final int targetIndex;

  bool get isNone => kind == ThermalQualityKind.none;
}

/// The best lighter stream: the tallest one at or below [maxHeight],
/// or — when no stream is that light — the tallest one below
/// [currentHeight]. Null when nothing is lighter. Shared by the
/// thermal governor and the PiP quality drop (+31): both walk the same
/// ladder, only the ceiling differs (1080p for heat, 480p for PiP).
int? bestLighterStreamIndex(
  List<int?> qualities,
  int currentHeight,
  int maxHeight,
) {
  int? bestBelow;
  int? bestLight;
  for (var i = 0; i < qualities.length; i++) {
    final quality = qualities[i];
    if (quality == null || quality <= 0 || quality >= currentHeight) {
      continue;
    }
    if (bestBelow == null || quality > qualities[bestBelow]!) {
      bestBelow = i;
    }
    if (quality <= maxHeight &&
        (bestLight == null || quality > qualities[bestLight]!)) {
      bestLight = i;
    }
  }
  return bestLight ?? bestBelow;
}

/// Decides, per tick, whether the phone's heat wants a quality change.
///
/// Fed the OS thermal state, every stream's height (`null` or `0` for an
/// adaptive HLS master — see `StreamResult.quality`) and the stream now
/// playing. The screen calls [evaluate] on its thermal timer and acts on
/// the decision; it calls [noteManualPick] from the source/Quality pick
/// path, so a hand pick is never overridden.
class ThermalQualityGovernor {
  ThermalQualityGovernor({
    this.dropAboveHeight = 1080,
    this.restoreNominalTicks = 2,
  });

  /// A stream taller than this is heavy: dropped when the phone is hot.
  final int dropAboveHeight;

  /// Consecutive nominal ticks before the original stream is restored.
  final int restoreNominalTicks;

  int? _droppedFrom;
  int? _droppedTo;
  int? _manualPickIndex;
  int _nominalStreak = 0;
  bool _hintShown = false;

  /// While the render lightening is on (single-file response).
  bool _lightened = false;

  /// Consecutive nominal ticks while lightened, before it comes off.
  int _lightenNominalStreak = 0;

  /// True while the render lightening is on (single-file response).
  bool get isLightened => _lightened;

  /// True while a governor drop is in effect.
  bool get isDropped => _droppedFrom != null;

  /// The viewer picked a source by hand. A hand pick stands until the
  /// phone cools: the governor never overrides it while this hot episode
  /// lasts. A tap on the stream the governor itself dropped to is a
  /// no-op, not a pick.
  void noteManualPick(int index) {
    if (_droppedTo != null && index == _droppedTo) return;
    _manualPickIndex = index;
  }

  /// One tick's decision. Never throws: a bad index or an empty list is
  /// no change.
  ///
  /// [inPip] is true while the PiP window is up (+31): the PiP drop owns
  /// quality then, so the ladder logic is skipped entirely — a ladder
  /// decision would see the PiP target as a third source and cancel the
  /// governor's own drop episode — and only the render lightening is
  /// evaluated. Lightening changes no stream, so it cannot fight the
  /// PiP drop, and for a single-file source it is the only thermal
  /// relief there is.
  ThermalQualityDecision evaluate({
    required ThermalState thermal,
    required List<int?> qualities,
    required int currentIndex,
    bool inPip = false,
  }) {
    if (currentIndex < 0 || currentIndex >= qualities.length) {
      return const ThermalQualityDecision.none();
    }
    final height = qualities[currentIndex];

    if (inPip) {
      return _evaluateLighten(
        thermal: thermal,
        height: height,
        currentIndex: currentIndex,
      );
    }

    if (_lightened) {
      return _evaluateLightened(
        thermal: thermal,
        height: height,
        currentIndex: currentIndex,
      );
    }

    if (_droppedFrom != null) {
      if (currentIndex == _droppedFrom) {
        // Back on the original — the restore landed, or the viewer
        // re-picked it by hand. The episode is over, and the hand pick
        // stands if it was one.
        _manualPickIndex = currentIndex;
        _clearDrop();
        return const ThermalQualityDecision.none();
      }
      if (currentIndex != _droppedTo) {
        // The viewer picked a third source mid-episode: their choice
        // stands, the drop is over.
        _manualPickIndex = currentIndex;
        _clearDrop();
        return const ThermalQualityDecision.none();
      }
      // Still on the dropped-to stream: watch for cooling. Anything but
      // nominal — including an unreadable state — resets the streak, so
      // the restore only happens on a phone that is really cool.
      if (thermal == ThermalState.nominal) {
        _nominalStreak++;
        if (_nominalStreak >= restoreNominalTicks) {
          final from = _droppedFrom!;
          _clearDrop();
          return ThermalQualityDecision.restore(from);
        }
      } else {
        _nominalStreak = 0;
      }
      return const ThermalQualityDecision.none();
    }

    // Not dropped. A hand pick stands until the phone cools; a pick that
    // is no longer current (failover, a new episode's auto-open) is
    // forgotten.
    if (_manualPickIndex != null) {
      if (currentIndex == _manualPickIndex) {
        if (thermal == ThermalState.nominal) _manualPickIndex = null;
        return const ThermalQualityDecision.none();
      }
      _manualPickIndex = null;
    }
    if (thermal == ThermalState.nominal) {
      // Cool again: a fresh episode starts, the hint may show again.
      _hintShown = false;
      return const ThermalQualityDecision.none();
    }
    if (thermal != ThermalState.serious &&
        thermal != ThermalState.critical) {
      // Fair: warm but not throttling — watch, don't act.
      return const ThermalQualityDecision.none();
    }

    // Hot from here. An adaptive master has no ladder to switch down:
    // one hint per episode, and the viewer picks in the Quality tab.
    if (height == null || height == 0) {
      if (_hintShown) return const ThermalQualityDecision.none();
      _hintShown = true;
      return const ThermalQualityDecision.hint();
    }
    if (height <= dropAboveHeight) return const ThermalQualityDecision.none();
    final target = _bestLighterIndex(qualities, height);
    if (target != null) {
      _droppedFrom = currentIndex;
      _droppedTo = target;
      _nominalStreak = 0;
      return ThermalQualityDecision.drop(target);
    }
    // No lighter stream: a single-file source (the 20.96 GB 4K file the
    // user reported, 2026-11-15) — the ladder drop is a no-op there, so
    // lighten the render instead. The stream never changes, so a hand
    // pick cannot be overridden by this; the manual-pick latch above
    // already returned for a picked stream.
    _lightened = true;
    _lightenNominalStreak = 0;
    return const ThermalQualityDecision.lighten();
  }

  /// The render lightening, evaluated while the PiP window is up (see
  /// [evaluate]): the only thermal response that cannot fight the PiP
  /// drop, because it changes no stream.
  ThermalQualityDecision _evaluateLighten({
    required ThermalState thermal,
    required int? height,
    required int currentIndex,
  }) {
    // A hand pick stands, in PiP as out of it; a pick that is no longer
    // current is forgotten.
    if (_manualPickIndex != null) {
      if (currentIndex == _manualPickIndex) {
        if (thermal == ThermalState.nominal) _manualPickIndex = null;
        return const ThermalQualityDecision.none();
      }
      _manualPickIndex = null;
    }
    if (_lightened) {
      return _evaluateLightened(
        thermal: thermal,
        height: height,
        currentIndex: currentIndex,
      );
    }
    if (thermal != ThermalState.serious &&
        thermal != ThermalState.critical) {
      return const ThermalQualityDecision.none();
    }
    if (height == null || height == 0 || height <= dropAboveHeight) {
      return const ThermalQualityDecision.none();
    }
    _lightened = true;
    _lightenNominalStreak = 0;
    return const ThermalQualityDecision.lighten();
  }

  /// The lightened state: watch for cooling, or for the stream itself
  /// becoming light (a switch to a lighter source makes the lightening
  /// pointless). Anything but nominal resets the streak, so the
  /// lightening only comes off on a phone that is really cool.
  ThermalQualityDecision _evaluateLightened({
    required ThermalState thermal,
    required int? height,
    required int currentIndex,
  }) {
    if (height != null && height > 0 && height <= dropAboveHeight) {
      _clearLighten();
      return const ThermalQualityDecision.unlighten();
    }
    if (thermal == ThermalState.nominal) {
      _lightenNominalStreak++;
      if (_lightenNominalStreak >= restoreNominalTicks) {
        _clearLighten();
        return const ThermalQualityDecision.unlighten();
      }
    } else {
      _lightenNominalStreak = 0;
    }
    return const ThermalQualityDecision.none();
  }

  void _clearLighten() {
    _lightened = false;
    _lightenNominalStreak = 0;
  }

  /// The best lighter stream for the governor's ceiling.
  int? _bestLighterIndex(List<int?> qualities, int currentHeight) =>
      bestLighterStreamIndex(qualities, currentHeight, dropAboveHeight);

  void _clearDrop() {
    _droppedFrom = null;
    _droppedTo = null;
    _nominalStreak = 0;
  }
}
