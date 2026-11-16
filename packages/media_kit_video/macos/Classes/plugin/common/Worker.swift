// https://stackoverflow.com/questions/49043257/how-to-ensure-to-run-some-code-on-same-background-thread/49075382#49075382
class Worker {
  public typealias Job = () -> Void

  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSRecursiveLock()
  private var thread: Thread!
  private var queue = [Job]()
  private var canceled: Bool = false

  init() {
    thread = Thread(block: loop)
    // +32 (ZoroX): the render thread. A plain Thread runs at default
    // QoS; the software render is the heaviest work in the process
    // and iOS throttles backgrounded apps hard, so the thread that
    // renders (and taps) frames for PiP runs user-interactive.
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  public func cancel() {
    signalCancel()
    thread.cancel()
  }

  public func enqueue(_ job: @escaping Job) {
    locked {
      queue.append(job)
    }

    semaphore.signal()
  }

  private func loop() {
    while true {
      semaphore.wait()

      if isCanceled() {
        return
      }

      let job = getFirstJob()
      job()
    }
  }

  private func signalCancel() {
    locked {
      canceled = true
    }

    semaphore.signal()
  }

  private func isCanceled() -> Bool {
    let c = locked {
      canceled
    }

    return c
  }

  private func getFirstJob() -> Job {
    let job = locked {
      queue.removeFirst()
    }

    return job
  }

  private func locked<T>(do block: () -> T) -> T {
    lock.lock()
    defer {
      lock.unlock()
    }

    return block()
  }
}
