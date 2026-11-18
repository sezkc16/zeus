#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

// This class creates and manipulates the different types of FlutterTexture,
// handles resizing, rendering calls, and notify Flutter when a new frame is
// available to render.
//
// To improve the user experience, a worker is used to execute heavy tasks on a
// dedicated thread.
public class VideoOutput: NSObject {
  // Will be called on the main thread
  public typealias TextureUpdateCallback = (Int64, CGSize) -> Void

  private static let isSimulator: Bool = {
    let isSim: Bool
    #if targetEnvironment(simulator)
      isSim = true
    #else
      isSim = false
    #endif
    return isSim
  }()

  private let handle: OpaquePointer
  private let enableHardwareAcceleration: Bool
  // Zeus fork (build 74): the renderer in use right now — it can be
  // swapped under a playing core (see setRenderer). Worker thread only.
  private var hardwareRenderer: Bool = false
  // The one texture Flutter knows about. It shows the current
  // renderer's frames, and across a swap the outgoing renderer's last
  // frame until the incoming one has drawn real picture.
  private var host: SwitchableTexture!
  private var holding: Bool = false
  private var holdRenders: Int = 0
  private let registry: FlutterTextureRegistry
  private let textureUpdateCallback: TextureUpdateCallback
  private let worker: Worker = .init()
  private var width: Int64?
  private var height: Int64?
  private var texture: ResizableTextureProtocol!
  private var textureId: Int64 = -1
  private var currentSize: CGSize = CGSize.zero
  private var disposed: Bool = false

  init(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    registry: FlutterTextureRegistry,
    textureUpdateCallback: @escaping TextureUpdateCallback
  ) {
    let handle = OpaquePointer(bitPattern: Int(handle))
    assert(handle != nil, "handle casting")

    self.handle = handle!
    width = configuration.width
    height = configuration.height
    enableHardwareAcceleration = configuration.enableHardwareAcceleration
    self.registry = registry
    self.textureUpdateCallback = textureUpdateCallback

    super.init()

    worker.enqueue {
      self._init()
    }
  }

  deinit {
    worker.cancel()

    disposed = true
    disposeTextureId()
  }

  public func setSize(width: Int64?, height: Int64?) {
    worker.enqueue {
      self.width = width
      self.height = height
    }
  }

  private func _init() {
    let enableHardwareAcceleration =
      VideoOutput.isSimulator ? false : enableHardwareAcceleration

    NSLog(
      "VideoOutput: enableHardwareAcceleration: \(enableHardwareAcceleration)"
    )

    if VideoOutput.isSimulator {
      NSLog(
        "VideoOutput: warning: hardware rendering is disabled in the iOS simulator, due to an incompatibility with OpenGL ES"
      )
    }

    texture = makeTexture(hardware: enableHardwareAcceleration)
    hardwareRenderer = enableHardwareAcceleration
    host = SwitchableTexture(texture)

    DispatchQueue.main.sync { [weak self]() in
      guard let that = self else {
        return
      }
      that.registerTextureId()
    }
  }

  private func makeTexture(hardware: Bool) -> ResizableTextureProtocol {
    if hardware {
      return SafeResizableTexture(
        TextureHW(
          handle: handle,
          // Use `weak self` to prevent memory leaks
          updateCallback: { [weak self]() in
            guard let that = self else {
              return
            }
            that.updateCallback()
          }
        )
      )
    }
    return SafeResizableTexture(
      TextureSW(
        handle: handle,
        // Use `weak self` to prevent memory leaks
        updateCallback: { [weak self]() in
          guard let that = self else {
            return
          }
          that.updateCallback()
        }
      )
    )
  }

  // Zeus fork (build 74): swaps the renderer (hardware <-> software)
  // under the SAME mpv core, so a PiP round trip no longer needs a
  // second player and a re-open of the source.
  //
  // libmpv allows one render context per core, so the outgoing
  // context is freed first — mpv answers that by shutting its video
  // chain down (audio and the demuxer keep running) — and the caller
  // then switches the video track back on, which mpv brings up on the
  // new context. `completion` runs on the main thread once the new
  // context exists (the software one is created on the main queue,
  // and this completion is queued behind it).
  public func setRenderer(
    hardware: Bool,
    width: Int64?,
    height: Int64?,
    completion: @escaping (Bool) -> Void
  ) {
    worker.enqueue {
      let ok = self._setRenderer(
        hardware: hardware,
        width: width,
        height: height
      )
      DispatchQueue.main.async {
        completion(ok)
      }
    }
  }

