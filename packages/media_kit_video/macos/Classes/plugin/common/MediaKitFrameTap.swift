import CoreVideo
import Foundation

/// Frame-export tap for ZoroX's iOS mpv Picture-in-Picture.
///
/// ZoroX fork addition (see FORK.md): the software renderer ([TextureSW])
/// posts every completed frame on this notification. The ZoroX PiP plugin
/// (`zorox_mpv_pip`) observes it and copies the frame into its own pool —
/// it must copy synchronously on receipt, because [TextureSW] reuses a
/// 3-buffer pool and the next render may overwrite this buffer.
///
/// Deliberately `NotificationCenter`, not a direct call: the PiP plugin is
/// a separate module and must not import `media_kit_video`. The post costs
/// one no-op dispatch while nobody observes it, so normal playback — and
/// every platform the PiP plugin does not run on — is unaffected.
///
/// The notification is posted on the media_kit worker thread that ran the
/// render, while the buffer is still locked by the renderer, so the memory
/// is stable for the observer's synchronous copy.
public extension Notification.Name {
  static let zoroxMpvRenderedFrame = Notification.Name(
    "ZoroXMpvRenderedFrame",
  )
}

/// Lock-guarded counters for the software render loop (+32, ZoroX).
///
/// The PiP plugin reads these from the frame tap's userInfo and prints
/// them in its 1 s native diag snapshot, so a stall can be told apart
/// as renderer vs pipeline: if the mpv update count grows but the
/// render count doesn't, the Worker/main hop is the problem; if the
/// render count grows but the plugin's ingest count doesn't, the tap
/// is. Diagnostic only — written from mpv's callback thread and the
/// media_kit worker thread, read from the render thread, so the state
/// lives behind a lock. A single shared instance: the class reference
/// is a `let` and the mutable state is locked, so it is safe to touch
/// from any thread (Swift 6 concurrency-safe by construction).
public final class ZoroXMpvRenderStats {
  public static let shared = ZoroXMpvRenderStats()

  private let lock = NSLock()
  private var updateCount = 0
  private var renderCount = 0
  private var lastRenderMs: Double = 0

  private init() {}

  public func noteUpdate() {
    lock.lock()
    defer { lock.unlock() }
    updateCount += 1
  }

  public func noteRender(durationMs: Double) {
    lock.lock()
    defer { lock.unlock() }
    renderCount += 1
    lastRenderMs = durationMs
  }

  public func snapshot() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    return [
      "updateCount": updateCount,
      "renderCount": renderCount,
      "renderMs": lastRenderMs,
    ]
  }
}
