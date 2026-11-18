import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/storage/secure_token_storage.dart';
import '../../../core/storage/settings_repository.dart';
import '../../../core/storage/storage_service.dart'
    show kOsPasswordKey, kSubDlPasswordKey;
import '../../../core/utils/source_language.dart';
import '../../player/domain/network_buffer.dart';
import '../../player/domain/subtitle_code_pages.dart';
import '../../player/domain/track_language.dart';
import '../../player/data/subtitle_providers.dart';
import '../../../core/network/dio_client_provider.dart';

part 'player_settings_provider.g.dart';

/// The action a vertical drag on one half of the video performs.
///
/// [seek] slides the playhead: a full screen height of travel is 90 seconds,
/// the same scale the horizontal swipe-seek uses per full width, so the two
/// seek gestures agree with each other. It only exists because the design
/// preview's Left/Right Gesture rows offer Seek alongside Volume, Brightness
/// and None; the VLC controls honour it, and the mpv (Golden) controls honour
/// it on their outer thirds.
enum PlayerGesture { brightness, volume, seek, none }

/// Preferred playback quality tier. Plugins don't guarantee a specific
/// quality but sources are sorted so the preferred tier is tried first.
/// Default Wi-Fi quality ceiling for users who have never opened the setting.
///
/// Was 4K. media_kit sizes its render target to the *source* resolution — the
/// `videoParams` listener pushes the decoded width/height straight into
/// SetSize/SetSurfaceSize and AndroidVideoController.setSize() throws
/// UnsupportedError, so there is no in-app escape once a 4K stream is chosen.
/// A 3840x2160 buffer is ~33 MB per frame, filled twice (render + composite),
/// on every device including 1 GB TV sticks.
///
/// 1080p matches the existing mobile default and is a ceiling, not a floor:
/// anyone who wants 4K can still select it, and an explicit stored choice is
/// never overwritten — this only changes what happens when nothing was chosen.
const QualityPreference kDefaultWifiQuality = QualityPreference.q1080;

/// What "Max quality on mobile data" (v7) offers: Off, 1080p, 720p, 480p.
const List<QualityPreference> kMobileDataMaxQualities = <QualityPreference>[
  QualityPreference.any,
  QualityPreference.q1080,
  QualityPreference.q720,
  QualityPreference.q480,
];

enum QualityPreference {
  any, // no preference — keep original order
  q360, // 360p
  q480, // 480p / SD
  q720, // 720p / HD
  q1080, // 1080p / FHD
  q4k, // 4K / UHD / 2160p
}

/// Controls how the quality preference threshold is applied when streams are loaded.
enum QualityFilterMode {
  any, // Sort only — show everything (current behaviour)
  atOrAbove, // Hide sources strictly below the preferred quality tier
  atOrBelow, // Hide sources strictly above the preferred tier (data-saver mode)
}

/// Whether a video starts with a subtitle showing.
///
/// A default, not a lock. [off] decides only what the player does with media
/// it has just opened by itself; the Subtitles menu keeps working exactly as
/// it does today, and a track the viewer picks there stays picked for as long
/// as that media is playing.
///
/// Applied per opened media, which is what "by default" has to mean here:
/// every failover, recovery, rendition step-down, live reconnect and episode
/// advance hands libVLC brand-new media that re-selects a subtitle on its own,
/// so the default is re-applied to each. See `VlcPlayerScreen`'s
/// `_applySubtitleDefault` for the whole rule.
enum SubtitleDefault {
  /// Today's behaviour, unchanged: whatever the source and libVLC select is
  /// what plays, including the preferred-language side-car match in
  /// `preferredSubtitleIndex`.
  auto,

  /// Media starts with no subtitle selected.
  off,

  /// Media starts with an English subtitle when the media carries one,
  /// whatever the subtitle search language says.
  english,

  /// Only a forced subtitle goes on — the track that translates the lines
  /// spoken in another language than the film's. When the media carries no
  /// forced track, no subtitle shows. Applied when the tracks are picked at
  /// open time (see `_pickPreferredSubtitle`); the engine's own later
  /// re-select, e.g. at an HLS discontinuity, is not chased.
  forcedOnly,

  /// Media starts with a subtitle in the language of the audio track that
  /// is playing — the same language the viewer is hearing, read off the
  /// active audio track once the tracks are known.
  sameAsAudio,
}

/// How heavily subtitle letters are outlined.
///
/// Both renderers take it, each in its own unit: libVLC as a share of the
/// glyph, ZoroX's own subtitles as a stroke - see `subtitle_style.dart`.
/// [thin] is the outline every install had before this was a setting.
enum SubtitleOutline { none, thin, normal, thick }

/// The typeface subtitles are drawn in.
///
/// [standard] is each renderer's own, which is what every install had before
/// this was a setting; the others are families every platform has under some
/// name - see `subtitleFontFamily`. [netflix] is the bundled Roboto face, the
/// clean grotesque Netflix subtitles are set in.
enum SubtitleFont { standard, serif, monospace, netflix }

/// The lifts the player offers for subtitles, as shares of the picture's
/// height: at the bottom, and up to a fifth of the way up.
const List<double> kSubtitleRaises = <double>[0, 0.05, 0.1, 0.15, 0.2];

/// The text opacities the player offers, opaque first. A quarter is the
/// least: text nobody can see is not a style.
const List<double> kSubtitleTextOpacities = <double>[1, 0.75, 0.5, 0.25];

/// Which engine plays video.
///
/// libmpv (media_kit, the Golden player) is the default: it is the engine
/// the Golden UI was built on, and the one every +14 fix targets. libVLC
/// is the v16/v17 engine. iOS Picture-in-Picture works on both now: libVLC
/// natively, and libmpv through the +28 software-renderer bridge (see
/// [PlayerSettings.iosMpvPip]) — before +28 only libVLC could do it.
/// The choice takes effect on the NEXT play — the route reads it once when
/// the player opens, so a change mid-play never swaps the engine under a
/// running video.
enum PlayerEngine {
  /// libmpv via media_kit — the Golden player. PiP on Android, and on
  /// iOS when the +28 setting is on. Build 72: the player opens on the
  /// hardware renderer and moves to the software renderer only when
  /// the PiP button is tapped (see `mpv_pip_renderer.dart`).
  mpv,

  /// libVLC — the v16/v17 engine. PiP on Android and iOS.
  vlc,
}

/// Which Picture-in-Picture implementation the iOS player uses.
///
/// The design preview's Picture-in-Picture segmented control: mpv or iOS.
/// Only the mpv engine has two things to choose between, and only on iOS:
///
/// * [mpv] — the +28 software-renderer bridge (`MpvPipIos`): the player opens
///   with the software renderer so frames are available to the PiP window.
///   This is the only PiP the mpv engine can do on iOS, and the default: it
///   is the behaviour every install already had.
/// * [ios] — the system's own PiP. The libVLC engine already uses it, and
///   nothing changes there. On the mpv engine there is no system path — mpv
///   renders into a Flutter texture, not an AVPlayer — so iOS mode leaves the
///   mpv player on the hardware renderer and its PiP button hidden, and the
///   viewer who wants PiP gets it by switching the engine to libVLC.
///   The settings row says exactly that, so the choice never reads as a
///   second mpv PiP that does not exist.
///
/// Gated by the Enable PiP toggle ([PlayerSettings.iosMpvPip]) either way:
/// the toggle is the master on/off, the mode only picks the implementation.
enum PipMode { mpv, ios }

/// Which output preset the iOS mpv player's Video panel applies (+57).
///
/// The panel (Infuse-style, GoldenPlayerControls → GoldenVideoDrawer)
/// offers four presets; the choice is stored by name and applied to the
/// live mpv instance at once (see `videoOutputPresetOptions` in
/// `mpv_ios_options.dart`) and again on the next open, when the screen
/// applies the stored preset at setup. iOS mpv only — Android has no
/// Video button and never reads this.
///
/// True EDR passthrough is impossible through the 8-bit Flutter texture
/// on either render path, so "Native EDR" is the closest achievable
/// behaviour (no tone-mapping curve), not real EDR — see the per-value
/// notes. `hdr-compute-peak` is never set by any preset: it blacks the
/// video with vo=libmpv (media_kit forces it off).
///
/// v9: the panel shows two choices only — "Bright" ([nativeEdr]) and
/// "Balanced" ([sdrToneMapped]) — and only on HDR videos. [compatibility]
/// and [custom] are no longer offered; the names stay so an old stored
/// value (or an old backup) still parses, and [migrateVideoOutputPreset]
/// turns them into one of the two.
enum VideoOutputPreset {
  /// Closest to HDR passthrough: no tone-mapping curve, hard clip at
  /// peak white (`tone-mapping: clip` on the hardware path, the clip LUT
  /// on the software path). The default: it IS the behaviour every
  /// install already had (clip on both paths since +50), so an upgrade
  /// changes nothing.
  nativeEdr,

