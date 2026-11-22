/// The PREMIUM GOLDEN player UI, on the mpv engine (via media_kit).
///
/// The stock chrome ([VlcPlayerControls] + [PlayerPanel]) replaced by the
/// golden design the user asked for (ChatGPT spec + mockup): black #080808
/// with champagne gold #D4AF37, dark top/bottom gradients, a thin golden
/// seekbar, rounded floating buttons, 200–300 ms fades. The engine is the
/// v18-mpv one: 512 MiB forward + backward demuxer cache, VideoToolbox
/// hardware decode, ±10 s seek, pause keeps the position.
///
/// What this build carries over the stock player:
///   * the golden overlay ([GoldenPlayerControls]): top bar (Back, title,
///     season/episode, subtitle style, Episodes, More), centre transport
///     (−10 s, gold play/pause, +10 s), bottom golden seekbar + times and
///     the utility row (prev/next, CC, volume, speed, lock, aspect,
///     rotate), single-tap show/hide with a 3 s auto-hide, double-tap
///     ±10 s, right-side long-press 2x (gold "▶▶ 2x" pill, exact speed
///     restored on release), pinch zoom, skip-intro/outro chip;
///   * the golden right-side drawers: Episodes (season selector, real
///     episode data, gold highlight on the playing row, resume bar),
///     Subtitle Style (size, colour, font, bold, background, outline,
///     position + nudge, opacity, encoding, reset — all live on mpv),
///     Audio (track list) and Sources (source list, as separate
///     drawers);
///   * skip-intro/outro chips, the up-next countdown, and the ended card;
///   * subtitles that sit low and at full size: media_kit's SubtitleView
///     caches its padding at creation and scales text down on phones, so
///     the screen pushes the padding through VideoState.setSubtitleViewPadding
///     and the configuration uses a 1.0 text scaler — the Position slider
///     and +5/−5 nudge move the caption live.
///   * Continue Watching resume (a [PlaybackProgressRecorder] fed from the
///     same samples as the tracker), the source list in portrait before
///     play, Back stopping the audio and returning to portrait, no centre
///     "+10s"/"−10s" pop-up, and the pre-play source list with auto-play
///     of the first working source.
///
/// What it deliberately does NOT carry (mpv limits, reported honestly):
///   * PiP on iOS — before +28 there was none: mpv renders through a
///     texture, not an AVPlayerLayer, so there is no iOS PiP window.
///     +28 adds it behind the "Picture-in-Picture (mpv)" setting in
///     Settings → Player, off by default: the player then runs the
///     software renderer (GPU work is not allowed in the background)
///     and a native plugin taps the rendered frames into a
///     sample-buffer PiP window (see `packages/zorox_mpv_pip`). Android
///     PiP exists as before: the activity enters it through
///     [PlayerPlatformService] — a button in the top bar, plus auto-enter
///     when the viewer leaves the app mid-play — and the chrome unmounts
///     while the window is open. Audio keeps playing in the background
///     (the app declares the `audio` background mode).
///   * Cast — no cast button; media_kit has no cast in this app.
///   * Subtitle/audio delay — media_kit 1.2.6 exposes no delay API, so
///     there is no delay control (the stock panel's steppers were no-ops
///     showing 0).
///   * HLS quality picker — mpv's ABR picks the rendition; no Quality tab.
///   * Side-car subtitle download, ClearKey DRM, torrent files.
library;

import '../../../../core/utils/app_utils.dart';
import '../../../../core/utils/source_language.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart'
    show ProviderListenable;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:vlc_player/vlc_player.dart';
import 'package:zorox_mpv_pip/zorox_mpv_pip.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/providers/device_info_provider.dart';
import '../../../../core/providers/thermal_state.dart';
import '../../../../core/services/local_proxy_service.dart';
import '../../../../core/services/notification_service.dart';
import '../../../../core/services/stream_cache/stream_cache_proxy.dart';
import '../../../../core/services/stream_cache/stream_cache_service.dart';
import '../../../../core/storage/app_temp_directory.dart';
import '../../../../core/storage/episode_watch_repository.dart';
import '../../../../core/storage/history_repository.dart';
import '../../../../core/storage/settings_repository.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../details/data/metadata_resolution_service.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import '../../../skip/data/aniskip_service.dart';
import '../../../skip/data/skip_service.dart';
import '../../../tracking/data/simkl_service.dart';
import '../../domain/episode_navigator.dart';
import '../../domain/hls_fmp4_detection.dart';
import '../../domain/hls_video_length.dart';
import '../../domain/next_episode_autoplay.dart';
import '../../domain/episode_duration.dart';
import '../../domain/playback_progress.dart';
import '../../domain/playback_recovery.dart';
import '../../domain/playback_tracker.dart';
import '../../domain/skip_segments.dart';
import '../../domain/sleep_timer.dart';
import '../../domain/source_row_status.dart';
import '../../domain/stream_resolver.dart';
import '../../domain/temp_download.dart';
import '../../domain/subtitle_search_target.dart';
import '../../domain/track_memory.dart';
import '../player_platform_service.dart';
import '../vlc/chrome_visibility_controller.dart';
import '../vlc/ended_card.dart';
import '../vlc/next_episode_countdown.dart';
import '../vlc/panel/player_panel_data.dart';
import '../vlc/panel/player_panel_labels.dart';
import '../vlc/player_startup_view.dart';
import '../widgets/resolve_diagnostic_text.dart';
import 'golden_player_controls.dart';
import 'golden_player_theme.dart';
import 'mpv_android_options.dart';
import 'golden_video_drawer.dart' show PictureValues;
import 'mpv_ios_options.dart';
import 'mpv_pip_quality.dart';
import 'mpv_pip_renderer.dart';
import 'mpv_stream_proxy.dart';
import 'seek_band.dart';
import 'mpv_subtitle_style.dart';
import 'mpv_thermal_quality.dart';
import 'mpv_vlc_controller.dart';

/// mpv demuxer cache, forward AND backward, in bytes.
///
/// media_kit maps `PlayerConfiguration.bufferSize` to mpv's
/// `demuxer-max-bytes` and `demuxer-max-back-bytes`, so this one value is
/// both how far ahead the engine pre-buffers and how much already-played
/// data it keeps for a backward seek. It is the ONLY cache knob media_kit
/// exposes — there is no public API for `cache-secs`,
/// `demuxer-readahead-secs` or `cache-pause-*`, so a bigger cushion has to
/// come through this size.
///
/// 768 MiB (up from 512 MiB in v18-mpv): at a 4K bitrate of ~25 Mbit/s the
/// old cap held ~2.5 minutes of video; the new one holds ~4 minutes, which
/// is the difference between riding out a 60–90 s dip on a slow mobile line
/// and stalling on it. It is only a cap — mpv allocates what arrives, so a
/// slow connection never pays for the headroom — and it is still small
/// against an 8 GB phone. v17's libVLC prefetch ring was 512 MiB; mpv now
/// holds more because its stall has no other recovery below.
const int kMpvBufferSize = 768 * 1024 * 1024;

/// How long an opened stream gets to show playback before it counts as dead
/// and the failover moves to the next candidate.
const Duration _kStartupWatchdog = Duration(seconds: 12);

/// How long the pre-play source list stays up with its rows painted before
/// the first source auto-plays. The streams are preloaded, so resolution is
/// fast and the list would otherwise flash past unseen — the viewer must see
/// the list (and get a chance to tap a row) before the video starts. This is
/// a floor on visibility, not a forced wait: a tap still opens at once.
const Duration _kMinListVisible = Duration(milliseconds: 3000);

/// Pre-buffer before the first play: how much must be buffered ahead of
/// the playhead before the video starts, and the longest the start may be
/// held for it.
///
/// mpv starts on the first frame with only ~1s of readahead by default
/// (media_kit exposes no `demuxer-readahead-secs` / `cache-pause-initial`
/// knob — `PlayerConfiguration` only carries the cache SIZE), so the
/// playhead catches the buffered edge 2–3s in and stalls, then stalls
/// again when the next segment is slow. Holding the start until 5s are
/// buffered gives it a cushion. The hold is capped at 4s so a slow source
/// still starts instead of hanging on a paused first frame — and a fast
/// source plays at once, since the buffer is usually there already.
///
/// A high-bitrate (4K) stream gets a bigger cushion: at ~25 Mbit/s the
/// same 5s is only ~15 MB and the playhead eats it in seconds on a line
/// that cannot keep up, so 4K opens wait for 10s (capped at 6s). The
/// values are per-open — see [_prebufferTarget]/[_prebufferMaxWait],
/// set in [_openStream] from [isHighBitrateStream].
const Duration _kPrebufferTarget = Duration(seconds: 5);
const Duration _kPrebufferMaxWait = Duration(seconds: 4);

/// The pre-buffer target and hold cap for a high-bitrate (4K) open.
/// See [_kPrebufferTarget].
const Duration _kPrebufferTargetHighBitrate = Duration(seconds: 10);
const Duration _kPrebufferMaxWaitHighBitrate = Duration(seconds: 6);

/// How many times a stalled source may be reopened at the same position
/// before the watchdog gives up on it and fails over to the next
/// candidate (see [_onStallTick]). Two reopens are room for a demuxer
/// that dropped its request twice; a third would just stall again on
/// the same line, and the failover ladder has others to try.
const int _kStallMaxReopens = 2;

/// How often the thermal watch reads the phone's heat while a film plays
/// (iOS only, see [_onThermalTick]). 30s is slow enough to cost nothing
/// and fast enough to catch a phone heating up mid-film; the stall
/// watchdog's 2s tick is not reused — a channel read every 2s would be
/// noise.
const Duration _kThermalPoll = Duration(seconds: 30);

/// The mpv stats overlay's refresh (+34): the live measurements are
/// re-read this often while playing.
const Duration _kMpvStatsInterval = Duration(seconds: 2);

/// Build 100: the fMP4 probe's bounds. The playlist head is read through
/// the local proxy (no headers needed — the proxy re-injects them
/// upstream), at most [_kFmp4HeadBytes] — an init segment always sits in
/// the header, ahead of the segments — and [_kFmp4FetchTimeout] per
/// request, [_kFmp4DetectTimeout] for the whole probe (master + variant).
/// A probe that runs out is "unknown", and the open falls back to the
/// b99-wide software decode so the film still plays.
const int _kFmp4HeadBytes = 32 << 10;
const Duration _kFmp4FetchTimeout = Duration(seconds: 3);
const Duration _kFmp4DetectTimeout = Duration(seconds: 6);

/// Pinch-zoom range, same as the VLC screen.
const double _kMinZoom = 0.5;
const double _kMaxZoom = 3.0;

enum _Stage { resolving, playing, failed }

/// The stock player screen, on the mpv engine. Same constructor as
/// VlcPlayerScreen so the route can point at either.
class MpvPlayerScreen extends ConsumerStatefulWidget {
  const MpvPlayerScreen({
    required this.item,
    required this.videoUrl,
    this.episode,
    this.preloadedStreams,
    super.key,
  });

  final MultimediaItem item;

  /// The plugin's resolution token, not a URL. See [resolvePlayback].
  final String videoUrl;

  final Episode? episode;

  /// Sources already aggregated by a source sheet. When present, no plugin
  /// call is made.
  final List<StreamResult>? preloadedStreams;

  @override
  ConsumerState<MpvPlayerScreen> createState() => _MpvPlayerScreenState();
}