  private func _setRenderer(
    hardware: Bool,
    width: Int64?,
    height: Int64?
  ) -> Bool {
    let want = VideoOutput.isSimulator ? false : hardware
    if disposed || texture == nil || host == nil {
      return false
    }

    self.width = width
    self.height = height

    if want == hardwareRenderer {
      // Same renderer: only the size changed; the next frame applies it.
      return true
    }

    NSLog("VideoOutput: setRenderer: hardware: \(want)")

    // The outgoing picture stays on screen from here.
    host.beginHold()
    holding = true
    holdRenders = 0

    // Frees the mpv render context; returns once mpv's video output
    // is gone.
    let old: ResizableTextureProtocol = texture
    old.disposeRenderer()

    let next = makeTexture(hardware: want)
    texture = next
    hardwareRenderer = want
    currentSize = CGSize.zero
    host.setChild(next)

    return true
  }

  // Must be run on the main thread
  private func registerTextureId() {
    // Textures must be registered on the platform thread.
    textureId = registry.register(host)
    // textureUpdateCallback must run on the main thread
    textureUpdateCallback(textureId, CGSize(width: 0, height: 0))
  }

  private func disposeTextureId() {
    let registry_ = self.registry
    let textureId_ = self.textureId
    textureId = -1
    DispatchQueue.main.async {
      // Textures must be unregistered on the platform thread
      registry_.unregisterTexture(textureId_)
    }
  }

  public func updateCallback() {
    worker.enqueue {
      self._updateCallback()
    }
  }

  private func _updateCallback() {
    if disposed || texture == nil {
      return
    }

    // Zeus fork (build 74): across a renderer swap nothing is drawn
    // until mpv's video output is configured again — a render before
    // that is a black frame, and with a fixed size it would both end
    // the held picture and prime the PiP layer with black.
    if holding {
      let params = MPVHelpers.getVideoOutParams(handle)
      if params.dw <= 0 || params.dh <= 0 {
        return
      }
    }

    let size = videoSize

    if size.width == 0 || size.height == 0 {
      return
    }

    if currentSize != size {
      currentSize = size

      texture.resize(size)
      DispatchQueue.main.sync { [weak self] in
        guard let that = self else { return }
        // textureUpdateCallback must run on the main thread
        that.textureUpdateCallback(that.textureId, size)
      }
    }

    if disposed {
      return
    }

    texture.render(size)
    if holding {
      // The first draws after a reconfigure can still be empty; the
      // held picture goes on the third — or, for a paused film (mpv
      // draws its one frame and stops), a moment after the first.
      holdRenders += 1
      if holdRenders >= 3 {
        holding = false
        host.endHold()
      } else if holdRenders == 1 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
          guard let that = self else { return }
          that.worker.enqueue {
            that.endHoldIfNeeded()
          }
        }
      }
    }
    DispatchQueue.main.sync { [weak self] in
      guard let that = self else { return }
      // Textures must be marked as available from the main thread
      that.registry.textureFrameAvailable(that.textureId)
    }
  }

  // Worker thread. Ends a hold that the render count did not end (a
  // paused film) and shows the incoming renderer's frame.
  private func endHoldIfNeeded() {
    if disposed || !holding {
      return
    }
    holding = false
    host.endHold()
    DispatchQueue.main.sync { [weak self] in
      guard let that = self else { return }
      that.registry.textureFrameAvailable(that.textureId)
    }
  }

    private var videoSize: CGSize {
        // fixed size
        if width != nil && height != nil {
            return CGSize(
                width: Double(width!),
                height: Double(height!)
            )
        }
        
        let params = MPVHelpers.getVideoOutParams(handle)
        return CGSize(
            width: Double(width ?? (params.rotate == 0 || params.rotate == 180
                                    ? params.dw
                                    : params.dh)),
            height: Double(height ?? (params.rotate == 0 || params.rotate == 180
                                      ? params.dh
                                      : params.dw))
        )
  }
}

// Zeus fork (build 74): the texture registered with Flutter. It
// forwards to the current renderer's texture; across a renderer swap
// it keeps handing out the outgoing renderer's last frame until the
// incoming one has drawn real picture (see VideoOutput.setRenderer),
// so the swap shows no black and the texture id never changes.
public class SwitchableTexture: NSObject, FlutterTexture {
  private let lock = NSLock()
  private var child: FlutterTexture
  private var held: CVPixelBuffer?
  private var holding = false

  init(_ child: FlutterTexture) {
    self.child = child
  }

  public func setChild(_ child: FlutterTexture) {
    lock.lock()
    self.child = child
    lock.unlock()
  }

  public func beginHold() {
    lock.lock()
    let current = child
    lock.unlock()

    let frame = current.copyPixelBuffer()?.takeRetainedValue()

    lock.lock()
    held = frame
    holding = true
    lock.unlock()
  }

  public func endHold() {
    lock.lock()
    holding = false
    held = nil
    lock.unlock()
  }

  public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    let frame = holding ? held : nil
    let isHolding = holding
    let current = child
    lock.unlock()

    if let frame = frame {
      return Unmanaged.passRetained(frame)
    }
    if isHolding {
      // Nothing was captured: draw nothing rather than the incoming
      // renderer's empty frames.
      return nil
    }
    return current.copyPixelBuffer()
  }
}