  /// The reference SDR tone-mapping curve: `tone-mapping: bt.2390` on the
  /// hardware path, the BT.2390 EETF LUT on the software path — both
  /// paths roll highlights off identically, so PiP ON matches PiP OFF.
  /// More predictable whites and blacks than the clip.
  sdrToneMapped,

  /// mpv's own defaults, no custom tone mapping: `tone-mapping: auto`
  /// (which maps to bt.2390 on vo=gpu) plus the default scalers
  /// (lanczos / hermite, dither auto, correct downscaling on) — the
  /// render the app had before the +34 cheap-scalers. The curve is the
  /// same as SDR tone mapped; the scalers are what differ. Costs more
  /// GPU than the other presets; the thermal governor does not touch the
  /// scalers, so this stays as picked until the viewer changes it.
  compatibility,

  /// The stored advanced values ([videoCustomToneMapping] /
  /// [videoCustomTargetPeak]); with none stored it behaves as Native EDR.
  /// The advanced controls live in the Video panel's Custom preset (see
  /// `golden_video_drawer.dart`): tone mapping and target peak below the
  /// presets.
  custom,
}

class PlayerSettings {
  final PlayerGesture leftGesture;
  final PlayerGesture rightGesture;
  final bool doubleTapEnabled;
  final bool swipeSeekEnabled;
  final int seekDuration;
  final String defaultResizeMode;
  final double subtitleSize;
  final int subtitleColor;
  final int subtitleBackgroundColor;
  final double subtitleBackgroundOpacity;

  /// How heavily the letters are outlined.
  final SubtitleOutline subtitleOutline;

  /// Whether the letters carry a drop shadow instead of an outline.
  ///
  /// The mpv player's Style tab offers edge = none / outline / shadow; the
  /// stock outline enum has no shadow, so this is the shadow's own flag.
  /// libVLC ignores it (it only reads the outline).
  final bool subtitleShadow;

  /// How far the lines are lifted from the bottom, as a share of the picture's
  /// height: one of [kSubtitleRaises].
  final double subtitleRaise;

  /// Whether the caption positions itself (+27): when on, the saved
  /// [subtitleRaise] is ignored — the caption sits just above the bottom
  /// controls while they are visible, low when they are hidden — and the
  /// Manual slider in the Style tab is hidden. Off by default, so every
  /// existing install keeps its manual position.
  final bool subtitleAutoAdjust;

  /// Whether the letters are bold.
  ///
  /// This, [subtitleFont], [subtitleTextOpacity] and [subtitleEncoding] reach
  /// libVLC only when a player is created, so a track inside the video takes
  /// them the next time the player opens. ZoroX's own subtitle files
  /// follow all four at once.
  final bool subtitleBold;

  final SubtitleFont subtitleFont;

  /// How opaque the letters are: one of [kSubtitleTextOpacities].
  final double subtitleTextOpacity;

  /// The code page subtitle files that are not Unicode are read in, by
  /// libVLC's name for it (`Windows-1251`), or empty for Auto - Windows-1252,
  /// which is what every install read them as before this was a setting.
  ///
  /// A change reads the files already fetched again, so the one showing
  /// changes at once - see `SideCarSubtitles.encoding`.
  final String subtitleEncoding;

  /// Whether a newly opened video starts with a subtitle showing.
  /// [SubtitleDefault.auto] is what every install did before this setting
  /// existed, so an upgrade changes nothing.
  final SubtitleDefault subtitleDefault;

  /// Empty means leave the source's audio choice unchanged. A recognized
  /// ISO language code prefers a matching track on each newly opened video.
  final String preferredAudioLanguage;

  final bool hardwareDecoding;
  final String?
  preferredPlayer; // null = internal, 'vlc' / 'mpv' etc. = external

  /// Quality to prefer when on Wi-Fi. Defaults to [kDefaultWifiQuality]
  /// (1080p), not 4K — see that constant for why.
  final QualityPreference wifiQuality;

  /// Quality to prefer when on mobile data. Default: 1080p.
  final QualityPreference mobileQuality;

  /// "Max quality on mobile data" (v7): on cellular, sources at or below
  /// this come first in the source list and playback starts among them;
  /// higher ones stay listed below. [QualityPreference.any] is Off, the
  /// default. One of [kMobileDataMaxQualities].
  final QualityPreference mobileDataMaxQuality;

  /// "Preferred source language" (v9): sources that say they carry it are
  /// listed first. Off by default.
  final SourceLanguage preferredSourceLanguage;

  /// The Video panel's PICTURE sliders (v9): brightness, contrast and
  /// saturation, each −50…+50, 0 by default. Global, not per title;
  /// applied to every video on open and live while dragging (see
  /// `pictureOptions` in `mpv_ios_options.dart`).
  final int pictureBrightness;
  final int pictureContrast;
  final int pictureSaturation;

  /// Whether the next episode starts on its own when one ends (v7): a 5 s
  /// "Next episode" card with Play now and Cancel. Off: the episode just
  /// ends, with Next episode on the ended card. Default on.
  final bool autoPlayNextEpisode;

  /// Controls whether streams below/above the quality preference are hidden.
  /// Default: [QualityFilterMode.any] (sort only, no filtering).
  final QualityFilterMode qualityFilterMode;

  /// The read-ahead size the viewer picked, in megabytes, or null for Auto.
  ///
  /// Auto sizes each open's read-ahead from the video's bitrate, the network
  /// and this device's memory (`bufferPlanFor`, spec 1.2). A size picked here
  /// replaces that for every kind of media: a file, a torrent, and HLS, which
  /// gets it as seconds at its bitrate.
  ///
  /// Stored under `player_buffer_override_mb`. The key before it,
  /// `player_network_buffer_mb`, held a size every install had been nudged
  /// into, so it is never read: everyone starts on Auto.
  final int? bufferOverrideMb;

  /// Maximum volume the player allows, as a percentage (100–200).
  /// mpv can amplify beyond the source level; 100 disables the boost.
  final int maxVolumePercent;

  /// When true, the progress-bar time header shows the remaining time
  /// (e.g. "-1:23:45 / 2:00:00") instead of the elapsed time. Sticky
  /// across sessions because users who prefer one view almost always
  /// want it always.
  final bool showRemainingTime;

  /// Toggles for individual player control-bar buttons. All default to
  /// visible. Options stays available for sources, tracks, and episodes.
  /// The episode toggle controls only the previous/next transport buttons.
  ///
  /// The rotate toggle is back with the rotate button (2026-10-11), on the
  /// `player_show_rotate` key it had before the button went away, so an old
  /// install that hid it keeps it hidden.
  ///
  /// Old installs may still hold `player_readahead` and the five
  /// `player_hdr_*` / `player_tone_map` / `player_inverse_tone_map` keys in the
  /// Hive settings box; they are never read, and nothing enumerates that box,
  /// so they cost one unread value each and need no migration. libVLC 3 has
  /// neither a read-ahead-in-seconds control nor mpv's tone mapping, so the
  /// settings that wrote them went away with the engine that could have
  /// honoured them.
  final bool showVolume;
  final bool showPip;
  final bool showResize;
  final bool showRotate;
  final bool showPlaybackSpeed;
  final bool showEpisodes;

  /// Auto Skip (v2.9.4): automatically skip intro/recap/outro segments
  /// (opening + ending, like anime/dramas) with no tap. Default on.
  final bool autoSkip;

  /// Which engine plays video. libmpv (the Golden player) by default;
  /// libVLC when the viewer picks it. Read once by the player route when
  /// the player opens — see [PlayerEngine].
  final PlayerEngine playerEngine;

  /// iOS Picture-in-Picture on the mpv engine (+28).
  ///
  /// Off by default: PiP on iOS needs the software renderer — GPU work is
  /// not allowed while the app is backgrounded — so turning this on runs
  /// the player with `enableHardwareAcceleration: false` plus
  /// `hwdec: videotoolbox-copy` (hardware decode, software render). The
  /// picture loses the shaders, HDR looks washed out, and 4K is heavy.
  /// Takes effect on the NEXT play, like the engine choice: the
  /// VideoController is created once when the player opens. On Android
  /// this does nothing — Android mpv PiP already works on the hardware
  /// renderer.
  final bool iosMpvPip;

