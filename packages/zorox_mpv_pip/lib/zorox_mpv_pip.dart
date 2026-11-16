/// iOS Picture-in-Picture for the mpv (Golden) player.
///
/// Thin MethodChannel wrapper around the native `ZoroxMpvPipPlugin`
/// (iOS only). The native side taps the frames the forked `media_kit_video`
/// software renderer already produces (see `packages/media_kit_video/
/// FORK.md`), wraps each one as a `CMSampleBuffer`, and drives an
/// `AVPictureInPictureController` from an `AVSampleBufferDisplayLayer`.
///
/// The controller owns no player: the screen passes playback state in and
/// wires the native callbacks out. Subtitles are the screen's job too —
/// mpv's own `sub-visibility` is switched on when PiP actually starts and
/// restored when it stops (see the screen's PiP handlers); this controller
/// never touches it, so normal playback can never show a doubled caption.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The native mpv PiP bridge, iOS only.
///
/// One instance per player screen. Create it when the player opens (only
/// when the iOS mpv PiP setting is on — the player runs the software
/// renderer in that mode), `prepare` once the media is loaded, and
/// `dispose` when the screen goes away.
///
/// The platform gate reads [defaultTargetPlatform] rather than
/// `Platform.isIOS`, because only the former can be overridden by a test
/// (the same convention as `PlayerPlatformService`).
class MpvPipIos {
  static const MethodChannel _channel = MethodChannel(
    'dev.akash.skystream.player/pip_mpv_ios',
  );

  bool _prepared = false;
  bool _inPip = false;

  /// Whether `prepare` has run and the native source exists.
  bool get isPrepared => _prepared;

  /// Whether the native PiP window is up right now.
  bool get inPip => _inPip;

  /// Fired when the native PiP window actually opens.
  void Function()? onPipStarted;

  /// Fired when the native PiP window closes. [restored] is true when the
  /// viewer tapped the window to come back to the player, false when the
  /// window was closed (X) instead.
  void Function(bool restored)? onPipStopped;

  /// Fired when the native window or the system could not open PiP.
  void Function(String reason)? onPipFailed;

  /// The PiP window's play/pause button was pressed.
  void Function(bool playing)? onPipSetPlaying;

  /// The PiP window asked to skip by [seconds] (positive forward).
  void Function(int seconds)? onPipSkip;

  /// Whether this device can do sample-buffer PiP at all.
  ///
  /// False off iOS, and false when the native plugin is not registered
  /// (an old build). Never throws.
  static Future<bool> get isSupported async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Creates the native source layer and arms frame delivery.
  ///
  /// Call once, after the player is created and the media is loaded.
  /// The native side holds the latest frame as a prime in memory and
  /// pushes it into the layer only when a PiP start is attempted (the
  /// button, or the app backgrounding for auto-PiP) — the layer must
  /// already hold a frame or the start refuses (+30). The layer stays
  /// empty in-app: it sits above Flutter's rendered view, so any frame
  /// in it would show as a second copy of the video inside the app.
  Future<void> prepare({
    required Duration position,
    required Duration duration,
    required bool playing,
    double rate = 1.0,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    // Synchronous: setMethodCallHandler returns void, not a Future.
    _channel.setMethodCallHandler(_onNativeCall);
    await _channel.invokeMethod<void>('prepare', <String, Object>{
      'position': position.inMilliseconds / 1000,
      'duration': duration.inMilliseconds / 1000,
      'playing': playing,
      'rate': rate,
    });
    _prepared = true;
  }

  /// Syncs playback state into the native window (scrubber, play/pause).
  ///
  /// Call on play/pause, position and duration changes while prepared.
  /// Also arms auto-PiP while [playing] is true, so swiping Home opens
  /// the window; a paused film never auto-opens.
  Future<void> updateState({
    required Duration position,
    required Duration duration,
    required bool playing,
    double rate = 1.0,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.iOS || !_prepared) return;
    await _channel.invokeMethod<void>('updateState', <String, Object>{
      'position': position.inMilliseconds / 1000,
      'duration': duration.inMilliseconds / 1000,
      'playing': playing,
      'rate': rate,
    });
  }

  /// Opens the native PiP window now (the top-bar button).
  ///
  /// Returns false when the window could not open; [onPipFailed] carries
  /// the reason, including the native diagnostic string.
  Future<bool> enterPiP() async {
    if (defaultTargetPlatform != TargetPlatform.iOS || !_prepared) return false;
    try {
      return await _channel.invokeMethod<bool>('enterPip') ?? false;
    } on PlatformException catch (e) {
      onPipFailed?.call(e.message ?? e.code);
      return false;
    }
  }

  /// Closes the native PiP window, if it is up.
  Future<void> exitPiP() async {
    if (defaultTargetPlatform != TargetPlatform.iOS || !_prepared) return;
    await _channel.invokeMethod<void>('exitPip');
  }

  /// Native diagnostic string for a PiP failure: layer status, whether the
  /// layer is in a window, whether PiP is possible, the gate state
  /// (`pipActive`), the audio category, how many frames the tap has
  /// delivered (`ingest`), and the live-feed throughput while PiP is up
  /// (`liveEnq` / `liveDrop` / `liveAgeMs`, +31) — plus the prime state
  /// (`primed` / `primeAgeMs` / `primes`).
  Future<String> get diag async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return 'not iOS';
    try {
      return await _channel.invokeMethod<String>('diag') ?? '';
    } catch (e) {
      return e.toString();
    }
  }

  /// Tears the native session down. Safe to call when not prepared.
  Future<void> dispose() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    if (_prepared) {
      await _channel.invokeMethod<void>('release');
    }
    // Synchronous: setMethodCallHandler returns void, not a Future.
    _channel.setMethodCallHandler(null);
    _prepared = false;
    _inPip = false;
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'pipStarted':
        _inPip = true;
        onPipStarted?.call();
      case 'pipStopped':
        _inPip = false;
        final restored =
            (call.arguments as Map?)?['restored'] as bool? ?? false;
        onPipStopped?.call(restored);
      case 'pipSetPlaying':
        onPipSetPlaying?.call(call.arguments as bool);
      case 'pipSkip':
        onPipSkip?.call(call.arguments as int);
      case 'pipFailed':
        onPipFailed?.call(
          (call.arguments as Map?)?['reason'] as String? ?? 'unknown',
        );
    }
    return null;
  }
}
