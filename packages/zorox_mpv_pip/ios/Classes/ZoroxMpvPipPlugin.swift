import Accelerate
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Flutter
import Foundation
import UIKit

/// Host view for the PiP display layer. CALayer sublayers do NOT follow
/// their superlayer's bounds, so the host must push its size into the
/// layer on every layout pass. Without this, a layer framed while the
/// window was portrait keeps a portrait frame after the player rotates
/// to landscape — and PiP opens a narrow vertical strip (+29).
private final class PipHostView: UIView {
  weak var displayLayer: AVSampleBufferDisplayLayer?

  override func layoutSubviews() {
    super.layoutSubviews()
    if let layer = displayLayer, layer.frame != bounds {
      layer.frame = bounds
    }
  }
}

/// iOS Picture-in-Picture for the mpv (Golden) player.
///
/// iOS PiP needs an `AVPlayerLayer` or an `AVSampleBufferDisplayLayer`;
/// mpv has neither, and libmpv allows only one render context per core, so
/// a second renderer for PiP is impossible. This plugin therefore taps the
/// frames the forked `media_kit_video` software renderer already produces:
/// `TextureSW` posts every completed frame on the
/// `ZoroXMpvRenderedFrame` notification (see `packages/media_kit_video/
/// FORK.md`), this plugin copies the frame synchronously into its own pool
/// — the renderer's pool has only 3 buffers — wraps it as a
/// `CMSampleBuffer`, and enqueues it into an `AVSampleBufferDisplayLayer`
/// that drives an `AVPictureInPictureController`.
///
/// Only the software renderer can feed it: GPU work is not allowed while
/// the app is in the background, and PiP runs while backgrounded. The
/// player therefore runs with `enableHardwareAcceleration: false` plus
/// `hwdec: videotoolbox-copy` (hardware decode, software render) whenever
/// the iOS mpv PiP setting is on. Cost: no shaders, HDR looks washed out,
/// 4K is heavy — which is why PiP is behind a setting, off by default.
///
/// Public APIs only, no entitlement; the app already declares the `audio`
/// background mode. Flutter subtitles never appear in the PiP window — the
/// overlay is a Flutter widget. mpv's own subtitles do: the Dart side
/// switches `sub-visibility` on when PiP actually starts and restores it
/// when PiP stops, so they burn into the frame.
///
/// +29: frames are enqueued ONLY while the PiP window is actually up
/// (gated on the PiP delegate, not the request), the feed is downscaled
/// to ~640 px wide (vImage), and the in-app Video widget is unmounted
/// while PiP is up — the +28 build drew the film twice (Flutter texture
/// + PiP layer), saturating the CPU (cut-cut voice, dropped frames) and
/// leaving a second copy of the video visible inside the app. The
/// display layer also tracks the window on rotation now: a layer framed
/// while portrait stayed portrait after the player rotated, and PiP
/// opened a narrow vertical strip.
///
/// +30: +29's gate broke PiP completely — the window never opens, on
/// either the button or the home-swipe path. Chicken-and-egg:
/// startPictureInPicture() refuses while the layer is EMPTY
/// (isPictureInPicturePossible == false), but pipActive is only set
/// once PiP WILL start, so no frame is ever enqueued. The +28 build
/// opened because its ~5 fps trickle kept a frame in the layer. The
/// fix is a PRIME: the latest frame is held in memory (never enqueued)
/// and pushed into the layer only at the moment a start is attempted —
/// synchronously in enter(), and when the app backgrounds (for
/// auto-PiP), with a flush on become-active if PiP never started.
/// There is deliberately NO standing trickle: the host view is a
/// subview of the FlutterView itself, so it renders ABOVE the Metal
/// layer — any frame in the display layer shows on top of the player
/// as a second copy. The +28 video proves it: the second copy was
/// full-width with shifted, clipped subtitles, i.e. the layer's own
/// video rect on top of the Flutter scene, not Flutter's video showing
/// through. So the layer stays empty in-app and is primed only when
/// a start is imminent.
///
/// +32: the +31 phone test shows PiP plays ~3 s of real motion and
/// then runs JERKILY (frames arrive rarely, in bursts; voice stutters
/// too) — "freeze nahi, atak atak k chalta hein". The user asked
/// Claude and ChatGPT as well (3-AI approach), and both converged on
/// the sample-buffer pipeline, NOT the CPU: (1) TIMESTAMPS — the
/// layer's controlTimebase was anchored to the MOVIE position
/// (apply() re-set it on every Dart position update, ~5x/s) while
/// every sample buffer carried a WALL-CLOCK PTS
/// (CFAbsoluteTimeGetCurrent, seconds since 2001 — ~800M seconds in
/// the future of the layer's clock), so the layer queued frames and
/// waited, isReadyForMoreMediaData went false, ingest() dropped
/// everything, and only an occasional frame slipped through when the
/// timebase was re-anchored — exactly the jerky trickle. Fix: the
/// timebase is set ONCE to the host clock in prepare() and re-synced
/// only on play/pause transitions; the PTS is the host clock
/// (CMClockGetTime), DisplayImmediately kept. (2) UNBOUNDED QUEUE —
/// ingest() checked isReady BEFORE the copy and the async hop, so
/// frames piled up in frameQueue while the layer fell behind, and the
/// pool's "minimum 3" is a minimum, not a maximum, so it gave no
/// backpressure at all. Fix: ONE in-flight live frame
/// (DispatchSemaphore, non-blocking wait), a session-generation
/// counter so frames queued before a stop can't enter the next
/// session, and the pool minimum raised to 8. (3) THREAD OWNERSHIP —
/// the layer was touched from three threads (render thread, frame
/// queue, main). Fix: the display layer is main-only now; ingest()
/// copies on the render thread (the tap contract) and hands the
/// buffer to the main queue, never main.sync. (4) SILENT .failed —
/// enqueue() flushed a failed layer and then enqueued into it anyway.
/// Fix: on .failed, log layer.error, flush, DROP the frame and count
/// it, so the next frame is the recovery attempt. (5) DIAGNOSTICS —
/// a native 1 s snapshot (NSLog, not a Dart timer) while PiP is up,
/// and diag() extended with pool/layer/PTS-delta counters, so the
/// next phone test names the cause. Secondary: the render worker
/// runs .userInteractive (fork Worker.swift), the live feed's serial
/// queue is gone (main owns the layer), and a latency-critical
/// activity assertion is held for the PiP lifetime (cheap insurance;
/// the audio background mode is what keeps the app alive). The 480p
/// drop stays (ceiling 360p in +32, Dart side) with the thermal
/// stand-down. What +32 deliberately does NOT do: a second mpv render
/// context or a native render worker decoupled from Flutter (the
/// stretch goal both AIs named) — that is the next round if the
/// pipeline fix alone is not enough; neither does it chase the
/// layer-flush theory (the window never went black) or the gate
/// (proven open by the burned-in subtitle).
///
/// Own channel `dev.toji.zorox.player/pip_mpv_ios` — deliberately NOT
/// `dev.toji.zorox.player/pip`, which the libVLC side already uses;
/// reusing that name would replace its handler.
public class ZoroxMpvPipPlugin: NSObject, FlutterPlugin,
  AVPictureInPictureControllerDelegate,
  AVPictureInPictureSampleBufferPlaybackDelegate
{
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "dev.toji.zorox.player/pip_mpv_ios",
      binaryMessenger: registrar.messenger()
    )
    let instance = ZoroxMpvPipPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  /// The notification the forked media_kit_video software renderer posts
  /// with each completed frame (`CVPixelBuffer` as the object).
  private static let frameNotification = Notification.Name(
    "ZoroXMpvRenderedFrame"
  )

  private let channel: FlutterMethodChannel

  private var pip: AVPictureInPictureController?
  private var timebase: CMTimebase?
  private var layer: AVSampleBufferDisplayLayer?
  private var hostView: UIView?
  private var frameObserver: NSObjectProtocol?

  private var pipActive = false
  private var armed = false
  private var prepared = false
  private var playing = false
  private var duration: Double = 0
  private var lastPosition: Double = 0
  private var rate: Double = 1

  private let lock = NSLock()
  private var pool: CVPixelBufferPool?
  private var poolW = 0
  private var poolH = 0
  private var frameCount = 0

  // +32: ONE in-flight live frame. ingest() runs on the media_kit
  // render thread and must never block, so the wait is non-blocking
  // (timeout .now()): if a previous frame is still being handed to
  // the layer, the new one drops. The semaphore is signalled on the
  // main queue after the hand-off (or the drop) completes — see
  // ingest()/enqueue(). Before +32 the readiness check happened
  // BEFORE the copy and the async hop, so frames piled up in
  // frameQueue while the layer fell behind, and the pool's "minimum
  // 3" is a minimum, not a maximum, so it gave no backpressure at
  // all. There is no frameQueue anymore: the display layer is
  // main-only (see enqueue()), and ingest() hands the copied buffer
  // straight to the main queue.
  private let liveSemaphore = DispatchSemaphore(value: 1)

  // +32: session generation. Bumped on every session boundary
  // (enter, stop, release) so a frame queued before PiP stopped —
  // or before a new attempt — can never enter a later session: the
  // main-queue hand-off drops it when the generation it captured no
  // longer matches.
  private var sessionGeneration = 0

  // +32: pool pressure. makeBuffer() used to ignore the pool's return
  // code; a pool that cannot allocate (all buffers held by the layer)
  // now counts here, with the last status, so the next phone test can
  // tell pool exhaustion apart from layer backpressure.
  private var poolFailed = 0
  private var lastPoolStatus: Int32 = 0

  // +32: how many times enqueue() found the layer .failed, and the
  // PTS-vs-layer-clock delta of the last enqueued frame, in ms. The
  // delta is the smoking gun for the +31 timestamp bug: before +32
  // the PTS was wall-clock (~800M s) against a movie-position
  // timebase, so it read in the hundreds of millions of seconds.
  // After the fix it should be ~0.
  private var layerFailed = 0
  private var lastPtsDeltaMs: Int64 = 0

  // +32: the fork's render counters, carried in the tap
  // notification's userInfo (see MediaKitFrameTap.swift) — how many
  // mpv update callbacks fired, how many renders completed, and how
  // long the last render took. If ingest() grows but these don't,
  // the tap is the problem; if the update count grows but the render
  // count doesn't, the Worker/main hop is.
  private var lastUpdateCount = 0
  private var lastRenderCount = 0
  private var lastRenderMs: Double = 0

  // +32: the native 1 s diag snapshot (NSLog, not a Dart timer — the
  // Flutter isolate may be suspended in background). Runs only while
  // PiP is up; see startDiagSnapshot()/stopDiagSnapshot().
  private var diagTimer: Timer?

  // +32: a latency-critical activity assertion for the PiP lifetime.
  // Cheap insurance that the system schedules this process's work
  // promptly while the window is up; the audio background mode is
  // what keeps the app alive. Held from PiP start to PiP stop.
  private var pipActivity: NSObjectProtocol?

  // +32: the playing state apply() last saw, so the timebase is only
  // re-synced on a genuine play/pause transition — never on the
  // ~5x/s position updates. Before +32, apply() re-anchored the
  // timebase to the movie position on EVERY updateState, a
  // discontinuity five times a second.
  private var lastAppliedPlaying = false

  // +31: throughput counters for diag() — how many frames the tap
  // delivered, how many reached the layer while PiP was up, how many
  // were dropped, and when the last live frame landed. Guarded by
  // `lock`: ingest() runs on the media_kit render thread, enqueue()
  // on the frame queue, diag() on the main thread.
  private var ingestCount = 0
  private var liveEnqueued = 0
  private var liveDropped = 0
  private var lastLiveEnqueueAt: CFAbsoluteTime = 0

  // +31: the format description for the feed's dimensions, cached so
  // enqueue() does not build one per frame (CoreMedia work on the
  // throttled background feed thread). All frames in a session share
  // dimensions and pixel format; a dimension change rebuilds it.
  private var cachedFormatDesc: CMVideoFormatDescription?
  private var cachedFormatW = 0
  private var cachedFormatH = 0

  // MARK: - Prime (+30)
  //
  // The latest rendered frame, held in memory (never enqueued) so a
  // PiP start always has a frame to push into the layer. Two slots,
  // ping-pong: ingest() writes only the INACTIVE slot and then swaps
  // the current pointer under the lock, so a buffer being enqueued by
  // enter() is never overwritten mid-copy. The slots are plain
  // CVPixelBuffers (not from the live-feed pool) so holding one can
  // never starve the live feed. Refreshed at most ~5 fps while the
  // player runs; a paused film keeps its last frame, which is exactly
  // the frame PiP should open on.
  private var primeBuffers: [CVPixelBuffer?] = [nil, nil]
  private var primeCurrent = 0
  private var primeReady = false
  private var primeUpdatedAt: CFAbsoluteTime = 0
  private var primeW = 0
  private var primeH = 0
  private var primeCount = 0
  private var lastPrimedAt: CFAbsoluteTime = 0
  private var enterPending = false
  private var lifecycleObservers: [NSObjectProtocol] = []

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  deinit {
    if let observer = frameObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    for observer in lifecycleObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  // MARK: - MethodChannel

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "isSupported":
      result(AVPictureInPictureController.isPictureInPictureSupported())
    case "prepare":
      guard let args = call.arguments as? [String: Any] else {
        result(
          FlutterError(
            code: "bad_args",
            message: "prepare needs position/duration/playing",
            details: nil
          )
        )
        return
      }
      result(prepare(args))
    case "updateState":
      if let args = call.arguments as? [String: Any] {
        apply(args)
      }
      result(nil)
    case "enterPip":
      enter(result)
    case "exitPip":
      pip?.stopPictureInPicture()
      result(nil)
    case "release":
      release()
      result(nil)
    case "diag":
      result(diag())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Session

  private func prepare(_ args: [String: Any]) -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      return false
    }
    guard let rootView = hostRootView() else {
      return false
    }
    if pip == nil {
      let displayLayer = AVSampleBufferDisplayLayer()
      displayLayer.videoGravity = .resizeAspect

      // Full-window host, NOT hidden: PiP refuses to start for a layer
      // that is hidden or outside the window hierarchy. NOTE the host
      // is a subview of the FlutterView itself, so it renders ABOVE
      // the Metal layer — the layer is NOT hidden behind Flutter's
      // view. Any frame in it shows on top of the player as a second
      // copy (+28). The layer therefore stays EMPTY in-app and is
      // primed only when a start is imminent (+30). The host is a
      // PipHostView (+29) so the layer tracks the window on rotation:
      // a plain sublayer keeps the frame it was created with.
      let host = PipHostView(frame: rootView.bounds)
      host.isUserInteractionEnabled = false
      host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      host.isHidden = false
      displayLayer.frame = host.bounds
      host.displayLayer = displayLayer
      host.layer.addSublayer(displayLayer)
      rootView.insertSubview(host, at: 0)

      // CMTimebase(masterClock:) throws in this SDK; a failed timebase
      // means PiP cannot be prepared.
      guard let tb = try? CMTimebase(masterClock: CMClockGetHostTimeClock())
      else { return false }
      // +32: the timebase is anchored to the HOST clock ONCE, here,
      // and runs at rate 1 — it is the same timeline the sample
      // buffers' PTS use (see enqueue()). Before +32, apply()
      // re-anchored it to the MOVIE position on every Dart position
      // update (~5x/s) while the PTS was wall-clock, so the layer
      // queued frames ~800M seconds in its future and waited. The
      // only later re-sync is a genuine play/pause transition in
      // apply(); a stream re-open never touches it.
      CMTimebaseSetTime(
        tb,
        time: CMClockGetTime(CMClockGetHostTimeClock())
      )
      CMTimebaseSetRate(tb, rate: 1)
      displayLayer.controlTimebase = tb

      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: displayLayer,
        playbackDelegate: self
      )
      let controller = AVPictureInPictureController(contentSource: source)
      controller.delegate = self
      // Armed per playback state in apply(): auto-PiP only while playing.
      controller.canStartPictureInPictureAutomaticallyFromInline = false

      self.layer = displayLayer
      self.hostView = host
      self.timebase = tb
      self.pip = controller
    }

    apply(args)

    lock.lock()
    armed = true
    lock.unlock()

    // queue: nil delivers synchronously on the posting thread — the
    // media_kit worker thread that just rendered the frame — so the
    // copy in ingest() reads the buffer before the renderer reuses it.
    // +32: the tap also carries the fork's render counters in
    // userInfo (see MediaKitFrameTap.swift); the 1 s snapshot prints
    // them, so a stall can be told apart as renderer vs pipeline.
    if frameObserver == nil {
      frameObserver = NotificationCenter.default.addObserver(
        forName: Self.frameNotification,
        object: nil,
        queue: nil
      ) { [weak self] note in
        // Swift 6 flags a conditional downcast from Any to the CF type
        // CVPixelBuffer as always succeeding, so check the
        // CoreFoundation type ID first, then force-cast.
        guard let obj = note.object,
              CFGetTypeID(obj as CFTypeRef) == CVPixelBufferGetTypeID()
        else { return }
        self?.noteRenderCounters(note.userInfo)
        self?.ingest(obj as! CVPixelBuffer)
      }
    }

    // +55: auto-PiP is REMOVED (user decision 2026-11-16: PiP opens
    // only when the PiP button is tapped). There is no
    // didEnterBackground observer at all — a Home swipe must never
    // open a window on its own, and the +53 first-Home failure that
    // left the renderer stale cannot happen without an entry to fail.
    // The manual enter primes via attemptEnter independently, so no
    // background prime is ever needed.
    // +51: do NOT prime on resign-active. It fires for transient
    // interruptions (Control Center, Notification Center, a call)
    // where the app never backgrounds — and the primed frame renders
    // ON TOP of the Flutter player (the host is a subview of
    // FlutterView, above the Metal layer), showing as a second,
    // wrong-aspect copy (a thin strip) in the middle of the screen
    // for ~1 s after the overlay is dismissed, until the
    // become-active flush clears it. So there is no resign-active
    // observer at all.
    // didBecomeActive (not willEnterForeground): resign-active also
    // fires for transient interruptions (Control Center, a call) where
    // the app never backgrounds, and only become-active follows those.
    // The become-active flush stays: a failed manual enter can still
    // leave a prime behind, and it must not linger on top of the
    // player. Main queue: these notifications arrive there.
    if lifecycleObservers.isEmpty {
      let center = NotificationCenter.default
      lifecycleObservers.append(
        center.addObserver(
          forName: UIApplication.didBecomeActiveNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in self?.clearStalePrime() }
      )
    }

    prepared = true
    return true
  }

  private func apply(_ args: [String: Any]) {
    lastPosition = num(args, "position")
    duration = num(args, "duration")
    playing = (args["playing"] as? Bool) ?? false
    rate = args["rate"] != nil ? num(args, "rate") : 1.0

    // +32: the timebase is a HOST-clock clock (set once in
    // prepare()), so it is NEVER re-anchored to the movie position
    // here — before +32 this ran on every Dart position update
    // (~5x/s) and moved the layer's clock under the queued frames.
    // Only a genuine play/pause transition touches it: on pause the
    // clock stops, on resume it re-syncs to host-now and runs again.
    // The movie position is irrelevant to the layer once the PTS is
    // host-clocked (see enqueue()); the PiP scrubber reads the
    // timeRange delegate, which is anchored to this clock (+43).
    if let tb = timebase, playing != lastAppliedPlaying {
      if playing {
        CMTimebaseSetTime(
          tb,
          time: CMClockGetTime(CMClockGetHostTimeClock())
        )
        CMTimebaseSetRate(tb, rate: rate)
      } else {
        CMTimebaseSetRate(tb, rate: 0)
      }
      lastAppliedPlaying = playing
    }
    // +55: auto-PiP is REMOVED — the arm stays off, always. The flag
    // alone never opened the window for this sample-buffer source
    // (+41), but leaving it armed while playing would let the system
    // open PiP on its own on some iOS version, and the user wants PiP
    // ONLY from the button. The button's explicit enter() does not
    // need the arm (it calls startPictureInPicture directly).
    pip?.canStartPictureInPictureAutomaticallyFromInline = false
    pip?.invalidatePlaybackState()
  }

  /// Pushes the host's current bounds into the display layer. The
  /// host's layoutSubviews does this on every rotation; this is the
  /// belt-and-braces call right before PiP starts, so the window is
  /// shaped by the window's size now, not by the size at prepare time.
  private func syncLayerFrame() {
    guard let host = hostView, let layer = layer else { return }
    if layer.frame != host.bounds {
      layer.frame = host.bounds
    }
  }

  // +53: the enter poll budget. The layer MUST hold a frame before
  // startPictureInPicture — an empty layer reports
  // isPictureInPicturePossible == false and the start refuses (the
  // +29 regression). The layer processes the enqueued buffer
  // asynchronously, so possible may flip true a beat after the
  // enqueue — and on a COLD layer (first-ever prime, fresh app
  // launch) that beat is longer than the old 20-tick (~1 s) poll:
  // the user confirmed (2026-11-16) the first Home swipe NEVER
  // opens PiP while the 2nd/3rd swipe does, i.e. the cold layer
  // needs >1 s and is warm by the 2nd/3rd attempt. 60 ticks at
  // 50 ms is ~3 s — 3x the old budget, enough for the cold layer
  // to warm up in one attempt (it warmed within ~2–3 s of
  // cumulative processing across swipes), and still inside the
  // Dart side's 5 s watchdog. +55: the poll is button-only now
  // (automatic PiP removed) — the same cold-layer wait applies to
  // the first button tap, so the 60-tick budget stays.
  private static let enterPollAttempts = 60

  private func enter(_ result: @escaping FlutterResult) {
    guard let pip = pip else {
      result(
        FlutterError(
          code: "not_prepared",
          message: "call prepare first",
          details: nil
        )
      )
      return
    }
    if pip.isPictureInPictureActive {
      result(true)
      return
    }
    // One enter at a time: a double-tap on the button must not run two
    // poll loops against the same result callback.
    lock.lock()
    let already = enterPending
    if !already { enterPending = true }
    lock.unlock()
    guard !already else {
      result(
        FlutterError(code: "busy", message: "PiP start already running", details: nil)
      )
      return
    }
    syncLayerFrame()
    // +32: a new attempt is a new session — any live frame queued
    // before this (e.g. from a previous PiP session that just
    // stopped) must not enter it; the main-queue hand-off drops
    // frames whose generation no longer matches.
    lock.lock()
    sessionGeneration += 1
    lock.unlock()
    // +30: the layer MUST hold a frame before startPictureInPicture —
    // an empty layer reports isPictureInPicturePossible == false and
    // the start refuses (the +29 regression). Prime it with the latest
    // held frame, then poll for possible: the layer processes the
    // enqueued buffer asynchronously, so possible may flip true a
    // beat after the enqueue. The Dart side has a 5 s watchdog, so a
    // ~3 s wait here is safe (see [enterPollAttempts], +53).
    attemptEnter(pip: pip, result: result, attemptsLeft: Self.enterPollAttempts)
  }

  /// One tick of the enter() poll. Prime the layer if a newer held
  /// frame arrived since the last prime, then start when possible.
  /// Runs on the main queue (MethodChannel handlers are main-thread).
  /// +55: automatic PiP is removed — this poll runs only for the
  /// manual button path, so there is no auto/foreground distinction
  /// any more (the old `isAuto` guard is gone with it).
  private func attemptEnter(
    pip: AVPictureInPictureController,
    result: @escaping FlutterResult,
    attemptsLeft: Int
  ) {
    // Keep the layer's image fresh while we wait: a newer prime
    // replaces the stale one.
    if let prime = takePrimeIfNewer() {
      enqueuePrime(prime)
    }
    if pip.isPictureInPictureActive {
      finishEnter(result: result, success: true)
      return
    }
    if pip.isPictureInPicturePossible {
      syncLayerFrame()
      pip.startPictureInPicture()
      // +31: open the gate here too, not only in willStart — the start
      // was accepted (possible was true), so the live feed must flow
      // from now on even if the delegate callback is delayed or lost.
      // A failed start clears it again (failedToStart -> stopPipFeed),
      // as does a stop, so a refusal cannot leave the gate open.
      lock.lock()
      pipActive = true
      lock.unlock()
      // +32: the PiP lifetime starts here (willStart repeats these
      // calls harmlessly if it fires too): the activity assertion
      // and the 1 s native diag snapshot.
      beginPipActivity()
      startDiagSnapshot()
      finishEnter(result: result, success: true)
      return
    }
    if attemptsLeft > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        guard let self = self else { return }
        self.attemptEnter(
          pip: pip,
          result: result,
          attemptsLeft: attemptsLeft - 1
        )
      }
      return
    }
    // Still impossible after ~1 s: flush the prime so no frozen frame
    // lingers on top of the player, and report with diag.
    layer?.flushAndRemoveImage()
    finishEnter(result: result, success: false)
  }

  /// Clears the enter guard and answers the MethodChannel call exactly
  /// once. A failure carries the diag string so a future "PiP doesn't
  /// open" can be told apart from a layer problem.
  private func finishEnter(result: @escaping FlutterResult, success: Bool) {
    lock.lock()
    enterPending = false
    lock.unlock()
    if success {
      result(true)
    } else {
      result(
        FlutterError(code: "not_possible", message: diag(), details: nil)
      )
    }
  }

  /// Pushes the held prime frame into the display layer, synchronously
  /// on the calling (main) thread. The prime is copied into a fresh
  /// pool buffer first: the held slot will be overwritten by a later
  /// refresh, and the copy must never be torn mid-enqueue. Returns
  /// false when the layer isn't ready — the caller retries on the next
  /// poll tick.
  @discardableResult
  private func enqueuePrime(_ pb: CVPixelBuffer) -> Bool {
    guard let layer = layer, layer.isReadyForMoreMediaData else {
      return false
    }
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    guard let dst = makeBuffer(w, h) else { return false }
    copyFrame(src: pb, dst: dst)
    // +32: enqueue() is main-only now and takes the layer from self;
    // this runs on main already (enter poll / lifecycle observers).
    enqueue(dst)
    lock.lock()
    primeCount += 1
    lastPrimedAt = CFAbsoluteTimeGetCurrent()
    lock.unlock()
    return true
  }

  /// Back active without PiP up: a background prime that never became
  /// a window would sit on top of the player as a frozen frame. Flush
  /// it. This also covers transient interruptions (Control Center, a
  /// call), where become-active follows without any foreground
  /// transition. Harmless when PiP did start — the live feed is
  /// already flowing and the flush only clears a stale image.
  private func clearStalePrime() {
    guard !pipActive else { return }
    layer?.flushAndRemoveImage()
  }

  private func release() {
    stopDiagSnapshot()
    endPipActivity()
    pip?.stopPictureInPicture()
    pip = nil
    timebase = nil
    if let l = layer {
      l.flushAndRemoveImage()
      l.removeFromSuperlayer()
    }
    layer = nil
    hostView?.removeFromSuperview()
    hostView = nil
    if let observer = frameObserver {
      NotificationCenter.default.removeObserver(observer)
      frameObserver = nil
    }
    for observer in lifecycleObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    lifecycleObservers = []
    pool = nil
    lock.lock()
    armed = false
    pipActive = false
    prepared = false
    primeBuffers = [nil, nil]
    primeReady = false
    primeUpdatedAt = 0
    primeW = 0
    primeH = 0
    enterPending = false
    ingestCount = 0
    liveEnqueued = 0
    liveDropped = 0
    lastLiveEnqueueAt = 0
    cachedFormatDesc = nil
    cachedFormatW = 0
    cachedFormatH = 0
    sessionGeneration += 1
    poolFailed = 0
    lastPoolStatus = 0
    layerFailed = 0
    lastPtsDeltaMs = 0
    lastUpdateCount = 0
    lastRenderCount = 0
    lastRenderMs = 0
    lastAppliedPlaying = false
    lock.unlock()
  }

  private func hostRootView() -> UIView? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
    return window?.rootViewController?.view
  }

  private func num(_ args: [String: Any], _ key: String) -> Double {
    if let n = args[key] as? NSNumber { return n.doubleValue }
    if let d = args[key] as? Double { return d }
    return 0
  }

  /// Layer status, whether the layer is in a window, whether PiP can
  /// start, the audio category, how many frames reached the PiP
  /// layer — and the prime state (+30): whether a frame is held ready
  /// for a start, how old it is, and how many primes were enqueued.
  /// The first thing to check when PiP fails on a phone: primed=false
  /// means no frame ever arrived (renderer tap broken); primed=true
  /// with possible=false means the layer saw the prime but the
  /// controller still refuses.
  /// +31: also the gate state and the live-feed throughput — frames
  /// the tap delivered (ingest), frames enqueued while PiP was up
  /// (liveEnq), frames dropped while up (liveDrop), and the age of
  /// the last live frame (liveAgeMs). A slow PiP reads as liveAgeMs
  /// in the seconds (the +30 phone test: ~5000 ms) while pipActive
  /// is true; a closed gate reads as pipActive=false with liveEnq
  /// stuck at 0.
  /// +32: also the pool pressure (poolFail, lastPoolStatus — 0 is
  /// success, -6683 is would-exceed-allocation-threshold), the layer
  /// failures (layerFail + the layer's error), the PTS-vs-layer-clock
  /// delta (ptsDeltaMs — ~0 after the timestamp fix; hundreds of
  /// millions of seconds before it), and the fork's render counters
  /// (upd/rend/rendMs — if ingest grows but upd/rend don't, the tap
  /// is the problem; if upd grows but rend doesn't, the Worker/main
  /// hop is).
  private func diag() -> String {
    lock.lock()
    let pReady = primeReady
    let pAgeMs = primeReady
      ? Int((CFAbsoluteTimeGetCurrent() - primeUpdatedAt) * 1000)
      : -1
    let pCount = primeCount
    let gate = pipActive
    let ingested = ingestCount
    let enqueued = liveEnqueued
    let dropped = liveDropped
    let liveAgeMs = lastLiveEnqueueAt > 0
      ? Int((CFAbsoluteTimeGetCurrent() - lastLiveEnqueueAt) * 1000)
      : -1
    let pFail = poolFailed
    let pStatus = lastPoolStatus
    let lFail = layerFailed
    let ptsDelta = lastPtsDeltaMs
    let upd = lastUpdateCount
    let rend = lastRenderCount
    let rendMs = lastRenderMs
    lock.unlock()
    let layerErr = (layer?.error as? NSError)?.localizedDescription ?? "none"
    return "layer=\(layer?.status.rawValue ?? -1) "
      + "inWindow=\(hostView?.window != nil) "
      + "possible=\(pip?.isPictureInPicturePossible ?? false) "
      + "pipActive=\(gate) "
      + "audio=\(AVAudioSession.sharedInstance().category.rawValue) "
      + "frames=\(frameCount) "
      + "ingest=\(ingested) liveEnq=\(enqueued) liveDrop=\(dropped) "
      + "liveAgeMs=\(liveAgeMs) "
      + "primed=\(pReady) primeAgeMs=\(pAgeMs) primes=\(pCount) "
      + "poolFail=\(pFail) poolStatus=\(pStatus) "
      + "layerFail=\(lFail) layerErr=\(layerErr) "
      + "ptsDeltaMs=\(ptsDelta) "
      + "upd=\(upd) rend=\(rend) rendMs=\(String(format: "%.1f", rendMs))"
  }

  // MARK: - Frame ingest

  private func ingest(_ pb: CVPixelBuffer) {
    lock.lock()
    let isArmed = armed
    let isPipActive = pipActive
    let generation = sessionGeneration
    ingestCount += 1
    lock.unlock()
    guard isArmed else { return }

    // The PiP window is small: full-res 1080p frames through the copy
    // + compositor are wasted work and helped saturate the CPU (+29).
    // Cap the feed at ~640 px wide; the aspect is preserved and the
    // height is kept even (BGRA rows).
    let sw = CVPixelBufferGetWidth(pb)
    let sh = CVPixelBufferGetHeight(pb)
    let maxPipWidth = 640
    let tw: Int
    let th: Int
    if sw > maxPipWidth {
      tw = maxPipWidth
      th = max(2, (sh * maxPipWidth / sw) & ~1)
    } else {
      tw = sw
      th = sh
    }

    // Frames feed the PiP window ONLY while it is actually up (+29):
    // the host view is a subview of the FlutterView itself, so it
    // renders ABOVE the Metal layer — any frame enqueued while the app
    // is in the foreground shows as a second copy of the video inside
    // the app (the +28 second screen). While PiP is NOT up, the frame
    // only refreshes the held prime (+30): a copy in memory, never
    // enqueued, so the layer stays empty in-app and a start always
    // has a fresh frame to push.
    if isPipActive {
      // +32: ONE in-flight live frame. The semaphore wait is
      // NON-BLOCKING (timeout .now()) — this runs on the media_kit
      // render thread and must never block it. If the previous frame
      // is still being handed to the layer, this one drops. The
      // isReadyForMoreMediaData pre-check that used to live here is
      // gone: it read a main-actor layer from the render thread, and
      // it ran BEFORE the copy and the async hop, so it could not
      // stop frames piling up behind a slow layer anyway. The
      // backpressure is now the semaphore (here) plus the readiness
      // check inside enqueue() on the main queue (there).
      guard liveSemaphore.wait(timeout: .now()) == .success else {
        noteLiveDrop()
        return
      }
      guard let dst = makeBuffer(tw, th) else {
        // Pool could not allocate (all buffers held by the layer):
        // count it and release the slot — never retry in a loop on
        // the render thread.
        lock.lock()
        poolFailed += 1
        lock.unlock()
        liveSemaphore.signal()
        noteLiveDrop()
        return
      }
      // Synchronous copy on the render thread: the tap contract —
      // the renderer reuses its buffer on the next render. The
      // hand-off to the layer then goes to the main queue (the layer
      // is main-only); the semaphore is released there, in the
      // hand-off's defer, so a slow main queue — not a queue of
      // frames — is what throttles the tap. The semaphore is captured
      // strongly (it is a let): the slot is released even if the
      // plugin is gone by the time the hand-off runs.
      copyFrame(src: pb, dst: dst)
      let semaphore = liveSemaphore
      DispatchQueue.main.async { [weak self] in
        defer { semaphore.signal() }
        guard let self = self else { return }
        // A frame queued before PiP stopped (or before a new attempt)
        // must not enter the next session.
        self.lock.lock()
        let current = self.sessionGeneration
        self.lock.unlock()
        guard current == generation else { return }
        self.enqueue(dst, live: true)
      }
      return
    }
    refreshPrime(pb, tw: tw, th: th)
  }

  // MARK: - Prime (+30)

  /// Refreshes the held prime with the latest rendered frame, at most
  /// ~5 fps. Runs on the media_kit render thread (ingest is called
  /// synchronously from the frame notification). The copy goes into
  /// the INACTIVE slot and the swap happens under the lock, so a
  /// buffer being enqueued by enter() is never overwritten mid-copy.
  /// One ~640 px vImage scale per 200 ms is negligible next to the
  /// render work itself.
  private func refreshPrime(_ pb: CVPixelBuffer, tw: Int, th: Int) {
    let now = CFAbsoluteTimeGetCurrent()
    lock.lock()
    let last = primeUpdatedAt
    let current = primeCurrent
    let pw = primeW
    let ph = primeH
    let existing = primeBuffers[1 - current]
    lock.unlock()
    guard now - last >= 0.2 else { return }

    // Reuse the inactive slot's buffer when it already has the right
    // size; otherwise create a fresh one. The buffer object is only
    // ever written here, on the render thread, and the array slot is
    // assigned under the lock below — so no other thread can observe
    // a half-written slot.
    let writeSlot = 1 - current
    let dst: CVPixelBuffer?
    if let existing = existing, pw == tw && ph == th {
      dst = existing
    } else {
      dst = createPrimeBuffer(w: tw, h: th)
    }
    guard let dst = dst else { return }
    copyFrame(src: pb, dst: dst)
    lock.lock()
    primeBuffers[writeSlot] = dst
    primeCurrent = writeSlot
    primeReady = true
    primeUpdatedAt = now
    primeW = tw
    primeH = th
    lock.unlock()
  }

  /// The current prime, but only if it is newer than the last one
  /// enqueued — the enter() poll uses this so it re-primes only when
  /// a fresher frame arrived while waiting for possible to flip.
  private func takePrimeIfNewer() -> CVPixelBuffer? {
    lock.lock()
    defer { lock.unlock() }
    guard primeReady, primeUpdatedAt > lastPrimedAt else { return nil }
    return primeBuffers[primeCurrent]
  }

  /// A fresh prime-slot buffer, created directly — NOT from the
  /// live-feed pool, so holding a prime can never starve the live
  /// feed. IOSurface-backed, like the pool buffers.
  private func createPrimeBuffer(w: Int, h: Int) -> CVPixelBuffer? {
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: w,
      kCVPixelBufferHeightKey as String: h,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    var out: CVPixelBuffer?
    guard CVPixelBufferCreate(
      kCFAllocatorDefault,
      w,
      h,
      kCVPixelFormatType_32BGRA,
      attrs as CFDictionary,
      &out
    ) == kCVReturnSuccess, let buf = out else { return nil }
    return buf
  }

  /// Synchronous copy into our own IOSurface-backed BGRA pool: the
  /// renderer reuses its buffer on the next render, so the tap's buffer
  /// must not be handed to the display layer as-is. When the target is
  /// smaller than the source (+29 downscale) the copy scales with
  /// vImage (SIMD): both buffers are 32BGRA, 4 bytes/pixel, and scaling
  /// is channel-order agnostic, so ARGB8888 is the right routine for
  /// BGRA data too.
  private func copyFrame(src: CVPixelBuffer, dst: CVPixelBuffer) {
    let sw = CVPixelBufferGetWidth(src)
    let sh = CVPixelBufferGetHeight(src)
    let dw = CVPixelBufferGetWidth(dst)
    let dh = CVPixelBufferGetHeight(dst)
    CVPixelBufferLockBaseAddress(src, .readOnly)
    CVPixelBufferLockBaseAddress(dst, [])
    defer {
      CVPixelBufferUnlockBaseAddress(src, .readOnly)
      CVPixelBufferUnlockBaseAddress(dst, [])
    }
    guard
      let s = CVPixelBufferGetBaseAddress(src),
      let d = CVPixelBufferGetBaseAddress(dst)
    else { return }
    let sb = CVPixelBufferGetBytesPerRow(src)
    let db = CVPixelBufferGetBytesPerRow(dst)
    if sw == dw && sh == dh {
      if sb == db {
        memcpy(d, s, sb * sh)
      } else {
        for y in 0..<sh {
          memcpy(d + y * db, s + y * sb, min(sb, db))
        }
      }
      return
    }
    var srcBuf = vImage_Buffer(
      data: s,
      height: vImagePixelCount(sh),
      width: vImagePixelCount(sw),
      rowBytes: sb
    )
    var dstBuf = vImage_Buffer(
      data: d,
      height: vImagePixelCount(dh),
      width: vImagePixelCount(dw),
      rowBytes: db
    )
    _ = vImageScale_ARGB8888(
      &srcBuf,
      &dstBuf,
      nil,
      vImage_Flags(kvImageNoFlags)
    )
  }

  private func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
    lock.lock()
    defer { lock.unlock() }
    if pool == nil || poolW != w || poolH != h {
      let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: w,
        kCVPixelBufferHeightKey as String: h,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      ]
      var p: CVPixelBufferPool?
      // +32: minimum 8 buffers, not 3 — the layer can hold buffers
      // while backgrounded, and a 3-buffer pool runs dry the moment
      // the layer is a beat slow to release. (The minimum is a
      // minimum, not a maximum: Core Video allocates beyond it, so
      // this is headroom, not a hard bound — the hard bound is the
      // one-in-flight semaphore in ingest().)
      CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        [kCVPixelBufferPoolMinimumBufferCountKey as String: 8] as CFDictionary,
        attrs as CFDictionary,
        &p
      )
      pool = p
      poolW = w
      poolH = h
    }
    guard let pool = pool else { return nil }
    var out: CVPixelBuffer?
    // +32: record the return code — kCVReturnWouldExceedAllocationThreshold
    // means the pool is under pressure (buffers held by the layer);
    // any other failure is a different fault. Never retry in a loop
    // on the render thread.
    let status = CVPixelBufferPoolCreatePixelBuffer(
      kCFAllocatorDefault,
      pool,
      &out
    )
    lastPoolStatus = status
    return status == kCVReturnSuccess ? out : nil
  }

  /// One dropped live frame, for diag(). A live frame is one enqueued
  /// while PiP is up; primes are not counted here.
  private func noteLiveDrop() {
    lock.lock()
    liveDropped += 1
    lock.unlock()
  }

  /// Records the fork's render counters from a tap notification's
  /// userInfo (+32; see MediaKitFrameTap.swift). Runs on the media_kit
  /// render thread, like ingest() — the lock keeps the snapshot and
  /// diag() consistent.
  private func noteRenderCounters(_ userInfo: [AnyHashable: Any]?) {
    guard let info = userInfo else { return }
    lock.lock()
    if let v = info["updateCount"] as? Int { lastUpdateCount = v }
    if let v = info["renderCount"] as? Int { lastRenderCount = v }
    if let v = info["renderMs"] as? Double { lastRenderMs = v }
    lock.unlock()
  }

  /// Holds a latency-critical activity assertion for the PiP lifetime
  /// (+32). Cheap insurance that the system schedules this process's
  /// work promptly while the window is up; the audio background mode
  /// is what keeps the app alive. Idempotent — a second begin while
  /// one is held is a no-op.
  private func beginPipActivity() {
    guard pipActivity == nil else { return }
    pipActivity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .latencyCritical],
      reason: "ZoroX PiP"
    )
  }

  private func endPipActivity() {
    guard let activity = pipActivity else { return }
    pipActivity = nil
    ProcessInfo.processInfo.endActivity(activity)
  }

  /// Starts the native 1 s diag snapshot (+32): a compact diag() via
  /// NSLog every second while PiP is up. Native, not a Dart timer —
  /// the Flutter isolate may be suspended in background, and the
  /// snapshot is the record the next phone test is read against:
  /// ingest flat = tap/renderer stopped; liveEnq flat while ingest
  /// grows = backpressure/pool/layer; liveAgeMs in seconds with
  /// liveEnq growing = the layer is eating frames but not showing
  /// them (then layer status/error and ptsDeltaMs name it).
  /// Idempotent; runs on the main runloop (all callers are main).
  private func startDiagSnapshot() {
    guard diagTimer == nil else { return }
    diagTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
      [weak self] _ in
      guard let self = self else { return }
      self.lock.lock()
      let active = self.pipActive
      self.lock.unlock()
      guard active else { return }
      NSLog("[pip] snap \(self.diag())")
    }
  }

  private func stopDiagSnapshot() {
    diagTimer?.invalidate()
    diagTimer = nil
  }

  /// The format description for a frame's dimensions, cached (+31):
  /// every frame in a session shares dimensions and pixel format, and
  /// creating one per frame is CoreMedia work on the throttled
  /// background feed thread. A dimension change (e.g. a quality
  /// switch) rebuilds it. Format descriptions are immutable and safe
  /// to share across the sample buffers built from them.
  private func formatDescription(for pb: CVPixelBuffer) -> CMVideoFormatDescription? {
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    lock.lock()
    if let cached = cachedFormatDesc, cachedFormatW == w, cachedFormatH == h {
      lock.unlock()
      return cached
    }
    lock.unlock()
    var fmt: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pb,
      formatDescriptionOut: &fmt
    )
    guard let fd = fmt else { return nil }
    lock.lock()
    cachedFormatDesc = fd
    cachedFormatW = w
    cachedFormatH = h
    lock.unlock()
    return fd
  }

  /// Enqueues one frame into the display layer. MAIN QUEUE ONLY
  /// (+32): AVSampleBufferDisplayLayer is main-actor isolated, and
  /// before +32 it was touched from three threads (render thread,
  /// frame queue, main). Every caller runs on main — the live feed
  /// via DispatchQueue.main.async from ingest(), the prime from the
  /// enter poll / lifecycle observers — so this is asserted in debug
  /// builds rather than silently tolerated.
  private func enqueue(
    _ pb: CVPixelBuffer,
    live: Bool = false
  ) {
    assert(
      Thread.isMainThread,
      "ZoroxMpvPipPlugin.enqueue must run on the main queue"
    )
    guard let layer = layer else {
      if live { noteLiveDrop() }
      return
    }
    // +32: a failed layer ignores enqueue while still showing the
    // last frame — exactly a freeze. Log the error, flush, DROP this
    // frame and count it: the next frame is the recovery attempt.
    // Before +32 the code flushed and then enqueued into the failed
    // layer anyway, on every frame. If the layer never recovers,
    // layerFailed grows in diag() and the next round recreates it.
    if layer.status == .failed {
      if let err = layer.error {
        NSLog("ZoroX PiP: layer failed: \(err)")
      }
      layer.flush()
      lock.lock()
      layerFailed += 1
      lock.unlock()
      if live { noteLiveDrop() }
      return
    }
    // Drop rather than queue up: a backlog would show stale frames and
    // grow without bound while the renderer is not ready.
    guard layer.isReadyForMoreMediaData else {
      if live { noteLiveDrop() }
      return
    }
    guard let fd = formatDescription(for: pb) else {
      if live { noteLiveDrop() }
      return
    }
    // +32: the PTS is the HOST clock — the same timeline the layer's
    // controlTimebase runs on (set once in prepare(), re-synced only
    // on play/pause transitions). Before +32 it was
    // CFAbsoluteTimeGetCurrent() against a timebase anchored to the
    // MOVIE position: every frame was ~800M seconds in the layer's
    // future, so the layer queued it and waited, isReadyForMoreMediaData
    // went false, and ingest() dropped everything — the jerky trickle
    // of the +31 phone test. The delta is recorded for diag(): it
    // should read ~0 ms now.
    let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
    if let tb = timebase {
      let layerNow = CMTimebaseGetTime(tb)
      let deltaMs = Int64(
        (hostNow.seconds - layerNow.seconds) * 1000
      )
      lock.lock()
      lastPtsDeltaMs = deltaMs
      lock.unlock()
    }
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: hostNow,
      decodeTimeStamp: .invalid
    )
    var sb: CMSampleBuffer?
    let st = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pb,
      formatDescription: fd,
      sampleTiming: &timing,
      sampleBufferOut: &sb
    )
    guard st == noErr, let s = sb else {
      if live { noteLiveDrop() }
      return
    }
    // mpv already timed the display; without this, frames judged late
    // are dropped silently — the classic black or frozen PiP.
    // The dictionaries returned by CMSampleBufferGetSampleAttachmentsArray
    // are the sample buffer's live attachments, so mutating the first
    // one in place is enough — no setter call needed.
    // (CMSampleBufferSetSampleAttachmentsArray is not visible to Swift
    // in this SDK, and the old code also subscripted the array itself
    // with a String key instead of its first dictionary.)
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      s,
      createIfNecessary: true
    ) as? [NSMutableDictionary],
      let dict = attachments.first
    {
      dict.setObject(
        true,
        forKey: kCMSampleAttachmentKey_DisplayImmediately as NSString
      )
    }
    layer.enqueue(s)
    frameCount += 1
    if live {
      lock.lock()
      liveEnqueued += 1
      lastLiveEnqueueAt = CFAbsoluteTimeGetCurrent()
      lock.unlock()
    }
  }

  // MARK: - AVPictureInPictureControllerDelegate

  public func pictureInPictureControllerWillStartPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    // Full-rate frames from here on.
    lock.lock()
    pipActive = true
    lock.unlock()
    // +32: the auto-PiP path reaches here without enter(), so the
    // activity assertion and the diag snapshot start here too (the
    // button path already started them in attemptEnter; both helpers
    // are idempotent).
    beginPipActivity()
    startDiagSnapshot()
  }

  public func pictureInPictureControllerDidStartPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    channel.invokeMethod("pipStarted", arguments: nil)
  }

  public func pictureInPictureControllerDidStopPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    stopPipFeed()
    channel.invokeMethod("pipStopped", arguments: ["restored": false])
  }

  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
      completionHandler: @escaping (Bool) -> Void
  ) {
    stopPipFeed()
    channel.invokeMethod("pipStopped", arguments: ["restored": true])
    completionHandler(true)
  }

  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    stopPipFeed()
    channel.invokeMethod(
      "pipFailed",
      arguments: ["reason": "\(error.localizedDescription) | \(diag())"]
    )
  }

  /// Stops the PiP feed and empties the display layer (+29): the layer
  /// renders above Flutter's scene, so a stale frame left in it would
  /// keep showing as a second copy of the video inside the app after
  /// PiP stops. The prime (+30) is held in memory, not in the layer,
  /// so the next start re-primes from the next frame arrival.
  /// +32: bumps the session generation (a queued live frame must not
  /// enter the next session), ends the activity assertion and the
  /// diag snapshot.
  private func stopPipFeed() {
    stopDiagSnapshot()
    endPipActivity()
    lock.lock()
    pipActive = false
    sessionGeneration += 1
    let targetLayer = layer
    lock.unlock()
    targetLayer?.flushAndRemoveImage()
  }

  public func pictureInPictureControllerIsPlaybackPaused(
    _ controller: AVPictureInPictureController
  ) -> Bool {
    !playing
  }

  /// The clock the PiP scrubber reads (+43): the display layer's
  /// controlTimebase, which runs on the host clock — or the host clock
  /// itself before the timebase exists. The timebase is frozen while
  /// paused, so this holds still then and ticks at rate 1 while
  /// playing.
  private func pipClockNow() -> CMTime {
    if let tb = timebase {
      return CMTimebaseGetTime(tb)
    }
    return CMClockGetTime(CMClockGetHostTimeClock())
  }

  public func pictureInPictureControllerTimeRangeForPlayback(
    _ controller: AVPictureInPictureController
  ) -> CMTimeRange {
    if duration > 0 && duration.isFinite {
      // +43: the scrubber's position is the layer's timebase time
      // mapped into this range — and the timebase runs on the HOST
      // clock (~800M s since 2001), not the movie clock. A range
      // starting at zero put every timebase reading far past its end,
      // so the bar clamped to full whatever had played. Anchor the
      // range to the timebase's now, minus the playhead: the bar then
      // reads position/duration, advances with the timebase while
      // playing, and holds still while paused.
      let now = pipClockNow()
      return CMTimeRange(
        start: CMTime(
          seconds: now.seconds - lastPosition,
          preferredTimescale: 1000
        ),
        duration: CMTime(seconds: duration, preferredTimescale: 1000)
      )
    }
    return CMTimeRange(
      start: .negativeInfinity,
      duration: .positiveInfinity
    )
  }

  // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    self.playing = playing
    channel.invokeMethod("pipSetPlaying", arguments: playing)
    pip?.invalidatePlaybackState()
  }

  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    channel.invokeMethod("pipSkip", arguments: Int(skipInterval.seconds))
    completionHandler()
  }

  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    timeToSeekTo time: CMTime,
    completion completionHandler: @escaping (Bool) -> Void
  ) {
    // +43: the range is anchored to the layer timebase (see
    // pictureInPictureControllerTimeRangeForPlayback), so the time
    // handed back is a host-clock time, not a movie position. The
    // movie position it means is the time minus the range's start;
    // the skip is that position minus where playback is now — which
    // is just the time minus the timebase's now.
    let now = pipClockNow()
    channel.invokeMethod(
      "pipSkip",
      arguments: Int(time.seconds - now.seconds)
    )
    completionHandler(true)
  }

  // Required by AVPictureInPictureSampleBufferPlaybackDelegate (the
  // fifth of its five callbacks). The parameter type is CMVideoDimensions
  // in this SDK — the earlier CMVideoSize spelling is not in scope for
  // Swift here, which is why the method was briefly deleted; deleting it
  // broke conformance (build 6af8e5c9: "does not conform to protocol
  // 'AVPictureInPictureSampleBufferPlaybackDelegate'"). The body is a
  // no-op — aspect is preserved by the layer's .resizeAspect gravity.
  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
  }
}