  /// Which PiP implementation the iOS player uses. [PipMode.mpv] is what
  /// every install already had (the +28 bridge); see [PipMode].
  final PipMode pipMode;

  /// The Video output preset (+57). Default Native EDR: it is the
  /// behaviour every install already had (clip on both paths since +50),
  /// so an upgrade changes nothing. See [VideoOutputPreset].
  final VideoOutputPreset videoOutputPreset;

  /// The Custom preset's stored tone-mapping value, or null when the
  /// viewer has never set one (Custom then behaves as Native EDR).
  /// Set from the Video panel's Custom advanced controls.
  final String? videoCustomToneMapping;

  /// The Custom preset's stored target peak, or null when never set.
  final String? videoCustomTargetPeak;

  // Subtitle Accounts
  final String osUsername;
  final String osPassword;
  final String osApiKey;
  final String subdlEmail;
  final String subdlPassword;
  final String subdlApiKey;
  final String subsourceApiKey;

  const PlayerSettings({
    this.leftGesture = PlayerGesture.brightness,
    this.rightGesture = PlayerGesture.volume,
    this.doubleTapEnabled = true,
    this.swipeSeekEnabled = true,
    this.seekDuration = 10,
    this.defaultResizeMode = 'Fit',
    this.subtitleSize = 22.0,
    this.subtitleColor = 0xFFFFFFFF, // White
    this.subtitleBackgroundColor = 0x00000000, // Transparent
    this.subtitleBackgroundOpacity = 0.5, // Default opacity (50%)
    this.subtitleOutline = SubtitleOutline.thin,
    this.subtitleShadow = false,
    this.subtitleRaise = 0.0,
    this.subtitleAutoAdjust = false,
    this.subtitleBold = false,
    this.subtitleFont = SubtitleFont.standard,
    this.subtitleTextOpacity = 1.0,
    this.subtitleEncoding = '',
    this.subtitleDefault = SubtitleDefault.auto,
    this.preferredAudioLanguage = '',
    this.hardwareDecoding = true,
    this.preferredPlayer,
    this.wifiQuality = kDefaultWifiQuality,
    this.mobileQuality = QualityPreference.q1080,
    this.qualityFilterMode = QualityFilterMode.any,
    this.mobileDataMaxQuality = QualityPreference.any,
    this.preferredSourceLanguage = SourceLanguage.off,
    this.pictureBrightness = 0,
    this.pictureContrast = 0,
    this.pictureSaturation = 0,
    this.autoPlayNextEpisode = true,
    this.bufferOverrideMb,
    this.maxVolumePercent = 200,
    this.showRemainingTime = false,
    this.showVolume = true,
    this.showPip = true,
    this.showResize = true,
    this.showRotate = true,
    this.showPlaybackSpeed = true,
    this.showEpisodes = true,
    this.autoSkip = true,
    this.playerEngine = PlayerEngine.mpv,
    this.iosMpvPip = false,
    this.pipMode = PipMode.mpv,
    this.videoOutputPreset = VideoOutputPreset.nativeEdr,
    this.videoCustomToneMapping,
    this.videoCustomTargetPeak,
    this.osUsername = '',
    this.osPassword = '',
    this.osApiKey = '',
    this.subdlEmail = '',
    this.subdlPassword = '',
    this.subdlApiKey = '',
    this.subsourceApiKey = '',
  });

  PlayerSettings copyWith({
    PlayerGesture? leftGesture,
    PlayerGesture? rightGesture,
    bool? doubleTapEnabled,
    bool? swipeSeekEnabled,
    int? seekDuration,
    String? defaultResizeMode,
    double? subtitleSize,
    int? subtitleColor,
    int? subtitleBackgroundColor,
    double? subtitleBackgroundOpacity,
    SubtitleOutline? subtitleOutline,
    bool? subtitleShadow,
    double? subtitleRaise,
    bool? subtitleAutoAdjust,
    bool? subtitleBold,
    SubtitleFont? subtitleFont,
    double? subtitleTextOpacity,
    String? subtitleEncoding,
    SubtitleDefault? subtitleDefault,
    String? preferredAudioLanguage,
    bool? hardwareDecoding,
    String? preferredPlayer,
    bool clearPreferredPlayer = false,
    QualityPreference? wifiQuality,
    QualityPreference? mobileQuality,
    QualityFilterMode? qualityFilterMode,
    QualityPreference? mobileDataMaxQuality,
    SourceLanguage? preferredSourceLanguage,
    int? pictureBrightness,
    int? pictureContrast,
    int? pictureSaturation,
    bool? autoPlayNextEpisode,
    int? bufferOverrideMb,
    bool clearBufferOverride = false,
    int? maxVolumePercent,
    bool? showRemainingTime,
    bool? showVolume,
    bool? showPip,
    bool? showResize,
    bool? showRotate,
    bool? showPlaybackSpeed,
    bool? showEpisodes,
    bool? autoSkip,
    PlayerEngine? playerEngine,
    bool? iosMpvPip,
    PipMode? pipMode,
    VideoOutputPreset? videoOutputPreset,
    String? videoCustomToneMapping,
    bool clearVideoCustomToneMapping = false,
    String? videoCustomTargetPeak,
    bool clearVideoCustomTargetPeak = false,
    String? osUsername,
    String? osPassword,
    String? osApiKey,
    String? subdlEmail,
    String? subdlPassword,
    String? subdlApiKey,
    String? subsourceApiKey,
  }) {
    return PlayerSettings(
      leftGesture: leftGesture ?? this.leftGesture,
      rightGesture: rightGesture ?? this.rightGesture,
      doubleTapEnabled: doubleTapEnabled ?? this.doubleTapEnabled,
      swipeSeekEnabled: swipeSeekEnabled ?? this.swipeSeekEnabled,
      seekDuration: seekDuration ?? this.seekDuration,
      defaultResizeMode: defaultResizeMode ?? this.defaultResizeMode,
      subtitleSize: subtitleSize ?? this.subtitleSize,
      subtitleColor: subtitleColor ?? this.subtitleColor,
      subtitleBackgroundColor:
          subtitleBackgroundColor ?? this.subtitleBackgroundColor,
      subtitleBackgroundOpacity:
          subtitleBackgroundOpacity ?? this.subtitleBackgroundOpacity,
      subtitleOutline: subtitleOutline ?? this.subtitleOutline,
      subtitleShadow: subtitleShadow ?? this.subtitleShadow,
      subtitleRaise: subtitleRaise ?? this.subtitleRaise,
      subtitleAutoAdjust: subtitleAutoAdjust ?? this.subtitleAutoAdjust,
      subtitleBold: subtitleBold ?? this.subtitleBold,
      subtitleFont: subtitleFont ?? this.subtitleFont,
      subtitleTextOpacity: subtitleTextOpacity ?? this.subtitleTextOpacity,
      subtitleEncoding: subtitleEncoding ?? this.subtitleEncoding,
      subtitleDefault: subtitleDefault ?? this.subtitleDefault,
      preferredAudioLanguage:
          preferredAudioLanguage ?? this.preferredAudioLanguage,
      hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
      preferredPlayer: clearPreferredPlayer
          ? null
          : (preferredPlayer ?? this.preferredPlayer),
      wifiQuality: wifiQuality ?? this.wifiQuality,
      mobileQuality: mobileQuality ?? this.mobileQuality,
      qualityFilterMode: qualityFilterMode ?? this.qualityFilterMode,
      mobileDataMaxQuality: mobileDataMaxQuality ?? this.mobileDataMaxQuality,
      preferredSourceLanguage:
          preferredSourceLanguage ?? this.preferredSourceLanguage,
      pictureBrightness: pictureBrightness ?? this.pictureBrightness,
      pictureContrast: pictureContrast ?? this.pictureContrast,
      pictureSaturation: pictureSaturation ?? this.pictureSaturation,
      autoPlayNextEpisode: autoPlayNextEpisode ?? this.autoPlayNextEpisode,
      bufferOverrideMb: clearBufferOverride
          ? null
          : (bufferOverrideMb ?? this.bufferOverrideMb),
      maxVolumePercent: maxVolumePercent ?? this.maxVolumePercent,
      showRemainingTime: showRemainingTime ?? this.showRemainingTime,
      showVolume: showVolume ?? this.showVolume,
      showPip: showPip ?? this.showPip,
      showResize: showResize ?? this.showResize,
      showRotate: showRotate ?? this.showRotate,
      showPlaybackSpeed: showPlaybackSpeed ?? this.showPlaybackSpeed,
      showEpisodes: showEpisodes ?? this.showEpisodes,
      autoSkip: autoSkip ?? this.autoSkip,
      playerEngine: playerEngine ?? this.playerEngine,
      iosMpvPip: iosMpvPip ?? this.iosMpvPip,
      pipMode: pipMode ?? this.pipMode,
      videoOutputPreset: videoOutputPreset ?? this.videoOutputPreset,
      videoCustomToneMapping: clearVideoCustomToneMapping
          ? null
          : (videoCustomToneMapping ?? this.videoCustomToneMapping),
      videoCustomTargetPeak: clearVideoCustomTargetPeak
          ? null
          : (videoCustomTargetPeak ?? this.videoCustomTargetPeak),
      osUsername: osUsername ?? this.osUsername,
      osPassword: osPassword ?? this.osPassword,
      osApiKey: osApiKey ?? this.osApiKey,
      subdlEmail: subdlEmail ?? this.subdlEmail,
      subdlPassword: subdlPassword ?? this.subdlPassword,
      subdlApiKey: subdlApiKey ?? this.subdlApiKey,
      subsourceApiKey: subsourceApiKey ?? this.subsourceApiKey,
    );
  }