class _MpvPlayerScreenState extends ConsumerState<MpvPlayerScreen>
    with WidgetsBindingObserver {
  /// The engine. Created once per screen; disposed with it.
  /// Build 72: not final — the on-demand PiP renderer replaces the
  /// engine (see [_switchRenderer]).
  late Player _player;
  late VideoController _videoController;

  /// Whether [_player]/[_videoController] exist and are usable. False
  /// before the first engine and for the moment between the old engine
  /// being disposed and the new one being created during a move.
  bool _engineReady = false;

  /// Build 72: PiP mode mpv with the PiP setting on (iOS). The player
  /// then opens on the HARDWARE renderer and moves to the software
  /// renderer only when the PiP button is tapped (see
  /// `mpv_pip_renderer.dart`).
  bool _iosPipOnDemand = false;

  /// Where the on-demand renderer is.
  MpvRendererPhase _rendererPhase = MpvRendererPhase.hardware;

  /// Build 73: the outgoing engine during a move. It is not disposed
  /// before the new one opens any more — it stays alive, paused, and
  /// its own texture is the held picture (see the move overlay in
  /// [build]). Nothing is asked of it while it waits, so a saturated
  /// engine cannot stall the move; it is disposed after the swap.
  VideoController? _outgoingController;
  GlobalKey<VideoState> _outgoingKey = GlobalKey<VideoState>();

  /// Build 73: how long each step of the last move took, for the QoE
  /// overlay (see [switchTimingLine]).
  String _switchDirection = '';
  Map<String, int> _switchSteps = const <String, int>{};
  String _switchOutcome = '';

  /// Build 75: where the picture wait of the last in-place move went
  /// (see [switchWaitLine]).
  String _switchDetail = 'switch-wait: -';

  /// Build 73: the last PiP window, for the QoE overlay — how long it
  /// was up and how many frames the renderer dropped under it.
  String _pipLastLine = 'pip-last: -';

  /// Build 74: what the last PiP window's feed did, read from the
  /// native plugin when the window closes (see [pipFeedLine]).
  String _pipFeedLine = 'pip-feed: -';

  /// Build 74: the move in flight keeps the SAME engine (see
  /// [_switchRendererInPlace]) — the video widget stays mounted and
  /// holds the outgoing picture itself, so the move overlay of the
  /// re-open route is not drawn over it.
  bool _inPlaceMove = false;
  DateTime? _pipStartedAt;
  int? _pipStartDrops;

  /// Build 73: the viewer tapped the PiP window to come back (the
  /// native restore). Sticky until the app is `resumed`: iOS sends a
  /// plain "stopped" after it, and Flutter replays `hidden` on the way
  /// in — neither may pause the film.
  bool _pipRestoring = false;

  /// Build 73: whether the film was playing in the window when it
  /// went away — what the move back to hardware resumes.
  bool _pipEndWasPlaying = false;

  /// Build 73: a PiP entry (prepare → move → window) is in flight; the
  /// native bridge must not be suspended under it.
  bool _pipEntering = false;

  /// A move back to hardware that has to wait for the foreground (GPU
  /// work is not allowed in the background).
  bool _pendingSwitchToHardware = false;

  /// Whether a PiP window was up (or being opened) when the app last
  /// went to the background — that return is the PiP end, not a Home
  /// return (see [rendererReturnLogicAllowed]).
  bool _backgroundedWithPip = false;

  /// Bumped by every move, so a stale move's tail stands down.
  int _switchToken = 0;

  /// The stock UI's view of the engine. Created with the player; fed from
  /// every mpv state change via [_publishAdapter].
  late final MpvVlcController _adapter;
  bool _adapterCreated = false;

  _Stage _stage = _Stage.resolving;
  String? _error;

  /// Candidates in failover order, and which one is open.
  List<StreamResult> _streams = const [];

  /// Index into [_streams] of the source this title last played on, as the
  /// resolver found it, or -1 (v7): the Sources drawer tags it "Last used".
  int _lastUsedIndex = -1;

  /// Whether the mobile-data limit ordered [_streams] (v7).
  bool _dataSaver = false;
  int _streamIndex = 0;
  final Set<int> _failedStreams = <int>{};

  // Build 77: the stream cache proxy (see `mpv_stream_proxy.dart`).
  /// The film as the proxy knows it, when the open went through it.
  StreamCacheHandle? _proxyHandle;

  /// Which source [_proxyHandle] belongs to.
  int _proxyIndex = -1;

  /// Why the current open is NOT through the proxy (overlay).
  String? _proxyOff = 'platform';

  /// Sources that failed through the proxy in this screen: they open
  /// straight from the host from then on.
  final Set<int> _proxyBlocked = <int>{};

  /// Build 78: sources that kept stopping to buffer through the proxy
  /// (overlay `proxy: off(slow)`), and the watch that notices it.
  final Set<int> _proxySlow = <int>{};
  final StreamProxySlowWatch _proxySlowWatch = StreamProxySlowWatch();

  /// Build 106: how many times the current source has reported itself
  /// finished far short of its duration ([isFalseEnd]). The first one
  /// reopens the film from the start through the proxy; the second
  /// fails over — a source that keeps ending eleven seconds in is not
  /// replayed forever. Reset when a different source opens.
  int _falseEndRecoveries = 0;

  // Build 107: progressive "download while watching" for a host that
  // does not serve ranges (see `temp_download.dart`). The stream plays
  // from the start while the film is fetched into the app's temp
  // directory; a seek to a downloaded position reopens the local temp
  // file at it, where seeking is instant.
  /// The temp download for the film on screen, if one is running.
  TempDownload? _tempDownload;

  /// The download's progress subscription.
  StreamSubscription<TempDownloadProgress>? _tempDownloadSub;

  /// Fraction of the film the temp download holds (0..1): the gold
  /// band on the seek bar.
  final ValueNotifier<double> _downloadedFraction = ValueNotifier<double>(0);

  /// A seek past the downloaded frontier, waiting for its bytes to
  /// arrive. The player keeps playing the stream meanwhile.
  Duration? _pendingTempSeek;

  /// The engine is currently playing the local temp file, not the
  /// stream.
  bool _playingLocalTemp = false;

  /// The local file address the engine has open, when [_playingLocalTemp].
  String? _tempLocalUrl;

  /// False ends while playing the local temp file with the download
  /// still running: each one reopens the local file where playback
  /// stopped (it has grown since). Capped — a third one falls through
  /// to the ordinary false-end path.
  int _localFalseEndCount = 0;

  /// The current source has already had its temp-download probe: one
  /// probe per source, so a failed probe does not hammer the host on
  /// every reopen.
  bool _tempDownloadTried = false;

  /// Build 120: the temp-file key the fast path already opened this
  /// screen on. A retry after a failed fast-path open must NOT take
  /// the fast path again for the same file (it would loop on a file
  /// the engine cannot open) — it resolves normally instead. A new
  /// screen (a new open) starts fresh, so a good file still opens
  /// instantly next time.
  String? _keptFileOpenedKey;

  /// Orders overlapping opens: only the newest goes on after the
  /// proxy has answered.
  int _proxyOpenToken = 0;

  /// A straight-from-the-host retry is being decided: further failure
  /// reports for the same open wait for it.
  bool _proxyRetrying = false;

  /// What the reachability check found per source, while resolving: the
  /// original ZoroX's rows read "Checking…" (spinner) while a source is
  /// probed, then a green check when it answers — the viewer watches the
  /// sources resolve and picks one before anything plays. mpv used to mark
  /// every row `notChecked` (blank), so the list said nothing and flashed
  /// past. Fed by `resolvePlayback`'s `onProbe`, cleared per resolve.
  final Map<int, ProbeOutcome> _probes = <int, ProbeOutcome>{};

  /// The row the viewer picked during the probe race, if any. A pick during
  /// the race must not be overruled when the resolve returns: the resolver's
  /// index is only the auto-pick, and the viewer's pick is already opening.
  int? _pickedIndex;

  /// True once this resolve has returned its streams and index. Before that
  /// (the probe race) no row is "being opened", so no row reads "Opening…" —
  /// the original leaves every playState blank until the first open starts.
  bool _resolveDone = false;
  StreamResult? get _selected =>
      _streams.isEmpty ? null : _streams[_streamIndex];

  /// Where to resume, resolved once before the first open.
  Duration _resumePosition = Duration.zero;

  /// Progress tracking (history, scrobbling, watched) — the same tracker the
  /// VLC screen uses, fed from mpv's state stream.
  PlaybackTracker? _tracker;
  int _sessionToken = 0;

  /// Continue Watching: the recorder is fed the same samples as the tracker
  /// and flushed (past its rate limit) on pause, on teardown, and when the
  /// app goes away — so Back from a point resumes from that point.
  PlaybackProgressRecorder? _recorder;
  ProgressSample? _sample;
  bool _recordedLivestream = false;

  /// Last good state, for the UI and the tracker. Buffering and completion
  /// are read off the engine by the adapter (which publishes them as the
  /// stock value), so they are not kept here.
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  bool _playing = false;
  bool _isLive = false;

  /// Which source the subtitle auto-select has already run for.
  int _subtitleAppliedFor = -1;

  /// The audio/subtitle picks the viewer made in the panel, re-applied when
  /// a failover opens a new source (mpv resets tracks to auto on open).
  int? _rememberedAudioId;
  int? _rememberedSubtitleId;

  /// The audio language the viewer asked for in Settings, as a canonical
  /// code ('hin', 'tam', …) — or null when the setting is empty. Captured
  /// per open in [_openStream]: a change in Settings reaches the next
  /// media, not the one on screen — the same rule the VLC screen uses.
  /// The mpv screen never read this setting at all, so mpv played its own
  /// auto pick (Tamil) while the drawer showed the resolved default
  /// (Hindi); the VLC screen applies it on open.
  String? _preferredAudioToPick;

  /// The adapter id the audio auto-select last set, and the source it was
  /// set for — so a tracks event that only re-lists the same tracks does
  /// not set the same track again, while a list that settles differently
  /// (Hindi arriving after Tamil) still corrects the pick. Reset on every
  /// open in [_openStream]: an open resets mpv's tracks to auto, so the
  /// pick has to be made again.
  int _audioAutoSelectSetId = -1;
  int _audioAutoSelectSetFor = -1;

  /// The audio pick the viewer last made in the Audio drawer, persisted
  /// across opens (Hive key [_kLastAudioPickKey]) so AUTO still plays it:
  /// the viewer taps Hindi every time, so on AUTO the next open applies
  /// Hindi instead of leaving mpv's early pick (Tamil) in place. Loaded
  /// per open in [_openStream]; written on every drawer tap. The Settings
  /// language, when set, still wins over it (see [_applyAudioAutoSelect]).
  /// Cleared by nothing: a pick is only replaced by a newer pick, never
  /// by an open — a failover that re-opens the same film must not forget
  /// what the viewer was hearing.
  RememberedTrack? _lastAudioPick;

  /// Hive key for [_lastAudioPick].
  static const String _kLastAudioPickKey = 'player_last_audio_track';

  /// True once playback has actually started for the open source (used by the
  /// startup watchdog).
  bool _startedPlaying = false;
  Timer? _watchdogTimer;

  /// Pre-buffer state (see _kPrebufferTarget): while true, an opened stream
  /// is held paused until enough is buffered ahead of the playhead. The
  /// token invalidates a wait from an earlier source, so a stale timer can
  /// never play a source the viewer has already left.
  bool _awaitingPrebuffer = false;
  Timer? _prebufferTimer;
  int _prebufferToken = 0;

  /// +49: when true, [_startAfterPrebuffer] clears the wait without
  /// playing — the old resume re-open ([_openStream] with `autoPlay:
  /// false`) refilled the cache while the film stayed paused, so the
  /// viewer tapped play into a full cushion instead of into a stall.
  /// +55 removed that re-open (plain pause/resume now; the stall
  /// fallback re-opens with `autoPlay: true`, so it plays once the
  /// pre-buffer refills) — the hold is kept for any future
  /// `autoPlay: false` open. Consumed on the first
  /// [_startAfterPrebuffer] call; a later open resets it through
  /// [_waitForPrebuffer], so a normal open always plays.
  bool _prebufferHoldPlay = false;

  /// +50: true once the app has passed through a real background state
  /// (`paused`/`hidden`) since the last `resumed`. The +49 resume
  /// re-open must only fire after a real backgrounding: a transient
  /// `inactive` (Control Center, Notification Center, a call) returns
  /// to `resumed` without ever backgrounding, and re-opening for one
  /// restarts the film for nothing. Set in [didChangeAppLifecycleState];
  /// consumed (and cleared) on every `resumed`.
  bool _appWasBackgrounded = false;

  /// +55: whether the film was actually playing at the moment the app
  /// went away. Snapshotted in the `inactive` branch — the FIRST
  /// lifecycle signal, before media_kit pauses on `hidden` and before
  /// the playing stream can flip [_playing] false — so the `resumed`
  /// branch knows whether to auto-play again. A film the viewer paused
  /// himself snapshots false and stays paused on return; a film that
  /// was playing resumes. Consumed (and cleared) on every `resumed`;
  /// reset in [_startEpisode].
  bool _wasPlayingBeforeBackground = false;

  /// +55: the one-shot stall-fallback timer, armed on `resumed` when a
  /// plain pause/resume starts (see [_maybeFallbackReopen]). If the
  /// plain resume makes no progress the stream is verifiably dead and
  /// the timer re-opens it once. Cancelled in [dispose], in
  /// [_startEpisode], and on the next backgrounding, so a stale timer
  /// can never re-open a source the viewer has already left.
  Timer? _resumeStallTimer;

  /// +55: the playhead at the moment the plain resume started playing
  /// (see [_maybeFallbackReopen]). If the position has not advanced
  /// past this + 2 s when the stall timer fires, the stream is dead.
  Duration _resumeStallPosition = Duration.zero;

  /// The pre-buffer target and hold cap for the open source, set in
  /// [_openStream]: the ordinary [_kPrebufferTarget]/[_kPrebufferMaxWait],
  /// or the high-bitrate pair for a 4K open (see
  /// [isHighBitrateStream]).
  Duration _prebufferTarget = _kPrebufferTarget;
  Duration _prebufferMaxWait = _kPrebufferMaxWait;

  /// Mid-playback stall recovery (see [_onStallTick]): the clock that
  /// measures how long the playhead has stood still, the highest rung of
  /// the [stallActionFor] ladder already fired for this stall window, and
  /// how many times the current source has been reopened for a stall.
  /// A source that plays again earns a fresh budget (see the tick); a
  /// source reopened twice without playing is abandoned for the next
  /// candidate instead of being reopened forever.
  final StallClock _stallClock = StallClock();
  StallAction _stallLastAction = StallAction.none;
  int _stallRecoveries = 0;
  int _stallStreamIndex = -1;

  /// The buffered position the last stall tick saw: if it grew since then,
  /// bytes are still arriving and the cache is refilling rather than dead
  /// (see [stallActionFor]'s `arriving`).
  Duration _stallBufferedAt = Duration.zero;

  /// The stall watchdog's tick, every 2s while the screen lives.
  Timer? _stallTimer;

  /// The thermal watch's tick, every [_kThermalPoll] while the screen
  /// lives (iOS only): reads the phone's heat and drops a 4K stream for
  /// 1080p when it is serious or critical (see [_onThermalTick]).
  Timer? _thermalTimer;

  /// The thermal-aware quality governor (see `mpv_thermal_quality.dart`):
  /// decides, per thermal tick, whether the phone's heat wants a quality
  /// change. Pure — the screen acts on its decision.
  final ThermalQualityGovernor _thermalGovernor = ThermalQualityGovernor();

  /// The mpv stats overlay (+34): the live playback measurements
  /// (decoder, render target, drop counters, cache) drawn over the
  /// video while the QoE-log developer option is on. It rides on that
  /// option because it is the only diagnostics switch that works on a
  /// release build — the app-log viewer is debug-only, so a debugPrint
  /// log is invisible on the user's phone and the overlay is the only
  /// surface he can screenshot and report.
  bool _showMpvStatsOverlay = false;

  /// The overlay's text, refreshed every [_kMpvStatsInterval] while
  /// playing. Empty until the first refresh.
  final ValueNotifier<String> _mpvStatsText = ValueNotifier<String>('');

  /// The drop counters at the last overlay refresh, so the overlay can
  /// show the change since the last tick (+N) next to each cumulative
  /// total.
  final Map<String, int> _prevMpvDrops = <String, int>{};

  Timer? _mpvStatsTimer;

  /// The stream that was playing when iOS PiP started, when the PiP
  /// quality drop (+31) moved to a lighter one. Null when no drop is
  /// in effect: either PiP is not up, the stream was already light,
  /// or there was no lighter stream. Restored on PiP stop (see
  /// `_restoreQualityAfterPip`). Kept apart from the thermal
  /// governor's own drop state — the two drops are independent, and
  /// the thermal watch stands down while PiP is up (see
  /// `_onThermalTick`), so neither can cancel the other's episode.
  int? _pipDroppedFrom;

  /// Whether the PiP render cap (+35 P1) is in effect: the SW render
  /// target is capped at 1920x1080 while the iOS PiP window is up.
  /// Tracked apart from the thermal governor's own lightened state —
  /// the two caps share one actuation ([_setIosRenderCap]), so the
  /// target is always the min of the two (see [pipRenderCapTarget]):
  /// the PiP restore on stop must not clobber a thermal lighten, and
  /// a thermal unlighten during PiP must not raise the PiP cap (see
  /// [_clearThermalLighten]). False when PiP is down or the source is
  /// at or below 1080p (nothing to cap).
  bool _pipRenderCapped = false;

  /// Whether a VideoToolbox restore (+40 P4) is already running: the
  /// resume hook and the PiP-stop hook can both fire for one return,
  /// and two overlapping restores could re-open the stream twice.

  /// The hardware-decode watch that follows a Home → return (build 70,
  /// see [_runHwdecResumeWatch]). The token is bumped by every new
  /// watch and by every backgrounding, so an older watch stands down
  /// the moment it is superseded. The counters feed the QoE overlay's
  /// `hw-restore:` line ([hwdecResumeOverlayLine]).
  int _hwdecWatchToken = 0;
  int _hwdecWatchChecks = 0;
  int _hwdecWatchCycles = 0;
  bool _hwdecWatchReopened = false;
  String _hwdecWatchOutcome = 'waiting';

  /// Build 71: how many returns from the background the restore has
  /// handled in this player session (the overlay's `#N`; 0 = none
  /// yet), what the paused-decoder refresh did on the last one (the
  /// overlay's `pre:`), and whether the watch is waiting for the
  /// viewer to press play — the film comes back from Home PAUSED, so
  /// the watch starts from the playing stream, not from the return
  /// (see [_onIosReturnHwdec]).
  int _hwdecReturns = 0;
  String _hwdecPre = '-';
  bool _hwdecWatchPending = false;

  /// Whether this source has been SEEN decoding on VideoToolbox (build
  /// 70). The restore only ever brings back what was there: with the
  /// PiP renderer on (PiP mode mpv) a film can run with an empty
  /// `hwdec-current` from its first frame (phone proof 2026-11-18,
  /// 1080p, `pip: on`, `hwdec:` empty while playing normally), and
  /// build 69 called that "lost" on every return from the PiP window
  /// and re-opened the source — the black 00:00/LIVE flash. Set by
  /// [_noteHwdecBaseline]; cleared on a different source and after the
  /// watch's own re-open, so one film is re-opened for this at most
  /// once until hardware decode is seen again.
  bool _hwdecSeenAlive = false;

  /// Build 99 (diagnostic) made permanent in build 100: whether the
  /// current open plays with hardware decode off. The QoE overlay
  /// pinned the Nebula black-video failure to VideoToolbox decoding
  /// but never reaching the output texture (`src: 1920x800`, `out: x
  /// tex: 0x0`, `hwdec: videotoolbox`) — and the Paris control test
  /// proved it is Nebula-fMP4-specific, not general HLS — so b99
  /// opened HLS-proxy streams with `hwdec=no` (software decode) and
  /// the phone test proved VideoToolbox was the culprit. Build 100
  /// scopes it: only fMP4 HLS (or an HLS probe that could not tell)
  /// sets this; plain .ts HLS keeps VideoToolbox. A normal open
  /// restores the usual decoder (see [_applyHlsProxyHwdec]), and the
  /// resume machinery stands down on its own — it only ever restores a
  /// decoder that was seen alive ([_hwdecSeenAlive] stays false under
  /// software decode). iOS only: the fMP4 HLS shape lives there, and
  /// 4K smoothness elsewhere depends on hardware decode.
  bool _hlsProxyHwdecNo = false;

  /// Where the open source started (its resume point, else zero): the
  /// pre-buffer cushion is measured from here, not from the stream start.
  Duration _openStart = Duration.zero;

  /// The chrome's auto-hide clock, owned here and lent to the controls.
  late final ChromeVisibilityController _chrome;

  /// The video view's key, so the screen can push the subtitle padding
  /// into it — media_kit's SubtitleView caches its padding at creation
  /// and never re-reads the configuration (see _syncSubtitlePadding).
  GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();

  /// The subtitle padding last pushed into the video view, so the sync
  /// only calls the view when the padding actually moved.
  EdgeInsets? _lastSubtitlePadding;

  /// The width of a right-side drawer open over the video (build 86),
  /// 0 when none is open. The caption shifts left by it — see
  /// `mpvSubtitleViewConfiguration`'s `drawerWidth` — so it is never
  /// hidden behind a drawer. Set by the controls' `onDrawerChanged`;
  /// the build below folds it into the subtitle configuration, and the
  /// post-frame sync pushes it to the view.
  double _drawerOpenWidth = 0;

  /// The screen height last seen in build. The padding sync runs from a
  /// post-frame callback and from the chrome listener — outside build —
  /// so it reads the height from here instead of calling MediaQuery
  /// (an inherited-widget read) off the build path.
  double _lastScreenHeight = 0;

  /// The pinch zoom's value, owned here and written by the controls'
  /// gesture layer; the Transform over the video reads it.
  final ValueNotifier<double> _videoScale = ValueNotifier<double>(1.0);

  /// The video fit, owned here; the controls report changes through
  /// onFitChanged and the video widget reads it.
  VlcVideoFit _fit = VlcVideoFit.contain;

  /// Fraction of the media fetched ahead of the playhead, for the seek
  /// bar's buffered band.
  final ValueNotifier<double> _bufferedFraction = ValueNotifier<double>(0.0);

  /// Whether this media has a subtitle to pick — an embedded track the
  /// engine has published, or a file the source shipped. The subtitles
  /// button is only there when there is one.
  final ValueNotifier<bool> _hasSubtitles = ValueNotifier<bool>(false);

  /// Whether the screen is locked against accidental touches.
  final ValueNotifier<bool> _locked = ValueNotifier<bool>(false);

  /// What the side panel shows, published from every place it changes.
  final ValueNotifier<PanelData> _panelData = ValueNotifier<PanelData>(
    PanelData.empty,
  );

  /// Intro/outro bands, usually empty. IntroDB (TV/dramas, on by
  /// default) and AniSkip (anime, +55) fill them in the background;
  /// a title with no data in either simply has no Skip button.
  List<SkipSegment> _skipSegments = const <SkipSegment>[];

  /// The episode the AniSkip lookup already ran for (see
  /// [_maybeLoadAniSkip]): the duration listener fires on every
  /// duration change, and without this the same episode would
  /// re-fetch on each one.
  String? _aniskipAttemptedKey;

  /// +56: the item after [_loadSkipSegments] enriched it with TMDB/IMDb
  /// ids. [_maybeLoadAniSkip] reads the ORIGINAL item's sync data, so
  /// without this the Simkl lookup below would have no ids to ask
  /// with — the exact gap that left Attack on Titan with no Skip Intro
  /// on +55 (the plugin files no sync ids, and the enrichment only fed
  /// IntroDB). Null until the enrichment step runs; reset per episode
  /// in [_startEpisode].
  MultimediaItem? _enrichedItem;

  /// +56: the enrichment step in [_loadSkipSegments] has run (whether
  /// it enriched anything or not). [_maybeLoadAniSkip] defers while
  /// this is false and the plugin filed no ids, so a title-only
  /// attempt never resolves through the AniList title search before
  /// Simkl (the exact lookup) gets its chance.
  bool _skipEnrichmentDone = false;

  /// +56: the Simkl-resolved sync ids for this title, cached by item
  /// URL so a series is resolved once, not once per episode. Only a
  /// successful resolution is cached — a miss is retried next episode,
  /// same rule as the service caches. NOT reset in [_startEpisode]:
  /// the URL key is the series, so the resolution survives episode
  /// advances and is only re-asked for a different title.
  Map<String, String>? _resolvedSyncIds;
  String? _resolvedSyncIdsForUrl;

  /// The episode being played, and the route token for it. Both move on an
  /// advance; the panel and the next/previous arrows read them.
  Episode? _currentEpisode;
  late String _currentVideoUrl;

  /// An episode advance in flight.
  bool _advancing = false;

  /// The up-next card's episode, or null when no card is up.
  Episode? _nextEpisodeOffer;

  /// The viewer pressed Cancel on the up-next card.
  bool _nextEpisodeDeclined = false;

  /// The up-next card on screen was raised while the episode was still
  /// playing (its outro started, or Skip outro was tapped) rather than by
  /// the episode ending (v7). Cancel then just puts the card away — there
  /// is no "ended" to show — and the countdown pauses with the video.
  bool _offerBeforeEnd = false;

  /// The outro already raised the card once this episode (v7), so seeking
  /// back into it does not raise it again.
  bool _outroOffered = false;

  /// "Auto-play next episode" (Settings → Player, v7), read when it is
  /// needed so a change applies to the episode on screen.
  bool get _autoPlayNext =>
      ref.read(playerSettingsProvider).asData?.value.autoPlayNextEpisode ??
      true;

  /// The ended card's kind, or null when no card is up.
  EndedKind? _ended;

  /// The sleep timer (v7): one for the whole player session, so it keeps
  /// counting across episode changes; gone when the player closes.
  late final SleepTimer _sleepTimer = SleepTimer()..onFire = _onSleepTimerFired;

  /// A timed sleep fired while no video was playing yet (an episode
  /// still loading): the pause lands as soon as it starts.
  bool _sleepPausePending = false;

  /// The settings, live, for the panel's Subtitle style page. Updated from
  /// the provider (see [_init]); the panel reads this, not the provider.
  late final ValueNotifier<PlayerSettings> _playerSettings;

  /// Last position-update setState, so mpv's frequent ticks do not rebuild
  /// the whole screen at full rate.
  DateTime _lastPositionUi = DateTime.fromMicrosecondsSinceEpoch(0);

  bool _disposed = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  /// The platform bridge for Android picture-in-picture: the activity
  /// enters PiP through it, and the PiP window's transport buttons and
  /// mode changes come back through it (see [_attachPip]).
  final PlayerPlatformService _platform = PlayerPlatformService();

  /// True while the PiP window is open (or an enter request is out): the
  /// golden chrome is unmounted, so the video is bare under the window.
  bool _inPip = false;

  /// Set by the first Back, so a second one cannot pop the page under
  /// the player as well.
  bool _leaving = false;

  /// The PiP watchdog: if the window never opens after a successful
  /// request, the chrome comes back after 5 s instead of staying hidden
  /// forever (mirrors the VLC screen).
  Timer? _pipWatchdog;

  /// The iOS mpv PiP diag log (+31): while the PiP window is up, a tick
  /// every 5 s that logs the native `diag()` — gate state and live-feed
  /// throughput (ingest / liveEnq / liveDrop / liveAgeMs) — so the next
  /// phone test's console can tell "gate closed" from "no frames" from
  /// "frames too slow". debugPrint only; cancelled on PiP stop and in
  /// dispose. Best-effort: if the isolate is suspended in background
  /// the timer simply does not fire.
  Timer? _pipDiagTimer;
  int _pipAttempt = 0;
  bool _pipWindowOpened = false;
  bool _pipAttemptFromButton = false;

  /// iOS mpv PiP (+28): the native bridge, created in [_init] only when
  /// the viewer turned the setting on — the player then runs the software
  /// renderer, which is what makes the frames available to tap. Null on
  /// Android and when the setting is off.
  MpvPipIos? _iosPip;

  /// Whether this player opened with the iOS mpv PiP setting on. Read
  /// once in [_init], like the engine choice: a change mid-play takes
  /// effect on the next play, because the VideoController — hardware or
  /// software renderer — is created once when the player opens.
  bool _iosMpvPipEnabled = false;

  /// Whether the native plugin reports sample-buffer PiP as supported on
  /// this device. Resolved in [_init]; false everywhere the bridge does
  /// not exist, so the button never renders there.
  bool _iosPipSupported = false;

  /// mpv's `sub-visibility` as it was before PiP started, so the burn-in
  /// the PiP window needs can be undone exactly when PiP stops. Null
  /// while PiP is not up. Normally `no` (media_kit sets it from
  /// `PlayerConfiguration.libass`, false here) — remembered rather than
  /// assumed, so a build that changes the default still restores right.
  String? _subVisibilityBeforePip;

  bool get _isSeries =>
      widget.item.contentType == MultimediaContentType.series ||
      widget.item.contentType == MultimediaContentType.anime;

  bool get _isEpisodic => _isSeries && _currentEpisode != null;

  bool get _canSeek => _duration > Duration.zero && !_isLive;

  /// Picture-in-picture: Android always (an activity mode), iOS only
  /// when the viewer turned the +28 setting on — PiP on iOS needs the
  /// software renderer, so the player must have opened in that mode —
  /// and the native plugin reports support. Meaningless on a television
  /// either way.
  ///
  /// The gate reads [defaultTargetPlatform] rather than `Platform.isAndroid`
  /// because only the former can be overridden by a test (see
  /// [PlayerPlatformService.enterPip]); in production the two agree.
  bool get _pipAvailable {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      if (!_iosPipOnDemand || !_iosPipSupported) return false;
      final profile = ref.read(deviceProfileProvider).asData?.value;
      return playerFormFactorOf(profile) != PlayerFormFactor.tv;
    }
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    final profile = ref.read(deviceProfileProvider).asData?.value;
    return playerFormFactorOf(profile) != PlayerFormFactor.tv;
  }

  /// Whether an episode follows this one. Recomputed rather than cached so
  /// it cannot go stale after an advance.
  bool get _hasNextEpisode =>
      nextEpisodeFor(
        item: widget.item,
        current: _currentEpisode,
        videoUrl: _currentVideoUrl,
      ).next !=
      null;

  Episode? get _previousEpisode => previousEpisodeFor(
    item: widget.item,
    current: _currentEpisode,
    videoUrl: _currentVideoUrl,
  );

  /// The app's provider container, taken once in [initState].
  ///
  /// The progress recorder and the tracker write through this and not
  /// through `ref`: `ref` throws once the widget is being unmounted, and
  /// [dispose] forces a last progress write. With `ref.read` that write
  /// threw, and everything after it in [dispose] — the engine stop, the
  /// portrait turn, the system bars — never ran. The on-screen arrow hid
  /// it by doing all three before the pop; Android's system Back (button
  /// or swipe) pops the route directly, so the film kept playing with
  /// the app left in landscape (user report 2026-11-19, v2 APK).
  late final ProviderContainer _container;

  T _read<T>(ProviderListenable<T> provider) => _container.read(provider);

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    WidgetsBinding.instance.addObserver(this);
    _currentEpisode = widget.episode;
    _currentVideoUrl = widget.videoUrl;
    // Fullscreen playback hides the Android status + navigation bars, so
    // the video fills the whole screen with nothing on top of it. The VLC
    // screen does the same in its own initState; the mpv screen never did,
    // which is why the status bar (time, signal, battery) showed over the
    // video on Android. iOS already hides its status bar here, so this is
    // Android-only. Restored in dispose.
    if (defaultTargetPlatform == TargetPlatform.android) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    // No landscape here: the source list shown before play stays portrait,
    // and landscape is forced only when the video itself first starts
    // playing (see the playing listener).
    _chrome = ChromeVisibilityController(
      isPlaying: () => _adapter.value.isPlaying,
    );
    // The chrome showing/hiding moves the caption's bottom padding, so
    // the padding is pushed into the video view on every change.
    _chrome.addListener(_onChromeVisibilityChanged);
    _locked.addListener(_onChromeVisibilityChanged);
    // PiP transport buttons + mode changes ride back through the platform
    // channel; attach early so a window opened before the first play is
    // still routed.
    _attachPip();
    _init();
  }

  @override
  void dispose() {
    _disposed = true;
    // Build 119: the temp download STOPS with the player but its file
    // is KEPT (see [TempDownload.stop]) — it lives as long as Zeus is
    // open, so Continue Watching reopens the film from the bytes
    // already fetched. The file is deleted only when Zeus closes or
    // the viewer cancels the download.
    unawaited(_tempDownload?.stop());
    _tempDownload = null;
    unawaited(_tempDownloadSub?.cancel());
    _tempDownloadSub = null;
    _sleepTimer.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _watchdogTimer?.cancel();
    _prebufferTimer?.cancel();
    _resumeStallTimer?.cancel();
    _stallTimer?.cancel();
    _thermalTimer?.cancel();
    _mpvStatsTimer?.cancel();
    _mpvStatsText.dispose();
    _pipWatchdog?.cancel();
    _pipDiagTimer?.cancel();
    // Build 77: forget the film in the stream cache proxy (deletes its
    // store file). A moment later, so the engine has stopped reading.
    _proxyOpenToken++;
    final proxyHandle = _proxyHandle;
    _proxyHandle = null;
    if (proxyHandle != null) {
      Future<void>.delayed(const Duration(seconds: 2), () {
        StreamCacheService.instance.close(proxyHandle.token);
      });
    }
    // The native side remembers the last synced playing state (see the
    // playing listener): clear it now, or a film left playing would make
    // MainActivity open a PiP window for a player that no longer exists
    // the next time the viewer presses Home from another screen.
    _platform.syncPipState(false);
    // The channel handler closes over this screen; without the detach it
    // would keep routing PiP buttons into a disposed player.
    _platform.detachPipListener();
    // iOS mpv PiP (+28): release the native session and put mpv's
    // subtitle rendering back the way it was, while the player still
    // exists to answer the property write.
    unawaited(_restoreMpvSubtitlesAfterPip());
    unawaited(_iosPip?.dispose());
    _iosPip = null;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    // Order matters: write first, tear down second. A stop after the write
    // halts the audio now — the async dispose alone left it running after
    // the screen was gone. Guarded: nothing in the write may keep the
    // engine stop and the portrait turn below from running.
    try {
      _flushProgress();
    } catch (_) {}
    try {
      _tracker?.finish();
    } catch (_) {
      // Tracking must never block leaving the player.
    }
    _chrome.removeListener(_onChromeVisibilityChanged);
    _locked.removeListener(_onChromeVisibilityChanged);
    _chrome.dispose();
    _videoScale.dispose();
    _bufferedFraction.dispose();
    _downloadedFraction.dispose();
    _hasSubtitles.dispose();
    _locked.dispose();
    _videoIsHdr.dispose();
    _panelData.dispose();
    _playerSettings.dispose();
    _switchToken++;
    if (_engineReady) {
      _engineReady = false;
      unawaited(_disposeEngine(_player));
    }
    if (_adapterCreated) _adapter.dispose();
    _restoreOrientation();
    // Hands the status + navigation bars back: without this the app stays
    // in immersive mode after the player closes, and Home has no status
    // bar. Mirrors the hide in initState (Android only).
    if (defaultTargetPlatform == TargetPlatform.android) {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Build 70: note whether hardware decode is alive on the way out,
    // so the return only restores a decoder that was really there.
    if (state != AppLifecycleState.resumed) {
      unawaited(_noteHwdecBaseline());
    }
    if (_disposed || !mounted) return;
    // Build 77: iOS may close the proxy's listening socket while the
    // app is suspended; open it again (same port) before the engine
    // needs its next connection.
    if (state == AppLifecycleState.resumed && _proxyHandle != null) {
      unawaited(StreamCacheService.instance.ensureListening());
    }
    if (state == AppLifecycleState.inactive) {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        // iOS: `inactive` fires for a transient overlay too — Control
        // Center, Notification Center, a call — and for a real leaving
        // (Home, the app switcher) before `hidden`. Nothing opens PiP
        // here any more: automatic PiP was removed in +55 (user
        // 2026-11-16: "jab vi pip click karu tabhi pip on ho") — the
        // native drive (autoEnterPiP) and the Dart `hidden` backup are
        // both gone, and only the PiP button opens a window. The one
        // thing `inactive` is good for is the snapshot below: it is
        // the FIRST signal, before media_kit pauses on `hidden` and
        // before the playing stream can flip [_playing] false, so it
        // still holds the pre-background playing state the `resumed`
        // branch needs (see [_wasPlayingBeforeBackground]).
        //
        // Build 71 finding, NOT changed here: Flutter replays `hidden`
        // → `inactive` → `resumed` on the way back IN as well, so this
        // line runs a second time while Home's pause is in force and
        // the snapshot reads false at `resumed`. On the phone the film
        // therefore always returns paused, the viewer taps play, and
        // [_resumeIosAfterBackground] (auto-play, the 4K re-open, the
        // stall timer) never acts — both 2026-11-18 recordings show
        // exactly that. Making the snapshot stick would turn the
        // auto-play and the 4K re-open (black, 00:00/LIVE) on for the
        // first time, which is the viewer's call, not this build's.
        // The hardware-decode restore no longer depends on it (see
        // [_onIosReturnHwdec]).
        _wasPlayingBeforeBackground = _playing;
        // Build 73: on the way back IN (`hidden` → `inactive` →
        // `resumed`) this is the first foreground signal — a move
        // back to hardware that was waiting for the foreground starts
        // here instead of after `resumed` and its backstop.
        if (_appWasBackgrounded &&
            (_pendingSwitchToHardware || _pipRestoring)) {
          unawaited(_onPipEnded(reason: 'inactive'));
        }
      } else {
        // Home swipe / app switcher on Android: the moment to enter PiP.
        // `inactive` is the activity pausing while still visible, so the
        // enter call is still valid here — and the window opening keeps
        // the app from ever reaching `paused`, so media_kit's
        // pauseUponEnteringBackgroundMode never fires and the film keeps
        // playing under the window. Only while actually playing, and only
        // where PiP exists; a paused film stays paused.
        if (!_inPip && _pipAvailable && _playing) {
          unawaited(_enterPip());
        }
      }
    }
    if (state == AppLifecycleState.resumed) {
      // Backstop behind `pipModeChanged`: returning to the foreground is
      // what ending PiP looks like, and the chrome must come back with it
      // whether or not the activity got round to telling us. The window
      // is already gone by the time the app is foregrounded, so there is
      // no native stop to send — just take the chrome back.
      final wasInPip = _inPip;
      // +50: consume the backgrounded flag (see [_appWasBackgrounded]):
      // the resume re-open below runs only after a REAL backgrounding
      // (paused/hidden → resumed). A transient inactive (Control
      // Center, Notification Center) returns to resumed with the flag
      // clear, so the film is left alone. Cleared on every resumed so
      // a stale backgrounding can never fire a later re-open.
      final wasBackgrounded = _appWasBackgrounded;
      _appWasBackgrounded = false;
      if (_inPip) {
        _pipWatchdog?.cancel();
        _pipWatchdog = null;
        setState(() => _inPip = false);
      }
      // +40 P4: iOS can invalidate the VideoToolbox session while the
      // app is backgrounded, and the file then decodes in software for
      // the rest of its run — 4K lags after every Home → return even
      // though PiP was never used (user proof 2026-11-15). Check the
      // live decoder and restore it when it is actually lost — never
      // when it is healthy. Build 71: decided on every `resumed` by
      // [_onIosReturnHwdec]; build 70 only armed its watch in places
      // that never run when the film comes back paused, which is how
      // it always comes back.
      // Build 72: not on a return from the PiP window and not during
      // a renderer move (see [rendererReturnLogicAllowed]).
      final backgroundedWithPip = _backgroundedWithPip;
      _backgroundedWithPip = false;
      final returnLogicAllowed = rendererReturnLogicAllowed(
        phase: _rendererPhase,
        backgroundedWithPip: backgroundedWithPip || wasInPip,
      );
      if (returnLogicAllowed) {
        _onIosReturnHwdec(
          wasBackgrounded: wasBackgrounded,
          wasInPip: wasInPip,
          resumePathActs: iosResumePathActs(
            wasBackgrounded: wasBackgrounded,
            wasInPip: wasInPip,
            wasPlaying: _wasPlayingBeforeBackground,
          ),
        );
      }
      // Build 72: the PiP end, decided now that the app is in the
      // foreground (keep the software session, or move to hardware).
      if (_iosPipOnDemand) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_onPipEnded(reason: 'resumed'));
        });
        // Backstop: the native "PiP stopped" can trail the lifecycle
        // by a moment; ask once more when it has had time to land.
        Future<void>.delayed(const Duration(milliseconds: 1500), () {
          if (_disposed || !mounted) return;
          unawaited(_onPipEnded(reason: 'resumed+'));
        });
      }
      // +55: NO re-open on return (user 2026-11-16, +54 installed:
      // every Home → return showed 00:00/LIVE + black + spinner for
      // ~3-4 s before resuming at the paused position — the +49
      // re-open itself). Home pauses the film (see the paused/hidden
      // branch below); return just resumes it from the paused
      // position — a plain play(), no fresh connection, no restart,
      // the position stays where it was. Only when the film was
      // actually playing when the app went away (see
      // [_wasPlayingBeforeBackground] — a film the viewer paused
      // himself stays paused) and only after a REAL backgrounding
      // ([wasBackgrounded] above — a Control Center pull-down must
      // not auto-play). A PiP window open means the film never
      // paused, so there is nothing to resume. iOS only: the +49
      // re-open was iOS-only, and Android's return path is unchanged.
      // The plain resume relies on mpv's own reconnect
      // (`reconnect=1`, see [kMpvIosOptions]) to re-establish the
      // socket iOS killed while suspended. If the stream is
      // verifiably dead anyway — no position progress 8 s after
      // resume-play — the stall fallback ([_maybeFallbackReopen])
      // re-opens it once (the old +49 path, now a fallback, never
      // the default). +56: one exception — 4K (see
      // [_resumeIosAfterBackground]). The plain resume lags at 4K
      // bitrates on a stale decoder/socket while 1080p recovers, so
      // a 4K track re-opens the source on return; everything below
      // 4K keeps the plain resume above.
      if (defaultTargetPlatform == TargetPlatform.iOS && returnLogicAllowed) {
        unawaited(
          _resumeIosAfterBackground(
            wasBackgrounded: wasBackgrounded,
            wasInPip: wasInPip,
            wasPlaying: _wasPlayingBeforeBackground,
          ),
        );
      }
      _wasPlayingBeforeBackground = false;
    }
    // A backstop behind the pause flush: the position at the moment the
    // app goes away is the one Continue Watching must have.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // +50: a real backgrounding (not a transient inactive) — the
      // next `resumed` may run the plain resume (see
      // [_appWasBackgrounded]).
      if (!_appWasBackgrounded) {
        _backgroundedWithPip = _inPip || rendererSwitching(_rendererPhase);
      }
      _appWasBackgrounded = true;
      // Build 70: a new backgrounding ends the last return's
      // hardware-decode watch; the next return arms a fresh one.
      _hwdecWatchToken++;
      _hwdecWatchPending = false;
      _flushProgress();
      // +55: Home PAUSES the film (user 2026-11-16: "home se janepe
      // pause ho"). With automatic PiP removed there is no window any
      // more to keep it playing, and with the PiP setting ON media_kit's
      // `pauseUponEnteringBackgroundMode` never fires (see the player
      // setup) — without this the film would keep playing invisibly in
      // the background. Never pause under a live PiP window: the window
      // IS the playback, and pausing would freeze it. A film already
      // paused is a no-op. The stall-fallback timer from the last
      // return is cancelled: a new backgrounding starts a fresh cycle.
      _resumeStallTimer?.cancel();
      _resumeStallTimer = null;
      // Build 73: nor on the way back in from the PiP window — the
      // native restore lands before Flutter replays `hidden`, and the
      // build-72 pause here is what left the film on the play icon.
      if (!_inPip &&
          !_pipRestoring &&
          _engineReady &&
          !rendererSwitching(_rendererPhase)) {
        unawaited(_player.pause());
      }
    }
    if (state == AppLifecycleState.resumed) {
      // The return is complete: the restore no longer needs protecting.
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        if (_disposed) return;
        _pipRestoring = false;
      });
    }
  }

  /// +56: the iOS Home → return after a real backgrounding, 4K-aware
  /// (user 2026-11-16: "only 4k videos hi ... source reconnect
  /// hojaye ... baki sab ... reconnect naho"). Implements the decision
  /// table in [iosResumeAction] — the early return is its `none`, the
  /// 4K branch its `reopen4K`, the fall-through its `plainResume`.
  ///
  /// 4K re-opens the source at the paused position and plays once the
  /// pre-buffer refills (the +49 shape, `autoPlay: true` — the film
  /// comes back playing, as +55 promised), because the plain resume
  /// lags at 4K bitrates on a stale decoder/socket while 1080p
  /// recovers. The re-open DOES show the 00:00/LIVE + black + spinner
  /// briefly on return — the trade-off the user chose for 4K only —
  /// and it arms NO stall timer: the re-open IS the recovery, and a
  /// second re-open 8 s later would just replay the reconnect for a
  /// stream that is already fresh (a re-opened stream that is itself
  /// dead is mpv's own reconnect's job, not a second re-open's).
  /// Everything below 4K takes the +55 plain resume: a plain play()
  /// from the paused position, the delayed HW restore, and the 8 s
  /// stall fallback.
  Future<void> _resumeIosAfterBackground({
    required bool wasBackgrounded,
    required bool wasInPip,
    required bool wasPlaying,
  }) async {
    if (_disposed || !mounted) return;
    if (!iosResumePathActs(
      wasBackgrounded: wasBackgrounded,
      wasInPip: wasInPip,
      wasPlaying: wasPlaying,
    )) {
      return;
    }
    final is4K = await _isCurrentVideo4K();
    if (_disposed || !mounted) return;
    if (is4K) {
      debugPrint(
        '[mpv] resume: 4K, re-opening stream $_streamIndex '
        'at $_position (+56)',
      );
      _resumeStallTimer?.cancel();
      _resumeStallTimer = null;
      unawaited(_openStream(_streamIndex, start: _position, autoPlay: true));
      // Build 70: the re-open itself can come up in SOFTWARE decode
      // (phone proof 2026-11-18: `hwdec: videotoolbox` before Home,
      // empty after the 4K re-open, for the rest of the film), and
      // nothing checked the decoder after it — the early check in the
      // resumed hook stands down while the film is still paused. So
      // the decoder is verified once the re-opened film is playing.
      unawaited(_runHwdecResumeWatch());
      return;
    }
    debugPrint(
      '[mpv] resume: plain resume from $_position '
      '(no re-open, +55)',
    );
    _resumeStallPosition = _position;
    unawaited(_player.play());
    // +40 P4: iOS can invalidate the VideoToolbox session while
    // the app is backgrounded. The early call in the resumed hook
    // stands down while paused, so the watch below is what makes
    // the restore run on a Home → return at all. Build 70: the
    // single delayed check became the bounded watch the 4K branch
    // uses too (see [_runHwdecResumeWatch]) — it waits for the film
    // to be playing, and a lost decoder is cycled in place before
    // any re-open, so a film below 4K gets no 00:00/black flash
    // unless two cycles have already failed.
    unawaited(_runHwdecResumeWatch());
    _resumeStallTimer?.cancel();
    _resumeStallTimer = Timer(const Duration(seconds: 8), _maybeFallbackReopen);
  }

  /// +56: is the video track currently decoding 4K? Reads the live
  /// `video-params` size — the ground truth of what is decoding, not
  /// the source row's label (a mislabelled 1080p file must not
  /// reconnect). When the properties are unreadable — a decoder too
  /// stale to answer — falls back to the source row's label
  /// ([isHighBitrateStream]): a 4K-labelled source with unreadable
  /// video-params is exactly the stale-decoder case the re-open
  /// fixes. Never throws; false on any failure (the plain resume is
  /// the safe default — only a proven 4K reconnects).
  Future<bool> _isCurrentVideo4K() async {
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        final width = _parseVideoParam(
          await platform.getProperty('video-params/w'),
        );
        final height = _parseVideoParam(
          await platform.getProperty('video-params/h'),
        );
        if (width != null || height != null) {
          return is4KVideo(width: width, height: height);
        }
      }
    } catch (_) {
      // Fall through to the label.
    }
    return _streamIndex >= 0 &&
        _streamIndex < _streams.length &&
        isHighBitrateStream(_streams[_streamIndex]);
  }

  /// Parses an mpv video-param size: an int, or a numeric string
  /// ("3840", or "3840.0" from a double-typed read).
  static int? _parseVideoParam(dynamic value) {
    if (value is num) return value.toInt();
    final parsed = double.tryParse(value.toString());
    return parsed?.toInt();
  }

  /// Applies a Video output preset to the live mpv instance (+57):
  /// the picture changes on the current video, no re-open, no seek.
  /// The custom values come from the live settings — the Custom
  /// preset's stored tone-mapping / target peak, null when never set
  /// (Custom then behaves as Native EDR). Best-effort: a setProperty
  /// failing must not break playback, and the read-back log shows what
  /// actually landed (see [applyVideoOutputPresetOptions]).
  Future<void> _applyVideoOutputPreset(VideoOutputPreset preset) async {
    try {
      final platform = _player.platform;
      if (platform is! NativePlayer) return;
      final settings = _playerSettings.value;
      await applyVideoOutputPresetOptions(
        platform,
        preset,
        customToneMapping: settings.videoCustomToneMapping,
        customTargetPeak: settings.videoCustomTargetPeak,
      );
    } catch (_) {
      // A preset failing to apply must never break playback.
    }
  }

  /// Applies the Video panel's PICTURE sliders to the live mpv instance
  /// (v9): mpv's own brightness / contrast / saturation. Called on every
  /// drag tick, so the picture follows the thumb.
  Future<void> _applyPicture(PictureValues values) async {
    try {
      final platform = _player.platform;
      if (platform is! NativePlayer) return;
      await applyPictureOptions(
        platform,
        brightness: values.brightness,
        contrast: values.contrast,
        saturation: values.saturation,
      );
    } catch (_) {
      // A slider failing to apply must never break playback.
    }
  }

  /// Whether the playing video is HDR (v9), for the Video panel: null
  /// until mpv reports the video's transfer function, and when it cannot
  /// be read.
  final ValueNotifier<bool?> _videoIsHdr = ValueNotifier<bool?>(null);

  /// Reads `video-params/gamma` — `pq` or `hlg` is HDR, the same test the
  /// software renderer's tone-mapping LUT uses. Run when the video's size
  /// is known (a new video) so the panel is right by the time it opens.
  Future<void> _refreshVideoIsHdr() async {
    try {
      final platform = _player.platform;
      if (platform is! NativePlayer) return;
      final gamma = await platform.getProperty('video-params/gamma');
      if (_disposed || !mounted) return;
      _videoIsHdr.value = videoGammaIsHdr(gamma);
    } catch (_) {
      if (_disposed) return;
      _videoIsHdr.value = null;
    }
  }

  /// +55 stall fallback: the plain pause/resume on Home → return relies
  /// on mpv's own reconnect (`reconnect=1`, see [kMpvIosOptions]) to
  /// re-establish the socket iOS killed while suspended. If the stream
  /// is verifiably dead anyway — the playhead has not advanced 8 s
  /// after resume-play — re-open it once from the current position
  /// (the old +49 path, now a fallback, never the default). Runs at
  /// most once per backgrounding cycle: the one-shot timer is not
  /// re-armed, and a second backgrounding cancels it first.
  ///
  /// 8 s is beyond mpv's own recovery budget (`network-timeout: 5` +
  /// `reconnect_delay_max: 2`), so a healthy plain resume — which
  /// starts progressing within a few seconds — never triggers it, and
  /// a dead one is not left stuck. `autoPlay: true`: the fallback is a
  /// recovery of a film that was playing, so it comes back playing.
  void _maybeFallbackReopen() {
    if (_disposed || !mounted) return;
    if (!_playing) return; // viewer paused it (or it never resumed).
    if (_position > _resumeStallPosition + const Duration(seconds: 2)) {
      return; // progressing — the plain resume worked.
    }
    if (!shouldResyncDecoderOnResume(
      wasBackgrounded: true,
      inPip: false,
      awaitingPrebuffer: _awaitingPrebuffer,
      startedPlaying: _startedPlaying,
      hasStream: _streamIndex >= 0 && _streamIndex < _streams.length,
    )) {
      return;
    }
    debugPrint(
      '[mpv] resume stall fallback: no progress 8 s after '
      'resume-play, re-opening stream $_streamIndex at $_position',
    );
    unawaited(_openStream(_streamIndex, start: _position, autoPlay: true));
  }

  void _forceLandscapeIfPortrait() {
    final size = MediaQuery.sizeOf(context);
    if (size.width < size.height) {
      unawaited(
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    }
  }

  void _restoreOrientation() {
    // Force portrait on the way out: the player is the only landscape
    // screen, and DeviceOrientation.values (all) does NOT rotate the
    // device — it just lifts the pin, so the app stays sideways in
    // landscape after Back. portraitUp rotates it back upright.
    unawaited(
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
    );
  }

  /// Leaves the player: stop the audio first, then portrait (so the rotation
  /// starts with the exit transition), then the pop. dispose() repeats the
  /// stop and the portrait as a safety net for a route that went any other
  /// way.
  void _goBack() {
    if (_leaving) return;
    _leaving = true;
    _flushProgress();
    if (_engineReady) {
      unawaited(_player.stop().catchError((Object _) {}));
    }
    _restoreOrientation();
    if (mounted) Navigator.of(context).pop();
  }

  /// Writes the last known-good sample, bypassing the rate limit.
  void _flushProgress() {
    final sample = _sample;
    final recorder = _recorder;
    if (sample == null || recorder == null) return;
    recorder.record(sample, lastStreamUrl: _selected?.url, force: true);
  }

  /// Routes the PiP window's transport buttons and mode changes back to
  /// the screen (Android only; the channel is inert elsewhere).
  ///
  /// The handler is keyed by channel name, so it is process-wide — a
  /// second call replaces the first. Detached in [dispose].
  void _attachPip() {
    _platform.attachPipListener(
      onAction: (action) => switch (action) {
        PipAction.play => unawaited(_player.play()),
        PipAction.pause => unawaited(_player.pause()),
        PipAction.seekForward => _seekRelative(
          PlayerPlatformService.pipSeekStep,
        ),
        PipAction.seekBackward => _seekRelative(
          -PlayerPlatformService.pipSeekStep,
        ),
      },
      onModeChanged: (inPip) {
        if (!mounted || _disposed) return;
        // The attempt's answer, whatever it is: the watchdog stands down.
        // This must run BEFORE the state-match return below: _enterPip
        // sets _inPip optimistically, so on a successful entry the event
        // arrives with inPip == _inPip and the old early return skipped
        // the cancel — the watchdog then fired at 5 s and flipped the
        // player out of PiP (Android: black window until the reset).
        _pipWatchdog?.cancel();
        _pipWatchdog = null;
        if (inPip) _pipWindowOpened = true;
        if (inPip == _inPip) return;
        // The other way into PiP: the viewer swiped home and the
        // auto-enter below never ran, or the system's own PiP control
        // opened it. A locked PiP window has no chip in it, so the lock
        // clears on the way in.
        if (inPip) {
          _pipAttemptFromButton = false;
          _locked.value = false;
        }
        setState(() => _inPip = inPip);
      },
    );
  }

  /// Seeks by [delta] from wherever playback is, for the PiP buttons.
  ///
  /// Clamped at both ends: a negative target is refused outright by mpv,
  /// and overshooting the duration would trip the end-of-media handler.
  /// Counted from the last known position. No chain can straddle this:
  /// [GoldenPlayerControls] is built only while `!_inPip`, so it is
  /// unmounted before a PiP window exists to press these buttons in.
  void _seekRelative(Duration delta) {
    if (!_canSeek) return;
    var target = _position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (_duration > Duration.zero && target > _duration) {
      target = _duration;
    }
    // Build 107: the +10 s / -10 s buttons go through the same seek
    // handler as the bar — a downloaded target reopens the local temp
    // file, a target past the frontier waits with progress.
    unawaited(
      _handleTempSeekRequest(target).then((handled) {
        if (!handled && !_disposed) unawaited(_player.seek(target));
      }),
    );
  }

  /// Enters the Android PiP window.
  ///
  /// Mirrors the VLC screen: the chrome comes off optimistically in the
  /// same frame the request is made, and the lock clears on the way in
  /// (a locked PiP window has no chip in it). Android answers false —
  /// not an error — when the user has PiP disabled for the app, and then
  /// never sends `pipModeChanged`; without the reset below the optimism
  /// is permanent and the chrome never comes back.
  Future<void> _enterPip({bool fromButton = false}) async {
    // iOS mpv PiP (+28) rides the native bridge, not the Android
    // activity call: the window is a sample-buffer PiP window, and the
    // answer arrives through `pipStarted` / `pipFailed`.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // Build 72: the player runs on the hardware renderer until now;
      // the button moves it to the software renderer first.
      switch (pipButtonPlan(_rendererPhase)) {
        case PipButtonPlan.ignore:
          return;
        case PipButtonPlan.enter:
          _pipEntering = true;
          try {
            await _prepareIosPipBridge();
            if (_disposed || !mounted) return;
            await _enterIosMpvPip(fromButton: fromButton);
          } finally {
            _pipEntering = false;
          }
          if (!_inPip) unawaited(_suspendIosPipBridge());
        case PipButtonPlan.switchThenEnter:
          _pipEntering = true;
          try {
            await _switchThenEnterPip(fromButton: fromButton);
          } finally {
            _pipEntering = false;
          }
          if (!_inPip) unawaited(_suspendIosPipBridge());
      }
      return;
    }
    _pipAttemptFromButton = fromButton;
    _pipWindowOpened = false;
    setState(() => _inPip = true);
    _locked.value = false;
    final entered = await _platform.enterPip(
      _playing,
      // Shapes the window to the film. Read at the moment of the request
      // rather than remembered, because a failover or a next-episode start
      // can have changed it since the last size event.
      videoSize: _adapter.value.videoSize,
    );
    if (_disposed || !mounted || !_inPip) return;
    if (!entered) {
      if (fromButton) {
        // The native side refused outright (no PiP support, no picture):
        // say so, instead of the button silently doing nothing.
        ref
            .read(notificationServiceProvider)
            .showInfo(
              'Picture-in-picture isn\'t available for this video right now.',
              title: 'Picture-in-picture',
            );
      }
      setState(() => _inPip = false);
      return;
    }
    // The request went out; the window opening, or failing to, is
    // reported through `pipModeChanged`. If neither arrives, the watchdog
    // takes the chrome back (see [_armPipWatchdog]).
    _armPipWatchdog();
  }

  /// Build 73: creates the native PiP controller, layer and frame tap
  /// for one window. They exist only from the button to the end of
  /// that window (see [_suspendIosPipBridge]).
  Future<void> _prepareIosPipBridge() async {
    final pip = _iosPip;
    if (pip == null || pip.isPrepared) return;
    try {
      await pip.prepare(
        position: _position,
        duration: _duration,
        playing: _playing,
      );
    } catch (e) {
      debugPrint('[mpv] PiP prepare failed: $e');
    }
  }

  /// Build 73: tears the native PiP controller down once no window is
  /// up or being opened. Phone proof on build 72: after one PiP round
  /// trip a plain Home swipe opened a PiP window by itself (automatic
  /// PiP was off; iOS brought the previous window back on its own).
  /// With no controller there is nothing for iOS to start.
  Future<void> _suspendIosPipBridge() async {
    final pip = _iosPip;
    if (pip == null || !pip.isPrepared) return;
    if (pipBridgeWanted(
      entering: _pipEntering,
      windowUp: _inPip || pip.inPip,
    )) {
      return;
    }
    await pip.suspend();
  }

  Future<void> _switchThenEnterPip({required bool fromButton}) async {
    // The tap has to be listening before the software renderer draws
    // its first frames: they prime the PiP layer.
    await _prepareIosPipBridge();
    if (_disposed || !mounted) return;
    final moved = await _switchRenderer(toSoftware: true);
    if (_disposed || !mounted) return;
    if (!moved) {
      ref
          .read(notificationServiceProvider)
          .showInfo(
            'Picture-in-picture could not start for this video.',
            title: 'Picture-in-picture',
          );
      return;
    }
    // The PiP layer is primed from a software-rendered frame: give the
    // new renderer a moment to produce one.
    // Build 74: the move now ends on a real frame (`vo-configured`),
    // so this is only the prime's own refresh (5 a second).
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (_disposed || !mounted) return;
    if (_rendererPhase != MpvRendererPhase.software) return;
    await _enterIosMpvPip(fromButton: fromButton);
    if (!_inPip) unawaited(_onPipEnded(reason: 'enter refused'));
  }

  /// Enters the iOS mpv PiP window through the native bridge.
  ///
  /// Mirrors the Android path above: the chrome comes off optimistically
  /// in the same frame the request is made, and the lock clears on the
  /// way in (a locked PiP window has no chip in it). The window opening
  /// is reported through `pipStarted` (see [_setupIosMpvPip]); a refusal
  /// arrives through `pipFailed` or, if neither arrives, the watchdog
  /// takes the chrome back.
  Future<void> _enterIosMpvPip({required bool fromButton}) async {
    final pip = _iosPip;
    if (pip == null) return;
    _pipAttemptFromButton = fromButton;
    _pipWindowOpened = false;
    setState(() => _inPip = true);
    _locked.value = false;
    final entered = await pip.enterPiP();
    if (_disposed || !mounted || !_inPip) return;
    if (!entered) {
      if (fromButton) {
        ref
            .read(notificationServiceProvider)
            .showInfo(
              'Picture-in-picture isn\'t available for this video right now.',
              title: 'Picture-in-picture',
            );
      }
      setState(() => _inPip = false);
      return;
    }
    _armPipWatchdog();
  }

  /// Creates the iOS mpv PiP bridge (+28) and wires the native callbacks.
  ///
  /// Runs in [_init] when the viewer turned the setting on. The native
  /// layer is created once, up front, so the button and auto-PiP both
  /// have a source ready; the latest frame is held as a prime in memory
  /// and pushed into the layer only when a start is attempted (+30 —
  /// the layer sits above Flutter's rendered view, so any frame in it
  /// would show as a second copy of the video inside the app, and an
  /// empty layer refuses to start at all). `isSupported` is checked
  /// first: a device without PiP leaves the bridge null and the button
  /// hidden. The trailing setState rebuilds once support is known, so
  /// the button appears on the first play rather than the next rebuild.
  Future<void> _setupIosMpvPip() async {
    if (defaultTargetPlatform != TargetPlatform.iOS || !_iosPipOnDemand) {
      return;
    }
    if (!await MpvPipIos.isSupported) return;
    final pip = MpvPipIos();
    pip.onPipStarted = () {
      if (!mounted || _disposed) return;
      // The window opened — for the button path this confirms the
      // optimistic chrome-off; for auto-PiP (native, on Home swipe)
      // this is the first the screen hears of it, so the chrome comes
      // off here.
      _pipWindowOpened = true;
      _pipWatchdog?.cancel();
      _pipWatchdog = null;
      unawaited(_enableMpvSubtitlesForPip());
      // +31's PiP quality drop is part of the renderer move now
      // (build 72, see [_switchRenderer]). The diag log, so the console
      // shows the live-feed throughput while PiP runs.
      _startPipDiagLog();
      if (!_inPip) setState(() => _inPip = true);
      _pipRestoring = false;
      _pipStartedAt = DateTime.now();
      _pipStartDrops = null;
      unawaited(_readVoDrops(_player).then((v) => _pipStartDrops = v));
      // +35 P1: cap the SW render target while the window is up (see
      // [_applyPipRenderCap]) — full 4K software render in the
      // background, under iOS CPU throttling, is what lags the PiP
      // window. No toast: the cap is not a heat event.
      unawaited(_applyPipRenderCap());
    };
    pip.onPipStopped = (restored) {
      if (!mounted || _disposed) return;
      // Build 73: iOS reports a restore (the viewer tapped the window)
      // and then a plain stop for the same window. The first report
      // decides; the film's state is read before anything can pause
      // it.
      final firstReport = _pipStartedAt != null;
      if (firstReport) {
        _pipEndWasPlaying = _playing;
        unawaited(_notePipWindowStats(_player, _pipStartedAt!));
        _pipStartedAt = null;
        // Build 74: the feed's counters, read before the bridge is
        // suspended (that resets them).
        unawaited(
          pip.diag.then((diag) {
            if (_disposed) return;
            _pipFeedLine = pipFeedLine(diag);
          }),
        );
      }
      if (restored) {
        _pipRestoring = true;
        // Bounded: a later Home swipe must pause the film as always.
        Future<void>.delayed(const Duration(seconds: 3), () {
          if (_disposed) return;
          _pipRestoring = false;
        });
      }
      // The native controller goes once the restore animation is over
      // (see [_suspendIosPipBridge]): nothing is left for iOS to
      // re-open on a later Home swipe.
      Future<void>.delayed(const Duration(milliseconds: 1200), () {
        if (_disposed) return;
        unawaited(_suspendIosPipBridge());
      });
      unawaited(_restoreMpvSubtitlesAfterPip());
      _pipDiagTimer?.cancel();
      _pipDiagTimer = null;
      // +31: back to the stream PiP started on. Build 72: the renderer
      // move back to hardware re-opens it (see [_onPipEnded]).
      // +35 P1: PiP is down — restore the render cap to the
      // governor's desired state (see [_restorePipRenderCap]): a
      // thermal lighten keeps 1080p, otherwise full size returns.
      unawaited(_restorePipRenderCap());
      _pipWatchdog?.cancel();
      _pipWatchdog = null;
      if (_inPip) setState(() => _inPip = false);
      // Build 72: the PiP end — keep the software session playing
      // (below 4K), or move back to the hardware renderer (4K). The
      // build-69/71 decoder restore no longer runs here: it re-opened
      // the source on a healthy software session.
      unawaited(
        _onPipEnded(reason: 'pipStopped', restored: restored || _pipRestoring),
      );
    };
    pip.onPipFailed = (reason) {
      if (kDebugMode) {
        debugPrint('MpvPlayerScreen: iOS PiP failed: $reason');
      }
      if (_disposed || !mounted || !_inPip || _pipWindowOpened) return;
      _pipWatchdog?.cancel();
      _pipWatchdog = null;
      if (_pipAttemptFromButton) {
        ref
            .read(notificationServiceProvider)
            .showInfo(
              'Picture-in-picture didn\'t open for this video.',
              title: 'Picture-in-picture',
            );
      }
      setState(() => _inPip = false);
      unawaited(_suspendIosPipBridge());
      unawaited(_onPipEnded(reason: 'pipFailed'));
    };
    pip.onPipSetPlaying = (playing) {
      if (_disposed || !_engineReady) return;
      unawaited(playing ? _player.play() : _player.pause());
    };
    pip.onPipSkip = (seconds) {
      if (_disposed) return;
      _seekRelative(Duration(seconds: seconds));
    };
    _iosPip = pip;
    _iosPipSupported = true;
    // Build 73: on demand the native controller is NOT created here —
    // only by the PiP button (see [_prepareIosPipBridge]), so a Home
    // swipe has nothing iOS could open by itself.
    if (!_iosPipOnDemand) {
      await pip.prepare(
        position: _position,
        duration: _duration,
        playing: _playing,
      );
    }
    if (mounted && !_disposed) setState(() {});
  }

  /// Build 73: mpv's cumulative presentation-drop counter, or null.
  Future<int?> _readVoDrops(Player player) async {
    try {
      final platform = player.platform;
      if (platform is! NativePlayer) return null;
      return int.tryParse(
        (await platform.getProperty('frame-drop-count')).toString(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Build 73: what the last PiP window cost, for the QoE overlay —
  /// its length, the frames the renderer dropped under it and the size
  /// it was rendered at. The proof the phone test reads for "is the
  /// window smooth".
  Future<void> _notePipWindowStats(Player player, DateTime startedAt) async {
    final seconds = DateTime.now().difference(startedAt).inSeconds;
    final rect = _videoController.rect.value;
    final tex = rect == null
        ? '?'
        : '${rect.width.toInt()}x${rect.height.toInt()}';
    final before = _pipStartDrops;
    final after = await _readVoDrops(player);
    final drops = before != null && after != null ? '+${after - before}' : '?';
    _pipLastLine = 'pip-last: ${seconds}s vo-drop $drops tex $tex';
  }

  /// Syncs playback state into the iOS PiP bridge: the scrubber, the
  /// play/pause state, and the auto-PiP arm (on only while playing).
  ///
  /// Called from the playing/duration listeners on every change and from
  /// the position listener on the same 200 ms throttle as the UI rebuild,
  /// so the channel sees at most ~5 syncs a second. No-op when the bridge
  /// does not exist.
  void _syncIosPipState() {
    final pip = _iosPip;
    if (pip == null || !pip.isPrepared) return;
    unawaited(
      pip.updateState(
        position: _position,
        duration: _duration,
        playing: _playing,
      ),
    );
  }

  /// Turns mpv's own subtitle rendering on for the PiP window, so the
  /// caption burns into the frame the plugin taps.
  ///
  /// Only while PiP is up: normal playback shows subtitles through the
  /// Flutter overlay, and `sub-visibility: yes` would show them twice.
  /// The previous value is remembered (see [_subVisibilityBeforePip]) so
  /// the restore is exact. Best-effort: a failure leaves the PiP window
  /// without subtitles, not without video.
  Future<void> _enableMpvSubtitlesForPip() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      _subVisibilityBeforePip ??= await platform.getProperty('sub-visibility');
      await platform.setProperty('sub-visibility', 'yes');
    } catch (_) {
      // Best-effort: PiP video still works without burned-in subtitles.
    }
  }

  /// Puts mpv's subtitle rendering back the way it was before PiP.
  Future<void> _restoreMpvSubtitlesAfterPip() async {
    final before = _subVisibilityBeforePip;
    _subVisibilityBeforePip = null;
    if (before == null) return;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('sub-visibility', before);
    } catch (_) {
      // Best-effort: the overlay is the subtitle display anyway.
    }
  }

  /// Starts the iOS mpv PiP diag log (+31): a tick every 5 s while the
  /// window is up, logging the native diag string (gate + throughput).
  /// The suffix (+32) is the stream actually playing — 'adaptive' for
  /// an HLS master with no ladder, where the quality drop is a no-op
  /// and the render stays full-res: the phone test proves whether the
  /// drop happened. debugPrint only. Cancelled on PiP stop (see the
  /// onPipStopped handler) and in dispose.
  void _startPipDiagLog() {
    _pipDiagTimer?.cancel();
    _pipDiagTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_disposed) return;
      final diag = await _iosPip?.diag;
      if (diag == null || diag.isEmpty) return;
      final quality = _streamIndex >= 0 && _streamIndex < _streams.length
          ? _streams[_streamIndex].quality
          : null;
      final qualityLabel = quality != null && quality > 0
          ? '${quality}h'
          : 'adaptive';
      if (kDebugMode) debugPrint('[pip] diag: $diag | quality=$qualityLabel');
    });
  }

  /// Arms the PiP watchdog for the attempt that just went out.
  ///
  /// The native start only says the request went out; the window opening,
  /// or failing to, is reported through `pipModeChanged`. If neither
  /// arrives, the player is left with its controls unmounted and no touch
  /// handling at all — the screen looks frozen until the app is
  /// backgrounded and foregrounded again. Five seconds is the backstop
  /// behind the native side's own three: the native gate gives up at
  /// three seconds and reports the failure itself, so this only fires
  /// when no event arrived at all.
  void _armPipWatchdog() {
    _pipWatchdog?.cancel();
    final attempt = ++_pipAttempt;
    _pipWatchdog = Timer(const Duration(seconds: 5), () {
      if (_disposed || !mounted || attempt != _pipAttempt) return;
      // The window opened after all, or the event is already on its way.
      if (_pipWindowOpened || !_inPip) return;
      if (kDebugMode) {
        debugPrint(
          'MpvPlayerScreen: PiP watchdog fired — the window never opened',
        );
      }
      final fromButton = _pipAttemptFromButton;
      _pipAttemptFromButton = false;
      if (fromButton) {
        ref
            .read(notificationServiceProvider)
            .showInfo(
              'Picture-in-picture didn\'t open for this video.',
              title: 'Picture-in-picture',
            );
      }
      if (mounted && !_disposed) setState(() => _inPip = false);
      unawaited(_onPipEnded(reason: 'watchdog'));
    });
  }

  Future<void> _init() async {
    // media_kit must be initialized before the first Player; main() already
    // does this, but the screen is usable on its own too.
    try {
      MediaKit.ensureInitialized();
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = 'mpv could not start: $e';
        });
      }
      return;
    }

    // The panel's copy of the settings, kept live from the provider.
    // Read before the VideoController: the iOS mpv PiP setting decides
    // which renderer the controller creates (see below).
    final settings =
        ref.read(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    _playerSettings = ValueNotifier<PlayerSettings>(settings);
    ref.listenManual<AsyncValue<PlayerSettings>>(playerSettingsProvider, (
      _,
      next,
    ) {
      final value = next.asData?.value;
      if (value != null && !_disposed) _playerSettings.value = value;
    });

    // iOS mpv PiP (+28): when the viewer turned it on AND the PiP mode is
    // mpv, the player runs the software renderer — GPU work is not allowed
    // while the app is backgrounded, and PiP runs while backgrounded —
    // with `hwdec: videotoolbox-copy` (hardware decode, software render)
    // so the forked media_kit_video tap can feed the PiP window. Off by
    // default: the software renderer loses the shaders, HDR looks washed
    // out, and 4K is heavy. Takes effect on the next play, like the
    // engine choice.
    //
    // The mode matters here: iOS mode means the system's own PiP, which
    // the libVLC engine already uses and the mpv engine cannot — mpv
    // renders into a Flutter texture, not an AVPlayer — so in iOS mode
    // this player stays on the hardware renderer and its PiP button stays
    // hidden (see [_pipAvailable]).
    //
    // Build 72: the setting no longer decides the renderer the player
    // OPENS with — that is always hardware now. It only makes the PiP
    // button available; the button moves the session to the software
    // renderer on demand ([_switchRenderer]). [_iosMpvPipEnabled] is
    // "the engine that exists is the software renderer".
    _iosPipOnDemand =
        defaultTargetPlatform == TargetPlatform.iOS &&
        settings.iosMpvPip &&
        settings.pipMode == PipMode.mpv;
    _iosMpvPipEnabled = false;
    _rendererPhase = MpvRendererPhase.hardware;
    // The stats overlay (+34): on while the QoE-log developer option is
    // on — see [_showMpvStatsOverlay]. Read here, at setup, so the
    // first play can arm its refresh timer.
    _showMpvStatsOverlay = ref.read(settingsRepositoryProvider).getDevQoeLog();
    final engineError = await _createEngine(software: false);
    if (engineError != null) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = engineError;
        });
      }
      return;
    }
    // The mid-playback stall watchdog: a tick every 2s that asks whether
    // the playhead has moved, and recovers the source when it has not
    // (see _onStallTick). It stands down while the screen is gone.
    _stallTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _onStallTick(),
    );
    // The thermal watch (iOS + Android, +33): a tick every [_kThermalPoll]
    // that reads the phone's heat and drops a 4K stream for 1080p when it
    // is serious or critical, restoring it when the phone cools — or, for
    // a single-file source with no ladder, lightens the render instead
    // (see [_onThermalTick]).
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android) {
      _thermalTimer = Timer.periodic(
        _kThermalPoll,
        (_) => unawaited(_onThermalTick()),
      );
    }
    // iOS mpv PiP bridge (+28): created once, up front, so the button and
    // auto-PiP both have a source ready when playback starts.
    await _setupIosMpvPip();
    await _resolveAndOpen();
  }

  /// Creates the engine — [Player], [VideoController], the adapter's
  /// attachment, the listeners and every mpv option — on the hardware
  /// or the software renderer. Used by [_init] and by every renderer
  /// move ([_switchRenderer]). Returns null on success, else the error
  /// text.
  Future<String?> _createEngine({
    required bool software,
    RenderSize? renderSize,
  }) async {
    final settings = _playerSettings.value;
    final Player player;
    try {
      player = Player(
        configuration: const PlayerConfiguration(
          // Forward AND backward demuxer cache (see kMpvBufferSize).
          bufferSize: kMpvBufferSize,
        ),
      );
    } catch (e) {
      return 'mpv could not start: $e';
    }
    final VideoController controller;
    try {
      controller = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          // VideoToolbox is Apple-only: on Android the old hardcoded
          // 'videotoolbox' made mpv fall back to software decoding, and
          // 4K HEVC in software is the stutter the viewer reported on
          // Android (iOS is smooth because VideoToolbox engages there).
          // Android uses media_kit's default 'auto-safe' (mediacodec).
          // iOS picks its decoder through [mpvIosHwdec]: the PiP
          // (software) renderer uses 'videotoolbox-copy'.
          hwdec: defaultTargetPlatform == TargetPlatform.iOS
              ? mpvIosHwdec(pipEnabled: software)
              : mpvHwdecForPlatform(defaultTargetPlatform),
          enableHardwareAcceleration: !software,
          // Build 73: a 4K film on the software (PiP) renderer is
          // drawn small from its very first frame (see
          // [softwareRenderSize]).
          width: software ? renderSize?.width : null,
          height: software ? renderSize?.height : null,
        ),
      );
    } catch (e) {
      unawaited(_disposeEngine(player));
      return 'mpv video output could not start: $e';
    }
    _player = player;
    _videoController = controller;
    _iosMpvPipEnabled = software;
    _pipRenderCapped = software && renderSize != null;
    _videoKey = GlobalKey<VideoState>();
    _lastSubtitlePadding = null;
    if (_adapterCreated) {
      _adapter.attachPlayer(player);
    } else {
      _adapter = MpvVlcController(
        player: player,
        externalSubtitles: () => _selected?.subtitles ?? const [],
        mediaTitle: () => widget.item.title,
      );
      // Build 107: every seek asks the temp download first — a
      // downloaded target reopens the local temp file, a target past
      // the frontier waits with progress.
      _adapter.onSeekRequested = _handleTempSeekRequest;
      _adapterCreated = true;
    }
    _engineReady = true;

    _listen();
    // Android-only mpv options (see mpv_android_options.dart): applied
    // after the VideoController (which owns `hwdec`) exists and before
    // the first open, so they govern every file this player loads.
    // Best-effort: a failure leaves media_kit's defaults in place and
    // the open still goes ahead. iOS gets its own options below.
    if (defaultTargetPlatform == TargetPlatform.android) {
      final platform = player.platform;
      if (platform is NativePlayer) {
        await applyMpvAndroidOptions(platform);
        // v2: the Video drawer's HDR choice and PICTURE sliders on
        // Android too. Android renders through mpv's own GPU output
        // (vo=gpu), which applies `tone-mapping` and the brightness /
        // contrast / saturation equalizers itself. The default choice
        // (Bright = `clip`) and sliders at 0 are exactly what the
        // Android options above already set, so an untouched install
        // plays as before.
        await applyVideoOutputPresetOptions(
          platform,
          settings.videoOutputPreset,
          customToneMapping: settings.videoCustomToneMapping,
          customTargetPeak: settings.videoCustomTargetPeak,
        );
        await applyPictureOptions(
          platform,
          brightness: settings.pictureBrightness,
          contrast: settings.pictureContrast,
          saturation: settings.pictureSaturation,
        );
      }
    }
    // iOS-only mpv options (see mpv_ios_options.dart): the VideoToolbox
    // fallback Nuvio sets, so a session invalidated under heat is
    // recreated instead of dropping to software decode for the rest of
    // the file, plus the same framedrop policy Android has.
    // Best-effort like the Android options above.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final iosPlatform = player.platform;
      if (iosPlatform is NativePlayer) {
        await applyMpvIosOptions(iosPlatform);
        // The stored Video output preset (+57), applied after the base
        // options.
        await applyVideoOutputPresetOptions(
          iosPlatform,
          settings.videoOutputPreset,
          customToneMapping: settings.videoCustomToneMapping,
          customTargetPeak: settings.videoCustomTargetPeak,
        );
        // The PICTURE sliders (v9), re-applied on every open.
        await applyPictureOptions(
          iosPlatform,
          brightness: settings.pictureBrightness,
          contrast: settings.pictureContrast,
          saturation: settings.pictureSaturation,
        );
        if (software && renderSize != null) {
          await _applyFastSoftwareScaler(iosPlatform);
        }
      }
    }
    // Subtitle options for every platform (+26): the secondary track
    // is off, always (see applyMpvSubtitleOptions). Best-effort.
    final subtitlePlatform = player.platform;
    if (subtitlePlatform is NativePlayer) {
      await applyMpvSubtitleOptions(subtitlePlatform);
    }
    return null;
  }

  /// Stops and disposes an engine. Never throws: an engine that is
  /// already gone is fine.
  /// Build 73: the cheap scaler for a 4K film drawn small by the
  /// software renderer — the picture is a PiP window, and the scaler
  /// is the larger part of the per-frame cost. Best-effort.
  Future<void> _applyFastSoftwareScaler(NativePlayer platform) async {
    for (final entry in const <String, String>{
      'sws-fast': 'yes',
      'sws-scaler': 'fast-bilinear',
    }.entries) {
      try {
        await platform.setProperty(entry.key, entry.value);
      } catch (_) {}
    }
  }

  /// Build 73: sizes the software renderer for the film that is
  /// actually decoding (see [softwareRenderSize]): a 4K picture is
  /// drawn small for the whole time it is on the software renderer,
  /// anything below 4K at its own size. On demand only — a session
  /// that lives on the software renderer is watched full screen.
  Future<void> _applySoftwareRenderSize() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    if (!_iosPipOnDemand || !_engineReady || !_iosMpvPipEnabled) return;
    final params = _player.state.videoParams;
    final width = params.dw ?? params.w;
    final height = params.dh ?? params.h;
    final size = softwareRenderSize(
      videoWidth: width,
      videoHeight: height,
      is4K: is4KVideo(width: width, height: height),
    );
    if (size == null) {
      if (!_pipRenderCapped) return;
      if (width == null || height == null) return;
      // The film turned out to be below 4K: back to its own size.
      _pipRenderCapped = false;
      await _setIosRenderCap(_thermalGovernor.isLightened);
      return;
    }
    final controller = _videoController;
    if (await _setIosRenderCap(true, width: size.width, height: size.height)) {
      if (identical(controller, _videoController)) _pipRenderCapped = true;
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await _applyFastSoftwareScaler(platform);
      }
    }
  }

  Future<void> _disposeEngine(Player player) async {
    try {
      await player.stop();
    } catch (_) {}
    try {
      await player.dispose();
    } catch (_) {}
  }

  /// One mpv property as text, or null when it cannot be read.
  Future<String?> _readMpvProperty(Player player, String name) async {
    try {
      final platform = player.platform;
      if (platform is! NativePlayer) return null;
      return (await platform.getProperty(name)).toString();
    } catch (_) {
      return null;
    }
  }

  /// Build 74: why a move has no picture yet (see [switchWaitReason]).
  Future<String> _switchWaitReason(Player player) async => switchWaitReason(
    voConfiguredRaw: await _readMpvProperty(player, 'vo-configured'),
    cacheSeconds: await _readMpvProperty(player, 'demuxer-cache-duration'),
    pausedForCache: await _readMpvProperty(player, 'paused-for-cache'),
    cacheSpeed: await _readMpvProperty(player, 'cache-speed'),
  );

  /// Build 74: moves the session to the other renderer on the SAME
  /// engine — no second player, no re-open, the connection and the
  /// buffer position stay.
  ///
  /// The fork's native side frees the current mpv render context and
  /// creates the other renderer's on the same core; mpv answers the
  /// free by shutting its video chain down (audio and the demuxer keep
  /// running). `hwdec` is then set for the new renderer (the software
  /// one needs the copy flavour) and the video track is switched back
  /// on, which mpv brings up on the new context with one seek in the
  /// stream it already has open. The video widget keeps the outgoing
  /// picture on the same texture until the new renderer has drawn, so
  /// there is no black and nothing to cover it with.
  ///
  /// Returns true/false when the move was carried out here (false: it
  /// was abandoned — the screen went away), and null when it could not
  /// be done in place or brought no picture: the caller then runs the
  /// re-open move.
  Future<bool?> _switchRendererInPlace({
    required bool toSoftware,
    required bool? playing,
    required int token,
  }) async {
    final player = _player;
    final controller = _videoController;
    final platform = player.platform;
    if (platform is! NativePlayer) return null;
    bool live() =>
        !_disposed &&
        mounted &&
        token == _switchToken &&
        identical(player, _player);
    final clock = Stopwatch()..start();
    final steps = <String, int>{};
    var lapStart = 0;
    void lap(String name) {
      final now = clock.elapsedMilliseconds;
      steps[name] = now - lapStart;
      lapStart = now;
    }

    final direction = toSoftware ? '>sw' : '>hw';
    void finish(String outcome) {
      _switchDirection = direction;
      _switchSteps = steps;
      _switchOutcome = outcome;
    }

    final before = _rendererPhase;
    final wasPlaying = playing ?? _playing;
    // A PiP window opens on a playing film; the way back does what the
    // film was doing in the window.
    final resume = toSoftware || wasPlaying;
    final params = player.state.videoParams;
    final width = params.dw ?? params.w;
    final height = params.dh ?? params.h;
    final size = toSoftware
        ? softwareRenderSize(
            videoWidth: width,
            videoHeight: height,
            is4K: is4KVideo(width: width, height: height),
          )
        : null;
    // Read BEFORE the swap: once the render context is freed mpv
    // reports `no`.
    final vid = inPlaceVideoTrack(await _readMpvProperty(player, 'vid'));
    final cacheBefore = await _readMpvProperty(
      player,
      'demuxer-cache-duration',
    );
    // Build 76: where the film is, for the keyframe landing below.
    var placeBefore =
        mpvTimePos(await _readMpvProperty(player, 'time-pos')) ??
        (_position > Duration.zero ? _position : null);
    // Build 79: what the player has read ahead of the playhead, and
    // what the proxy holds behind the reading point — read BEFORE the
    // swap (the track switch empties the player's buffer). They decide
    // whether the film can land exactly where it was.
    final demuxAtHold = parseDemuxState(
      await _readMpvProperty(player, 'demuxer-cache-state'),
      ms: 0,
    );
    final holdProxy = _proxyHandle;
    StreamCacheStats? holdStats;
    if (holdProxy != null) {
      try {
        holdStats = await StreamCacheService.instance
            .stats(holdProxy.token)
            .timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
    final exactPossible = exactLandingForMove(
      proxyServing: holdStats != null && !holdStats.dead,
      behind: holdStats == null ? null : holdStats.held - holdStats.ahead,
      forwardBytes: demuxAtHold?.forwardBytes,
    );
    if (!live()) return false;
    debugPrint(
      '[mpv] renderer move (in place) → '
      '${toSoftware ? 'software' : 'hardware'} at $_position '
      '(vid $vid, size $size)',
    );
    _adapter.holdTimeline(
      position: _position,
      duration: _duration,
      playing: resume,
    );
    setState(() {
      _inPlaceMove = true;
      _rendererPhase = toSoftware
          ? MpvRendererPhase.toSoftware
          : MpvRendererPhase.toHardware;
    });
    // Everything that watched the decoder stands down for the move.
    _hwdecWatchToken++;
    _hwdecWatchPending = false;
    _hwdecSeenAlive = false;
    _resumeStallTimer?.cancel();
    _resumeStallTimer = null;
    _prevMpvDrops.clear();
    lap('hold');
    // Build 75: the film stands still for the move. Switching the
    // video track back on makes mpv seek the source to just before the
    // playhead and decode up to it; on a playing film that playhead
    // keeps moving while the data arrives — the long, uneven waits of
    // build 74. Held here, the picture has a fixed point to reach, and
    // playback starts again as soon as it is there.
    final held = pauseForInPlaceMove(playing: player.state.playing);
    if (held) {
      try {
        await player.pause().timeout(const Duration(seconds: 2));
      } catch (e) {
        debugPrint('[mpv] renderer swap: pause failed: $e');
      }
      if (!live()) return false;
      // Build 79: where the film actually stopped (it ran on for a
      // moment after the first reading).
      placeBefore =
          mpvTimePos(await _readMpvProperty(player, 'time-pos')) ?? placeBefore;
      if (!live()) return false;
    }
    lap('pause');
    void unhold() {
      if (held && resume) {
        unawaited(player.play().catchError((Object _) {}));
      }
    }

    void stand(MpvRendererPhase phase) {
      _adapter.releaseTimeline();
      setState(() {
        _inPlaceMove = false;
        _rendererPhase = phase;
      });
    }

    var swapped = false;
    try {
      swapped = await controller
          .setRenderer(
            hardware: !toSoftware,
            width: size?.width,
            height: size?.height,
          )
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[mpv] renderer swap failed: $e');
    }
    lap('swap');
    if (!live()) return false;
    if (!swapped) {
      // Nothing changed (an old native side, or no video output yet).
      finish('n/a');
      unhold();
      stand(before);
      return null;
    }
    // Build 76: the reader's state before the video track comes back —
    // what the wait is measured against (see [splitSwitchWaitByDemux]).
    final demuxBefore = parseDemuxState(
      await _readMpvProperty(player, 'demuxer-cache-state'),
      ms: 0,
    );
    _iosMpvPipEnabled = toSoftware;
    _pipRenderCapped = toSoftware && size != null;
    try {
      // Build 99 (diagnostic): a renderer swap during an HLS-proxy
      // playback keeps `hwdec=no` — the swap's usual restore to
      // VideoToolbox would silently undo the diagnostic. Software
      // decode already produces system-memory frames, so the software
      // renderer reads them either way.
      await platform.setProperty(
        'hwdec',
        _hlsProxyHwdecNo ? 'no' : mpvIosHwdec(pipEnabled: toSoftware),
      );
      if (toSoftware && size != null) {
        await _applyFastSoftwareScaler(platform);
      }
      await platform.setProperty('vid', vid);
    } catch (e) {
      debugPrint('[mpv] renderer swap: video track not restored: $e');
    }
    // Build 76: the picture comes back on the keyframe at or before
    // the playhead (see [keyframeSeekCommand]) instead of mpv decoding
    // and discarding its way up to the playhead. Sent right behind the
    // track switch so it takes the place of mpv's own refresh seek.
    // The film continues from that keyframe — a little before where it
    // was, never after. When it cannot be sent the move goes on as in
    // build 75.
    //
    // Build 79: when the phone itself still holds the film around the
    // playhead (the stream cache proxy), the landing is exact instead:
    // the film continues on the frame it stopped on (see
    // [exactSeekCommand]). Off the proxy the keyframe landing stays —
    // it is what keeps the host's answer short.
    var keyLanding = false;
    var exactLanding = false;
    if (keyframeLandingForMove(seekable: _canSeek, position: placeBefore)) {
      try {
        await platform
            .command(
              exactPossible
                  ? exactSeekCommand(placeBefore!)
                  : keyframeSeekCommand(placeBefore!),
            )
            .timeout(const Duration(seconds: 2));
        if (exactPossible) {
          exactLanding = true;
        } else {
          keyLanding = true;
        }
      } catch (e) {
        debugPrint('[mpv] renderer swap: landing not sent: $e');
      }
    }
    lap('vid');
    final after = toSoftware
        ? MpvRendererPhase.software
        : MpvRendererPhase.hardware;
    var gotPicture = false;
    // Build 76: the reader's state, sampled while waiting — the seek
    // count going up and the buffer filling again split the wait into
    // "the host answering" and "reading and decoding". (Build 75
    // sampled `stream-pos`, which never moves back: all "?".)
    final waitStart = clock.elapsedMilliseconds;
    // Build 77: wall-clock start of the whole move, to pick the
    // proxy's requests that belong to it (2 s of slack for the steps
    // before this point).
    final moveWallStart =
        DateTime.now().millisecondsSinceEpoch - waitStart - 2000;
    final samples = <DemuxSample>[];
    Future<void> sample() async {
      final reading = parseDemuxState(
        await _readMpvProperty(player, 'demuxer-cache-state'),
        ms: clock.elapsedMilliseconds - waitStart,
      );
      if (reading != null) samples.add(reading);
    }

    while (live() && clock.elapsedMilliseconds < 15000) {
      if (voConfigured(await _readMpvProperty(player, 'vo-configured'))) {
        gotPicture = true;
        break;
      }
      await sample();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!live()) return false;
    final frameMs = clock.elapsedMilliseconds - waitStart;
    await sample();
    final cacheAfter = await _readMpvProperty(player, 'demuxer-cache-duration');
    final placeAfter = mpvTimePos(await _readMpvProperty(player, 'time-pos'));
    // Build 77: where the request(s) of this move were answered from.
    final proxyHandle = _proxyHandle;
    final proxyStats = proxyHandle == null
        ? null
        : await StreamCacheService.instance.stats(proxyHandle.token);
    if (!live()) return false;
    _switchDetail = switchWaitLine(
      wait: splitSwitchWaitByDemux(
        before: demuxBefore,
        samples: samples,
        frameMs: frameMs,
      ),
      cacheBefore: cacheBefore,
      cacheAfter: cacheAfter,
      paused: held,
      extra:
          (exactLanding
              ? exactLandingNote(before: placeBefore, after: placeAfter)
              : keyframeLandingNote(
                  used: keyLanding,
                  before: placeBefore,
                  after: placeAfter,
                )) +
          (samples.isEmpty ? ' no-state' : '') +
          switchSourceNote(stats: proxyStats, sinceMs: moveWallStart),
    );
    if (!gotPicture) {
      lap('frame');
      finish('no-frame(${await _switchWaitReason(player)})');
      if (!live()) return false;
      stand(after);
      return null;
    }
    lap('frame');
    // Playing again at once: the held picture leaves on the third
    // frame the new renderer draws (native side), and those only come
    // from a running film.
    if (resume && !player.state.playing) {
      unawaited(player.play().catchError((Object _) {}));
    }
    // A beat for those frames to reach the screen.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    lap('show');
    if (!live()) return false;
    if (player.state.position > Duration.zero) {
      _position = player.state.position;
    }
    finish('ok');
    stand(after);
    // The swap handed the hardware renderer the film's own size; a
    // thermal lighten that was in force is put back.
    if (!toSoftware && _thermalGovernor.isLightened) {
      unawaited(_setIosRenderCap(true));
    }
    _syncIosPipState();
    _publishAdapter();
    debugPrint(
      '[mpv] renderer move done (in place): $_rendererPhase '
      '${switchTimingLine(direction: direction, steps: steps, outcome: _switchOutcome)}',
    );
    return true;
  }

  /// Moves the session to the other renderer (build 72): a new engine
  /// and a re-open of the same source at the same position — libmpv
  /// allows one render context per core and the fork's VideoOutput
  /// picks its texture once, so there is no in-place switch.
  ///
  /// While it runs the viewer sees the last picture of the old engine
  /// (or the backdrop when the capture failed) with the buffering
  /// spinner, and the seek bar keeps the real position and length
  /// ([MpvVlcController.holdTimeline]) — never black, never 00:00/LIVE.
  /// The tracker and the Continue Watching recorder are kept, so no
  /// scrobble or history point is fired twice. Returns whether the
  /// session ended on the renderer asked for; a failed move to software
  /// comes back on hardware.
  Future<bool> _switchRenderer({
    required bool toSoftware,
    bool? playing,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;
    if (_disposed || !mounted || !_engineReady) return false;
    if (rendererSwitching(_rendererPhase)) return false;
    if (_streamIndex < 0 || _streamIndex >= _streams.length) return false;
    final token = ++_switchToken;
    // Build 73: every step is timed for the QoE overlay.
    final clock = Stopwatch()..start();
    final steps = <String, int>{};
    var lapStart = 0;
    void lap(String name) {
      final now = clock.elapsedMilliseconds;
      steps[name] = now - lapStart;
      lapStart = now;
    }

    final direction = toSoftware ? '>sw' : '>hw';
    bool live() => !_disposed && mounted && token == _switchToken;
    _pendingSwitchToHardware = false;
    // The PiP quality drop (+31), folded into the move so it costs no
    // second re-open: to software opens the light stream, to hardware
    // opens the one PiP started on.
    var targetIndex = _streamIndex;
    // Only a 4K picture is dropped: below 4K the software renderer
    // carries the stream as it is, and keeping it is what lets the
    // return from PiP continue with no re-open at all.
    // Build 74: the same engine, the other renderer — nothing is
    // opened. Only when that cannot be done (or brings no picture)
    // does the re-open move below run.
    // Build 75: read before the in-place move, which pauses the film
    // for its length — the re-open fallback must not take that pause
    // for what the film was doing.
    final playingAtStart = playing ?? _playing;
    if (rendererMoveRoute(qualityDropped: _pipDroppedFrom != null) ==
        RendererMoveRoute.inPlace) {
      final moved = await _switchRendererInPlace(
        toSoftware: toSoftware,
        playing: playingAtStart,
        token: token,
      );
      if (moved != null) return moved;
      if (_disposed || !mounted || !_engineReady) return false;
      if (token != _switchToken) return false;
    }
    final is4KNow = toSoftware && await _isCurrentVideo4K();
    if (_disposed || !mounted || !_engineReady) return false;
    if (rendererSwitching(_rendererPhase)) return false;
    if (toSoftware && is4KNow) {
      final drop = pipQualityDropTarget(
        qualities: _streams.map((stream) => stream.quality).toList(),
        currentIndex: _streamIndex,
      );
      if (drop != null && _pipDroppedFrom == null) {
        _pipDroppedFrom = _streamIndex;
        targetIndex = drop;
      }
    } else {
      final from = _pipDroppedFrom;
      _pipDroppedFrom = null;
      if (from != null && from >= 0 && from < _streams.length) {
        targetIndex = from;
      }
    }
    final old = _player;
    final oldController = _videoController;
    final wasPlaying = playingAtStart;
    final carry = RendererCarryOver(
      position: _position,
      duration: _duration,
      wasPlaying: wasPlaying,
      rate: old.state.rate,
      volume: old.state.volume,
      streamIndex: targetIndex,
    );
    var software = toSoftware;
    final autoPlay = carry.autoPlay(toSoftware: software);
    // The size the software renderer draws at, known up front when the
    // same stream is re-opened (a quality drop opens another file; its
    // size is applied when its parameters arrive, see [_listen]).
    final oldParams = old.state.videoParams;
    final oldWidth = oldParams.dw ?? oldParams.w;
    final oldHeight = oldParams.dh ?? oldParams.h;
    final renderSize = targetIndex == _streamIndex
        ? softwareRenderSize(
            videoWidth: oldWidth,
            videoHeight: oldHeight,
            is4K: is4KVideo(width: oldWidth, height: oldHeight),
          )
        : null;
    debugPrint(
      '[mpv] renderer move → ${toSoftware ? 'software' : 'hardware'} '
      'at ${carry.position} (stream $targetIndex, size $renderSize)',
    );
    // Build 73: nothing below waits on the old engine. Build 72 awaited
    // its pause, a full-size JPEG screenshot (3 s timeout) and its
    // dispose (4 s timeout) one after the other before the new engine
    // was even created — on a software engine saturated by 4K those
    // are the frozen seconds of the phone recording. The old engine is
    // told to pause and then left alone: its own texture is the held
    // picture, and it is disposed after the swap.
    _adapter.holdTimeline(
      position: carry.position,
      duration: carry.duration,
      playing: autoPlay,
    );
    setState(() {
      _outgoingController = oldController;
      _outgoingKey = GlobalKey<VideoState>();
      _rendererPhase = toSoftware
          ? MpvRendererPhase.toSoftware
          : MpvRendererPhase.toHardware;
      _engineReady = false;
    });
    unawaited(old.pause().catchError((Object _) {}));
    // Everything that watched the old engine stands down.
    _hwdecWatchToken++;
    _hwdecWatchPending = false;
    _hwdecSeenAlive = false;
    _prebufferToken++;
    _awaitingPrebuffer = false;
    _prebufferTimer?.cancel();
    _watchdogTimer?.cancel();
    _resumeStallTimer?.cancel();
    _resumeStallTimer = null;
    _subVisibilityBeforePip = null;
    _pipRenderCapped = false;
    _prevMpvDrops.clear();
    // The old engine's buffer mark would read as a full pre-buffer.
    _buffered = Duration.zero;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    lap('hold');

    var outgoingReleased = false;
    void releaseOutgoing() {
      _outgoingController = null;
      if (outgoingReleased) return;
      outgoingReleased = true;
      // Paused since the first line of the move: the stop and the
      // dispose run behind the new picture, not in front of it.
      unawaited(_disposeEngine(old));
    }

    void finish(String outcome) {
      _switchDirection = direction;
      _switchSteps = steps;
      _switchOutcome = outcome;
    }

    if (!live()) {
      releaseOutgoing();
      return false;
    }
    var error = await _createEngine(
      software: software,
      renderSize: software ? renderSize : null,
    );
    if (error != null && software) {
      // Could not get the software renderer: come back on hardware.
      software = false;
      error = await _createEngine(software: false);
    }
    lap('new');
    if (!live()) {
      releaseOutgoing();
      return false;
    }
    if (error != null) {
      _adapter.releaseTimeline();
      setState(() {
        releaseOutgoing();
        _rendererPhase = MpvRendererPhase.hardware;
        _stage = _Stage.failed;
        _error = error;
      });
      finish('failed');
      return false;
    }
    final rate = carry.rateToApply;
    try {
      if (rate != null) await _player.setRate(rate);
      await _player.setVolume(carry.volume);
    } catch (_) {}
    // The position the screen keeps is the held one until the new
    // engine reports its own (see the position listener).
    _position = carry.position;
    _duration = carry.duration;
    final play = carry.autoPlay(toSoftware: software);
    setState(() {});
    // Build 73: no pre-buffer hold on a move — the film starts on its
    // first frame; the stall logic covers a slow source from there.
    await _openStream(
      carry.streamIndex,
      start: carry.start,
      autoPlay: play,
      keepSession: true,
      skipPrebuffer: true,
    );
    lap('open');
    if (!live()) {
      releaseOutgoing();
      return false;
    }
    // Hold the old picture until the new engine has one of its own.
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    // Build 74: "has a picture" is mpv's own word for it
    // (`vo-configured`), not the texture's size — the software texture
    // is pre-sized, so on build 73 this was true 154 ms in, before a
    // single frame existed, and PiP opened on an empty layer.
    final waitStart = clock.elapsedMilliseconds;
    var gotPicture = false;
    while (live() && DateTime.now().isBefore(deadline)) {
      if (_stage == _Stage.failed) break;
      final hasPicture = voConfigured(
        await _readMpvProperty(_player, 'vo-configured'),
      );
      if (!live()) break;
      if (hasPicture && (_startedPlaying || !play)) {
        gotPicture = true;
        break;
      }
      // Build 74: the phone showed the new engine with no data at all
      // (`cache: 0.000000s 1 KiB/s`) for as long as the old one was
      // kept. If that is the old engine's connection in the way, this
      // ends it; the overlay's `old-off` step says whether a picture
      // followed.
      if (!outgoingReleased && clock.elapsedMilliseconds - waitStart > 6000) {
        steps['old-off'] = clock.elapsedMilliseconds - lapStart;
        lapStart = clock.elapsedMilliseconds;
        setState(releaseOutgoing);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final waitReason = gotPicture || !live()
        ? ''
        : await _switchWaitReason(_player);
    if (!live()) {
      releaseOutgoing();
      return false;
    }
    if (!play) {
      // Held paused: the startup watchdog must not call a paused film
      // a dead source.
      _watchdogTimer?.cancel();
    }
    // A beat for the first texture frame to reach the screen before
    // the held picture goes.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    lap('frame');
    if (!live()) {
      releaseOutgoing();
      return false;
    }
    _position = _player.state.position > Duration.zero
        ? _player.state.position
        : carry.position;
    if (_player.state.duration > Duration.zero) {
      _duration = _player.state.duration;
    }
    _adapter.releaseTimeline();
    setState(() {
      releaseOutgoing();
      _rendererPhase = rendererPhaseAfterSwitch(
        toSoftware: toSoftware,
        succeeded: software == toSoftware,
      );
    });
    finish(gotPicture ? 'ok' : 'no-frame($waitReason)');
    _syncIosPipState();
    debugPrint(
      '[mpv] renderer move done: $_rendererPhase '
      '${switchTimingLine(direction: direction, steps: steps, outcome: _switchOutcome)}',
    );
    return software == toSoftware;
  }

  Future<void> _onPipEnded({
    required String reason,
    bool restored = false,
  }) async {
    if (!_iosPipOnDemand || _disposed || !mounted) return;
    if (_rendererPhase != MpvRendererPhase.software) return;
    if (_inPip || (_iosPip?.inPip ?? false)) return;
    final cameBack = restored || _pipRestoring;
    final is4K = _engineReady && await _isCurrentVideo4K();
    if (_disposed || !mounted) return;
    if (_rendererPhase != MpvRendererPhase.software) return;
    if (_inPip || (_iosPip?.inPip ?? false)) return;
    // Build 73: `inactive` on the way back in is already the
    // foreground (GPU work is allowed again); build 72 waited for
    // `resumed`, a frame, and then a 1.5 s backstop.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final foreground =
        lifecycle == AppLifecycleState.resumed ||
        lifecycle == AppLifecycleState.inactive;
    final plan = pipEndPlan(
      phase: _rendererPhase,
      pipWindowUp: false,
      appResumed: foreground,
      needsHardware:
          _pendingSwitchToHardware ||
          pipEndNeedsHardware(
            is4K: is4K,
            qualityDropped: _pipDroppedFrom != null,
          ),
    );
    debugPrint('[mpv] PiP ended ($reason): $plan');
    final pauses = pipEndPauses(restored: cameBack, appForeground: foreground);
    switch (plan) {
      case PipEndPlan.none:
        return;
      case PipEndPlan.stayOnSoftware:
        // The window was closed while the app is still in the
        // background: nothing is showing the film, so it pauses.
        if (pauses && _engineReady) {
          _pipEndWasPlaying = false;
          unawaited(_player.pause());
        }
        return;
      case PipEndPlan.pauseAndDefer:
        _pendingSwitchToHardware = true;
        if (pauses && _engineReady) {
          _pipEndWasPlaying = false;
          unawaited(_player.pause());
        }
        return;
      case PipEndPlan.switchNow:
        // The film does on hardware what it was doing in the window.
        await _switchRenderer(
          toSoftware: false,
          playing: _pipEndWasPlaying || _playing,
        );
    }
  }

  void _listen() {
    // v9: a decoded size is a (new) video — ask whether it is HDR, for
    // the Video panel.
    _subs.add(
      _player.stream.width.listen((_) {
        if (_disposed) return;
        unawaited(_refreshVideoIsHdr());
      }),
    );
    _subs.add(
      _player.stream.playing.listen((playing) {
        if (_disposed) return;
        _playing = playing;
        // Build 71: the hardware-decode watch armed by the last return
        // from the background starts here, when the viewer presses
        // play (see [_onIosReturnHwdec]).
        if (playing && _hwdecWatchPending) {
          _hwdecWatchPending = false;
          unawaited(_runHwdecResumeWatch());
        }
        if (playing && _videoIsHdr.value == null) {
          unawaited(_refreshVideoIsHdr());
        }
        // Sleep timer (v7): see [_onSleepPlayingChanged].
        if (playing) _onSleepPlayingChanged();
        // Keeps the native side's picture-in-picture state current at all
        // times, not only while a window is open: MainActivity enters PiP
        // itself from onUserLeaveHint when the viewer swipes home, and it
        // can only do that if it knows the film is playing. One channel
        // call per play/pause flip is the price; the play/pause icon in
        // the window rides on the same sync.
        _platform.syncPipState(playing, videoSize: _adapter.value.videoSize);
        // iOS mpv PiP (+28): the same sync for the native bridge — the
        // scrubber, the play/pause state, and the auto-PiP arm, which is
        // on only while playing.
        _syncIosPipState();
        if (playing) {
          final firstPlay = !_startedPlaying;
          _startedPlaying = true;
          // Build 70: the decoder baseline, read once frames are
          // flowing (see [_hwdecSeenAlive]). Build 71: after every
          // play, not only the first — the baseline must come from
          // normal playback whether or not the overlay is on.
          Future<void>.delayed(const Duration(seconds: 3), () {
            if (!_disposed && mounted && _playing) {
              unawaited(_noteHwdecBaseline());
            }
          });
          // v7: this source plays, so it is the one remembered for this
          // title (see [streamSourceKey]) — the next episode starts on it
          // and the Sources list tags it "Last used".
          if (firstPlay &&
              _streamIndex >= 0 &&
              _streamIndex < _streams.length) {
            _rememberSource(_streams[_streamIndex]);
          }
          _watchdogTimer?.cancel();
          if (firstPlay) {
            // Build 107: the film is playing — a no-range source earns
            // its temp download from here (or from the duration event,
            // whichever lands first; the trigger runs once per source).
            unawaited(_maybeStartTempDownload());
            // First frame of playback: the video itself has started, so
            // now — and only now — rotate to landscape on a portrait
            // handset. The source list shown before this stays portrait.
            _forceLandscapeIfPortrait();
            // And the source list's job is done: the video is up.
            if (_stage == _Stage.resolving) {
              _stage = _Stage.playing;
            }
            // mpv has settled its pick by now, so re-read the aid the
            // drawer shows — the tracks-event read can land while mpv is
            // still on 'auto' — and give the audio auto-select a second
            // chance in case the first tracks event arrived before the
            // list was populated. Both are guarded (the read-back is
            // best-effort, the auto-select is deduped per open), and
            // neither touches a pick the viewer made.
            unawaited(_adapter.refreshRealAudioAid());
            unawaited(_applyAudioAutoSelect());
            // One-time decode diagnostic: what decoder is actually
            // engaged (see mpv_android_options.dart). Android should
            // print mediacodec; empty/no means software decode.
            unawaited(logMpvDecodeInfo(_player));
            // The mpv stats baseline (+34): the measurements that tell
            // the 4K layers apart — decoder, render target, drop
            // counters, cache. And, while the governor is lightened,
            // the render cap the fork re-requested full-size on this
            // open's video-parameter change (see [_setIosRenderCap]):
            // re-apply it now that the new stream's parameters are
            // known (first frame is playing).
            unawaited(_logMpvPlaybackStats('BASELINE'));
            // +35 P1 (+47 540p): the fork re-requests full size on a
            // video-parameter change, so a source change while PiP is
            // up would silently drop the PiP cap — re-apply it here
            // too. The PiP cap is 960x540, the thermal cap 1080p, so
            // the two are re-applied at their own sizes.
            if (_iosPipOnDemand && _iosMpvPipEnabled) {
              // Build 73: sized from the film that is decoding.
              unawaited(_applySoftwareRenderSize());
            } else if (_pipRenderCapped) {
              unawaited(_setIosRenderCap(true, width: 960, height: 540));
            } else if (_thermalGovernor.isLightened) {
              unawaited(_setIosRenderCap(true));
            }
            // The stats overlay (+34): the same values, live on screen
            // while the QoE-log developer option is on — the only
            // diagnostics surface that works on a release build (the
            // app-log viewer is debug-only).
            if (_showMpvStatsOverlay) _armMpvStatsTimer();
          }
        } else {
          _tracker?.onPaused();
          // Pausing is the viewer's own save point, so flush past the
          // rate limit. A stall that auto-pauses the engine flushes the
          // same way — the position is real either way.
          _flushProgress();
        }
        _publishAdapter();
        _chrome.poke();
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.position.listen((position) {
        if (_disposed) return;
        // Build 72: during a renderer move the new engine reads 00:00
        // until its open lands; the held position stands until then.
        if (rendererSwitching(_rendererPhase)) return;
        _position = position;
        // Feed the tracker and the Continue Watching recorder from the
        // same sample: only samples taken while playing count toward
        // history / watched, and the token ties them to this session.
        if (_playing && _duration > Duration.zero) {
          final sample = ProgressSample(
            position: position,
            duration: _duration,
            token: _sessionToken,
          );
          _tracker?.onPlaying(sample);
          if (sample.isWritable) {
            _sample = sample;
            _recorder?.record(sample, lastStreamUrl: _selected?.url);
          }
        }
        // A livestream has no position to store, but Continue Watching
        // still needs the row.
        if (!_recordedLivestream &&
            widget.item.contentType == MultimediaContentType.livestream) {
          _recordedLivestream = true;
          _recorder?.recordLivestream();
        }
        _maybeOfferAtOutro(position);
        _publishAdapter();
        // Throttle UI rebuilds: the bar only needs ~5 updates a second.
        final now = DateTime.now();
        if (now.difference(_lastPositionUi) >=
            const Duration(milliseconds: 200)) {
          _lastPositionUi = now;
          // iOS mpv PiP (+28): same throttle for the bridge sync, so the
          // native scrubber follows the playhead without a channel call
          // on every position tick.
          _syncIosPipState();
          setState(() {});
        }
      }),
    );
    // Build 73: the software renderer is sized the moment the film's
    // real size is known — before its first frame where possible.
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        _iosPipOnDemand &&
        _iosMpvPipEnabled) {
      _subs.add(
        _player.stream.videoParams.listen((_) {
          if (_disposed) return;
          unawaited(_applySoftwareRenderSize());
        }),
      );
    }
    _subs.add(
      _player.stream.duration.listen((duration) {
        if (_disposed) return;
        if (rendererSwitching(_rendererPhase) && duration <= Duration.zero) {
          return;
        }
        _duration = duration;
        // Build 107: the duration just became known — the temp
        // download's seek maths needs it, so a no-range source earns
        // its download from here (or from first play, whichever lands
        // first — the trigger is guarded to run once per source).
        unawaited(_maybeStartTempDownload());
        // The episode length just became known: for anime, that is
        // what the AniSkip lookup was waiting on (see [_maybeLoadAniSkip]).
        _maybeLoadAniSkip();
        _syncIosPipState();
        _publishAdapter();
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.buffer.listen((buffered) {
        if (_disposed) return;
        _buffered = buffered;
        _bufferedFraction.value = _canSeek
            ? seekBandFraction(
                bufferedEnd: _buffered,
                position: _position,
                duration: _duration,
              )
            : 0.0;
        // The pre-buffer target is met: start the held stream.
        if (_awaitingPrebuffer && _prebufferReady) {
          _startAfterPrebuffer();
        }
        _publishAdapter();
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.buffering.listen((buffering) {
        if (_disposed) return;
        // Build 107: the temp download must never starve playback —
        // while mpv is buffering it trickles at 64 KiB/s, while it
        // plays it may take up to 1 MiB/s.
        _tempDownload?.setRateCap(buffering ? 64 * 1024 : 1024 * 1024);
        if (_proxyWatching &&
            _proxySlowWatch.onBuffering(
              buffering: buffering,
              position: _position,
              nowMs: DateTime.now().millisecondsSinceEpoch,
            )) {
          _leaveSlowProxy();
        }
        _publishAdapter();
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.completed.listen((completed) {
        if (_disposed) return;
        if (completed) {
          // Build 106: a finish far short of the known duration is a
          // failure wearing an ending's clothes (a no-range origin
          // stream that died mid-film — the phone: 00:11 of 1:07:30,
          // data still flowing). Never show "finished" for it, and
          // never mark the episode finished — recover instead (the
          // VLC screen does the same with [isFalseEnd]).
          if (!_isLive &&
              _duration > Duration.zero &&
              isFalseEnd(position: _position, duration: _duration)) {
            _onFalseEnd();
          } else {
            _flushProgress();
            try {
              _tracker?.finish();
            } catch (_) {}
            _chrome.poke();
            _onEnded();
          }
        }
        _publishAdapter();
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.tracks.listen((_) {
        if (_disposed) return;
        _applyRememberedTracks();
        unawaited(_applyAudioAutoSelect());
        _applySubtitleAutoSelect();
        _updateHasSubtitles();
        _adapter.noteTracksChanged();
        _publishPanelData();
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.error.listen((message) {
        if (_disposed) return;
        if (kDebugMode) debugPrint('mpv error: $message');
        _adapter.noteError(message);
        // A dead source fails over; an error mid-play just shows in the log
        // — the watchdog owns startup, and a mid-play error is usually a
        // transient network hiccup mpv recovers from on its own.
        if (!_startedPlaying) _tryNextStream();
      }),
    );
  }

  /// Rebuilds the adapter's published value from the engine's state, so
  /// the stock chrome and panel always read mpv's truth.
  void _publishAdapter() {
    if (_disposed) return;
    _adapter.publish();
  }

  /// Build 120: re-playing an Instant title whose temp file is already
  /// on disk opens the local file at the resume position at once — no
  /// plugin call, no "Getting links", no re-download. The file is
  /// found by the film's identity (title + episode + the last-played
  /// source's stable label), not by the stream URL, because signed
  /// URLs are re-issued on every load and a URL hash never matches the
  /// kept file (b119's bug, phone-proven 2026-11-22). Returns true
  /// when the local file opened (the background resolve then keeps the
  /// fetch going); false when there is no kept file, it does not cover
  /// the resume point, or the open failed — the caller then resolves
  /// normally.
  Future<bool> _tryOpenKeptTempFile() async {
    if (_disposed) return false;
    if (widget.item.contentType == MultimediaContentType.livestream) {
      return false;
    }
    // The source this title last played on, remembered by its stable
    // label (see [streamSourceKey]). Nothing remembered means the film
    // was never played on a source, so there is no kept file.
    final lastKey = readLastSourceMap(_read)[widget.item.url];
    if (lastKey == null || lastKey.isEmpty) return false;
    // The resume point this device already knows, read locally — no
    // network, so the decision costs nothing.
    final resume = resumePointFor(
      read: _read,
      item: widget.item,
      episode: _currentEpisode,
      videoUrl: _currentVideoUrl,
    );
    if (resume == null || resume.position <= Duration.zero) return false;
    final fileKey = tempFileKeyFor(
      itemUrl: widget.item.url,
      episodeKey: _tempFileEpisodeKey,
      sourceKey: lastKey,
    );
    // A retry after this file already failed to open must resolve
    // normally instead of looping on it (see [_keptFileOpenedKey]).
    if (fileKey == _keptFileOpenedKey) return false;
    final Directory dir;
    try {
      dir = await appTempDirectory();
    } catch (_) {
      return false;
    }
    final kept = await TempDownload.findKept(
      directory: dir,
      fileKey: fileKey,
    );
    if (kept == null || !kept.covers(resume.position)) return false;
    final localUrl = AppUtils.normalizeUrl(kept.filePath);
    final localStream = localStreamForSourceKey(
      lastKey,
      localUrl: localUrl,
    );
    if (localStream == null) return false;
    // Open the local file under the source's own label, so remembering
    // it writes back the same key and the panel names the real source.
    _keptFileOpenedKey = fileKey;
    _streams = <StreamResult>[localStream];
    _streamIndex = 0;
    _lastUsedIndex = 0;
    _resolveDone = true;
    _resumePosition = resume.position;
    _isLive = false;
    _playingLocalTemp = true;
    _tempLocalUrl = localUrl;
    _localFalseEndCount = 0;
    _publishPanelData();
    if (mounted) setState(() {});
    unawaited(_loadSkipSegments(_currentEpisode));
    await _openStream(
      0,
      start: resume.position,
      skipPrebuffer: true,
      localFileUrl: localUrl,
    );
    if (_disposed) return true;
    if (_stage == _Stage.failed) {
      // The kept file would not open (corrupt, torn write): fall back
      // to the normal resolve instead of stranding the viewer.
      _playingLocalTemp = false;
      _tempLocalUrl = null;
      _streams = <StreamResult>[];
      _streamIndex = 0;
      _resolveDone = false;
      _failedStreams.clear();
      setState(() {
        _stage = _Stage.resolving;
        _error = null;
      });
      _publishPanelData();
      return false;
    }
    // The film is playing from the phone. Resolve the network links in
    // the background so the temp download can keep fetching past the
    // frontier (see [_resolveInBackgroundAndResumeDownload]).
    unawaited(_resolveInBackgroundAndResumeDownload());
    return true;
  }

  /// Build 120: the film is already playing from its kept temp file, so
  /// the network links are resolved in the background — only so the
  /// temp download can keep fetching past the frontier. A failure here
  /// is silent: playback continues on the local file, and the normal
  /// failover still applies once the list lands.
  Future<void> _resolveInBackgroundAndResumeDownload() async {
    if (_disposed) return;
    final ResolvedPlayback resolved;
    try {
      resolved = await resolvePlayback(
        read: _read,
        item: widget.item,
        videoUrl: _currentVideoUrl,
        preloadedStreams: widget.preloadedStreams,
      );
    } catch (_) {
      return;
    }
    if (_disposed || !_playingLocalTemp) return;
    // Only the local-only list is replaced: if the viewer already
    // picked another source, that source owns the screen now.
    if (_streams.length != 1) return;
    _streams = resolved.streams;
    _streamIndex = resolved.index;
    _lastUsedIndex = resolved.lastUsedIndex;
    _dataSaver = resolved.dataSaver;
    _resolveDone = true;
    _publishPanelData();
    if (mounted) setState(() {});
    // The fetch resumes for the resolved source (same stable file key,
    // so it adopts the kept bytes and appends). The proxy gate is
    // relaxed for the local-temp case (see [_maybeStartTempDownload]).
    unawaited(_maybeStartTempDownload());
  }

  Future<void> _resolveAndOpen() async {
    if (_disposed) return;
    // A fresh resolve: no probes yet, no pick, no row "being opened".
    _probes.clear();
    _pickedIndex = null;
    _resolveDone = false;
    // Build 120: a kept temp file for this film + source opens at once,
    // with no link resolution at all — the file IS the download, so
    // re-playing from Instant has no "Getting links" and no black
    // screen. When it is not there (or does not cover the resume
    // point), the normal resolve below runs.
    if (await _tryOpenKeptTempFile()) return;
    try {
      final resolved = await resolvePlayback(
        read: _read,
        item: widget.item,
        videoUrl: _currentVideoUrl,
        preloadedStreams: widget.preloadedStreams,
        // The original's list appears as soon as the candidates arrive and
        // its rows update live as each source is probed — the viewer watches
        // the sources resolve and picks one before anything plays. mpv used
        // to pass neither callback, so the list only appeared AFTER the
        // whole resolve (probe race included) had returned, and every row
        // read blank. Now the candidates land early and each probe answer
        // rebuilds the list, exactly as the stock screen narrates them.
        onCandidates: (streams) {
          if (_disposed) return;
          _streams = streams;
          _publishPanelData();
          if (mounted) setState(() {});
        },
        onProbe: (index, outcome) {
          if (_disposed) return;
          _probes[index] = outcome;
          if (mounted) setState(() {});
        },
      );
      final resume = await resolveResumePoint(
        read: _read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
      );
      if (_disposed) return;
      _streams = resolved.streams;
      _lastUsedIndex = resolved.lastUsedIndex;
      _dataSaver = resolved.dataSaver;
      _resolveDone = true;
      // The viewer picked a row during the probe race: it is already
      // opening (see _pickFromStartup), so do not overrule it with the
      // resolver's auto-pick and do not open a second source. Without
      // this the assignment below would overwrite the pick.
      if (_pickedIndex != null) return;
      _streamIndex = resolved.index;
      _resumePosition = resume?.position ?? Duration.zero;
      // Only a real livestream is LIVE; an HLS VOD reports its duration once
      // mpv reads the playlist, and _canSeek stays off until then.
      _isLive = widget.item.contentType == MultimediaContentType.livestream;
      _publishPanelData();
      // The list must be SEEN, not flashed: the streams are preloaded, so
      // resolution is fast, and until now nothing rebuilt the screen with
      // the rows — the first rebuild came from _openStream's trailing
      // setState, by which time the first frame was imminent and the list
      // was skipped entirely. Rebuild now, wait for the populated list to
      // paint, then hold it for a beat before the first source auto-plays.
      if (mounted) setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      if (_disposed) return;
      final listPaintedAt = DateTime.now();
      unawaited(_loadSkipSegments(_currentEpisode));
      _tracker = PlaybackTracker(
        read: _read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
        token: ++_sessionToken,
      );
      _recorder = PlaybackProgressRecorder(
        read: _read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
        token: _sessionToken,
      );
      final listVisibleFor = DateTime.now().difference(listPaintedAt);
      if (listVisibleFor < _kMinListVisible) {
        await Future<void>.delayed(_kMinListVisible - listVisibleFor);
      }
      if (_disposed) return;
      // A row tapped during the hold already opened its source; do not
      // overrule the viewer's pick with the auto-pick.
      if (_streamIndex != resolved.index) return;
      await _openStream(_streamIndex, start: _resumePosition);
    } on StreamResolutionException catch (e) {
      if (_disposed) return;
      setState(() {
        _stage = _Stage.failed;
        _error = describeStreamFailure(AppLocalizations.of(context)!, e);
      });
      _publishPanelData();
    } catch (e) {
      if (_disposed) return;
      setState(() {
        _stage = _Stage.failed;
        _error = 'Could not load sources: $e';
      });
      _publishPanelData();
    }
  }

  Future<void> _openStream(
    int index, {
    Duration? start,
    bool autoPlay = true,
    bool keepSession = false,
    bool skipPrebuffer = false,
    // Build 107: reopen on the local temp file at [start] instead of
    // the stream. The proxy is skipped entirely and the film plays
    // from the phone, where seeking is instant.
    String? localFileUrl,
  }) async {
    if (_disposed || _streams.isEmpty) return;
    // A genuinely different source (failover / source pick) ends the old
    // subtitle pick: the adapter's anchor belongs to the old media. A
    // same-index re-open (stall recovery) keeps it — the media is the
    // same, the remembered pick is re-applied, and the anchor holds the
    // drawer on it while the re-application lands.
    if (index != _streamIndex) {
      _adapter.noteNewSource();
      _hwdecSeenAlive = false;
    }
    _streamIndex = index;
    // +46 remembered the source here, on every open. v7 remembers it when
    // it actually starts playing instead (see the first-play branch of the
    // playing listener): a source that was opened and failed is not the
    // one "last played", and the next episode should not start on it.
    _startedPlaying = false;
    _subtitleAppliedFor = -1;
    // The audio-language setting is captured per open (a change in
    // Settings reaches the next media, not the one on screen), and the
    // auto-select record resets with it: an open resets mpv's tracks to
    // auto, so the pick has to be made again.
    final preferred = _playerSettings.value.preferredAudioLanguage;
    _preferredAudioToPick = preferred.isNotEmpty ? preferred : null;
    // And the last pick the viewer made, so AUTO applies it on this open
    // (see [_lastAudioPick]).
    _lastAudioPick = _readLastAudioPick();
    _audioAutoSelectSetId = -1;
    _audioAutoSelectSetFor = -1;
    _adapter.clearError();
    final stream = _streams[index];
    // Build 119: a different film's temp download is STOPPED when a
    // new film opens, but its file is KEPT (see [_stopTempDownload]) —
    // the file lives as long as Zeus is open, so going back to the old
    // film resumes from it. The new film gets its own file (the name
    // is a hash of the URL). A reopen on the local temp file keeps the
    // same origin URL, so it never stops its own download.
    if (_tempDownload != null && _tempDownload!.url != stream.url) {
      unawaited(_stopTempDownload());
    }
    // A high-bitrate (4K) open waits for a bigger cushion (see the
    // pre-buffer consts); an ordinary open keeps the 5s target.
    final highBitrate = isHighBitrateStream(stream);
    _prebufferTarget = highBitrate
        ? _kPrebufferTargetHighBitrate
        : _kPrebufferTarget;
    _prebufferMaxWait = highBitrate
        ? _kPrebufferMaxWaitHighBitrate
        : _kPrebufferMaxWait;
    // A new source earns a fresh stall budget; a reopen of the same one
    // (stall recovery) keeps its count, so a source that cannot play is
    // abandoned for the next candidate instead of reopened forever.
    if (index != _stallStreamIndex) {
      _stallStreamIndex = index;
      _stallRecoveries = 0;
      _stallLastAction = StallAction.none;
      _stallClock.reset();
      // Build 106: a different source earns a fresh false-end budget.
      _falseEndRecoveries = 0;
    }
    _stallBufferedAt = Duration.zero;
    // Build 72: a renderer move is the same play of the same film — it
    // keeps the tracker and the recorder, so nothing is scrobbled or
    // recorded twice.
    if (!keepSession || _tracker == null || _recorder == null) {
      _sessionToken++;
      _tracker = PlaybackTracker(
        read: _read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
        token: _sessionToken,
      );
      _recorder = PlaybackProgressRecorder(
        read: _read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
        token: _sessionToken,
      );
      _sample = null;
    }
    _publishPanelData();
    try {
      // Opened PAUSED: the first frame shows as soon as it is decoded, but
      // the playhead does not move until _waitForPrebuffer has a cushion
      // buffered ahead of it (see _kPrebufferTarget). Opening with
      // play: true started on the first frame with ~1s buffered, so it
      // stalled 2–3s in, then again — the spinner the viewer reported.
      _openStart = start != null && start > Duration.zero
          ? start
          : Duration.zero;
      // Build 77: a plain film file on the iPhone opens through the
      // stream cache proxy, so a renderer move finds its bytes on the
      // phone. Anything else — and any failure to get a proxied
      // address — opens the film's own address, as before.
      final previousProxy = _proxyHandle;
      var mediaUrl = stream.url;
      StreamCacheHandle? proxied;
      // Build 107: a reopen on the local temp file skips the proxy
      // entirely — the film plays from the phone, where seeking is
      // instant. The previous proxy entry closes after the open (see
      // the finally below), so the host stops being read twice.
      String? bypass;
      if (localFileUrl != null) {
        mediaUrl = localFileUrl;
        _proxyHandle = null;
        _proxyIndex = -1;
        _proxySlowWatch.disarm();
        _proxyOff = 'local';
      } else {
        bypass = streamProxyBypassReason(
          isIos: StreamCacheService.supported,
          stream: stream,
          item: widget.item,
          blocked: _proxyBlocked.contains(index),
          slow: _proxySlow.contains(index),
        );
        if (bypass == null) {
          final openToken = ++_proxyOpenToken;
          proxied = await StreamCacheService.instance.open(stream.url);
          if (_disposed || openToken != _proxyOpenToken) {
            // Left, or a newer open overtook this one while waiting.
            if (proxied != null)
              StreamCacheService.instance.close(proxied.token);
            return;
          }
          if (proxied != null) mediaUrl = proxied.url;
        } else {
          _proxyOpenToken++;
        }
        _proxyHandle = proxied;
        _proxyIndex = proxied != null ? index : -1;
        if (proxied != null) {
          _proxySlowWatch.arm(DateTime.now().millisecondsSinceEpoch);
        } else {
          _proxySlowWatch.disarm();
        }
        _proxyOff = proxied != null
            ? null
            : (bypass ?? StreamCacheService.instance.lastFailure ?? 'start');
      }
      // Build 98: an HLS film opens through the local proxy
      // (LocalProxyService), which rewrites its playlists so ffmpeg's
      // HLS demuxer sees real playlists and .ts segments. The mpv path
      // never did this — only VLC's `_deliverableUri` did — so a server
      // that disguises HLS as images (Cinejoy Nebula:
      // `1080p/playlist.jpg`, segments `playlist_NNN.jpg`) stalled on a
      // black screen with zero streams. The stream-cache proxy still
      // does not apply: HLS bypasses it, and a 127.0.0.1 address
      // bypasses it as 'local'.
      // Build 100 (iOS only): an HLS-proxy open decides its decoder by
      // shape, not by path. b99 proved `hwdec=no` plays Nebula's fMP4
      // HLS (VideoToolbox decoded it but never produced a texture) and
      // the Paris control test proved plain .ts HLS plays fine on
      // VideoToolbox — so only fMP4 (an init segment in the playlist,
      // see [detectFmp4Hls]) opens with software decode, and .ts HLS
      // keeps the hardware decoder. A probe that cannot tell falls back
      // to the b99-wide software decode, so an unreadable HLS shape
      // still plays rather than risking a black screen.
      var useSoftwareDecode = false;
      if (bypass == 'hls') {
        final hlsUri = Uri.tryParse(stream.url);
        if (hlsUri != null && looksLikeHls(hlsUri)) {
          final proxiedHls = await _hlsProxyUrl(stream);
          if (proxiedHls != null) {
            mediaUrl = proxiedHls;
            useSoftwareDecode = true;
            final proxiedUri = Uri.tryParse(proxiedHls);
            if (proxiedUri != null) {
              final isFmp4 = await detectFmp4Hls(
                proxiedUri,
                _fetchPlaylistHead,
              ).timeout(_kFmp4DetectTimeout, onTimeout: () => null);
              if (isFmp4 == false) useSoftwareDecode = false;
            }
          }
        }
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _applyHlsProxyHwdec(useSoftwareDecode);
      }
      try {
        await _player.open(
          Media(
            mediaUrl,
            httpHeaders: stream.headers,
            start: start != null && start > Duration.zero ? start : null,
          ),
          // Build 73: a renderer move starts on its first frame.
          play: skipPrebuffer && autoPlay,
        );
      } finally {
        // The film before this one is off the engine now (closing its
        // proxy entry any earlier would hand the engine an error for a
        // film it is still reading).
        if (previousProxy != null &&
            previousProxy.token != _proxyHandle?.token) {
          StreamCacheService.instance.close(previousProxy.token);
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('mpv open failed: $e');
      _failedStreams.add(index);
      _publishPanelData();
      _tryNextStream();
      return;
    }
    _armWatchdog();
    if (skipPrebuffer) {
      _prebufferToken++;
      _awaitingPrebuffer = false;
      _prebufferHoldPlay = false;
      _prebufferTimer?.cancel();
      _prebufferTimer = null;
    } else {
      _waitForPrebuffer(autoPlay: autoPlay);
    }
    if (mounted) setState(() {});
  }

  /// Build 98: an HLS address through the local proxy, mirroring VLC's
  /// `_proxied`: the server is started explicitly first (a cold first
  /// call would otherwise build a URL pointing at port 0), and exactly
  /// the cookies the source supplied are kept, so the proxy re-injects
  /// them upstream. Null when the proxy is not up — the caller then
  /// opens the address directly, as before.
  Future<String?> _hlsProxyUrl(StreamResult stream) async {
    await LocalProxyService.instance.startServer();
    if (LocalProxyService.instance.port == 0) return null;
    return LocalProxyService.instance.getProxyUrl(
      stream.url,
      headers: stream.headers,
      options: ProxyOptions(keepCookies: _cookieNames(stream.headers)),
    );
  }

  /// Build 100: applies the hardware-decode mode for this open, before
  /// [_player.open] so it governs the file being opened (mpv's `hwdec`
  /// applies to the next file loaded). [useSoftwareDecode] is true only
  /// for fMP4 HLS (see [detectFmp4Hls]) and for an HLS probe that could
  /// not tell — the b99 fallback — so those open with `hwdec=no`
  /// (software decode). Everything else restores the usual VideoToolbox
  /// decoder, but only when the previous open left it off, so ordinary
  /// opens cost no extra property set. Best-effort: a failed set never
  /// breaks the open.
  Future<void> _applyHlsProxyHwdec(bool useSoftwareDecode) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      if (useSoftwareDecode) {
        await platform.setProperty('hwdec', 'no');
        _hlsProxyHwdecNo = true;
        debugPrint('[mpv] build 100: fMP4/unknown HLS open, hwdec=no');
      } else if (_hlsProxyHwdecNo) {
        await platform.setProperty(
          'hwdec',
          mpvIosHwdec(pipEnabled: _iosMpvPipEnabled),
        );
        _hlsProxyHwdecNo = false;
        debugPrint('[mpv] build 100: normal open, hwdec restored');
      }
    } catch (e) {
      debugPrint('[mpv] build 100: hwdec set failed: $e');
    }
  }

  /// Build 100: reads the head of the playlist at [url] — through the
  /// local proxy, so no headers are needed (the proxy re-injects them
  /// upstream) — or null when it cannot be read. Bounded: at most
  /// [_kFmp4HeadBytes] (an init segment always sits in the header,
  /// ahead of the segments) and [_kFmp4FetchTimeout] per step, so a
  /// slow source never stalls the open; the caller treats null as
  /// "unknown". A non-playlist answer (a film behind an adaptive
  /// address) is null too.
  Future<String?> _fetchPlaylistHead(Uri url) async {
    final client = HttpClient();
    client.connectionTimeout = _kFmp4FetchTimeout;
    try {
      final request = await client.getUrl(url);
      final response = await request.close().timeout(_kFmp4FetchTimeout);
      if (response.statusCode != 200) return null;
      final bytes = <int>[];
      await for (final chunk in response.timeout(_kFmp4FetchTimeout)) {
        bytes.addAll(chunk);
        if (bytes.length >= _kFmp4HeadBytes) break;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      return text.contains('#EXTM3U') ? text : null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// The cookie names in [headers], for the local proxy's keep list.
  List<String> _cookieNames(Map<String, String>? headers) {
    if (headers == null) return const <String>[];
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() != 'cookie') continue;
      return entry.value
          .split(';')
          .map((pair) => pair.split('=').first.trim())
          .where((name) => name.isNotEmpty)
          .toList();
    }
    return const <String>[];
  }

  /// Holds an opened stream paused until the pre-buffer target is met, then
  /// plays. A fast source is usually buffered already, so it plays at once;
  /// a slow one waits at most _kPrebufferMaxWait and then plays anyway (the
  /// cache-pause will stall it if the server cannot keep up — same as
  /// before, but now from a cushion rather than from the first frame).
  ///
  /// +49: `autoPlay: false` (the old resume re-open) held the play —
  /// the pre-buffer still filled, but [_startAfterPrebuffer] left the
  /// film paused (see [_prebufferHoldPlay]). +55 removed that re-open;
  /// the stall fallback re-opens with `autoPlay: true`, so it plays
  /// once the pre-buffer refills.
  void _waitForPrebuffer({bool autoPlay = true}) {
    final token = ++_prebufferToken;
    _awaitingPrebuffer = true;
    _prebufferHoldPlay = !autoPlay;
    if (_prebufferReady) {
      _startAfterPrebuffer(token);
      return;
    }
    _prebufferTimer?.cancel();
    _prebufferTimer = Timer(_prebufferMaxWait, () {
      if (_disposed || token != _prebufferToken) return;
      _startAfterPrebuffer(token);
    });
  }

  /// Whether the buffered cushion ahead of the playhead meets the target.
  bool get _prebufferReady => _buffered - _openStart >= _prebufferTarget;

  void _startAfterPrebuffer([int? token]) {
    if (!_awaitingPrebuffer) return;
    if (token != null && token != _prebufferToken) return;
    _awaitingPrebuffer = false;
    _prebufferTimer?.cancel();
    _prebufferTimer = null;
    if (_disposed) return;
    if (_prebufferHoldPlay) {
      // +49 hold: stay paused (see [_prebufferHoldPlay]). No current
      // caller opens with `autoPlay: false` any more (+55 removed the
      // resume re-open; the stall fallback re-opens with `autoPlay:
      // true`), but the hold is kept for any future such open.
      _prebufferHoldPlay = false;
      return;
    }
    unawaited(_player.play());
  }

  /// One tick of the mid-playback stall watchdog (every 2s).
  ///
  /// The start-only pre-buffer (see [_waitForPrebuffer]) does nothing once
  /// playback has begun: on a line slower than a 4K stream's bitrate the
  /// forward cache drains mid-film, mpv's spinner comes up, and the
  /// playhead sits still — in the video the user sent, forever, with
  /// Control Center reading "Not Playing". The engine's `buffering` flag
  /// alone cannot be the trigger (it is true through healthy playback
  /// while the cache refills), so the trigger is the ground truth from
  /// [stallActionFor]: a playhead that has not moved.
  ///
  /// The ladder is the shared one, so a stall is ridden out before
  /// anything is done about it: a seek back to the frozen position at
  /// 10s (a fresh request for a demuxer that dropped its own — on a
  /// stalled HLS stream the forward cache is empty, so the seek throws
  /// nothing away), then a reopen of the same source at the same
  /// position at 25s, then the next candidate after two failed reopens.
  /// The nudge is kept for HLS on purpose: the ladder's `adaptive`
  /// exemption is written for libVLC, whose adaptive module restarts
  /// every stream at the playhead's segment and drops a rendition on a
  /// seek. mpv's HLS demuxer only re-fetches the segment at the seek
  /// point, and a stalled one has nothing buffered to lose — so the
  /// nudge is the move that restarts a demuxer whose segment retries
  /// are spent, not a cost.
  /// A source that is still delivering bytes (the buffered position
  /// growing) is refilling, not dead: no nudge, and recovery waits out
  /// the longest refill. Playback that is not expected — the viewer's
  /// own pause, the pre-buffer wait, or nothing started yet — restarts
  /// the clock instead of counting against the source, so ten minutes
  /// paused is never ten minutes stalled the moment play resumes.
  void _onStallTick() {
    if (_disposed || !_startedPlaying || _awaitingPrebuffer) return;
    if (!_engineReady || rendererSwitching(_rendererPhase)) return;
    final state = _player.state;
    if (_proxyWatching &&
        _proxySlowWatch.onTick(
          buffering: state.buffering,
          position: _position,
          nowMs: DateTime.now().millisecondsSinceEpoch,
        )) {
      _leaveSlowProxy();
      return;
    }
    if (!state.playing && !state.buffering) {
      _stallClock.restart();
      _stallLastAction = StallAction.none;
      return;
    }
    final moved = _stallClock.tick(_position);
    if (moved) {
      // The picture is moving again: the stall is over and the source
      // has earned a fresh recovery budget.
      _stallLastAction = StallAction.none;
      _stallRecoveries = 0;
      _stallBufferedAt = _buffered;
      return;
    }
    final arriving = _buffered > _stallBufferedAt;
    _stallBufferedAt = _buffered;
    final action = stallActionFor(
      stalledFor: _stallClock.stalledFor,
      hadFrames: _startedPlaying,
      lastAction: _stallLastAction,
      arriving: arriving,
    );
    switch (action) {
      case StallAction.none:
        break;
      case StallAction.nudge:
        _stallLastAction = StallAction.nudge;
        unawaited(_player.seek(_position));
      case StallAction.recover:
        _stallLastAction = StallAction.recover;
        _stallClock.reset();
        if (_stallRecoveries < _kStallMaxReopens) {
          _stallRecoveries++;
          // Build 77: a second stall on the same source re-opens it
          // straight from the host, in case the proxy is what stalls.
          if (_stallRecoveries >= 2) _proxyBlocked.add(_streamIndex);
          unawaited(_openStream(_streamIndex, start: _position));
        } else {
          _tryNextStream();
        }
    }
  }

  /// The thermal watch's tick (iOS + Android, +33; every [_kThermalPoll]
  /// while the screen lives): reads the phone's heat and asks the governor
  /// whether it wants a quality change. Stands down unless a film is
  /// playing — a paused film needs no drop, and the governor's restore
  /// streak only counts while playing. A switch is the same
  /// [_pickSource] a tap on a source row makes, so it re-opens at the
  /// playhead, re-applies the remembered audio/subtitle tracks, and
  /// earns a fresh stall budget (see [_openStream]).
  ///
  /// +33: the tick runs during PiP too, but only the render lightening
  /// is decided there — the governor's ladder logic is skipped while
  /// [_inPip], because the PiP drop (see `_dropQualityForPip`) owns
  /// quality while the window is up, and a ladder decision would see
  /// the PiP target as a third source and cancel the governor's own
  /// drop episode. The lightening changes no stream, so it cannot
  /// fight the PiP drop, and for a single-file source it is the only
  /// thermal relief there is (user report 2026-11-15: the 20.96 GB 4K
  /// file lags even without PiP).
  Future<void> _onThermalTick() async {
    if (_disposed || !_startedPlaying || !_playing) return;
    if (!_engineReady || rendererSwitching(_rendererPhase)) return;
    final decision = _thermalGovernor.evaluate(
      thermal: await readThermalState(),
      qualities: _streams.map((stream) => stream.quality).toList(),
      currentIndex: _streamIndex,
      inPip: _inPip,
    );
    if (decision.isNone || _disposed) return;
    switch (decision.kind) {
      case ThermalQualityKind.none:
        break;
      case ThermalQualityKind.drop:
        ref
            .read(notificationServiceProvider)
            .showInfo(
              'Phone is heating up — switched to '
              '${_thermalTargetLabel(decision.targetIndex)} to stay smooth',
              title: 'Phone is hot',
            );
        unawaited(_pickSource(decision.targetIndex));
      case ThermalQualityKind.restore:
        ref
            .read(notificationServiceProvider)
            .showInfo(
              'Phone cooled down — back to '
              '${_thermalTargetLabel(decision.targetIndex)}',
              title: 'Phone cooled down',
            );
        unawaited(_pickSource(decision.targetIndex));
      case ThermalQualityKind.hint:
        ref
            .read(notificationServiceProvider)
            .showInfo(
              'Phone is heating up — pick a lower quality in the Quality '
              'tab to stay smooth',
              title: 'Phone is hot',
            );
      case ThermalQualityKind.lighten:
        // A single-file source: no ladder to drop to, so lighten the
        // render instead. The stream never changes, so playback
        // carries on at the playhead. The toast only fires when the
        // lightening actually applied (+34: +33 toasted success even
        // when every property was refused).
        if (await _applyThermalLighten()) {
          ref
              .read(notificationServiceProvider)
              .showInfo(
                'Phone is heating up — playing at reduced detail to stay '
                'smooth',
                title: 'Phone is hot',
              );
        }
      case ThermalQualityKind.unlighten:
        if (await _clearThermalLighten()) {
          ref
              .read(notificationServiceProvider)
              .showInfo(
                'Phone cooled down — back to full detail',
                title: 'Phone cooled down',
              );
        }
    }
  }

  /// The height of the stream now playing, or null when unknown (an
  /// adaptive master with no ladder height) or no stream is selected.
  /// The PiP render cap (+35 P1) only ever engages for a known height
  /// above 1080p — unknown is treated as "nothing to cap", the same
  /// conservatism as the thermal governor.
  int? get _currentStreamHeight {
    if (_streamIndex < 0 || _streamIndex >= _streams.length) return null;
    return _streams[_streamIndex].quality;
  }

  /// Applies the PiP render cap (+35 P1, +47 540p): while the iOS PiP
  /// window is up the whole session runs on the software renderer, and
  /// a full 4K SW render in the background under iOS CPU throttling
  /// cannot keep up — so the render target drops to 960x540 (a
  /// sixteenth of the pixels; the feed is ~640 px wide, so nothing
  /// visible is lost, and the in-app texture is invisible while the
  /// app is backgrounded). The 1080p cap (+39) was not enough for the
  /// 22GB 4K file, which still lagged in the window. The decision is
  /// the pure [pipRenderCapTarget]: the PiP cap and the thermal cap
  /// share one actuation ([_setIosRenderCap]), so the target is the
  /// min of the two. No toast — the cap is not a heat event. No-op
  /// when already capped or when the source is at or below 1080p.
  Future<void> _applyPipRenderCap() async {
    if (_iosPipOnDemand) {
      // Build 73: the label is not trusted (a 4K file with no quality
      // label was never capped) — the size comes from the film itself.
      await _applySoftwareRenderSize();
      return;
    }
    if (_pipRenderCapped) return;
    final target = pipRenderCapTarget(
      pipUp: true,
      thermalLightened: _thermalGovernor.isLightened,
      sourceHeight: _currentStreamHeight ?? 0,
    );
    if (target != PipRenderCap.capped540p) return;
    if (await _setIosRenderCap(true, width: 960, height: 540)) {
      _pipRenderCapped = true;
    }
  }

  /// Lifts the PiP render cap (+35 P1, +47 540p) now the window is
  /// down, and restores the render target to the governor's desired
  /// state: if the thermal governor is lightened the 1080p cap stays
  /// (re-applied — the PiP restore must never clobber a thermal
  /// lighten); otherwise full size returns. No-op when the PiP cap
  /// was never applied.
  Future<void> _restorePipRenderCap() async {
    // Build 73: on demand nothing is restored here. A 4K film leaves
    // the software renderer right after the window (rendering it at
    // full size for those moments is what build 72 did — `vo-drop
    // +48`), and a film below 4K was never shrunk.
    if (_iosPipOnDemand) return;
    if (!_pipRenderCapped) return;
    _pipRenderCapped = false;
    final target = pipRenderCapTarget(
      pipUp: false,
      thermalLightened: _thermalGovernor.isLightened,
      sourceHeight: _currentStreamHeight ?? 0,
    );
    await _setIosRenderCap(target == PipRenderCap.capped1080p);
  }

  /// Whether the film is actually moving again after a return: playing,
  /// past the pre-buffer hold of a re-open, and past its first play.
  /// Only then does `hwdec-current` say anything — it is empty until
  /// the decoder has produced a frame.
  bool get _hwdecWatchPlaybackReady =>
      _playing && !_awaitingPrebuffer && _startedPlaying;

  /// The hardware-decode watch that follows a Home → return (build 70).
  ///
  /// Why: on 2026-11-18 the user's 4K film (PiP mode iOS, so the
  /// hardware renderer) read `hwdec: videotoolbox` before Home and an
  /// empty `hwdec:` after the return, with `vo-drop` climbing and a
  /// full cache. The 4K return re-opens the source, the re-opened film
  /// came up in software decode, and no check ran after it: the one in
  /// the resumed hook returns at once because Home paused the film.
  ///
  /// What: once the film is moving again ([_hwdecWatchPlaybackReady])
  /// the live decoder is read up to [kHwdecResumeCheckDelays].length
  /// times — about 1 s, 3 s and 6 s later. A healthy decoder ends the
  /// watch untouched. A lost one is cycled (`hwdec` off, then back to
  /// [mpvIosHwdec]): mpv re-creates the decoder and seeks in place, so
  /// the position holds and there is no fresh connection. Only if it
  /// is still lost on the last check is the stream re-opened at the
  /// playhead, once, and the watch ends there — it never follows its
  /// own re-open, so it cannot loop ([hwdecResumeStep],
  /// [hwdecResumeContinues]).
  ///
  /// Bounded in time too: it gives up if the film has not started
  /// moving 45 s after the return (a dead source is the stall
  /// recovery's job). A new backgrounding, a newer watch or dispose
  /// ends it through [_hwdecWatchToken]. iOS only; Android is
  /// untouched.
  Future<void> _runHwdecResumeWatch() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    if (_disposed || !mounted) return;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    final token = ++_hwdecWatchToken;
    // Build 71: a watch started from the PiP-stop hook, with no return
    // counted yet, still shows up on the overlay.
    if (_hwdecReturns == 0) _hwdecReturns = 1;
    _hwdecWatchPending = false;
    _hwdecWatchChecks = 0;
    _hwdecWatchCycles = 0;
    _hwdecWatchReopened = false;
    _hwdecWatchOutcome = 'waiting';
    if (!hwdecRestoreAllowed(seenAlive: _hwdecSeenAlive)) {
      // This film was never seen on VideoToolbox (the PiP renderer's
      // software session, or a file the phone cannot hardware-decode):
      // there is nothing to restore, and a re-open would only flash.
      _hwdecWatchOutcome = kHwdecOutcomeSkipNoHardware;
      return;
    }
    bool live() => !_disposed && mounted && token == _hwdecWatchToken;
    final expected = mpvIosHwdec(pipEnabled: _iosMpvPipEnabled);
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    var attempt = 0;
    while (attempt < kHwdecResumeCheckDelays.length) {
      // Wait for the film to be moving again (the 4K re-open holds it
      // paused until the pre-buffer refills).
      while (!_hwdecWatchPlaybackReady) {
        if (!live()) return;
        if (DateTime.now().isAfter(deadline)) {
          _hwdecWatchOutcome = 'stopped';
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      await Future<void>.delayed(kHwdecResumeCheckDelays[attempt]);
      if (!live()) return;
      // Paused or re-buffering during the wait: the read would prove
      // nothing, so wait for playback again without spending a check
      // (still inside the 45 s budget).
      if (!_hwdecWatchPlaybackReady) {
        if (DateTime.now().isAfter(deadline)) {
          _hwdecWatchOutcome = 'stopped';
          return;
        }
        continue;
      }
      String? current;
      try {
        current = (await platform.getProperty('hwdec-current')).toString();
      } catch (_) {
        current = null;
      }
      if (!live()) return;
      _hwdecWatchChecks++;
      final step = hwdecResumeStep(
        current: current,
        attempt: attempt,
        inPip: _inPip,
      );
      switch (step) {
        case HwdecResumeStep.healthy:
          _hwdecWatchOutcome = 'ok';
          _hwdecSeenAlive = true;
          debugPrint(
            '[mpv] hwdec watch: healthy '
            '(hwdec-current="$current", check ${attempt + 1})',
          );
        case HwdecResumeStep.unreadable:
          _hwdecWatchOutcome = 'unreadable';
        case HwdecResumeStep.cycle:
          _hwdecWatchCycles++;
          _hwdecWatchOutcome = 'lost';
          debugPrint(
            '[mpv] hwdec watch: lost (hwdec-current="$current"), '
            'cycling hwdec to "$expected" (check ${attempt + 1})',
          );
          await _cycleHwdec(platform, expected);
          if (!live()) return;
        case HwdecResumeStep.reopen:
          if (_streamIndex < 0 || _streamIndex >= _streams.length) {
            _hwdecWatchOutcome = 'stopped';
            return;
          }
          _hwdecWatchReopened = true;
          _hwdecWatchOutcome = 'reopened';
          // One re-open per loss: no further one for this film until
          // hardware decode has been seen again.
          _hwdecSeenAlive = false;
          debugPrint(
            '[mpv] hwdec watch: still lost after '
            '$_hwdecWatchCycles cycle(s), re-opening stream '
            '$_streamIndex at $_position',
          );
          _resumeStallTimer?.cancel();
          _resumeStallTimer = null;
          unawaited(
            _openStream(_streamIndex, start: _position, autoPlay: true),
          );
        case HwdecResumeStep.giveUp:
          _hwdecWatchOutcome = 'stopped';
      }
      if (!hwdecResumeContinues(step: step, attempt: attempt)) return;
      attempt++;
    }
  }

  /// Re-creates the video decoder in place: `hwdec` off, then back to
  /// [expected]. A same-value set is a no-op in mpv, a real change
  /// makes it re-initialise the decoder and seek to the frame on
  /// screen — same position, no new connection. Both sets are
  /// synchronous in libmpv, so there is no wait between them (build 70
  /// waited 150 ms, which only let the software decoder start work it
  /// would throw away). Returns whether both sets went through.
  Future<bool> _cycleHwdec(NativePlayer platform, String expected) async {
    try {
      await platform.setProperty('hwdec', 'no');
      await platform.setProperty('hwdec', expected);
      return true;
    } catch (e) {
      debugPrint('[mpv] hwdec cycle failed: $e');
      return false;
    }
  }

  /// The hardware-decode restore's entry point, called on every iOS
  /// `resumed` (build 71). Implements [hwdecReturnPlan]:
  ///
  ///  * not a real backgrounding — nothing, the overlay keeps its line;
  ///  * never seen on VideoToolbox — `skip (no hw before)`;
  ///  * already playing (a PiP window kept the film running) — the
  ///    bounded watch starts now;
  ///  * paused — what every Home → return is on the phone — the watch
  ///    waits for the viewer's play ([_hwdecWatchPending], consumed by
  ///    the playing stream), and on the hardware renderer the decoder
  ///    is re-created at once, while nothing is moving
  ///    ([_refreshHwdecWhilePaused]).
  ///
  /// [resumePathActs]: [_resumeIosAfterBackground] is about to play or
  /// re-open the film itself and starts the watch from there, so this
  /// only counts the return. Synchronous on purpose — it must read
  /// [_playing] before anything in the same `resumed` changes it.
  void _onIosReturnHwdec({
    required bool wasBackgrounded,
    required bool wasInPip,
    required bool resumePathActs,
  }) {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    if (_disposed || !mounted) return;
    if (_player.platform is! NativePlayer) return;
    final plan = hwdecReturnPlan(
      wasBackgrounded: wasBackgrounded,
      seenAlive: _hwdecSeenAlive,
      playing: _playing,
      refreshAllowed:
          !_iosMpvPipEnabled &&
          !wasInPip &&
          !_awaitingPrebuffer &&
          _startedPlaying,
    );
    if (plan == HwdecReturnPlan.none) return;
    _hwdecWatchToken++;
    _hwdecReturns++;
    _hwdecPre = '-';
    _hwdecWatchPending = false;
    _hwdecWatchChecks = 0;
    _hwdecWatchCycles = 0;
    _hwdecWatchReopened = false;
    _hwdecWatchOutcome = 'waiting';
    debugPrint(
      '[mpv] hwdec return #$_hwdecReturns: $plan '
      '(resumePathActs=$resumePathActs)',
    );
    if (plan == HwdecReturnPlan.skipNoHardwareBefore) {
      _hwdecWatchOutcome = kHwdecOutcomeSkipNoHardware;
      return;
    }
    if (resumePathActs) return;
    switch (plan) {
      case HwdecReturnPlan.none:
      case HwdecReturnPlan.skipNoHardwareBefore:
        return;
      case HwdecReturnPlan.watchNow:
        unawaited(_runHwdecResumeWatch());
      case HwdecReturnPlan.watchOnPlay:
        _hwdecWatchOutcome = kHwdecOutcomeWaitPlay;
        _hwdecWatchPending = true;
      case HwdecReturnPlan.refreshThenWatchOnPlay:
        _hwdecWatchOutcome = kHwdecOutcomeWaitPlay;
        _hwdecWatchPending = true;
        unawaited(_refreshHwdecWhilePaused(_hwdecReturns));
    }
  }

  /// Re-creates the decoder while the film is still paused after a
  /// return from the background (build 71, see [hwdecReturnPlan] for
  /// why). One cycle, then one read-back about a second later for the
  /// overlay's `pre:` word — the read-back decides nothing, the watch
  /// after play does. [returnId] is the return this belongs to: a
  /// newer return, or dispose, ends it.
  Future<void> _refreshHwdecWhilePaused(int returnId) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    bool live() => !_disposed && mounted && returnId == _hwdecReturns;
    final expected = mpvIosHwdec(pipEnabled: _iosMpvPipEnabled);
    final sent = await _cycleHwdec(platform, expected);
    if (!live()) return;
    _hwdecPre = sent ? 'sent' : 'fail';
    if (!sent) return;
    await Future<void>.delayed(const Duration(seconds: 1));
    if (!live()) return;
    try {
      final current = (await platform.getProperty('hwdec-current')).toString();
      if (!live()) return;
      final lost = hwdecSessionLost(current: current);
      _hwdecPre = lost ? 'lost' : 'ok';
      debugPrint(
        '[mpv] hwdec return #$returnId: paused refresh read back '
        '"$current"',
      );
    } catch (_) {
      // Unreadable: the overlay keeps `sent`.
    }
  }

  /// Restores the VideoToolbox decoder after the app comes back to the
  /// foreground (+40 P4).
  ///
  /// iOS can invalidate the VideoToolbox session while the app is
  /// backgrounded (Home, the app switcher — the `mpv_ios_options.dart`
  /// header documents it), and the file then decodes in software for
  /// the rest of its run: the user proved it on 2026-11-15, PiP NOT
  /// used — normal play smooth, Home → return laggy, overlay `hwdec:`
  /// empty, `vo-drop: 18 (+18)`, `vf-fps: 12`. The
  /// `hwdec-software-fallback: 300` option did not save it (+49: the
  /// 300 was part of the problem — it tolerates ~12 s of failed
  /// decoding before falling back, and skips the failed packets; the
  /// mpv default is 3). So the live
  /// decoder is checked on every foreground resume, and restored only
  /// when it is actually lost — a healthy session is never touched,
  /// so an ordinary resume costs one property read.
  ///
  /// Two rungs, cheapest first: (1) re-apply the `hwdec` option to the
  /// live player — mpv re-initialises the decoder when it changes —
  /// then re-read after a second; a same-value set may be a no-op in
  /// mpv, which is why the re-read decides, not the set. (2) If the
  /// session is still lost, re-open the same stream at the playhead
  /// ([_openStream] with the current index — the stall-recovery shape,
  /// which keeps the subtitle anchor and re-applies the remembered
  /// tracks); a fresh open always creates a fresh decoder with the
  /// configured `hwdec`. The re-open never runs while the PiP window
  /// is up (it would tear the feed down) or while an open is already
  /// landing ([_awaitingPrebuffer]). No toast — the viewer only sees a
  /// brief spinner on the re-open rung, and only when the decoder was
  /// actually lost.
  // Build 72: no caller left — its one call site was the PiP stop,
  // which is the renderer move / keep-playing decision now
  // ([_onPipEnded]). Kept for reference with the +40 ladder.
  // ignore: unused_element
  Future<void> _restoreHwdecOnResume() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    if (_disposed || !mounted || !_playing) return;
    // Build 70: the one-shot check became the bounded watch (see
    // [_runHwdecResumeWatch]): it only restores a decoder that was
    // seen alive, cycles in place first, and re-opens at most once.
    // Build 69 re-opened here whenever `hwdec-current` was empty —
    // which is its normal value on the PiP renderer — so every return
    // from the PiP window flashed black 00:00/LIVE.
    await _runHwdecResumeWatch();
  }

  /// Records that this source decodes on VideoToolbox, when it does
  /// (see [_hwdecSeenAlive]). Never clears it: an empty read on the
  /// way out of the app is not proof the session was never there.
  Future<void> _noteHwdecBaseline() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    if (_disposed) return;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      final current = (await platform.getProperty('hwdec-current')).toString();
      if (!hwdecSessionLost(current: current)) _hwdecSeenAlive = true;
    } catch (_) {
      // Unreadable: leave the baseline as it is.
    }
  }

  /// The iOS render cap (+34, +47): caps the native render target
  /// (1920x1080 by default, 960x540 for the PiP cap — see
  /// [_applyPipRenderCap]) through the fork's `VideoController.setSize`,
  /// or restores the native video-params size with a no-arg call.
  /// Returns whether the cap actually applied. iOS only — the fork's
  /// Android controller throws UnsupportedError for setSize, so this
  /// returns false there without touching anything. A render cap is
  /// not a decode cap: the phone still decodes the original 4K
  /// bitstream; the render target is what shrinks, so the GPU has a
  /// quarter of the pixels to chew (a sixteenth at 540p). The fork
  /// re-requests the full size when the video parameters change, so a
  /// source change while lightened re-applies the cap from the
  /// first-play hook (see the `logMpvDecodeInfo` call site).
  Future<bool> _setIosRenderCap(
    bool enabled, {
    int width = 1920,
    int height = 1080,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;
    try {
      if (enabled) {
        await _videoController.setSize(width: width, height: height);
      } else {
        await _videoController.setSize();
      }
      if (kDebugMode) {
        debugPrint(
          '[4K] render cap=$enabled '
          'texture=${_videoController.rect.value}',
        );
      }
      return true;
    } catch (e) {
      debugPrint('[4K] render cap failed: $e');
      return false;
    }
  }

  /// The single-file thermal response: lighten the render of the stream
  /// now playing. The actuation is split by platform (+34): on iOS the
  /// render target is capped at 1920x1080 ([_setIosRenderCap]); on
  /// Android the `vf` scale + lavc options ([kThermalLightenProperties])
  /// are set through the native player, the same `setProperty` path the
  /// screen already uses for `sub-visibility` in PiP. No re-open is
  /// needed either way. Returns whether the lightening actually applied
  /// — +33 swallowed every exception and toasted success anyway, so a
  /// refused property looked like a fix; now a failure is logged and
  /// the toast stays silent (see [_onThermalTick]).
  Future<bool> _applyThermalLighten() async {
    await _logMpvPlaybackStats('BEFORE LIGHTEN');
    final bool applied;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      applied = await _setIosRenderCap(true);
    } else {
      applied = await _applyLightenProperties(kThermalLightenProperties);
    }
    if (applied) {
      await _logMpvPlaybackStats('AFTER LIGHTEN');
      if (kDebugMode) {
        debugPrint('mpv thermal: render lightened for a single-file 4K stream');
      }
    }
    return applied;
  }

  /// Take the render lightening off again (the phone cooled, or the
  /// stream itself is light now). Returns whether the restore actually
  /// applied, same contract as [_applyThermalLighten].
  Future<bool> _clearThermalLighten() async {
    // +35 P1: while the PiP cap is up the render stays at 1080p even
    // when the phone cools — the thermal restore must not raise the
    // PiP cap (take the min). The cap lifts on PiP stop instead (see
    // [_restorePipRenderCap]). Returning false also keeps the "back
    // to full detail" toast silent, which is correct: the detail
    // stays reduced while PiP is up.
    if (_pipRenderCapped) return false;
    await _logMpvPlaybackStats('BEFORE UNLIGHTEN');
    final bool cleared;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      cleared = await _setIosRenderCap(false);
    } else {
      cleared = await _applyLightenProperties(kThermalUnlightenProperties);
    }
    if (cleared) {
      await _logMpvPlaybackStats('AFTER UNLIGHTEN');
      if (kDebugMode) {
        debugPrint('mpv thermal: render lightening cleared');
      }
    }
    return cleared;
  }

  /// Applies one lighten/unlighten property map through the native
  /// player. Best effort per property — one refused property must not
  /// stop the others — but unlike +33 every failure is LOGGED, and the
  /// return says whether ALL of them applied, so the caller can toast
  /// only a real lightening.
  Future<bool> _applyLightenProperties(Map<String, String> properties) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return false;
    var allApplied = true;
    for (final entry in properties.entries) {
      try {
        await platform.setProperty(entry.key, entry.value);
      } catch (e) {
        allApplied = false;
        debugPrint('[mpv] thermal property ${entry.key} not applied: $e');
      }
    }
    return allApplied;
  }

  /// Reads the live mpv measurements, as `property → value`. Each read
  /// is its own try/catch: an unreadable property is skipped, never
  /// fatal. Shared by the debug log ([_logMpvPlaybackStats]) and the
  /// on-screen overlay ([_refreshMpvStatsOverlay]).
  Future<Map<String, String>> _readMpvStats() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return <String, String>{};
    const properties = <String>[
      'hwdec',
      'hwdec-current',
      'video-params/w',
      'video-params/h',
      'video-params/gamma',
      // Build 88: the primaries decide the gamut half of a PiP colour
      // gap (the SW LUT only maps the transfer); a bt.2020 film needs
      // a gamut conversion no per-channel LUT can do.
      'video-params/primaries',
      // The Video output preset's tone mapping (+57): the QoE overlay
      // shows which curve the live instance is running, so a phone
      // test can verify a preset pick actually landed.
      'tone-mapping',
      'video-out-params/w',
      'video-out-params/h',
      'vf',
      'framedrop',
      'video-sync',
      'decoder-frame-drop-count',
      'frame-drop-count',
      'mistimed-frame-count',
      'vo-delayed-frame-count',
      'demuxer-cache-duration',
      'cache-speed',
      'paused-for-cache',
      'estimated-vf-fps',
    ];
    final stats = <String, String>{};
    for (final name in properties) {
      try {
        final value = await platform.getProperty(name);
        stats[name] = value.toString();
      } catch (_) {
        // Unreadable on this build: skip it, never fatal.
      }
    }
    return stats;
  }

  /// The mpv playback stats (+34): the measurements that tell the 4K
  /// layers apart. `hwdec-current` is the decoder actually in use
  /// (`no` means software decode); `video-params/h` is the source
  /// height and `video-out-params/h` is the height after filters, so
  /// the two together prove whether a downscale really applied (a bare
  /// `vf` read-back does not — mpv 0.41 stopped rejecting bad filter
  /// values); `video-params/gamma` is `pq` for HDR; the drop counters
  /// are CUMULATIVE, so compare their change over a fixed interval
  /// rather than the final number. Called at first play (the baseline)
  /// and around every lighten/unlighten. The same values also feed the
  /// on-screen overlay ([_refreshMpvStatsOverlay]), which is the
  /// surface the user can read on a release build.
  Future<void> _logMpvPlaybackStats(String label) async {
    final stats = await _readMpvStats();
    if (stats.isEmpty) return;
    debugPrint('========== MPV $label ==========');
    for (final entry in stats.entries) {
      debugPrint('[MPV] ${entry.key} = ${entry.value}');
    }
    debugPrint('[MPV] texture rect = ${_videoController.rect.value}');
    debugPrint('[MPV] iOS PiP renderer mode = $_iosMpvPipEnabled');
    debugPrint('================================');
  }

  /// Arms the stats overlay's refresh: every [_kMpvStatsInterval] the
  /// live mpv measurements are re-read into [_mpvStatsText]. Armed
  /// once, at first play, and only while the overlay option is on.
  /// Cancelled in dispose.
  void _armMpvStatsTimer() {
    if (_mpvStatsTimer != null) return;
    _mpvStatsTimer = Timer.periodic(_kMpvStatsInterval, (_) {
      if (_disposed || !_playing) return;
      unawaited(_refreshMpvStatsOverlay());
    });
  }

  /// Re-reads the live mpv measurements into the overlay's text. The
  /// drop counters are cumulative, so each shows its total and the
  /// change since the last refresh (+N) — the change over the 2 s
  /// interval is what says whether frames are being dropped right now.
  /// The overlay is the phone test's primary diagnostic (+34): PiP was
  /// OFF during the failed +33 test and 4K still lagged, so the
  /// renderer theory is out and these numbers decide between decoder
  /// drops, presentation drops, and cache underruns.
  Future<void> _refreshMpvStatsOverlay() async {
    if (!_engineReady) return;
    final stats = await _readMpvStats();
    if (_disposed || stats.isEmpty || !_engineReady) return;
    final liveHwdec = stats['hwdec-current'];
    if (liveHwdec != null && !hwdecSessionLost(current: liveHwdec)) {
      _hwdecSeenAlive = true;
    }
    String dropLine(String key, String label) {
      final total = int.tryParse(stats[key] ?? '') ?? 0;
      final prev = _prevMpvDrops[key];
      _prevMpvDrops[key] = total;
      final delta = prev == null ? 0 : total - prev;
      return '$label: $total (+$delta)';
    }

    final rect = _videoController.rect.value;
    final tex = rect == null
        ? '?'
        : '${rect.width.toInt()}x${rect.height.toInt()}';
    final buffer = StringBuffer()
      ..writeln('hwdec: ${stats['hwdec-current'] ?? '?'}')
      ..writeln(
        'src: ${stats['video-params/w'] ?? '?'}x${stats['video-params/h'] ?? '?'} '
        'gamma:${stats['video-params/gamma'] ?? '?'} '
        'prim:${stats['video-params/primaries'] ?? '?'}',
      )
      // Build 88: which SW LUT the live gamma + tone-mapping imply
      // (Dart mirror of TextureSW's table) — the PiP colour question
      // needs this next to the gamma, not another eyeball: `sdr-exact`
      // is the build-87 LUT, `none` passes the frame through, `pq|hlg`
      // are the HDR tone-map LUTs.
      ..writeln(
        'sw-lut: ${swLutOverlayLabel(gamma: stats['video-params/gamma'], toneMapping: stats['tone-mapping'] ?? 'clip')}',
      )
      ..writeln(
        'out: ${stats['video-out-params/w'] ?? '?'}x${stats['video-out-params/h'] ?? '?'} '
        'tex: $tex',
      )
      ..writeln(dropLine('decoder-frame-drop-count', 'dec-drop'))
      ..writeln(dropLine('frame-drop-count', 'vo-drop'))
      ..writeln(dropLine('vo-delayed-frame-count', 'vo-delay'))
      ..writeln(
        'cache: ${stats['demuxer-cache-duration'] ?? '?'}s '
        '${_formatBytesPerSec(stats['cache-speed'])}',
      )
      ..writeln('paused-cache: ${stats['paused-for-cache'] ?? '?'}')
      ..writeln('vf-fps: ${stats['estimated-vf-fps'] ?? '?'}')
      ..writeln(
        'framedrop: ${stats['framedrop'] ?? '?'} '
        'pip: ${_iosMpvPipEnabled ? 'on' : 'off'}',
      );
    // Build 70: what the hardware-decode watch did on the last Home →
    // return (iOS only — Android has no such watch).
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      buffer.writeln(
        hwdecResumeOverlayLine(
          returns: _hwdecReturns,
          pre: _hwdecPre,
          checks: _hwdecWatchChecks,
          cycles: _hwdecWatchCycles,
          reopened: _hwdecWatchReopened,
          outcome: _hwdecWatchOutcome,
        ),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      buffer.writeln(
        rendererOverlayLine(_rendererPhase, onDemand: _iosPipOnDemand),
      );
      if (_iosPipOnDemand) {
        buffer
          ..writeln(
            switchTimingLine(
              direction: _switchDirection,
              steps: _switchSteps,
              outcome: _switchOutcome,
            ),
          )
          ..writeln(_switchDetail)
          ..writeln(_pipLastLine)
          ..writeln(_pipFeedLine);
      }
    }
    // Build 77: the stream cache proxy.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final handle = _proxyHandle;
      final StreamCacheStats? proxyStats = handle == null
          ? null
          : await StreamCacheService.instance.stats(handle.token);
      if (_disposed) return;
      buffer.writeln(
        streamProxyOverlayLine(
          opened: handle != null,
          bypassReason: _proxyOff,
          stats: proxyStats,
          duration: _duration,
        ),
      );
      // Build 119: the temp download's line — how much of the film
      // is on the phone, and that it stays while Zeus is open (it is
      // deleted only when Zeus closes or the viewer cancels it).
      final temp = _tempDownload;
      if (temp != null) {
        buffer.writeln(tempDownloadOverlayLine(temp.snapshot, _duration));
      }
    }
    final text = buffer.toString().trimRight();
    if (_mpvStatsText.value != text) _mpvStatsText.value = text;
  }

  /// A bytes-per-second figure in human units (`cache-speed` arrives
  /// as raw bytes).
  String _formatBytesPerSec(String? raw) {
    final value = double.tryParse(raw ?? '');
    if (value == null) return '?';
    if (value >= 1048576) {
      return '${(value / 1048576).toStringAsFixed(1)} MiB/s';
    }
    if (value >= 1024) return '${(value / 1024).toStringAsFixed(0)} KiB/s';
    return '${value.toStringAsFixed(0)} B/s';
  }

  /// The label a thermal switch's toast names ("1080p", "720p"): the
  /// target stream's height, or a generic word when it has none.
  String _thermalTargetLabel(int index) {
    if (index < 0 || index >= _streams.length) return 'a lower quality';
    final quality = _streams[index].quality;
    return quality != null && quality > 0 ? '${quality}p' : 'a lower quality';
  }

  void _armWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(_kStartupWatchdog, () {
      if (_disposed || _startedPlaying) return;
      // Nothing is playing after the budget: this source is dead.
      if (kDebugMode) {
        debugPrint('mpv watchdog: no playback in $_kStartupWatchdog');
      }
      _failedStreams.add(_streamIndex);
      _publishPanelData();
      _tryNextStream();
    });
  }

  /// Build 78: whether the slow-proxy watch should be listening: the
  /// film on screen is playing through the proxy, has started, and is
  /// not in the middle of a renderer move or its opening pre-buffer.
  bool get _proxyWatching =>
      _proxyHandle != null &&
      _proxyIndex == _streamIndex &&
      _startedPlaying &&
      !_awaitingPrebuffer &&
      _engineReady &&
      !rendererSwitching(_rendererPhase);

  /// Build 78: the film keeps stopping to buffer through the proxy:
  /// open it straight from the host, where it was fine before build 77.
  void _leaveSlowProxy() {
    if (_disposed) return;
    final index = _streamIndex;
    _proxySlowWatch.disarm();
    _proxySlow.add(index);
    _proxyBlocked.add(index);
    unawaited(_openStream(index, start: _position));
  }

  /// Build 77: a source that was opened through the proxy and did not
  /// play gets one more try straight from the host before it is given
  /// up — unless the proxy had already stepped aside (then the engine
  /// was talking to the host itself and that is what failed).
  Future<void> _retryWithoutProxy(int index, StreamCacheHandle handle) async {
    final stats = await StreamCacheService.instance.stats(handle.token);
    _proxyRetrying = false;
    if (_disposed || _streamIndex != index) return;
    if (stats != null && stats.dead) {
      _tryNextStream();
      return;
    }
    _failedStreams.remove(index);
    _publishPanelData();
    final resumeAt = _position > const Duration(seconds: 5)
        ? _position
        : _openStart;
    unawaited(_openStream(index, start: resumeAt));
  }

  void _tryNextStream() {
    if (_disposed || _proxyRetrying) return;
    final handle = _proxyHandle;
    if (handle != null &&
        _proxyIndex == _streamIndex &&
        !_proxyBlocked.contains(_streamIndex)) {
      _proxyBlocked.add(_streamIndex);
      _proxyRetrying = true;
      _watchdogTimer?.cancel();
      unawaited(_retryWithoutProxy(_streamIndex, handle));
      return;
    }
    final next = _streamIndex + 1;
    if (next >= _streams.length) {
      setState(() {
        _stage = _Stage.failed;
        _error = 'No working source found.';
      });
      _publishPanelData();
      return;
    }
    // Fail over near where the viewer was, rather than from the top.
    final resumeAt = _position > const Duration(seconds: 5)
        ? _position
        : Duration.zero;
    unawaited(_openStream(next, start: resumeAt));
  }

  /// A row picked on the startup list, before anything is playing: open
  /// that source instead of the one the auto-open chose. The list stays up
  /// until the picked source plays, so a pick that fails falls over to the
  /// next one the same way. The pick is remembered so a resolve still
  /// running cannot overrule it when it returns (see _resolveAndOpen).
  void _pickFromStartup(int index) {
    if (_disposed || index < 0 || index >= _streams.length) return;
    if (index == _streamIndex && !_startedPlaying) return;
    _pickedIndex = index;
    // Build 74: a row tapped in the startup list before anything has
    // played starts from the saved position, as the automatic pick
    // does — it used to start at 00:00, because the resume point is
    // only read after the resolve this tap cuts short.
    var start = _position;
    if (start <= Duration.zero && !_startedPlaying) {
      try {
        start =
            resumePointFor(
              read: _read,
              item: widget.item,
              episode: _currentEpisode,
              videoUrl: _currentVideoUrl,
            )?.position ??
            Duration.zero;
      } catch (_) {
        start = Duration.zero;
      }
    }
    unawaited(_openStream(index, start: start));
  }

  /// A source picked in the panel's Sources tab: open it from where the
  /// viewer was, as the stock screen does.
  Future<void> _pickSource(int index) async {
    if (_disposed || index < 0 || index >= _streams.length) return;
    if (index == _streamIndex) return;
    await _openStream(index, start: _position);
  }

  /// Re-applies the audio/subtitle picks the viewer made in the panel, when
  /// a new source reports its tracks (mpv resets tracks to auto on open).
  void _applyRememberedTracks() {
    final audioId = _rememberedAudioId;
    if (audioId != null) {
      unawaited(_adapter.setAudioTrack(audioId));
    }
    final subtitleId = _rememberedSubtitleId;
    if (subtitleId != null) {
      unawaited(_adapter.setSubtitleTrack(subtitleId));
    }
  }

  /// The persisted last audio pick, or null when there is none — or it is
  /// unreadable. A corrupted box reads as no pick, and mpv's own default
  /// stands, which is where the viewer would have been anyway.
  RememberedTrack? _readLastAudioPick() {
    try {
      final stored = ref
          .read(settingsRepositoryProvider)
          .getPlayerSetting<String>(_kLastAudioPickKey);
      if (stored == null || stored.isEmpty) return null;
      return RememberedTrack.fromJson(jsonDecode(stored));
    } catch (_) {
      return null;
    }
  }

  /// Persists the opened source for this title (see [streamSourceKey],
  /// [readLastSourceMap]). Fire-and-forget, like the audio pick: a write
  /// that fails just means the next open picks fresh.
  void _rememberSource(StreamResult stream) {
    try {
      final map = readLastSourceMap(ref.read);
      map[widget.item.url] = streamSourceKey(stream);
      unawaited(
        ref
            .read(settingsRepositoryProvider)
            .setPlayerSetting(kLastSourceByTitleKey, jsonEncode(map)),
      );
    } catch (_) {
      // No memory is better than a crash mid-open.
    }
  }

  /// Puts the audio the viewer wants on, once the tracks are known.
  ///
  /// mpv picks its audio at loadfile from the tracks it has seen so far —
  /// for HLS that list is still settling, so it can lock onto a track
  /// (Tamil) that is not the one the settled list resolves to (Hindi),
  /// and it never re-selects. Nothing on this screen corrected that: the
  /// viewer's pick is only re-applied when one was made in this session
  /// ([_applyRememberedTracks]), and the audio-language setting was never
  /// read here at all.
  ///
  /// Runs on every tracks event until the pick is set for this open, and
  /// once more on first play (the list may have settled by then): the
  /// setting's language first ([findPreferredAudioTrack] — a Hindi DD 5.1
  /// already playing is not moved to a Hindi 2.0 for being listed first),
  /// else the last pick the viewer made ([_lastAudioPick] — the viewer
  /// taps Hindi every time, so AUTO plays Hindi even with no language set
  /// in Settings), else mpv's own default from the LIVE list. Setting the
  /// track mpv already plays is a no-op, so re-running while the list
  /// settles only corrects the pick; a pick the viewer made wins and is
  /// never touched. A language not in the list yet returns early and
  /// retries on the next tracks event — never a delayed guess, the list
  /// itself is the clock.
  ///
  /// +5: the +4 version read the AUTO default from the published adapter
  /// snapshot (`_adapter.value.activeAudioTrackId`), which is STALE when
  /// the tracks listener runs — the listener fires before the adapter
  /// publishes, so on the first tracks event it read null and returned
  /// early, and on a direct file there is no second tracks event to retry
  /// on. That is why +4 fixed the setting (its branch reads the live
  /// list) but not AUTO (Tamil played while the drawer showed Hindi). The
  /// AUTO branch now reads the live list too, and applies the last pick
  /// before falling back to the live default.
  Future<void> _applyAudioAutoSelect() async {
    if (_disposed || _rememberedAudioId != null) return;
    // The LIVE track list, not the published snapshot: the tracks
    // listener runs before the adapter publishes (see above).
    final tracks = await _adapter.getAudioTracks();
    if (_disposed || _rememberedAudioId != null) return;
    if (tracks.isEmpty)
      return; // Not ready yet: retry on the next tracks event.
    final preferred = _preferredAudioToPick;
    int? targetId;
    if (preferred != null && preferred.isNotEmpty) {
      final match = findPreferredAudioTrack(
        tracks,
        preferred,
        activeId: _adapter.value.activeAudioTrackId,
      );
      if (match == null)
        return; // Not in the list yet: retry on the next tracks event.
      targetId = match.id;
    } else {
      // AUTO: the last pick the viewer made first — matched by language
      // and name, never by list position, so a settled list that moved
      // still finds it — else mpv's own default from the live list, set
      // explicitly so the engine plays what the drawer shows.
      final lastPick = _lastAudioPick;
      final remembered = lastPick != null
          ? matchRememberedTrack(tracks, lastPick)
          : null;
      targetId = remembered?.id ?? _adapter.liveDefaultAudioTrackId;
      if (targetId == null) return; // No tracks yet.
    }
    if (targetId == _audioAutoSelectSetId &&
        _audioAutoSelectSetFor == _streamIndex) {
      return; // Already set for this open.
    }
    await _adapter.setAudioTrack(targetId);
    if (_disposed || _rememberedAudioId != null) return;
    _audioAutoSelectSetId = targetId;
    _audioAutoSelectSetFor = _streamIndex;
  }

  /// Picks a subtitle without being asked: the plugin's own subtitle file
  /// first (usually the right language), else the first embedded track.
  /// Runs once per source, when mpv reports its tracks — and never over a
  /// pick the viewer already made.
  void _applySubtitleAutoSelect() {
    if (_disposed || _subtitleAppliedFor == _streamIndex) return;
    if (_rememberedSubtitleId != null) {
      _subtitleAppliedFor = _streamIndex;
      return;
    }
    final stream = _selected;
    if (stream == null) return;
    final embedded = _player.state.tracks.subtitle;
    final external = stream.subtitles ?? const [];
    if (external.isNotEmpty) {
      final first = external.first;
      // The adapter's `setSubtitleTrack` is idempotent and this selector
      // is not (+25): a second `sub-add` of the same file would leave a
      // duplicate of it in mpv's track list, and `state.subtitle` would
      // carry the line twice. Skip when the file is already current — the
      // same check the adapter makes.
      final current = _player.state.track.subtitle;
      if (!(current.uri == true && current.id == first.url)) {
        unawaited(
          _player.setSubtitleTrack(
            SubtitleTrack.uri(first.url, title: first.label),
          ),
        );
      }
      _subtitleAppliedFor = _streamIndex;
      return;
    }
    if (embedded.isNotEmpty) {
      // The engine's list leads with the `auto` and `no` sentinels,
      // which are not tracks: setting the first of them left the state
      // on 'auto' while mpv played its pick, so the drawer read "Off"
      // under a rendering subtitle. The default-flagged track is mpv's
      // own pick with no language preference set; else the first real
      // track — and the state is concrete from here on, so the drawer
      // shows the track that is actually playing.
      final real = embedded
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList(growable: false);
      if (real.isNotEmpty) {
        final def = real.indexWhere((t) => t.isDefault == true);
        final pick = real[def >= 0 ? def : 0];
        // As above: skip when the pick is already the current track, so a
        // re-run of this selector never issues a second set for it.
        if (_player.state.track.subtitle.id != pick.id) {
          unawaited(_player.setSubtitleTrack(pick));
        }
        _subtitleAppliedFor = _streamIndex;
      }
    }
  }

  /// Whether the subtitles button shows at all: only when this media has a
  /// subtitle to pick — an embedded track, or a file the source shipped.
  void _updateHasSubtitles() {
    final embedded = _player.state.tracks.subtitle;
    final external = _selected?.subtitles ?? const [];
    _hasSubtitles.value = embedded.isNotEmpty || external.isNotEmpty;
  }

  /// Looks up intro/outro segments in the background.
  ///
  /// Never awaited by the open path: both sources are network lookups
  /// against crowdsourced databases, and playback must not wait on a
  /// convenience.
  Future<void> _loadSkipSegments(Episode? episode) async {
    if (episode == null) return;
    // Dramas: IntroDB is keyed by IMDb id, and an item that skipped the
    // details screen may not have one yet — enrich it first so the
    // lookup below still finds its intro. Background only, never
    // awaited by the open path; on any failure the unenriched item is
    // used as-is and IntroDB simply returns [] without an IMDb id.
    var item = widget.item;
    if (item.imdbId == null) {
      try {
        item = await ref
            .read(metadataResolutionServiceProvider)
            .enrichWithIds(item);
      } catch (_) {
        // Keep the original item.
      }
    }
    // +56: keep the enriched item for the AniSkip lookup below (see
    // [_enrichedItem]): Simkl needs its tmdbId/imdbId, and the
    // original item has neither when the plugin filed no sync ids.
    // Set even when enrichment changed nothing, so [_maybeLoadAniSkip]
    // knows the ids are final and stops deferring.
    if (!_disposed) {
      _enrichedItem = item;
      _skipEnrichmentDone = true;
    }
    final segments = await fetchSkipSegments(
      read: _read,
      item: item,
      episode: episode,
    );
    if (_disposed) return;
    if (segments.isNotEmpty) {
      setState(() => _skipSegments = segments);
    }
    // Anime: AniSkip needs the episode length, which mpv only learns
    // once the stream opens — the duration listener below calls
    // [_maybeLoadAniSkip] when it arrives; this call covers the case
    // where it is already known.
    _maybeLoadAniSkip();
  }

  /// Fetches AniSkip (aniskip.com) OP/ED segments for the current anime
  /// episode, once per episode, as soon as mpv knows the episode length
  /// (the API requires it). Called from the duration listener and from
  /// [_loadSkipSegments]; the attempt key makes repeat calls cheap.
  void _maybeLoadAniSkip() {
    final episode = _currentEpisode;
    if (_disposed || episode == null) return;
    if (widget.item.contentType != MultimediaContentType.anime) return;
    if (_duration <= Duration.zero) return;
    // +56: the plugin filed no MAL/AniList id and the enrichment has
    // not finished yet — do NOT consume the attempt. The trailing call
    // in [_loadSkipSegments] runs the full chain once the ids are in;
    // a title-only attempt now would resolve through the AniList title
    // search before Simkl (the exact lookup, by tmdbId/imdbId) ever
    // got its chance. When the plugin DID file an id, or enrichment
    // is done, there is nothing to wait for.
    final sync = widget.item.syncData;
    if (AniskipService.malIdFromSyncData(sync) == null &&
        AniskipService.anilistIdFromSyncData(sync) == null &&
        !_skipEnrichmentDone) {
      return;
    }
    final key = '${widget.item.url}|${episode.url}|${episode.episode}';
    if (_aniskipAttemptedKey == key) return;
    _aniskipAttemptedKey = key;
    unawaited(_loadAniSkipSegments(episode, _duration));
  }

  Future<void> _loadAniSkipSegments(Episode episode, Duration duration) async {
    // +56: the MAL id the player asks AniSkip with. The plugin's own
    // sync data wins when it filed one; otherwise the id is resolved
    // here, in the player — Simkl on the enriched item (the details
    // screen's proven path), then the AniList title search inside the
    // service as a last resort. Miruro/Anikoto file no sync ids at
    // all, so without this the lookup never ran and no button ever
    // appeared (Attack on Titan S1E2 on +55: AniSkip HAS the OP data,
    // the app never asked).
    final service = ref.read(aniskipServiceProvider);
    final sync = widget.item.syncData;
    var malId = AniskipService.malIdFromSyncData(sync);
    var anilistId = AniskipService.anilistIdFromSyncData(sync);
    if (malId == null && anilistId == null) {
      final resolved = await _resolveSyncIdsViaSimkl();
      if (resolved != null) {
        malId = AniskipService.malIdFromSyncData(resolved);
        anilistId = AniskipService.anilistIdFromSyncData(resolved);
      }
    }
    final segments = await service.getSkipSegments(
      malId: malId,
      anilistId: anilistId,
      title: widget.item.title,
      episode: episode.episode > 0 ? episode.episode : 1,
      duration: duration.inSeconds,
    );
    if (_disposed || segments.isEmpty) return;
    // Title-specific AniSkip data beats the crowd-averaged IntroDB
    // answer, the same rule `fetchSkipSegments` applies to AnimeSkip.
    setState(() => _skipSegments = segments);
  }

  /// +56: Simkl sync ids for this title, on the enriched item
  /// ([_enrichedItem] — its tmdbId/imdbId are what Simkl is looked up
  /// by, exactly as the details screen does it). Cached per item URL
  /// so a series is resolved once, not once per episode; only a
  /// successful resolution is cached. Null when there is nothing to
  /// look up with, when Simkl finds nothing, or on any error — the
  /// AniList title search in the service is the fallback then, and a
  /// title Simkl cannot resolve is retried next episode rather than
  /// cached as a miss.
  Future<Map<String, String>?> _resolveSyncIdsViaSimkl() async {
    if (_resolvedSyncIdsForUrl == widget.item.url && _resolvedSyncIds != null) {
      return _resolvedSyncIds;
    }
    final enriched = _enrichedItem ?? widget.item;
    if (enriched.tmdbId == null && enriched.imdbId == null) return null;
    try {
      final resolved = await ref.read(simklServiceProvider).syncIds(enriched);
      if (resolved.isNotEmpty) {
        _resolvedSyncIds = resolved;
        _resolvedSyncIdsForUrl = widget.item.url;
        return resolved;
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AniSkip: Simkl id lookup failed: $e');
      }
      return null;
    }
  }

  // -- panel ---------------------------------------------------------------

  /// What the side panel shows, published from every place it changes.
  void _publishPanelData() {
    if (_disposed) return;
    _panelData.value = PanelData(
      sources: _streams,
      currentSourceIndex: _stage == _Stage.failed ? -1 : _streamIndex,
      failedSources: Set<int>.unmodifiable(_failedStreams),
      playedSources: _startedPlaying ? <int>{_streamIndex} : const <int>{},
      lastUsedSourceIndex: _lastUsedIndex,
      dataSaver: _dataSaver,
      preferredLanguage:
          ref
              .read(playerSettingsProvider)
              .asData
              ?.value
              .preferredSourceLanguage ??
          SourceLanguage.off,
      // mpv's ABR picks the rendition: no quality ladder, so no Quality tab.
      qualityLadder: const <int>[],
      episodes: effectiveEpisodes(widget.item, _currentEpisode),
      currentEpisode: _currentEpisode,
      subtitleTarget: SubtitleSearchTarget.of(widget.item, _currentEpisode),
    );
  }

  /// How much of [episode] the viewer has already seen, for the Episodes
  /// Episodes tab. Asked per row as the list builds it, never precomputed.
  EpisodeProgress _episodeProgressFor(Episode episode) {
    final mainUrl = widget.item.url;
    if (ref.read(episodeWatchRepositoryProvider).isWatched(mainUrl, episode)) {
      return const EpisodeProgress(watched: true);
    }
    final history = ref.read(historyRepositoryProvider);
    final duration = history.getEpisodeDuration(
      episode.url,
      mainUrl: mainUrl,
      season: episode.season,
      episode: episode.episode,
    );
    if (duration <= 0) return EpisodeProgress.none;
    final position = history.getEpisodePosition(
      episode.url,
      mainUrl: mainUrl,
      season: episode.season,
      episode: episode.episode,
    );
    return EpisodeProgress(fraction: (position / duration).clamp(0.0, 1.0));
  }

  /// How long [episode] is, for the Episodes drawer: the history's exact
  /// duration first, else the plugin's runtime in minutes.
  Duration? _episodeDurationFor(Episode episode) {
    final mainUrl = widget.item.url;
    final history = ref.read(historyRepositoryProvider);
    return episodeDurationFromHistoryMs(
      history.getEpisodeDuration(
        episode.url,
        mainUrl: mainUrl,
        season: episode.season,
        episode: episode.episode,
      ),
      runtimeMinutes: episode.runtime,
    );
  }

  // -- episodes -------------------------------------------------------------

  /// Switches to another episode in place: the current episode's progress
  /// is flushed, the engine is stopped, and the new episode resolves and
  /// opens through the same startup list. A saved position on the new
  /// episode resumes from there.
  Future<void> _pickEpisode(Episode next) async {
    if (_disposed || _advancing || next == _currentEpisode) return;
    _advancing = true;
    try {
      _flushProgress();
      try {
        _tracker?.finish();
      } catch (_) {}
      rollForwardHistory(read: _read, item: widget.item, next: next);
      await _startEpisode(next);
    } finally {
      _advancing = false;
    }
  }

  /// The next episode, or the previous one, from the chrome's arrows.
  Future<void> _advance() async {
    if (_disposed || _advancing) return;
    final next = nextEpisodeFor(
      item: widget.item,
      current: _currentEpisode,
      videoUrl: _currentVideoUrl,
    ).next;
    if (next == null) return;
    await _pickEpisode(next);
  }

  Future<void> _goToPreviousEpisode() async {
    if (_disposed || _advancing) return;
    final previous = _previousEpisode;
    if (previous == null) return;
    await _pickEpisode(previous);
  }

  Future<void> _startEpisode(Episode next) async {
    _sample = null;
    _streams = const [];
    _streamIndex = 0;
    _lastUsedIndex = -1;
    _dataSaver = false;
    _failedStreams.clear();
    _proxyBlocked.clear();
    _proxySlow.clear();
    _probes.clear();
    _pickedIndex = null;
    _resolveDone = false;
    _startedPlaying = false;
    _subtitleAppliedFor = -1;
    _rememberedAudioId = null;
    _rememberedSubtitleId = null;
    _adapter.noteNewSource();
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffered = Duration.zero;
    _resumePosition = Duration.zero;
    _recorder = null;
    _skipSegments = const <SkipSegment>[];
    _aniskipAttemptedKey = null;
    _enrichedItem = null;
    _skipEnrichmentDone = false;
    _resumeStallTimer?.cancel();
    _resumeStallTimer = null;
    _wasPlayingBeforeBackground = false;
    _resumeStallPosition = Duration.zero;
    _nextEpisodeOffer = null;
    _nextEpisodeDeclined = false;
    _offerBeforeEnd = false;
    _outroOffered = false;
    _ended = null;
    _currentEpisode = next;
    _currentVideoUrl = next.url;
    await _player.stop();
    if (_disposed) return;
    setState(() => _stage = _Stage.resolving);
    _publishPanelData();
    await _resolveAndOpen();
  }

  // -- ended / up-next ------------------------------------------------------

  /// Build 106: the engine reported the media finished far short of
  /// its known duration — a stream that died mid-film, not an ending
  /// (the phone: the origin fallback played the CJ ENM logo to 00:11
  /// of a 1:07:30 episode, then "You've finished"). The progress is
  /// deliberately NOT flushed as finished: the episode is not done.
  ///
  /// First time on this source, the film is reopened from the start
  /// through the proxy — the proxy is the one path that sustained
  /// playback from the start (it buffers ahead and smooths a trickling
  /// host), and the origin is what just died. The proxy block/slow
  /// marks are cleared for this one recovery, so the reopen really
  /// goes through the proxy. If that recovery false-ends too, the
  /// source is failed over to the next candidate instead of looping
  /// on the same eleven seconds forever.
  void _onFalseEnd() {
    if (_disposed || !mounted) return;
    // Build 107: a false end while playing the local temp file with
    // the download still running is just the demuxer reaching the end
    // of the file as it stands — the file has grown since. Reopen the
    // local file where playback stopped (capped: a third one falls
    // through to the ordinary false-end path, which reopens the stream
    // from the start).
    if (_playingLocalTemp && _tempLocalUrl != null) {
      final temp = _tempDownload;
      if (temp != null &&
          temp.status != TempDownloadStatus.complete &&
          _localFalseEndCount < 2) {
        _localFalseEndCount++;
        unawaited(
          _openStream(
            _streamIndex,
            start: _position,
            keepSession: true,
            skipPrebuffer: true,
            localFileUrl: _tempLocalUrl,
          ),
        );
        return;
      }
    }
    _falseEndRecoveries++;
    switch (falseEndRecovery(recoveries: _falseEndRecoveries)) {
      case FalseEndRecovery.reopenFromStart:
        _proxyBlocked.remove(_streamIndex);
        _proxySlow.remove(_streamIndex);
        try {
          ref
              .read(notificationServiceProvider)
              .showInfo(
                'Stream ended early — reopening from the start',
                title: 'Stream interrupted',
              );
        } catch (_) {}
        unawaited(_openStream(_streamIndex, start: Duration.zero));
      case FalseEndRecovery.failover:
        // The proxy-from-start recovery died the same way: this source
        // is done. Mark it blocked first, so [_tryNextStream] goes to
        // the next candidate instead of retrying the origin that just
        // ended it.
        _proxyBlocked.add(_streamIndex);
        _tryNextStream();
    }
  }

  /// The engine reached the end of the media. Everything that is a failure
  /// wearing an ending's clothes is caught before this (the watchdog, the
  /// failover); here the film or episode really finished.
  void _onEnded() {
    if (_disposed || !mounted) return;
    // Build 119: the episode ended — the temp download stops but its
    // file is KEPT (see [_stopTempDownload]), so rewatching the
    // episode resumes from the bytes already fetched. The file is
    // deleted only when Zeus closes or the viewer cancels it.
    unawaited(_stopTempDownload());
    // Sleep timer (v7): "End of episode", or a timed sleep that already
    // fired, stops here — the next episode is neither offered nor
    // auto-played. The ended card keeps its Next button when an episode
    // follows, so the viewer can carry on by hand.
    if (_sleepTimer.consumeEpisodeEnd()) {
      _nextEpisodeOffer = null;
      _showSleepNotice();
      _showEnded(_hasNextEpisode ? EndedKind.declinedNext : EndedKind.finished);
      return;
    }
    // v7: what follows is one decision (see [endOfEpisodeAction]) — the
    // 5 s card, a silent advance in picture-in-picture, or the ended card
    // (with Next episode on it when auto-play is off or was cancelled).
    // A film or a last episode never advances.
    switch (endOfEpisodeAction(
      hasNext: _hasNextEpisode && !_isLive,
      autoPlay: _autoPlayNext,
      declined: _nextEpisodeDeclined,
      inPip: _inPip,
    )) {
      case EndOfEpisodeAction.countdown:
        // A card raised at the outro is already counting; from here on it
        // belongs to the ending (Cancel shows the ended card).
        if (_nextEpisodeOffer != null) {
          setState(() => _offerBeforeEnd = false);
        } else {
          _offerNextEpisodeNow(atEnd: true);
        }
      case EndOfEpisodeAction.advanceSilently:
        // In PiP nothing of this screen is visible, so there is no card:
        // the next episode opens in the same player.
        if (_nextEpisodeOffer != null) {
          setState(() => _nextEpisodeOffer = null);
        }
        unawaited(_advance());
      case EndOfEpisodeAction.endedWithNext:
        if (_nextEpisodeOffer != null) {
          setState(() => _nextEpisodeOffer = null);
        }
        _showEnded(EndedKind.declinedNext);
      case EndOfEpisodeAction.ended:
        _showEnded(EndedKind.finished);
    }
  }

  // Build 107: progressive "download while watching" for a host that
  // does not serve ranges (see `temp_download.dart`). The stream plays
  // from the start while the film is fetched into the app's temp
  // directory; a seek to a downloaded position reopens the local temp
  // file at it, where seeking is instant, and a seek past the frontier
  // waits with honest progress. The file is deleted when the player
  // closes, when the episode ends, or when a new film opens — it never
  // reaches Documents, and never outlives the film.
  //
  // The trigger is the proxy's own verdict: only a source that opened
  // with `proxy: off(no range)` earns a download, and only once per
  // source. 206 sources, HLS, DASH and local files never start one.

  /// Build 120: the episode's stable identity for the temp file's
  /// key — the episode page URL, or, for a series opened without an
  /// episode object, the token that names the episode (the same
  /// fallback progress uses). Movies have no episode, so null. The
  /// write path ([_maybeStartTempDownload]) and the read path
  /// ([_tryOpenKeptTempFile]) both use it, so the same film always
  /// computes the same key.
  String? get _tempFileEpisodeKey {
    final episode = _currentEpisode;
    if (episode != null) return episode.url;
    if (widget.item.contentType == MultimediaContentType.series ||
        widget.item.contentType == MultimediaContentType.anime) {
      return _currentVideoUrl;
    }
    return null;
  }

  /// Starts the temp download for the film on screen, when it earns
  /// one. Called from first play and from the duration event —
  /// whichever lands first — and guarded to run once per source.
  Future<void> _maybeStartTempDownload() async {
    if (_disposed || _tempDownloadTried || _tempDownload != null) return;
    if (_duration <= Duration.zero) return;
    if (_streamIndex < 0 || _streamIndex >= _streams.length) return;
    final stream = _streams[_streamIndex];
    // Build 120: the proxy verdict gates the download — except when the
    // film is already playing from its kept temp file (the fast path):
    // a local open has no proxy verdict, and the fetch must resume so
    // the file keeps growing past the frontier.
    if (_proxyOff != 'no range' && !_playingLocalTemp) return;
    if (!isTempDownloadEligible(stream: stream, item: widget.item)) return;
    _tempDownloadTried = true;
    _localFalseEndCount = 0;
    try {
      final dir = await appTempDirectory();
      final temp = TempDownload(
        url: stream.url,
        headers: stream.headers,
        directory: dir,
        duration: _duration,
        // Build 120: the file is keyed by the film + source, not by the
        // stream URL — signed URLs are re-issued on every load, so a
        // URL hash orphans the kept file (b119's bug, phone-proven).
        fileKey: tempFileKeyFor(
          itemUrl: widget.item.url,
          episodeKey: _tempFileEpisodeKey,
          sourceKey: streamSourceKey(stream),
        ),
      );
      if (_disposed) {
        // Build 119: dropped mid-start — the player is gone and this
        // download never started, so its file goes with it (see
        // [TempDownload.cancel]). A kept file from an earlier open is
        // only at risk in this narrow race; the normal player-close
        // path keeps it (see [TempDownload.stop]).
        await temp.cancel();
        return;
      }
      // A different film opened while the directory resolved: it
      // reset [_tempDownloadTried], so this download belongs to the
      // old one — drop it.
      if (_tempDownload != null || !_tempDownloadTried) {
        await temp.cancel();
        return;
      }
      _tempDownload = temp;
      _tempDownloadSub = temp.progress.listen(_onTempDownloadProgress);
      final started = await temp.start();
      if (_disposed) return;
      if (!started) {
        // The probe said this host does serve ranges, or failed:
        // stream-only, exactly as before.
        _tempDownload = null;
        unawaited(_tempDownloadSub?.cancel());
        _tempDownloadSub = null;
        await temp.dispose();
      } else if (_resumePosition > Duration.zero &&
          !_playingLocalTemp &&
          temp.isDownloaded(_resumePosition)) {
        // Build 119: the kept file from an earlier open already
        // covers the resume position — open it at once instead of
        // playing the stream while the download re-fetches from byte
        // 0. That re-fetch is what made Continue Watching slow.
        // (Build 120: not when the film is already playing from the
        // local file — reopening at the old resume point would jump
        // playback backwards.)
        unawaited(_openLocalTempFile(_resumePosition));
      }
    } catch (_) {
      // A temp download that cannot start must never break playback.
      _tempDownload = null;
    }
  }

  /// A progress tick from the temp download: the gold band on the seek
  /// bar, and — when a seek is waiting for its bytes — the reopen the
  /// moment they arrive.
  void _onTempDownloadProgress(TempDownloadProgress progress) {
    if (_disposed) return;
    _downloadedFraction.value = progress.fraction(_duration);
    final pending = _pendingTempSeek;
    final temp = _tempDownload;
    if (pending != null && temp != null) {
      if (temp.isDownloaded(pending)) {
        _pendingTempSeek = null;
        unawaited(_openLocalTempFile(pending));
      } else if (temp.status == TempDownloadStatus.failed ||
          temp.status == TempDownloadStatus.stopped) {
        // The bytes are never coming (the fetch died, or the download
        // was stopped and the file kept): give the seek back to the
        // engine (the stream), rather than opening a local file that
        // does not hold the target.
        _pendingTempSeek = null;
        if (!_disposed) unawaited(_player.seek(pending));
      }
    }
    if (mounted) setState(() {});
  }

  /// The seek handler the adapter asks first (see
  /// [MpvVlcController.onSeekRequested]). True means the screen handled
  /// the seek and the engine is not told to seek.
  Future<bool> _handleTempSeekRequest(Duration target) async {
    final temp = _tempDownload;
    if (temp == null || _disposed) return false;
    if (_playingLocalTemp) {
      // Already on the local file: a seek inside what is downloaded
      // is instant (the engine seeks in a local file natively); a seek
      // past the frontier waits for its bytes.
      if (temp.isDownloaded(target)) return false;
      _setPendingTempSeek(target);
      return true;
    }
    switch (tempSeekAction(
      download: temp,
      target: target,
      duration: _duration,
    )) {
      case TempSeekAction.normalSeek:
        return false;
      case TempSeekAction.openLocalFile:
        await _openLocalTempFile(target);
        return true;
      case TempSeekAction.waitForDownload:
        _setPendingTempSeek(target);
        return true;
    }
  }

  /// Records a seek past the downloaded frontier: the player keeps
  /// playing the stream meanwhile, and [_onTempDownloadProgress]
  /// reopens the local file the moment the bytes arrive.
  void _setPendingTempSeek(Duration target) {
    _pendingTempSeek = target;
    if (mounted) setState(() {});
  }

  /// Reopens the film on the local temp file at [target]: the
  /// `keepSession: true` open keeps the tracker and recorder, so
  /// history and Continue Watching carry on as if nothing happened.
  Future<void> _openLocalTempFile(Duration target) async {
    final temp = _tempDownload;
    if (temp == null || _disposed) return;
    final localUrl = AppUtils.normalizeUrl(temp.localFilePath);
    _playingLocalTemp = true;
    _tempLocalUrl = localUrl;
    _pendingTempSeek = null;
    await _openStream(
      _streamIndex,
      start: target,
      keepSession: true,
      skipPrebuffer: true,
      localFileUrl: localUrl,
    );
    if (mounted) setState(() {});
  }

  /// Stops the temp download but KEEPS its file (b119): player close,
  /// episode end, or a new film. The file lives as long as Zeus is
  /// open, so reopening the film resumes from it; it is deleted only
  /// when Zeus closes or the viewer cancels the download. The next
  /// film may start its own download ([_tempDownloadTried] resets —
  /// b107 left it set after an episode ended, so episode 2 never got
  /// a temp download).
  Future<void> _stopTempDownload() async {
    final temp = _tempDownload;
    _tempDownload = null;
    _tempDownloadTried = false;
    _pendingTempSeek = null;
    _playingLocalTemp = false;
    _tempLocalUrl = null;
    _localFalseEndCount = 0;
    await _tempDownloadSub?.cancel();
    _tempDownloadSub = null;
    if (temp != null) await temp.stop();
    _downloadedFraction.value = 0;
    if (!_disposed && mounted) setState(() {});
  }

  /// Cancels the temp download and deletes its file: ONLY the viewer
  /// tapping "Cancel download" on the indicator. Everything else
  /// (player close, episode end, a new film) keeps the file — see
  /// [_stopTempDownload]. The viewer cancelled, so the download is
  /// not retried for this film ([_tempDownloadTried] stays set).
  Future<void> _cancelTempDownload() async {
    final temp = _tempDownload;
    _tempDownload = null;
    _pendingTempSeek = null;
    _playingLocalTemp = false;
    _tempLocalUrl = null;
    _localFalseEndCount = 0;
    await _tempDownloadSub?.cancel();
    _tempDownloadSub = null;
    if (temp != null) await temp.cancel();
    _downloadedFraction.value = 0;
    if (!_disposed && mounted) setState(() {});
  }

  /// Raises the up-next countdown card for the following episode.
  /// [atEnd]: the episode has ended; otherwise it is still playing (the
  /// outro, or a tap on Skip outro).
  void _offerNextEpisodeNow({bool atEnd = false}) {
    if (_disposed || !mounted) return;
    if (_advancing || _isLive) return;
    final next = nextEpisodeFor(
      item: widget.item,
      current: _currentEpisode,
      videoUrl: _currentVideoUrl,
    ).next;
    if (next == null) return;
    setState(() {
      _nextEpisodeDeclined = false;
      _nextEpisodeOffer = next;
      _offerBeforeEnd = !atEnd;
    });
  }

  /// v7: raises the card when an outro that runs to the end of the file
  /// starts (see [shouldOfferAtOutro]) — once per episode.
  void _maybeOfferAtOutro(Duration position) {
    if (_outroOffered || _skipSegments.isEmpty || _isLive) return;
    if (!_playing || _ended != null || _advancing) return;
    final seconds = position.inMilliseconds / 1000;
    final duration = _duration.inMilliseconds / 1000;
    for (final segment in _skipSegments) {
      if (segment.type != SkipType.outro) continue;
      if (!shouldOfferAtOutro(
        hasNext: _hasNextEpisode,
        autoPlay: _autoPlayNext,
        declined: _nextEpisodeDeclined,
        inPip: _inPip,
        alreadyOffered: _outroOffered,
        cardUp: _nextEpisodeOffer != null,
        stopRequested: _sleepTimer.blocksNextEpisode,
        positionSeconds: seconds,
        durationSeconds: duration,
        outroStart: segment.startTime,
        outroEnd: segment.endTime,
      )) {
        continue;
      }
      _outroOffered = true;
      _offerNextEpisodeNow();
      return;
    }
  }

  // -- sleep timer (v7) -----------------------------------------------------

  /// A timed sleep ran out: pause (the player stays open) and say so. An
  /// up-next countdown that is already on screen is withdrawn too, so it
  /// cannot auto-play the next episode over a sleeping viewer.
  void _onSleepTimerFired() {
    if (_disposed || !mounted) return;
    if (_nextEpisodeOffer != null) {
      setState(() => _nextEpisodeOffer = null);
      _showEnded(EndedKind.declinedNext);
    }
    if (_stage == _Stage.playing) {
      unawaited(_player.pause());
      _showSleepNotice();
    } else {
      // An episode is still loading: pause it the moment it starts.
      _sleepPausePending = true;
    }
  }

  /// Playback started. Either the pause a fired sleep still owes (see
  /// [_sleepPausePending]), or the viewer playing again after a sleep —
  /// which ends the sleep, so the next ending behaves normally.
  void _onSleepPlayingChanged() {
    if (_sleepPausePending) {
      _sleepPausePending = false;
      unawaited(_player.pause());
      _showSleepNotice();
      return;
    }
    _sleepTimer.noteResumed();
  }

  void _showSleepNotice() {
    if (!mounted) return;
    ref
        .read(notificationServiceProvider)
        .showInfo(
          AppLocalizations.of(context)!.playerSleepTimerPaused,
          icon: Icons.bedtime_rounded,
        );
  }

  void _showEnded(EndedKind kind) {
    if (_disposed || !mounted || _ended == kind) return;
    // The card unmounts the whole controls subtree, and the unlock chip
    // goes with it, so a lock left standing here would have nothing on
    // screen to undo it.
    _locked.value = false;
    setState(() => _ended = kind);
  }

  /// Plays the finished media again, from the top.
  void _startOver() {
    if (_disposed) return;
    _sample = null;
    _nextEpisodeDeclined = false;
    _nextEpisodeOffer = null;
    _offerBeforeEnd = false;
    _outroOffered = false;
    setState(() => _ended = null);
    unawaited(_player.seek(Duration.zero));
    unawaited(_player.play());
  }

  // -- chrome text ----------------------------------------------------------

  /// What the top bar's subtitle says: the source the picture is coming
  /// from. Null where nothing is playing yet, and the bar then renders no
  /// second line at all rather than an empty one.
  String? _chromeSubtitle() {
    final data = _panelData.value;
    final index = data.currentSourceIndex;
    if (index < 0 || index >= data.sources.length) return null;
    final stream = data.sources[index];
    return sourceProvider(stream) ?? sourceFactsOf(stream).title;
  }

  /// "S1 E3 · Episode name", for the startup list.
  String? get _episodeLine {
    final episode = _currentEpisode;
    if (!_isSeries || episode == null) return null;
    return 'S${episode.season} E${episode.episode} · ${episode.name}';
  }

  /// The startup list's current row: the one being opened, or null while
  /// the probe race is still running (the original shows no row as current
  /// until the first open starts, unless the viewer picked one).
  int? get _startupCurrentIndex {
    if (_streams.isEmpty) return null;
    if (!_resolveDone && _pickedIndex == null) return null;
    return _streamIndex;
  }

  /// The startup list's rows, in the original's own terms: a source's
  /// reachability is what the probe race found for it — Checking… (spinner)
  /// while it is probed, a green check when it answers, Failed when it
  /// does not — and its playState is whether it is the one being opened or
  /// is already playing. The original's rows read this way because the
  /// stock screen feeds `resolvePlayback`'s `onProbe` into these same
  /// helpers; mpv now does too. Before the resolve returns (the probe
  /// race) no row is "being opened", so every playState is blank — the
  /// original leaves them blank until the first open starts.
  List<StartupRow> get _startupRows {
    return <StartupRow>[
      for (var i = 0; i < _streams.length; i++)
        StartupRow(
          label: _startupRowLabel(_streams[i]),
          server: sourceServer(_streams[i]),
          quality: sourceQualityLabel(_streams[i]),
          size: sourceSizeLabel(_streams[i]),
          reachability: sourceReachabilityOf(
            _streams[i],
            _probes[i],
            hasPlayed: _startedPlaying && i == _streamIndex,
          ),
          playState: sourcePlayStateOf(
            isCurrent: i == _streamIndex && (_resolveDone || _pickedIndex == i),
            hasPicture: _startedPlaying,
            failed: _failedStreams.contains(i),
          ),
        ),
    ];
  }

  /// The plugin's own label for the source, led by its provider, with the
  /// quality after it — "HubCloud · 1080p".
  String _startupRowLabel(StreamResult stream) {
    final base = sourceRowLabel(stream);
    final quality = stream.quality;
    return quality != null && quality > 0 ? '$base · ${quality}p' : base;
  }

  // -- build ----------------------------------------------------------------

  /// Flips the handset the other way for the rest of this video (rotate
  /// button). Only where the player turns the device at all.
  void _flipOrientation() {
    final orientation = MediaQuery.orientationOf(context);
    unawaited(
      SystemChrome.setPreferredOrientations([
        orientation == Orientation.landscape
            ? DeviceOrientation.landscapeRight
            : DeviceOrientation.landscapeLeft,
      ]),
    );
  }

  BoxFit _boxFitFor(VlcVideoFit fit) {
    return switch (fit) {
      VlcVideoFit.cover => BoxFit.cover,
      VlcVideoFit.fill => BoxFit.fill,
      _ => BoxFit.contain,
    };
  }

  /// The chrome showed or hid. The caption's padding no longer follows it
  /// (+25: one fixed base in every state), so this is a no-op for the
  /// padding unless the raise or the PiP state moved with it — the sync
  /// still runs, and its guard makes it cheap.
  void _onChromeVisibilityChanged() => _syncSubtitlePadding();

  /// Whether the bottom control row is on screen (v9): the chrome is up
  /// and the screen is not locked — locked, only the lock pill shows, and
  /// there is no row for the caption to clear.
  bool get _bottomControlsShowing => _chrome.value && !_locked.value;

  /// Pushes the current subtitle padding into the video view.
  ///
  /// media_kit's [SubtitleView] caches its padding in a `late` field at
  /// creation and has no `didUpdateWidget`, so a rebuilt
  /// [SubtitleViewConfiguration] never reaches it — the caption stays
  /// wherever it was created (high) and the Position slider / +5/−5 nudge
  /// does nothing. The only update path is
  /// [VideoState.setSubtitleViewPadding]. This runs after every build
  /// (post-frame, so a settings change moves the caption) and whenever the
  /// chrome shows or hides. Guarded on the last pushed padding so it is a
  /// no-op when nothing moved.
  ///
  /// It never runs while the source list is up ([_Stage.resolving]): no
  /// caption is visible before the first frame, and the sync — a
  /// MediaQuery read plus a setState into the video view from outside the
  /// build — must not run during the resolving window, or the list never
  /// becomes visible (2.9.17+5 regression). Once the video is playing the
  /// post-frame callback in build and the chrome listener push it as
  /// before, so the caption sits low at full size and Position moves it
  /// live.
  void _syncSubtitlePadding() {
    if (_disposed || !mounted) return;
    if (_stage == _Stage.resolving) return;
    if (_lastScreenHeight <= 0) return;
    try {
      final settings =
          ref.read(playerSettingsProvider).asData?.value ??
          const PlayerSettings();
      final padding = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: _lastScreenHeight,
        controlsVisible: _bottomControlsShowing,
        // The PiP window is a third of the screen: the caption is halved
        // and its padding shrunk, or it overflows the window (v20+24).
        // The style reaches the view on the next rebuild (it reads the
        // configuration's style fresh each build); the padding is pushed
        // here because the view caches it (see the doc above).
        isPip: _inPip,
        // A drawer open over the video (build 86): the caption shifts
        // left by its width, into the visible area.
        drawerWidth: _drawerOpenWidth,
      ).padding;
      if (padding == _lastSubtitlePadding) return;
      // Only record the padding once the view has it: if the video state
      // is not mounted yet the push is lost, and recording it would make
      // the guard above treat the caption as moved when it never did —
      // the caption would sit at its creation padding until a setting
      // changed. Returning without recording retries it on the next
      // build or chrome change. (+25)
      final videoState = _videoKey.currentState;
      if (videoState == null) return;
      _lastSubtitlePadding = padding;
      videoState.setSubtitleViewPadding(padding);
    } catch (_) {
      // A subtitle-sync failure must never break the player.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The saved subtitle style, watched so a Style-tab change restyles the
    // caption live. An unloaded provider reads as a fresh install.
    final settings =
        ref.watch(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    // The subtitle configuration for the video view. The view caches its
    // padding at creation (see _syncSubtitlePadding), so a changed
    // configuration alone does not move the caption — push the new padding
    // after the frame, only if it moved. The height is cached for the sync
    // (it runs off the build path), and the callback is only armed once the
    // video is playing: while the source list is up no caption is visible,
    // and the sync must not run during the resolving window.
    final screenHeight = MediaQuery.sizeOf(context).height;
    _lastScreenHeight = screenHeight;
    final subtitleConfig = mpvSubtitleViewConfiguration(
      settings,
      screenHeight: screenHeight,
      controlsVisible: _bottomControlsShowing,
      // PiP halves the caption (see the doc in mpv_subtitle_style.dart);
      // _inPip flips by setState, so the rebuild carries it to the view.
      isPip: _inPip,
      // A drawer open over the video (build 86): the caption shifts left
      // by its width. The post-frame sync below pushes it to the view.
      drawerWidth: _drawerOpenWidth,
    );
    if (_stage != _Stage.resolving &&
        subtitleConfig.padding != _lastSubtitlePadding) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _syncSubtitlePadding(),
      );
    }
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final form = playerFormFactorOf(profile);
    final canRotate = playerCanRotate(profile);
    final isTv = form == PlayerFormFactor.tv;

    // Android's system Back (button or swipe) leaves exactly as the
    // on-screen arrow does: stop the film, portrait, then the pop. A
    // panel or dialog is its own route and takes Back first.
    // Android only: on the iPhone the route keeps popping as it always
    // has (dispose now stops the film there too).
    return PopScope(
      canPop: defaultTargetPlatform != TargetPlatform.android,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _goBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Video. The pinch zoom is a Transform over the picture, driven by
            // the controls' gesture layer through [_videoScale]. The picture
            // is its own repaint boundary: the chrome above it rebuilds on
            // every position tick, and without the boundary each of those
            // rebuilds re-rasterizes the 4K texture layer with it.
            //
            // While the iOS mpv PiP window is up (+29) the film must NOT
            // show here as well: the software renderer would draw it twice
            // — once into this Flutter texture and once into the PiP layer
            // — saturating the CPU, starving mpv's audio thread (cut-cut
            // voice) and dropping frames. The Video widget is only a
            // consumer: the render loop is mpv-driven (VideoOutput, owned
            // by the VideoController, which this screen keeps and disposes
            // only in dispose()), so unmounting the widget stops the
            // Flutter texture path while the PiP tap keeps receiving
            // frames. A black placeholder keeps the stack's layout.
            //
            // iOS ONLY (+38): on Android the PiP window IS the Flutter UI —
            // there is no separate native feed — so unmounting here blacks
            // the window for one watchdog interval (~5 s) and defeats the
            // +24 PiP subtitle halving (the SubtitleView only exists while
            // the Video is mounted). Android keeps the Video mounted and
            // the isPip wiring halves the captions as designed.
            if ((_inPip && defaultTargetPlatform == TargetPlatform.iOS) ||
                !_engineReady)
              const ColoredBox(color: Colors.black)
            else
              ValueListenableBuilder<double>(
                valueListenable: _videoScale,
                builder: (context, scale, child) => Transform.scale(
                  scale: scale.clamp(_kMinZoom, _kMaxZoom),
                  alignment: Alignment.center,
                  child: child,
                ),
                child: RepaintBoundary(
                  child: Center(
                    child: Video(
                      key: _videoKey,
                      controller: _videoController,
                      fit: _boxFitFor(_fit),
                      fill: Colors.black,
                      // The stock controls below; media_kit's own are hidden.
                      controls: (_) => const SizedBox.shrink(),
                      wakelock: true,
                      // iOS mpv PiP (+28): when the player runs the software
                      // renderer for PiP, the film must NOT pause when the app
                      // backgrounds — the PiP window IS the background
                      // playback, and a pause here would freeze it on the
                      // first frame. Off by default: without PiP the
                      // background pause is today's behaviour.
                      pauseUponEnteringBackgroundMode: !_iosMpvPipEnabled,
                      subtitleViewConfiguration: subtitleConfig,
                    ),
                  ),
                ),
              ),

            // Build 72: a renderer move in flight — the old engine's last
            // picture (else the backdrop) covers the new engine until it
            // has a picture of its own. Never black, never interactive.
            // Build 73: the picture is the OLD engine's own texture —
            // still alive, paused — so there is no capture to wait for
            // and no moment without a picture.
            // Build 74: not during an in-place move — the video widget
            // above is still the same engine's and holds the picture.
            if (rendererSwitching(_rendererPhase) && !_inPlaceMove)
              IgnorePointer(
                child: ColoredBox(
                  color: Colors.black,
                  child: _outgoingController != null
                      ? Center(
                          child: Video(
                            key: _outgoingKey,
                            controller: _outgoingController!,
                            fit: _boxFitFor(_fit),
                            fill: Colors.black,
                            controls: (_) => const SizedBox.shrink(),
                            pauseUponEnteringBackgroundMode: false,
                            resumeUponEnteringForegroundMode: false,
                            wakelock: false,
                            subtitleViewConfiguration:
                                const SubtitleViewConfiguration(visible: false),
                          ),
                        )
                      : widget.item.backdropImageUrl.isNotEmpty
                      ? Image.network(
                          widget.item.backdropImageUrl,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const SizedBox.expand(),
                        )
                      : const SizedBox.expand(),
                ),
              ),

            // Resolving: the source list. It stays up until the first source
            // actually plays — the list is the control, and the first open is
            // automatic. Portrait, until the video itself starts playing.
            if (_stage == _Stage.resolving)
              PlayerStartupView(
                title: widget.item.title,
                episodeLine: _episodeLine,
                logoUrl: widget.item.logoUrl,
                backdropUrl: widget.item.backdropImageUrl,
                sourceName: _selected?.displaySource,
                status: _streams.isEmpty ? 'Getting links…' : null,
                attempt: _streams.isEmpty
                    ? null
                    : (index: _streamIndex + 1, total: _streams.length),
                rows: _startupRows,
                currentIndex: _startupCurrentIndex,
                onPick: _pickFromStartup,
                onBack: _goBack,
                isTv: isTv,
              ),

            // Failed: every link tried, or the resolve itself failed.
            if (_stage == _Stage.failed)
              Container(
                color: Colors.black,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Colors.white54,
                          size: 48,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _error ?? l10n.playerNothingToPlay,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                        // The last WebView resolve's diagnostic (b124):
                        // one small line to screenshot when a resolve
                        // ends with nothing, so it says where it stopped.
                        const ResolveDiagnosticText(),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FilledButton(
                              onPressed: () {
                                setState(() {
                                  _stage = _Stage.resolving;
                                  _error = null;
                                  _failedStreams.clear();
                                  _proxyBlocked.clear();
                                  _proxySlow.clear();
                                });
                                unawaited(_resolveAndOpen());
                              },
                              child: Text(l10n.retry),
                            ),
                            const SizedBox(width: 12),
                            OutlinedButton(
                              onPressed: _goBack,
                              child: Text(l10n.cancel),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // The golden chrome. Unmounted while the ended card or the up-next
            // card is up, so their autofocus and Back handling own the route.
            if (_stage == _Stage.playing &&
                _ended == null &&
                _nextEpisodeOffer == null &&
                // The window is the chrome in PiP: the golden controls
                // unmount while it is open (mirrors the VLC screen).
                !_inPip)
              RepaintBoundary(
                child: GoldenPlayerControls(
                  controller: _adapter,
                  bufferedFraction: _bufferedFraction,
                  // Build 107: the gold "downloaded up to" band on
                  // the seek bar.
                  downloadedFraction: _downloadedFraction,
                  chrome: _chrome,
                  fit: _fit,
                  videoScale: _videoScale,
                  onFitChanged: (fit) {
                    if (!mounted) return;
                    setState(() => _fit = fit);
                  },
                  onRotate: canRotate ? _flipOrientation : null,
                  title: widget.item.title,
                  episodeLine: _episodeLine,
                  subtitle: _chromeSubtitle(),
                  onBack: _goBack,
                  onNextEpisode: _hasNextEpisode ? _advance : null,
                  onPreviousEpisode: _previousEpisode == null
                      ? null
                      : _goToPreviousEpisode,
                  panelData: _panelData,
                  settings: _playerSettings,
                  settingsNotifier: ref.read(playerSettingsProvider.notifier),
                  onPickEpisode: (episode) => unawaited(_pickEpisode(episode)),
                  onPickSource: (index) {
                    // A hand pick: the thermal governor never overrides it
                    // while the hot episode lasts (see
                    // `mpv_thermal_quality.dart`).
                    _thermalGovernor.noteManualPick(index);
                    unawaited(_pickSource(index));
                  },
                  onAudioPicked: (track) {
                    // Remembered across failover: the next source re-applies
                    // it — and persisted across opens, so AUTO plays it next
                    // time too (see [_lastAudioPick]).
                    _rememberedAudioId = track.id;
                    final pick = RememberedTrack.of(track);
                    _lastAudioPick = pick;
                    if (pick != null) {
                      unawaited(
                        ref
                            .read(settingsRepositoryProvider)
                            .setPlayerSetting(
                              _kLastAudioPickKey,
                              jsonEncode(pick.toJson()),
                            ),
                      );
                    }
                  },
                  onSubtitlePicked: (id) {
                    _rememberedSubtitleId = id;
                  },
                  episodeProgress: _episodeProgressFor,
                  episodeDuration: _episodeDurationFor,
                  hasSubtitles: _hasSubtitles,
                  isLive: _isLive,
                  skipSegments: _skipSegments,
                  onSkipOutro: _hasNextEpisode ? _offerNextEpisodeNow : null,
                  // Phone and tablet only: with nothing here the controls
                  // have no padlock.
                  locked: form.isTouch ? _locked : null,
                  lockAvailable: form.isTouch,
                  // PiP is Android-only; on iOS and TV this stays null and
                  // the button never renders.
                  onEnterPip: _pipAvailable
                      ? () => unawaited(_enterPip(fromButton: true))
                      : null,
                  // Video output presets (+57) and PICTURE sliders: iOS
                  // mpv, and since v2 Android mpv (see
                  // [videoPanelSupportedOn]). Null elsewhere, so the panel
                  // never renders there.
                  onVideoPresetChanged:
                      videoPanelSupportedOn(defaultTargetPlatform)
                      ? _applyVideoOutputPreset
                      : null,
                  onPictureChanged: videoPanelSupportedOn(defaultTargetPlatform)
                      ? (values) => unawaited(_applyPicture(values))
                      : null,
                  videoIsHdr: _videoIsHdr,
                  sleepTimer: _sleepTimer,
                  // Build 86: a drawer open over the video shifts the
                  // caption left by its width (see `_drawerOpenWidth`).
                  onDrawerChanged: (width) {
                    if (!mounted) return;
                    setState(() => _drawerOpenWidth = width);
                  },
                ),
              ),

            // Up-next countdown card.
            if (_nextEpisodeOffer != null)
              NextEpisodeCountdown(
                title: _nextEpisodeOffer!.name,
                posterUrl:
                    _nextEpisodeOffer!.posterUrl ?? widget.item.posterUrl,
                season: _nextEpisodeOffer!.season,
                episode: _nextEpisodeOffer!.episode,
                onPlayNext: () {
                  final next = _nextEpisodeOffer;
                  if (next == null) return;
                  setState(() => _nextEpisodeOffer = null);
                  unawaited(_pickEpisode(next));
                },
                onCancel: () {
                  final beforeEnd = _offerBeforeEnd;
                  setState(() {
                    _nextEpisodeDeclined = true;
                    _nextEpisodeOffer = null;
                    _offerBeforeEnd = false;
                  });
                  // Cancelled while the episode is still playing (v7): it
                  // just keeps playing; the ended card comes at the end.
                  if (!beforeEnd) _showEnded(EndedKind.declinedNext);
                },
                // v7: 5 s. At the end of the episode there is nothing left
                // to pause, so the countdown always runs; before the end it
                // pauses with the video.
                countdown: kNextEpisodeCountdown,
                paused: _offerBeforeEnd && !_playing,
                isTv: isTv,
              ),

            // Ended card.
            if (_ended != null)
              EndedCard(
                title: _isEpisodic
                    ? (_currentEpisode?.name ?? widget.item.title)
                    : widget.item.title,
                kind: _ended!,
                onStartOver: _startOver,
                onClose: _goBack,
                onNextEpisode: _ended == EndedKind.declinedNext
                    ? () {
                        setState(() => _ended = null);
                        unawaited(_advance());
                      }
                    : null,
                isTv: isTv,
              ),

            // Build 107: a seek past the downloaded frontier waits
            // here, with honest progress — the film keeps playing
            // where it is meanwhile, and the moment the bytes arrive
            // the local file reopens at the target. Cancel drops the
            // whole temp download and goes back to stream-only.
            if (_pendingTempSeek != null && _tempDownload != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 96,
                child: Center(
                  child: ValueListenableBuilder<double>(
                    valueListenable: _downloadedFraction,
                    builder: (context, fraction, _) {
                      final temp = _tempDownload;
                      final target = _pendingTempSeek;
                      if (temp == null || target == null) {
                        return const SizedBox.shrink();
                      }
                      final eta = temp.etaTo(target);
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.78),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: GoldenPlayerColors.accent(context).withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              'Downloading to ${goldenFormatTime(target)}'
                              ' · ${(fraction * 100).round()}%'
                              '${eta != null ? ' · ETA ${goldenFormatTime(eta)}' : ''}',
                              style: const TextStyle(
                                color: GoldenPlayerColors.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: 220,
                              child: LinearProgressIndicator(
                                value: fraction.clamp(0.0, 1.0),
                                backgroundColor: Colors.white24,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  GoldenPlayerColors.accent(context),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            TextButton(
                              onPressed: () {
                                unawaited(_cancelTempDownload());
                              },
                              child: Text(
                                'Cancel download',
                                style: TextStyle(
                                  color: GoldenPlayerColors.accent(context),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),

            // The mpv stats overlay (+34): the live measurements over the
            // video while the QoE-log developer option is on — the only
            // diagnostics surface that works on a release build (the
            // app-log viewer is debug-only). Never interactive
            // (IgnorePointer), so it cannot steal a tap, a swipe or a
            // pinch from the gesture layer below it. Top-left, below the
            // top bar, so it sits over the picture rather than the
            // chrome; a tap hides the chrome and leaves it fully
            // readable.
            if (_showMpvStatsOverlay)
              Positioned(
                top: 64,
                left: 8,
                child: IgnorePointer(
                  child: ValueListenableBuilder<String>(
                    valueListenable: _mpvStatsText,
                    builder: (context, text, _) {
                      if (text.isEmpty) return const SizedBox.shrink();
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          text,
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 10,
                            height: 1.4,
                            fontFamily: 'monospace',
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
