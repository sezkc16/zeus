#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

public protocol ResizableTextureProtocol: NSObject, FlutterTexture {
  func resize(_ size: CGSize)
  func render(_ size: CGSize)
  // Zeus fork (build 74): frees the mpv render context now, on the
  // calling thread, so another texture can take the core over (one
  // render context per core). The last frame stays readable. Idempotent.
  func disposeRenderer()
}