  /// Whether OpenSubtitles can answer at all.
  ///
  /// Without a key the provider returns an empty list before it sends a
  /// request, so a stored [osUsername] is not evidence of a working account —
  /// nothing ever logged in with it. The same two candidates the provider
  /// itself weighs, in the same order.
  bool get hasOpenSubtitlesKey =>
      osApiKey.isNotEmpty || OpenSubtitlesProvider.buildTimeApiKey.isNotEmpty;
}

@Riverpod(keepAlive: true)
class PlayerSettingsNotifier extends _$PlayerSettingsNotifier {
  SettingsRepository get _repository => ref.read(settingsRepositoryProvider);

  /// The last in-flight `player_sub_raise` persist (build 86): rapid
  /// Manual-slider drags chain their writes behind it, so they persist
  /// in order and the saved value is the last dragged one.
  Future<void> _subtitleRaisePersist = Future<void>.value();

  /// Keychain (iOS/macOS) / Keystore (Android) / libsecret / Credentials API,
  /// with the one-shot migration out of the plaintext Hive box built in.
  ///
  /// The same store the OAuth tokens already use — deliberately not a second
  /// mechanism.
  SecureTokenStorage get _credentials => ref.read(secureTokenStorageProvider);

  /// Resolves without an await so no consumer can observe an unresolved
  /// [PlayerSettings].
  ///
  /// The player is pushed straight from Continue Watching and from both source
  /// sheets, none of which wait for this provider; while `build` was async
  /// those routes built the player from `const PlayerSettings()` and the
  /// viewer's subtitle appearance, resize mode and decode preference were the
  /// factory defaults for the rest of the session. Every value here therefore
  /// comes out of the already-open Hive box. The two account passwords are the
  /// exception - they live in the platform secure store, which is a channel
  /// call - so they are folded in by [_loadAccountPasswords] when they arrive.
  @override
  FutureOr<PlayerSettings> build() {
    final storage = _repository;
    final l =
        storage.getPlayerSetting<String>(
          'player_gesture_left',
          defaultValue: 'brightness',
        ) ??
        'brightness';
    final r =
        storage.getPlayerSetting<String>(
          'player_gesture_right',
          defaultValue: 'volume',
        ) ??
        'volume';
    final dt =
        storage.getPlayerSetting<bool>(
          'player_double_tap',
          defaultValue: true,
        ) ??
        true;
    final dur =
        storage.getPlayerSetting<int>(
          'player_seek_duration',
          defaultValue: 10,
        ) ??
        10;
    final resize =
        storage.getPlayerSetting<String>(
          'player_default_resize',
          defaultValue: 'Fit',
        ) ??
        'Fit';
    final subSize =
        (storage.getPlayerSetting('player_sub_size') as num?)?.toDouble() ??
        22.0;
    final subColor =
        storage.getPlayerSetting<int>(
          'player_sub_color',
          defaultValue: 0xFFFFFFFF,
        ) ??
        0xFFFFFFFF;
    final subBg =
        (storage.getPlayerSetting('player_sub_bg') as num?)?.toInt() ??
        0x00000000;
    final subBgOpacity =
        (storage.getPlayerSetting('player_sub_bg_opacity') as num?)
            ?.toDouble() ??
        0.5;
    // A name this build does not know - written by a newer one, or a
    // corrupted box - reads as the default, as the subtitle default does.
    final subOutline = SubtitleOutline.values.firstWhere(
      (e) => e.name == storage.getPlayerSetting<String>('player_sub_outline'),
      orElse: () => SubtitleOutline.thin,
    );
    // +25: the saved raise is reset to 0 once. The raise is what put the
    // "default" caption ~140px up on a phone in landscape — the 40px base
    // plus a 0.2 raise over a ~393px height — and it was set through the
    // fiddly Position control, so it is not a deliberate choice to keep.
    // The user asked for the caption to sit close to the bottom edge by
    // default, and the slide gesture (also +25) is the way to move it from
    // there. The flag makes it one-shot: a raise the viewer sets after
    // this sticks, and a fresh install (no stored raise) is untouched.
    final subRaiseStored =
        (storage.getPlayerSetting('player_sub_raise') as num?)?.toDouble();
    final subRaiseReset =
        storage.getPlayerSetting<bool>(
              'player_sub_raise_v25_reset',
              defaultValue: false,
            ) ??
            false;
    final subRaise = subRaiseReset ? (subRaiseStored ?? 0.0) : 0.0;
    if (!subRaiseReset) {
      // Fire and forget: the in-memory value above is already 0, so the
      // player shows the low default on this very launch; the writes only
      // make it stick. The same one-shot migration shape the password
      // move out of Hive uses in this file.
      unawaited(storage.setPlayerSetting('player_sub_raise', 0.0));
      unawaited(
        storage.setPlayerSetting('player_sub_raise_v25_reset', true),
      );
    }
    // Auto-Adjust (+27): off unless the viewer turned it on. Absent on a
    // fresh install or an upgrade from before this setting.
    final subAutoAdjust =
        storage.getPlayerSetting<bool>(
              'player_sub_auto_adjust',
              defaultValue: false,
            ) ??
            false;
    final subBold =
        storage.getPlayerSetting<bool>(
          'player_sub_bold',
          defaultValue: false,
        ) ??
        false;
    final subShadow =
        storage.getPlayerSetting<bool>(
          'player_sub_shadow',
          defaultValue: false,
        ) ??
        false;
    final subFont = SubtitleFont.values.firstWhere(
      (e) => e.name == storage.getPlayerSetting<String>('player_sub_font'),
      orElse: () => SubtitleFont.standard,
    );
    final subTextOpacity =
        (storage.getPlayerSetting('player_sub_text_opacity') as num?)
            ?.toDouble() ??
        1.0;
    final subEncoding = _knownEncoding(
      storage.getPlayerSetting<String>('player_sub_encoding'),
    );
    // Absent (a fresh install, or an upgrade from before this setting) and
    // unrecognised (a value written by a newer build, or a corrupted box) both
    // land on Auto, which is the behaviour every install already had.
    final subtitleDefault = SubtitleDefault.values.firstWhere(
      (e) =>
          e.name == storage.getPlayerSetting<String>('player_subtitle_default'),
      orElse: () => SubtitleDefault.auto,
    );
    final savedAudioLanguage = storage.getPlayerSetting<String>(
      'player_audio_language',
    );
    final preferredAudioLanguage = languageCodeOf(savedAudioLanguage) ?? '';
    final prefPlayer = storage.getPlayerSetting<String>('player_preferred');
    final swipeSeek =
        storage.getPlayerSetting<bool>(
          'player_swipe_seek',
          defaultValue: true,
        ) ??
        true;
    final hwDec =
        storage.getPlayerSetting<bool>('player_hw_dec', defaultValue: true) ??
        true;
    final wifiQ = _parseQuality(
      storage.getPlayerSetting<String>('player_wifi_quality'),
      kDefaultWifiQuality,
    );
    final mobileQ = _parseQuality(
      storage.getPlayerSetting<String>('player_mobile_quality'),
      QualityPreference.q1080,
    );
    final showRemaining =
        storage.getPlayerSetting<bool>(
          'player_show_remaining',
          defaultValue: false,
        ) ??
        false;
    final osUser = storage.getPlayerSetting<String>('player_os_user') ?? '';
    final osKey = storage.getPlayerSetting<String>('player_os_key') ?? '';
    final dlEmail =
        storage.getPlayerSetting<String>('player_subdl_email') ?? '';
    final dlKey = storage.getPlayerSetting<String>('player_subdl_key') ?? '';
    final ssKey = storage.getPlayerSetting<String>('player_ss_key') ?? '';
    final filterMode = _parseFilterMode(
      storage.getPlayerSetting<String>('player_quality_filter_mode'),
    );
    final storedCap = _parseQuality(
      storage.getPlayerSetting<String>('player_mobile_data_max_quality'),
      QualityPreference.any,
    );
    final mobileDataMaxQuality = kMobileDataMaxQualities.contains(storedCap)
        ? storedCap
        : QualityPreference.any;
    final autoPlayNextEpisode =
        storage.getPlayerSetting<bool>(
          'player_autoplay_next_episode',
          defaultValue: true,
        ) ??
        true;

    final showVolume =
        storage.getPlayerSetting<bool>(
          'player_show_volume',
          defaultValue: true,
        ) ??
        true;
    final showPip =
        storage.getPlayerSetting<bool>('player_show_pip', defaultValue: true) ??
        true;
    final showResize =
        storage.getPlayerSetting<bool>(
          'player_show_resize',
          defaultValue: true,
        ) ??
        true;
    final showRotate =
        storage.getPlayerSetting<bool>(
          'player_show_rotate',
          defaultValue: true,
        ) ??
        true;
    final showPlaybackSpeed =
        storage.getPlayerSetting<bool>(
          'player_show_playback_speed',
          defaultValue: true,
        ) ??
        true;
    final showEpisodes =
        storage.getPlayerSetting<bool>(
          'player_show_episodes',
          defaultValue: true,
        ) ??
        true;
    final autoSkip =
        storage.getPlayerSetting<bool>(
          'player_auto_skip',
          defaultValue: true,
        ) ??
        true;
    // A name this build does not know — written by a newer one, or a
    // corrupted box — reads as the default, as the subtitle font does.
    final playerEngine = PlayerEngine.values.firstWhere(
      (e) => e.name == storage.getPlayerSetting<String>('player_engine'),
      orElse: () => PlayerEngine.mpv,
    );
    // iOS mpv PiP (+28): off unless the viewer turned it on. Absent on a
    // fresh install or an upgrade from before this setting.
    final iosMpvPip =
        storage.getPlayerSetting<bool>(
          'player_ios_mpv_pip',
          defaultValue: false,
        ) ??
        false;
    // PiP mode: stored by enum name; an unknown name — written by a newer
    // build, or a corrupted box — reads back as mpv, the behaviour every
    // install already had.
    final pipMode = PipMode.values.firstWhere(
      (e) => e.name == storage.getPlayerSetting<String>('player_pip_mode'),
      orElse: () => PipMode.mpv,
    );

    // Video output preset (+57): stored by enum name; an unknown name —
    // written by a newer build, or a corrupted box — reads back as
    // Native EDR, the behaviour every install already had.
    // v9: only two choices remain — Bright (nativeEdr) and Balanced
    // (sdrToneMapped). A stored Compatibility or Custom is read as the
    // one it was closest to (see [migrateVideoOutputPreset]); the stored
    // name itself is rewritten the first time the viewer picks.
    final videoCustomToneMapping = storage.getPlayerSetting<String>(
      'player_video_custom_tone_mapping',
    );
    final videoOutputPreset = migrateVideoOutputPreset(
      storage.getPlayerSetting<String>('player_video_output_preset'),
      customToneMapping: videoCustomToneMapping,
    );
    final videoCustomTargetPeak = storage.getPlayerSetting<String>(
      'player_video_custom_target_peak',
    );

    // No defaultValue: an absent key has to stay absent, because null is what
    // Auto is stored as. The old key, player_network_buffer_mb, is never read.
    final bufferOverrideMb = storage.getPlayerSetting<int>(
      'player_buffer_override_mb',
    );
    final maxVolumePercent =
        storage.getPlayerSetting<int>('player_max_volume', defaultValue: 200) ??
        200;

    _loadAccountPasswords();

    return PlayerSettings(
      leftGesture: _parse(l),
      rightGesture: _parse(r),
      doubleTapEnabled: dt,
      swipeSeekEnabled: swipeSeek,
      seekDuration: dur,
      defaultResizeMode: resize,
      subtitleSize: subSize,
      subtitleColor: subColor,
      subtitleBackgroundColor: subBg,
      subtitleBackgroundOpacity: subBgOpacity,
      subtitleOutline: subOutline,
      subtitleShadow: subShadow,
      subtitleRaise: subRaise,
      subtitleAutoAdjust: subAutoAdjust,
      subtitleBold: subBold,
      subtitleFont: subFont,
      subtitleTextOpacity: subTextOpacity,
      subtitleEncoding: subEncoding,
      subtitleDefault: subtitleDefault,
      preferredAudioLanguage: preferredAudioLanguage,
      hardwareDecoding: hwDec,
      preferredPlayer: prefPlayer,
      wifiQuality: wifiQ,
      mobileQuality: mobileQ,
      qualityFilterMode: filterMode,
      mobileDataMaxQuality: mobileDataMaxQuality,
      preferredSourceLanguage: sourceLanguageFromName(
        storage.getPlayerSetting<String>(kPreferredSourceLanguageKey),
      ),
      pictureBrightness: clampPictureValue(
        storage.getPlayerSetting<int>(kPictureBrightnessKey),
      ),
      pictureContrast: clampPictureValue(
        storage.getPlayerSetting<int>(kPictureContrastKey),
      ),
      pictureSaturation: clampPictureValue(
        storage.getPlayerSetting<int>(kPictureSaturationKey),
      ),
      autoPlayNextEpisode: autoPlayNextEpisode,
      bufferOverrideMb: bufferOverrideMb,
      maxVolumePercent: maxVolumePercent,
      showRemainingTime: showRemaining,
      showVolume: showVolume,
      showPip: showPip,
      showResize: showResize,
      showRotate: showRotate,
      showPlaybackSpeed: showPlaybackSpeed,
      showEpisodes: showEpisodes,
      autoSkip: autoSkip,
      playerEngine: playerEngine,
      iosMpvPip: iosMpvPip,
      pipMode: pipMode,
      videoOutputPreset: videoOutputPreset,
      videoCustomToneMapping: videoCustomToneMapping,
      videoCustomTargetPeak: videoCustomTargetPeak,
      osUsername: osUser,
      osApiKey: osKey,
      subdlEmail: dlEmail,
      subdlApiKey: dlKey,
      subsourceApiKey: ssKey,
    );
  }

  /// Folds the two subtitle account passwords in once the platform secure
  /// store answers.
  ///
  /// Reusable account passwords, not tokens, so they never touch the Hive
  /// settings box. [SecureTokenStorage.read] migrates a value an older build
  /// left in that box on first read and deletes the plaintext copy, so nothing
  /// is lost on upgrade. See [kOsPasswordKey].
  ///
  /// A sign-in that lands while the store is being read wins: it is the newer
  /// of the two, and it has already been written back.
  ///
  /// Nothing awaits this, so a store that cannot be read has to end here: an
  /// escaping error would be an unhandled one, and the rest of the settings
  /// have already been returned. The two rows then read as signed out, which
  /// is what an unreadable credential store means.
  Future<void> _loadAccountPasswords() async {
    final String osPass;
    final String dlPass;
    try {
      osPass = await _credentials.read(kOsPasswordKey) ?? '';
      dlPass = await _credentials.read(kSubDlPasswordKey) ?? '';
    } catch (_) {
      return;
    }
    if (osPass.isEmpty && dlPass.isEmpty) return;
    _update(
      (PlayerSettings current) => current.copyWith(
        osPassword: current.osPassword.isEmpty ? osPass : null,
        subdlPassword: current.subdlPassword.isEmpty ? dlPass : null,
      ),
    );
  }

  /// Applies [change] to the settings already in hand, or does nothing.
  ///
  /// `state.requireValue` throws whenever the state is not [AsyncData] - which
  /// a failed `build` leaves it as permanently - and every setter here is
  /// called fire-and-forget from a row's `onChanged`, so the throw would escape
  /// as an unhandled async error and lose the in-memory update after the write
  /// to Hive had already succeeded. The stored value is the durable one either
  /// way; this only decides whether the screen catches up before the next
  /// launch.
  ///
  /// Also the disposal guard for the writes that resume after an await.
  void _update(PlayerSettings Function(PlayerSettings) change) {
    if (!ref.mounted) return;
    final PlayerSettings? current = state.value;
    if (current == null) return;
    state = AsyncData(change(current));
  }

  Future<void> setLeftGesture(PlayerGesture g) async {
    await _repository.setPlayerSetting('player_gesture_left', g.name);
    _update((PlayerSettings c) => c.copyWith(leftGesture: g));
  }

  Future<void> setRightGesture(PlayerGesture g) async {
    await _repository.setPlayerSetting('player_gesture_right', g.name);
    _update((PlayerSettings c) => c.copyWith(rightGesture: g));
  }

  Future<void> setDoubleTapEnabled(bool val) async {
    await _repository.setPlayerSetting('player_double_tap', val);
    _update((PlayerSettings c) => c.copyWith(doubleTapEnabled: val));
  }

  Future<void> setSwipeSeekEnabled(bool val) async {
    await _repository.setPlayerSetting('player_swipe_seek', val);
    _update((PlayerSettings c) => c.copyWith(swipeSeekEnabled: val));
  }

  Future<void> setSeekDuration(int seconds) async {
    await _repository.setPlayerSetting('player_seek_duration', seconds);
    _update((PlayerSettings c) => c.copyWith(seekDuration: seconds));
  }

  Future<void> setDefaultResizeMode(String mode) async {
    await _repository.setPlayerSetting('player_default_resize', mode);
    _update((PlayerSettings c) => c.copyWith(defaultResizeMode: mode));
  }

  /// Whether the next video the player opens starts with a subtitle showing.
  ///
  /// Takes effect on the next media the player opens, not on the one already
  /// on screen: the rule is applied while media is being handed to the engine.
  Future<void> setSubtitleDefault(SubtitleDefault value) async {
    await _repository.setPlayerSetting('player_subtitle_default', value.name);
    _update((PlayerSettings c) => c.copyWith(subtitleDefault: value));
  }

  /// Applies to the next opened media, not the track already playing.
  /// Invalid codes are treated as Automatic instead of storing a selection
  /// that can never match any language the UI offers.
  Future<void> setPreferredAudioLanguage(String language) async {
    final normalized = languageCodeOf(language) ?? '';
    await _repository.setPlayerSetting('player_audio_language', normalized);
    _update(
      (PlayerSettings c) => c.copyWith(preferredAudioLanguage: normalized),
    );
  }

  Future<void> setHardwareDecoding(bool val) async {
    await _repository.setPlayerSetting('player_hw_dec', val);
    _update((PlayerSettings c) => c.copyWith(hardwareDecoding: val));
  }

  /// Picks a read-ahead size, or Auto with null.
  Future<void> setBufferOverrideMb(int? megabytes) async {
    if (megabytes == null) {
      await _repository.setPlayerSetting('player_buffer_override_mb', null);
      _update((PlayerSettings c) => c.copyWith(clearBufferOverride: true));
      return;
    }
    // The ends of [kNetworkBufferChoicesMb]. Clamped rather than validated so
    // a value from an older build - or a newer one - lands inside the range
    // this build actually offers.
    final clamped = megabytes.clamp(
      kNetworkBufferChoicesMb.first,
      kNetworkBufferChoicesMb.last,
    );
    await _repository.setPlayerSetting('player_buffer_override_mb', clamped);
    _update((PlayerSettings c) => c.copyWith(bufferOverrideMb: clamped));
  }

  Future<void> setMaxVolumePercent(int percent) async {
    final clamped = percent.clamp(100, 200);
    await _repository.setPlayerSetting('player_max_volume', clamped);
    _update((PlayerSettings c) => c.copyWith(maxVolumePercent: clamped));
  }

  Future<void> setShowVolume(bool val) async {
    await _repository.setPlayerSetting('player_show_volume', val);
    _update((PlayerSettings c) => c.copyWith(showVolume: val));
  }

  Future<void> setShowPip(bool val) async {
    await _repository.setPlayerSetting('player_show_pip', val);
    _update((PlayerSettings c) => c.copyWith(showPip: val));
  }

  Future<void> setShowResize(bool val) async {
    await _repository.setPlayerSetting('player_show_resize', val);
    _update((PlayerSettings c) => c.copyWith(showResize: val));
  }

  Future<void> setShowRotate(bool val) async {
    await _repository.setPlayerSetting('player_show_rotate', val);
    _update((PlayerSettings c) => c.copyWith(showRotate: val));
  }

  Future<void> setShowPlaybackSpeed(bool val) async {
    await _repository.setPlayerSetting('player_show_playback_speed', val);
    _update((PlayerSettings c) => c.copyWith(showPlaybackSpeed: val));
  }

  Future<void> setShowEpisodes(bool val) async {
    await _repository.setPlayerSetting('player_show_episodes', val);
    _update((PlayerSettings c) => c.copyWith(showEpisodes: val));
  }

  Future<void> setAutoSkip(bool val) async {
    await _repository.setPlayerSetting('player_auto_skip', val);
    _update((PlayerSettings c) => c.copyWith(autoSkip: val));
  }

  /// Which engine plays the next video. Stored as the enum name ('mpv' /
  /// 'vlc'); an unknown name reads back as mpv (see the load above).
  /// Takes effect on the next play — the player route reads it once when
  /// the player opens.
  Future<void> setPlayerEngine(PlayerEngine engine) async {
    await _repository.setPlayerSetting('player_engine', engine.name);
    _update((PlayerSettings c) => c.copyWith(playerEngine: engine));
  }

  /// iOS Picture-in-Picture on the mpv engine (+28). Takes effect on the
  /// next play: the VideoController is created once when the player opens.
  Future<void> setIosMpvPip(bool value) async {
    await _repository.setPlayerSetting('player_ios_mpv_pip', value);
    _update((PlayerSettings c) => c.copyWith(iosMpvPip: value));
  }

  /// Which PiP implementation the iOS player uses. Stored by enum name;
  /// an unknown name reads back as mpv (see the load above). Takes effect
  /// on the next play, like the enable toggle: the mpv screen reads it
  /// once when the player opens to decide whether the +28 bridge is the
  /// renderer at all.
  Future<void> setPipMode(PipMode mode) async {
    await _repository.setPlayerSetting('player_pip_mode', mode.name);
    _update((PlayerSettings c) => c.copyWith(pipMode: mode));
  }

  /// The Video output preset (+57). Stored by enum name; an unknown name
  /// reads back as Native EDR (see the load above). The player screen
  /// applies it to the live mpv instance at once (see
  /// `_applyVideoOutputPreset` in `mpv_player_screen.dart`); the setting
  /// itself also takes effect on the next open, because the screen
  /// applies the stored preset at setup.
  Future<void> setVideoOutputPreset(VideoOutputPreset preset) async {
    await _repository.setPlayerSetting(
      'player_video_output_preset',
      preset.name,
    );
    _update((PlayerSettings c) => c.copyWith(videoOutputPreset: preset));
  }

  /// The Custom preset's stored tone-mapping value, written by the
  /// Video panel's Custom advanced controls. Null clears it.
  Future<void> setVideoCustomToneMapping(String? value) async {
    await _repository.setPlayerSetting(
      'player_video_custom_tone_mapping',
      value,
    );
    _update(
      (PlayerSettings c) => c.copyWith(
        videoCustomToneMapping: value,
        clearVideoCustomToneMapping: value == null,
      ),
    );
  }

  /// The Custom preset's stored target peak. Null clears it.
  Future<void> setVideoCustomTargetPeak(String? value) async {
    await _repository.setPlayerSetting(
      'player_video_custom_target_peak',
      value,
    );
    _update(
      (PlayerSettings c) => c.copyWith(
        videoCustomTargetPeak: value,
        clearVideoCustomTargetPeak: value == null,
      ),
    );
  }

  Future<void> setSubtitleSettings(
    double size,
    int color,
    int bg, [
    double? opacity,
  ]) async {
    await _repository.setPlayerSetting('player_sub_size', size);
    await _repository.setPlayerSetting('player_sub_color', color);
    await _repository.setPlayerSetting('player_sub_bg', bg);
    if (opacity != null) {
      await _repository.setPlayerSetting('player_sub_bg_opacity', opacity);
    }
    _update(
      (PlayerSettings current) => current.copyWith(
        subtitleSize: size,
        subtitleColor: color,
        subtitleBackgroundColor: bg,
        subtitleBackgroundOpacity: opacity ?? current.subtitleBackgroundOpacity,
      ),
    );
  }

  /// Saves only the size, without rewriting the viewer's colour and
  /// background choices: the player's Subtitle style page steps it on its own.
  Future<void> setSubtitleSize(double size) async {
    final value = size.round().clamp(10, 80).toDouble();
    await _repository.setPlayerSetting('player_sub_size', value);
    _update((PlayerSettings current) => current.copyWith(subtitleSize: value));
  }

  /// Saves only the text colour, as [setSubtitleSize] saves only the size.
  Future<void> setSubtitleColor(int color) async {
    await _repository.setPlayerSetting('player_sub_color', color);
    _update((PlayerSettings c) => c.copyWith(subtitleColor: color));
  }

  /// The box behind the text: its colour and its opacity together, because
  /// neither means anything alone - zero opacity is no box, whatever the
  /// colour says.
  Future<void> setSubtitleBackground(int color, double opacity) async {
    await _repository.setPlayerSetting('player_sub_bg', color);
    await _repository.setPlayerSetting('player_sub_bg_opacity', opacity);
    _update(
      (PlayerSettings c) => c.copyWith(
        subtitleBackgroundColor: color,
        subtitleBackgroundOpacity: opacity,
      ),
    );
  }

  Future<void> setSubtitleOutline(SubtitleOutline outline) async {
    await _repository.setPlayerSetting('player_sub_outline', outline.name);
    _update((PlayerSettings c) => c.copyWith(subtitleOutline: outline));
  }

  /// The Style tab's edge = shadow: a drop shadow instead of an outline.
  /// The mpv renderer reads this; libVLC ignores it.
  Future<void> setSubtitleShadow(bool shadow) async {
    await _repository.setPlayerSetting('player_sub_shadow', shadow);
    _update((PlayerSettings c) => c.copyWith(subtitleShadow: shadow));
  }

  /// Held to [kSubtitleRaises]' range, so a lift from an older or newer build
  /// lands inside what this one offers.
  ///
  /// A manual lift is the viewer positioning by hand — a swipe on the
  /// video, the Position dropdown, the Manual slider — so Auto-Adjust
  /// goes off with it and the saved raise is what the caption uses.
  /// Only writes the Auto-Adjust key when it was on: the common path (a
  /// swipe while it is already off) stays one write.
  ///
  /// Build 86: state FIRST, persist after. The Manual slider calls this
  /// on every drag tick, and awaiting the repository write before the
  /// state change made every tick wait on a disk write, so the caption
  /// lagged and stuttered instead of following the finger. The state
  /// change is synchronous now, so the caption moves on the same frame
  /// as the drag; the writes still happen, chained behind the previous
  /// persist, and the saved value is the dragged one (a later drag
  /// overwrites an earlier in-flight write with a newer value, never an
  /// older one). Awaiting the returned future still means persisted —
  /// it resolves after this tick's write lands — so a caller that
  /// reboots right after awaiting it reads the dragged value; the slider
  /// never awaits it, it just fires per tick. Only this slider path
  /// changes: the other setters still await their write first, as before.
  Future<void> setSubtitleRaise(double raise) async {
    final value = raise
        .clamp(kSubtitleRaises.first, kSubtitleRaises.last)
        .toDouble();
    final wasAutoAdjust = state.value?.subtitleAutoAdjust ?? false;
    _update(
      (PlayerSettings c) => c.copyWith(
        subtitleRaise: value,
        subtitleAutoAdjust: false,
      ),
    );
    // Chained behind the previous persist, so rapid drags persist in
    // order and the saved value is always the last dragged one — never
    // an earlier tick landing after a later one. A failed write never
    // breaks the chain: the next drag re-persists the latest value.
    final persist = _subtitleRaisePersist.then((_) async {
      try {
        await _repository.setPlayerSetting('player_sub_raise', value);
        if (wasAutoAdjust) {
          await _repository.setPlayerSetting(
            'player_sub_auto_adjust',
            false,
          );
        }
      } catch (_) {
        // A failed persist must never break the player or the chain.
      }
    });
    _subtitleRaisePersist = persist;
    await persist;
  }

  /// Auto-Adjust (+27): on, the caption positions itself and the saved
  /// raise is ignored; off, the saved raise is what the caption uses.
  Future<void> setSubtitleAutoAdjust(bool auto) async {
    await _repository.setPlayerSetting('player_sub_auto_adjust', auto);
    _update((PlayerSettings c) => c.copyWith(subtitleAutoAdjust: auto));
  }

  Future<void> setSubtitleBold(bool bold) async {
    await _repository.setPlayerSetting('player_sub_bold', bold);
    _update((PlayerSettings c) => c.copyWith(subtitleBold: bold));
  }

  Future<void> setSubtitleFont(SubtitleFont font) async {
    await _repository.setPlayerSetting('player_sub_font', font.name);
    _update((PlayerSettings c) => c.copyWith(subtitleFont: font));
  }

  /// Held to [kSubtitleTextOpacities]' range: a quarter at the least.
  Future<void> setSubtitleTextOpacity(double opacity) async {
    final value = opacity
        .clamp(kSubtitleTextOpacities.last, kSubtitleTextOpacities.first)
        .toDouble();
    await _repository.setPlayerSetting('player_sub_text_opacity', value);
    _update((PlayerSettings c) => c.copyWith(subtitleTextOpacity: value));
  }

  /// A code page this build has no table for is stored as Auto: libVLC would
  /// be handed a name ZoroX's own reader cannot follow.
  Future<void> setSubtitleEncoding(String encoding) async {
    final value = _knownEncoding(encoding);
    await _repository.setPlayerSetting('player_sub_encoding', value);
    _update((PlayerSettings c) => c.copyWith(subtitleEncoding: value));
  }

  Future<void> setPreferredPlayer(String? playerId) async {
    if (playerId == null) {
      await _repository.setPlayerSetting('player_preferred', null);
      _update(
        (PlayerSettings current) =>
            current.copyWith(clearPreferredPlayer: true),
      );
    } else {
      await _repository.setPlayerSetting('player_preferred', playerId);
      _update(
        (PlayerSettings current) => current.copyWith(preferredPlayer: playerId),
      );
    }
  }

  Future<void> setSubtitleBackgroundOpacity(double val) async {
    await _repository.setPlayerSetting('player_sub_bg_opacity', val);
    _update((PlayerSettings c) => c.copyWith(subtitleBackgroundOpacity: val));
  }

  /// Every subtitle appearance setting back to what a fresh install has, and
  /// nothing else.
  Future<void> resetSubtitleSettings() async {
    const PlayerSettings fresh = PlayerSettings();
    await _repository.setPlayerSetting('player_sub_size', fresh.subtitleSize);
    await _repository.setPlayerSetting('player_sub_color', fresh.subtitleColor);
    await _repository.setPlayerSetting(
      'player_sub_bg',
      fresh.subtitleBackgroundColor,
    );
    await _repository.setPlayerSetting(
      'player_sub_bg_opacity',
      fresh.subtitleBackgroundOpacity,
    );
    await _repository.setPlayerSetting(
      'player_sub_outline',
      fresh.subtitleOutline.name,
    );
    await _repository.setPlayerSetting(
      'player_sub_shadow',
      fresh.subtitleShadow,
    );
    await _repository.setPlayerSetting('player_sub_raise', fresh.subtitleRaise);
    await _repository.setPlayerSetting(
      'player_sub_auto_adjust',
      fresh.subtitleAutoAdjust,
    );
    await _repository.setPlayerSetting('player_sub_bold', fresh.subtitleBold);
    await _repository.setPlayerSetting(
      'player_sub_font',
      fresh.subtitleFont.name,
    );
    await _repository.setPlayerSetting(
      'player_sub_text_opacity',
      fresh.subtitleTextOpacity,
    );
    await _repository.setPlayerSetting(
      'player_sub_encoding',
      fresh.subtitleEncoding,
    );

    _update(
      (PlayerSettings current) => current.copyWith(
        subtitleSize: fresh.subtitleSize,
        subtitleColor: fresh.subtitleColor,
        subtitleBackgroundColor: fresh.subtitleBackgroundColor,
        subtitleBackgroundOpacity: fresh.subtitleBackgroundOpacity,
        subtitleOutline: fresh.subtitleOutline,
        subtitleShadow: fresh.subtitleShadow,
        subtitleRaise: fresh.subtitleRaise,
        subtitleAutoAdjust: fresh.subtitleAutoAdjust,
        subtitleBold: fresh.subtitleBold,
        subtitleFont: fresh.subtitleFont,
        subtitleTextOpacity: fresh.subtitleTextOpacity,
        subtitleEncoding: fresh.subtitleEncoding,
      ),
    );
  }

  Future<void> setWifiQuality(QualityPreference q) async {
    await _repository.setPlayerSetting('player_wifi_quality', q.name);
    _update((PlayerSettings c) => c.copyWith(wifiQuality: q));
  }

  Future<void> setMobileQuality(QualityPreference q) async {
    await _repository.setPlayerSetting('player_mobile_quality', q.name);
    _update((PlayerSettings c) => c.copyWith(mobileQuality: q));
  }

  Future<void> setMobileDataMaxQuality(QualityPreference q) async {
    final value = kMobileDataMaxQualities.contains(q)
        ? q
        : QualityPreference.any;
    await _repository.setPlayerSetting(
      'player_mobile_data_max_quality',
      value.name,
    );
    _update((PlayerSettings c) => c.copyWith(mobileDataMaxQuality: value));
  }

  /// One of the Video panel's PICTURE sliders (v9), −50…+50.
  Future<void> setPictureBrightness(int value) async {
    final v = clampPictureValue(value);
    await _repository.setPlayerSetting(kPictureBrightnessKey, v);
    _update((PlayerSettings c) => c.copyWith(pictureBrightness: v));
  }

  Future<void> setPictureContrast(int value) async {
    final v = clampPictureValue(value);
    await _repository.setPlayerSetting(kPictureContrastKey, v);
    _update((PlayerSettings c) => c.copyWith(pictureContrast: v));
  }

  Future<void> setPictureSaturation(int value) async {
    final v = clampPictureValue(value);
    await _repository.setPlayerSetting(kPictureSaturationKey, v);
    _update((PlayerSettings c) => c.copyWith(pictureSaturation: v));
  }

  Future<void> setPreferredSourceLanguage(SourceLanguage language) async {
    await _repository.setPlayerSetting(
      kPreferredSourceLanguageKey,
      language == SourceLanguage.off ? null : language.name,
    );
    _update((PlayerSettings c) => c.copyWith(preferredSourceLanguage: language));
  }

  Future<void> setAutoPlayNextEpisode(bool val) async {
    await _repository.setPlayerSetting('player_autoplay_next_episode', val);
    _update((PlayerSettings c) => c.copyWith(autoPlayNextEpisode: val));
  }

  Future<void> setQualityFilterMode(QualityFilterMode mode) async {
    await _repository.setPlayerSetting('player_quality_filter_mode', mode.name);
    _update((PlayerSettings c) => c.copyWith(qualityFilterMode: mode));
  }

  Future<void> setShowRemainingTime(bool val) async {
    await _repository.setPlayerSetting('player_show_remaining', val);
    _update((PlayerSettings c) => c.copyWith(showRemainingTime: val));
  }

  Future<void> setOpenSubtitlesCredentials(
    String user,
    String pass, [
    String? key,
  ]) async {
    await _repository.setPlayerSetting('player_os_user', user);
    // Secure store, and [SecureTokenStorage.write] clears any legacy plaintext
    // copy as it goes.
    await _credentials.write(kOsPasswordKey, pass);
    if (key != null) {
      await _repository.setPlayerSetting('player_os_key', key);
    }
    _update(
      (PlayerSettings current) =>
          current.copyWith(osUsername: user, osPassword: pass, osApiKey: key),
    );
  }

  Future<void> setSubDlAuth({
    required String apiKey,
    String? email,
    String? pass,
  }) async {
    await _repository.setPlayerSetting('player_subdl_key', apiKey);
    if (email != null) {
      await _repository.setPlayerSetting('player_subdl_email', email);
    }
    if (pass != null) {
      await _credentials.write(kSubDlPasswordKey, pass);
    }

    _update(
      (PlayerSettings current) => current.copyWith(
        subdlApiKey: apiKey,
        subdlEmail: email ?? current.subdlEmail,
        subdlPassword: pass ?? current.subdlPassword,
      ),
    );
  }

  Future<void> setSubDlApiKey(String key) async {
    await _repository.setPlayerSetting('player_subdl_key', key);
    _update((PlayerSettings c) => c.copyWith(subdlApiKey: key));
  }

  Future<void> setSubSourceApiKey(String key) async {
    await _repository.setPlayerSetting('player_ss_key', key);
    _update((PlayerSettings c) => c.copyWith(subsourceApiKey: key));
  }

  /// Removes the two subtitle account passwords from the platform secure
  /// store.
  ///
  /// "Reset Data" empties the Hive box, which takes the usernames with it and
  /// leaves both rows reading "Not logged in" while the passwords are still on
  /// the device. Named keys only: the OAuth tokens share this store, and a
  /// reset that keeps extensions keeps those sessions too.
  Future<void> clearCredentials() async {
    await _credentials.delete(kOsPasswordKey);
    await _credentials.delete(kSubDlPasswordKey);
    _update(
      (PlayerSettings current) =>
          current.copyWith(osPassword: '', subdlPassword: ''),
    );
  }

  Future<bool> verifyOpenSubtitles(
    String user,
    String pass, [
    String? key,
  ]) async {
    final dio = ref.read(dioClientProvider);
    final provider = OpenSubtitlesProvider(
      dio,
      username: user,
      password: pass,
      apiKey: key,
    );
    return await provider.verifyCredentials();
  }

  Future<({String? key, String? error})> verifySubDl(
    String email,
    String pass,
  ) async {
    final dio = ref.read(dioClientProvider);
    final provider = SubDLProvider(dio, email: email, password: pass);
    return await provider.login(email, pass);
  }

  Future<bool> verifySubDlKey(String key) async {
    final dio = ref.read(dioClientProvider);
    final provider = SubDLProvider(dio, apiKey: key);
    return await provider.verifyKey();
  }

  Future<bool> verifySubSource(String key) async {
    final dio = ref.read(dioClientProvider);
    final provider = SubSourceProvider(dio, apiKey: key);
    return await provider.verifyKey();
  }

  PlayerGesture _parse(String s) {
    return PlayerGesture.values.firstWhere(
      (e) => e.name == s,
      orElse: () => PlayerGesture.none,
    );
  }

  QualityPreference _parseQuality(String? s, QualityPreference fallback) {
    if (s == null) return fallback;
    return QualityPreference.values.firstWhere(
      (e) => e.name == s,
      orElse: () => fallback,
    );
  }

  /// [encoding] when this build can read files in it, else Auto.
  static String _knownEncoding(String? encoding) =>
      subtitleCodePages.containsKey(encoding) ? encoding! : '';

  QualityFilterMode _parseFilterMode(String? s) {
    if (s == null) return QualityFilterMode.any;
    return QualityFilterMode.values.firstWhere(
      (e) => e.name == s,
      orElse: () => QualityFilterMode.any,
    );
  }
}


/// Storage keys of the Video panel's PICTURE sliders (v9).
const String kPictureBrightnessKey = 'player_picture_brightness';
const String kPictureContrastKey = 'player_picture_contrast';
const String kPictureSaturationKey = 'player_picture_saturation';

/// The PICTURE sliders' range (v9): −50…+50.
const int kPictureMin = -50;
const int kPictureMax = 50;

/// A stored or dragged PICTURE value held to its range; null (never set)
/// and anything that is not a number is 0, the untouched picture.
int clampPictureValue(num? value) {
  if (value == null || value.isNaN) return 0;
  return value.round().clamp(kPictureMin, kPictureMax);
}

/// What a stored `player_video_output_preset` means from v9 on, where the
/// panel offers only Bright ([VideoOutputPreset.nativeEdr]) and Balanced
/// ([VideoOutputPreset.sdrToneMapped]):
///
/// * `nativeEdr` → Bright;
/// * `sdrToneMapped`, `compatibility` → Balanced (both were bt.2390);
/// * `custom` → Bright when its stored tone mapping is `clip` or was never
///   set (Custom then behaved as Native EDR), otherwise Balanced;
/// * nothing stored, or a name this build does not know → Bright, the
///   default every install already had.
VideoOutputPreset migrateVideoOutputPreset(
  String? stored, {
  String? customToneMapping,
}) {
  switch (stored) {
    case 'sdrToneMapped':
    case 'compatibility':
      return VideoOutputPreset.sdrToneMapped;
    case 'custom':
      final tone = (customToneMapping ?? 'clip').trim().toLowerCase();
      return tone == 'clip'
          ? VideoOutputPreset.nativeEdr
          : VideoOutputPreset.sdrToneMapped;
    default:
      return VideoOutputPreset.nativeEdr;
  }
}
