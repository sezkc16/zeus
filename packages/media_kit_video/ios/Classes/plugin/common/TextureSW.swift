#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif
import Accelerate

public class TextureSW: NSObject, FlutterTexture, ResizableTextureProtocol {
  public typealias UpdateCallback = () -> Void

  private let handle: OpaquePointer
  private let updateCallback: UpdateCallback
  private var renderContext: OpaquePointer?
  private var textureContexts = SwappableObjectManager<TextureSWContext>(
    objects: [],
    skipCheckArgs: true
  )

  // +43 (ZoroX): the software renderer's gamma. mpv's SW backend
  // (libswscale, mpv 0.36 as bundled by media_kit_libs_ios_video
  // 1.1.4) expands the limited range correctly but never converts the
  // transfer function, so this buffer holds bt.1886-encoded values
  // for most films; the hardware path's gl_video converts to the sRGB
  // the display assumes, so the same frame looked faded here (lifted
  // shadows, grey veil) and right there. A per-channel LUT maps the
  // source TRC to sRGB right after mpv renders — both paths then show
  // the same colours, in the app and in the PiP window (which taps
  // this same buffer). Only TRCs that need it (bt.1886 and other pure
  // powers above 2.2); bt.709/sRGB are left alone, and HDR gets a
  // hard clip at the 100-nit SDR white instead of a gamma fix — the
  // same curve as the hardware path's `tone-mapping: clip` — PQ (see
  // pqToneMapLut, +46, clip since +50) and HLG (see hlgToneMapLut,
  // +47, clip since +50), each with its own decode. (+50: the +46/+47
  // BT.2390 EETF rolled diffuse white off and made PiP ON ~11%
  // darker than PiP OFF on HDR files; a clip matches the hardware
  // path exactly.)
  // The TRC is read once per video size from video-params/gamma;
  // unknown defaults to bt.1886, the TRC mpv itself guesses for SDR.
  private var swLutExponent: Double?
  /// +46: the file's peak luminance in nits while the PQ tone map is
  /// active (nil otherwise). Cached per video size next to the exponent.
  private var swLutPQPeak: Double?
  /// +47: same, while the HLG tone map is active (nil otherwise).
  private var swLutHLGPeak: Double?
  /// +57: the `tone-mapping` value the PQ/HLG LUT was built for
  /// ("clip", "bt.2390" or "auto"), read live each frame. A change
  /// rebuilds the LUT at once, so a preset pick in the Video panel
  /// changes the picture on the current video. Unreadable means
  /// "clip" (see readToneMapping).
  private var swLutToneMapping: String?
  private var swLutSize: CGSize?
  private var swLut: [UInt8]?
  private static let swLutIdentity: [UInt8] = (0...255).map { UInt8($0) }

  init(
    handle: OpaquePointer,
    updateCallback: @escaping UpdateCallback
  ) {
    self.handle = handle
    self.updateCallback = updateCallback

    super.init()

    DispatchQueue.main.async {
      self.initMPV()
    }
  }

  deinit {
    disposePixelBuffer()
    disposeMPV()
  }

  public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    let textureContext = textureContexts.current
    if textureContext == nil {
      return nil
    }

    return Unmanaged.passRetained(textureContext!.pixelBuffer)
  }

  private func initMPV() {
    let api = UnsafeMutableRawPointer(
      mutating: (MPV_RENDER_API_TYPE_SW as NSString).utf8String
    )
    var params: [mpv_render_param] = [
      mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
      mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
    ]

    MPVHelpers.checkError(
      mpv_render_context_create(&renderContext, handle, &params)
    )

    mpv_render_context_set_update_callback(
      renderContext,
      { (ctx) in
        // +32 (ZoroX): count mpv's update callbacks — the diag snapshot
        // tells an mpv stall (this stops) apart from a Worker/main-hop
        // stall (this grows but renders don't).
        ZoroXMpvRenderStats.shared.noteUpdate()
        let that = unsafeBitCast(ctx, to: TextureSW.self)
        DispatchQueue.main.async {
          that.updateCallback()
        }
      },
      UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    )
  }

  private func disposeMPV() {
    mpv_render_context_set_update_callback(renderContext, nil, nil)
    mpv_render_context_free(renderContext)
  }

  public func resize(_ size: CGSize) {
    if size.width == 0 || size.height == 0 {
      return
    }

    NSLog("TextureSW: resize: \(size.width)x\(size.height)")
    createPixelBuffer(size)
  }

  private func createPixelBuffer(_ size: CGSize) {
    disposePixelBuffer()

    textureContexts.reinit(
      objects: [
        TextureSWContext(size: size),
        TextureSWContext(size: size),
        TextureSWContext(size: size),
      ],
      skipCheckArgs: true
    )
  }

  private func disposePixelBuffer() {
    textureContexts.reinit(objects: [], skipCheckArgs: true)
  }

  public func render(_ size: CGSize) {
    let textureContext = textureContexts.nextAvailable()
    if textureContext == nil {
      return
    }

    CVPixelBufferLockBaseAddress(
      textureContext!.pixelBuffer,
      CVPixelBufferLockFlags(rawValue: 0)
    )
    defer {
      CVPixelBufferUnlockBaseAddress(
        textureContext!.pixelBuffer,
        CVPixelBufferLockFlags(rawValue: 0)
      )
    }

    var ssize: [Int32] = [Int32(size.width), Int32(size.height)]
    let format: String = "bgr0"
    var pitch: Int = CVPixelBufferGetBytesPerRow(textureContext!.pixelBuffer)
    let buffer = CVPixelBufferGetBaseAddress(textureContext!.pixelBuffer)

    // pointers
    let ssizePtr = ssize.withUnsafeMutableBytes {
      $0.baseAddress?.assumingMemoryBound(to: Int32.self)
    }
    let formatPtr = UnsafeMutablePointer(
      mutating: (format as NSString).utf8String
    )
    let pitchPtr = withUnsafeMutablePointer(to: &pitch) { $0 }
    let bufferPtr = buffer!.assumingMemoryBound(to: UInt8.self)

    var params: [mpv_render_param] = [
      mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: ssizePtr),
      mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: formatPtr),
      mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: pitchPtr),
      mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: bufferPtr),
      mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
    ]

    // +32 (ZoroX): time the render — the diag snapshot shows whether
    // the software render itself is slow (renderMs in the tens of ms)
    // or the frames simply never arrive.
    let renderStart = DispatchTime.now()
    mpv_render_context_render(renderContext, &params)
    let renderMs =
      Double(
        DispatchTime.now().uptimeNanoseconds
          - renderStart.uptimeNanoseconds
      ) / 1_000_000
    ZoroXMpvRenderStats.shared.noteRender(durationMs: renderMs)

    // +43: correct the SW path's gamma (see applySwGammaCorrection):
    // mpv writes the video's own transfer function into this buffer
    // while the hardware path hands Flutter sRGB values, so without
    // this the same frame looks faded here and right there.
    applySwGammaCorrection(
      size: size,
      pitch: pitch,
      buffer: bufferPtr
    )

    textureContexts.pushAsReady(textureContext!)

    // ZoroX fork: export the completed frame for the iOS mpv PiP plugin
    // (see MediaKitFrameTap.swift). Posted while the buffer is still
    // locked by the defer above, so the observer's synchronous copy reads
    // stable memory; the pool reuses this buffer on a later render.
    // +32: the render counters ride in userInfo for the plugin's diag.
    NotificationCenter.default.post(
      name: .zoroxMpvRenderedFrame,
      object: textureContext!.pixelBuffer,
      userInfo: ZoroXMpvRenderStats.shared.snapshot()
    )
  }

  /// The video's transfer function as a pure power (bt.1886 -> 2.4),
  /// or 2.4 when mpv cannot say (no video yet, or an untagged file —
  /// mpv guesses bt.1886 for SDR itself). PQ is branched off before
  /// this — see applySwGammaCorrection — so it never reaches here.
  private func readVideoGammaExponent() -> Double {
    guard
      let cStr = mpv_get_property_string(handle, "video-params/gamma")
    else { return 2.4 }
    defer { mpv_free(cStr) }
    switch String(cString: cStr) {
    case "bt.1886", "gamma2.4":
      return 2.4
    case "gamma2.6":
      return 2.6
    case "gamma2.8":
      return 2.8
    default:
      // bt.709, srgb, gamma2.2 and every HDR/log curve: no correction
      // (2.2 makes the LUT an identity, so it is skipped below).
      return 2.2
    }
  }

  /// The raw video-params/gamma string ("bt.1886", "pq", ...), or ""
  /// when mpv cannot say. The exponent reader above maps it to a power;
  /// the PQ branch needs the name itself.
  private func readVideoGammaName() -> String {
    guard
      let cStr = mpv_get_property_string(handle, "video-params/gamma")
    else { return "" }
    defer { mpv_free(cStr) }
    return String(cString: cStr)
  }

  /// +57: the live `tone-mapping` option ("clip", "bt.2390",
  /// "auto", ...), as the Video output preset set it on the hardware
  /// path — the software renderer reads the same value to pick its
  /// LUT, so one setting drives both paths. "clip" when mpv cannot
  /// say (the option is registered globally so it should read; the
  /// fallback is the current behaviour, no regression). Trimmed and
  /// lowercased by the caller where it matters.
  private func readToneMapping() -> String {
    guard
      let cStr = mpv_get_property_string(handle, "tone-mapping")
    else { return "clip" }
    defer { mpv_free(cStr) }
    return String(cString: cStr)
  }

  /// +57: does a `tone-mapping` value mean the BT.2390 EETF? Mirrors
  /// the Dart table (see swToneMapCurveForToneMapping in
  /// mpv_ios_options.dart): `bt.2390` and `auto` mean the EETF (mpv's
  /// `auto` maps to bt.2390 on vo=gpu); anything else — including an
  /// unreadable property — means the clip, the safe default that
  /// matches the hardware path's `tone-mapping: clip`.
  private static func toneMappingIsEetf(_ value: String) -> Bool {
    switch value.trimmingCharacters(in: .whitespaces).lowercased() {
    case "bt.2390", "auto": return true
    default: return false
    }
  }

  /// The file's peak luminance in nits, from video-params/sig-peak.
  /// mpv reports sig-peak relative to a 100-nit reference, so 10.0
  /// means a 1,000-nit master. Falls back to 1,000 nits when the
  /// property is missing or nonsense — the tone map then assumes the
  /// common 1,000-nit master rather than skipping the correction.
  private func readSigPeakNits() -> Double {
    var peak: Double = 0
    guard
      mpv_get_property(
        handle,
        "video-params/sig-peak",
        MPV_FORMAT_DOUBLE,
        &peak
      ) >= 0,
      peak.isFinite, peak > 0
    else { return 1000 }
    return min(max(peak * 100, 100), 10000)
  }

  // +46: SMPTE ST 2084 (PQ) constants, shared by pqEncode/pqEotf.
  private static let pqM1 = 2610.0 / 16384.0
  private static let pqM2 = 2523.0 / 4096.0 * 128.0
  private static let pqC1 = 3424.0 / 4096.0
  private static let pqC2 = 2413.0 / 4096.0 * 32.0
  private static let pqC3 = 2392.0 / 4096.0 * 32.0

  /// Linear light (0..1, 1 = 10,000 nits) -> PQ code value (ST 2084).
  private static func pqEncode(_ y: Double) -> Double {
    let ym = pow(max(0.0, y), pqM1)
    return pow((pqC1 + pqC2 * ym) / (1.0 + pqC3 * ym), pqM2)
  }

  /// PQ code value -> linear light (0..1, 1 = 10,000 nits).
  private static func pqEotf(_ c: Double) -> Double {
    let cPow = pow(max(0.0, c), 1.0 / pqM2)
    let den = pqC2 - pqC3 * cPow
    guard den > 0 else { return 1.0 }
    return pow(max(0.0, cPow - pqC1) / den, 1.0 / pqM1)
  }

  /// Linear light relative to display white (0..1) -> sRGB code value.
  private static func srgbEncode(_ l: Double) -> Double {
    if l <= 0.0031308 { return 12.92 * l }
    return 1.055 * pow(l, 1.0 / 2.4) - 0.055
  }

  // +57: the BT.2390 EETF helper, re-added from +46/+47 (removed in
  // +50 when the clip became the only curve). The Video output preset
  // selects it again: SDR tone mapped and Compatibility read
  // `tone-mapping` bt.2390/auto and get the EETF LUT below; Native
  // EDR and Custom-with-nothing-stored keep the clip. See
  // toneMappingIsEetf for the table.
  /// The BT.2390 EETF (see pqToneMapLutEetf): tone-maps a PQ code
  /// (0..1), `masteringWhite` the PQ code of the source peak,
  /// `maxLum` the display peak / source peak in PQ code words, `ks`
  /// the knee. Returns the tone-mapped PQ code. Shared by the PQ LUT
  /// and the HLG LUT (+47), so both HDR curves roll highlights off
  /// identically.
  private static func toneMapPQCode(
    _ code: Double,
    masteringWhite: Double,
    maxLum: Double,
    ks: Double
  ) -> Double {
    var p = code / masteringWhite
    if p > 1.0 { p = 1.0 }
    let p2: Double
    if p <= ks || ks >= 1.0 {
      p2 = p
    } else {
      let t = (p - ks) / (1.0 - ks)
      let t2 = t * t
      let t3 = t2 * t
      p2 =
        (2 * t3 - 3 * t2 + 1) * ks
        + (t3 - 2 * t2 + t) * (1.0 - ks)
        + (-2 * t3 + 3 * t2) * maxLum
    }
    return p2 * masteringWhite
  }

  /// PQ (HDR) -> SDR tone-mapping LUT: per 8-bit PQ code, a hard clip
  /// at the 100-nit SDR white — the same curve as the hardware path's
  /// `tone-mapping: clip` (see kMpvIosOptions). +46 used a BT.2390
  /// EETF here instead, but the EETF rolled diffuse white off
  /// (100 nits in -> ~0.84 sRGB on SW vs ~0.97 on HW for a 1,000-nit
  /// master) so PiP ON looked ~11% darker than PiP OFF on HDR files
  /// (user proof 2026-11-16, Avengers Endgame 4K). A clip matches
  /// the hardware path exactly; the EETF's highlight roll-off is
  /// what the hardware path does not do. PQ is absolute, so the clip
  /// does not depend on the mastering peak — `peakNits` is unused
  /// (kept in the signature so the PQ/HLG call sites stay
  /// symmetric). HLG has its own LUT (see hlgToneMapLut, +47) —
  /// same clip, different decode.
  private static func pqToneMapLut(peakNits: Double) -> [UInt8] {
    _ = peakNits
    let displayWhite = pqEncode(0.01)  // 100 nits, the SDR white
    return (0...255).map { i in
      let code = Double(i) / 255.0
      // Absolute PQ code, clipped at the display white.
      let newCode = min(code, displayWhite)
      // Absolute PQ code -> linear light (1.0 = 10,000 nits) -> relative
      // to the 100-nit SDR white -> sRGB code value.
      let linear = pqEotf(newCode) / 0.01
      let s = srgbEncode(min(1.0, max(0.0, linear)))
      return UInt8(max(0, min(255, (s * 255.0).rounded())))
    }
  }

  /// PQ (HDR) -> SDR tone-mapping LUT, BT.2390 EETF version (+57):
  /// per 8-bit PQ code, BT.2390 EETF in PQ space (verified against
  /// the reference curve in +46: 100 nits in -> ~69 nits out, 1,000
  /// nits in -> 100 nits out, for a 1,000-nit master on a 100-nit
  /// display) then PQ-decode and sRGB-encode. The EETF works on the
  /// PQ signal normalised by the mastering white: below the knee
  /// (KS = 1.5*maxLum - 0.5, maxLum = display peak / source peak in
  /// PQ code words) the signal passes 1:1, so shadows and diffuse
  /// white stay bright; above it a Hermite spline rolls the
  /// highlights off onto the display peak. A naive linear
  /// scale-to-peak would darken diffuse white to ~35% grey instead.
  /// HLG has its own LUT (see hlgToneMapLutEetf, +47) — same EETF,
  /// different decode. Selected when the live `tone-mapping` is
  /// bt.2390/auto (see toneMappingIsEetf).
  private static func pqToneMapLutEetf(peakNits: Double) -> [UInt8] {
    let masteringWhite = pqEncode(peakNits / 10000.0)
    guard masteringWhite > 0 else { return swLutIdentity }
    let displayWhite = pqEncode(0.01)  // 100 nits, the SDR white
    let maxLum = min(1.0, displayWhite / masteringWhite)
    let ks = max(0.0, min(1.0, 1.5 * maxLum - 0.5))
    return (0...255).map { i in
      let code = Double(i) / 255.0
      let newCode = toneMapPQCode(
        code,
        masteringWhite: masteringWhite,
        maxLum: maxLum,
        ks: ks
      )
      // Absolute PQ code -> linear light (1.0 = 10,000 nits) -> relative
      // to the 100-nit SDR white -> sRGB code value.
      let linear = pqEotf(newCode) / 0.01
      let s = srgbEncode(min(1.0, max(0.0, linear)))
      return UInt8(max(0, min(255, (s * 255.0).rounded())))
    }
  }

  // +47: HLG (ARIB STD-B67 / BT.2100) inverse OETF constants.
  private static let hlgA = 0.17883277
  private static let hlgB = 0.28466892
  private static let hlgC = 0.55991073

  /// HLG code value (0..1) -> scene-linear light (0..1). The OETF is
  /// sqrt(3E) below the 0.5 breakpoint (E = 1/12) and a*ln(12E - b) + c
  /// above it; the inverse mirrors both branches.
  private static func hlgInverseOetf(_ ePrime: Double) -> Double {
    if ePrime <= 0.5 {
      return (ePrime * ePrime) / 3.0
    }
    return (exp((ePrime - hlgC) / hlgA) + hlgB) / 12.0
  }

  /// HLG (HDR) -> SDR tone-mapping LUT: per 8-bit HLG code, inverse
  /// HLG OETF to scene-linear light, the reference HLG OOTF gamma
  /// (1.2) to display-linear light, scale by the mastering peak,
  /// then a hard clip at the 100-nit SDR white — the same curve as
  /// the hardware path's `tone-mapping: clip` (see pqToneMapLut for
  /// why the +47 BT.2390 EETF was replaced in +50: it darkened
  /// diffuse white relative to the hardware path). HLG is
  /// scene-referred where PQ is absolute, so it needs its own decode
  /// — reusing the PQ LUT's code values directly would be wrong —
  /// but the tone-mapping curve is shared. Verified numerically (see
  /// the +50 report): black -> 0, HLG mid (0.5) -> ~189, diffuse
  /// white (0.75) -> 255, peak -> 255, monotonic.
  private static func hlgToneMapLut(peakNits: Double) -> [UInt8] {
    return (0...255).map { i in
      let ePrime = Double(i) / 255.0
      let sceneLinear = hlgInverseOetf(ePrime)
      let displayLinear = pow(max(0.0, sceneLinear), 1.2)
      let nits = displayLinear * peakNits
      // Hard clip at the 100-nit SDR white.
      let linear = min(1.0, max(0.0, nits / 100.0))
      let s = srgbEncode(linear)
      return UInt8(max(0, min(255, (s * 255.0).rounded())))
    }
  }

  /// HLG (HDR) -> SDR tone-mapping LUT, BT.2390 EETF version (+57):
  /// per 8-bit HLG code, inverse HLG OETF to scene-linear light, the
  /// reference HLG OOTF gamma (1.2) to display-linear light, scale by
  /// the mastering peak, then the same BT.2390 EETF as the PQ LUT
  /// (via toneMapPQCode — the HLG-derived light is PQ-encoded first,
  /// so both HDR curves roll highlights off identically) and
  /// sRGB-encode. HLG is scene-referred where PQ is absolute, so it
  /// needs its own decode — reusing the PQ LUT's code values
  /// directly would be wrong — but the tone-mapping curve is shared.
  /// Verified numerically in +47: black -> 0, HLG mid (0.5) -> ~182,
  /// diffuse white (0.75) -> ~242, peak -> 255, monotonic. Selected
  /// when the live `tone-mapping` is bt.2390/auto (see
  /// toneMappingIsEetf).
  private static func hlgToneMapLutEetf(peakNits: Double) -> [UInt8] {
    let masteringWhite = pqEncode(peakNits / 10000.0)
    guard masteringWhite > 0 else { return swLutIdentity }
    let displayWhite = pqEncode(0.01)  // 100 nits, the SDR white
    let maxLum = min(1.0, displayWhite / masteringWhite)
    let ks = max(0.0, min(1.0, 1.5 * maxLum - 0.5))
    return (0...255).map { i in
      let ePrime = Double(i) / 255.0
      let sceneLinear = hlgInverseOetf(ePrime)
      let displayLinear = pow(max(0.0, sceneLinear), 1.2)
      let nits = displayLinear * peakNits
      let code = pqEncode(min(1.0, max(0.0, nits / 10000.0)))
      let newCode = toneMapPQCode(
        code,
        masteringWhite: masteringWhite,
        maxLum: maxLum,
        ks: ks
      )
      let linear = pqEotf(newCode) / 0.01
      let s = srgbEncode(min(1.0, max(0.0, linear)))
      return UInt8(max(0, min(255, (s * 255.0).rounded())))
    }
  }

  /// Maps the rendered frame's transfer function to sRGB, in place.
  /// Three cases, decided once per video size: a pure-power TRC
  /// (bt.1886 and friends) gets a power LUT, PQ (HDR) gets a
  /// tone-mapping LUT (see pqToneMapLut / pqToneMapLutEetf), and HLG
  /// (HDR) gets its own tone-mapping LUT (see hlgToneMapLut /
  /// hlgToneMapLutEetf, +47). Which HDR curve — the hard clip or the
  /// BT.2390 EETF — is the live `tone-mapping` value (see
  /// toneMappingIsEetf), read every frame (+57): a preset pick in
  /// the Video panel changes the LUT at once, on the current video.
  /// The clip is the same curve as the hardware path's
  /// `tone-mapping: clip`, so PiP ON and PiP OFF match on the
  /// default preset. The SDR power LUT is unaffected by the preset.
  /// A no-op (apart from the property reads on the first frame of a
  /// new size) when the source is already sRGB-like, or an HDR/log
  /// curve this does not cover.
  private func applySwGammaCorrection(
    size: CGSize,
    pitch: Int,
    buffer: UnsafeMutablePointer<UInt8>
  ) {
    let width = Int(size.width)
    let height = Int(size.height)
    if width <= 0 || height <= 0 || pitch <= 0 { return }
    // A new size is a new video, which may carry a different TRC.
    if swLutSize != size {
      swLutSize = size
      swLutExponent = nil
      swLutPQPeak = nil
      swLutHLGPeak = nil
      swLut = nil
    }
    // +57: the Video output preset's tone mapping, read live each
    // frame. A change re-decides the whole LUT at once: resetting
    // the exponent re-runs the gamma branch below, which re-reads
    // the peak and rebuilds the LUT from the new curve — the
    // picture changes on the current video, no re-open. The SDR
    // power LUT is unaffected by the preset.
    let toneMapping = readToneMapping()
    if swLutToneMapping != toneMapping {
      swLutToneMapping = toneMapping
      swLutExponent = nil
      swLutPQPeak = nil
      swLutHLGPeak = nil
      swLut = nil
    }
    if swLutExponent == nil {
      if readVideoGammaName() == "pq" {
        // +46: HDR (PQ) — tone-map, don't gamma-correct. The exponent
        // stays 1.0 as the "decided" marker; the peak rides alongside.
        swLutPQPeak = readSigPeakNits()
        swLutExponent = 1.0
      } else if readVideoGammaName() == "hlg" {
        // +47: HDR (HLG) — tone-map with its own LUT, don't
        // gamma-correct. Same "decided" marker and peak as PQ.
        swLutHLGPeak = readSigPeakNits()
        swLutExponent = 1.0
      } else {
        let source = readVideoGammaExponent()
        swLutExponent = source > 2.21 ? source / 2.2 : 1.0
      }
    }
    if let peak = swLutPQPeak {
      if swLut == nil {
        // +57: the EETF when the live tone-mapping is bt.2390/auto,
        // the clip otherwise (the default preset).
        swLut = Self.toneMappingIsEetf(swLutToneMapping ?? "clip")
          ? Self.pqToneMapLutEetf(peakNits: peak)
          : Self.pqToneMapLut(peakNits: peak)
      }
    } else if let hlgPeak = swLutHLGPeak {
      if swLut == nil {
        swLut = Self.toneMappingIsEetf(swLutToneMapping ?? "clip")
          ? Self.hlgToneMapLutEetf(peakNits: hlgPeak)
          : Self.hlgToneMapLut(peakNits: hlgPeak)
      }
    } else {
      guard let exponent = swLutExponent, exponent > 1.0 else { return }
      if swLut == nil {
        swLut = (0...255).map { i in
          let v = pow(Double(i) / 255.0, exponent)
          return UInt8(max(0, min(255, (v * 255.0).rounded())))
        }
      }
    }
    guard let lut = swLut else { return }
    lut.withUnsafeBufferPointer { lutPtr in
      Self.swLutIdentity.withUnsafeBufferPointer { idPtr in
        var src = vImage_Buffer(
          data: buffer,
          height: vImagePixelCount(height),
          width: vImagePixelCount(width),
          rowBytes: pitch
        )
        var dst = src
        _ = vImageTableLookUp_ARGB8888(
          &src,
          &dst,
          lutPtr.baseAddress,
          lutPtr.baseAddress,
          lutPtr.baseAddress,
          idPtr.baseAddress,
          // +45: kvImageNoFlags imports into Swift as Int, but this
          // parameter is vImage_Flags (UInt32) — the bare constant does
          // not convert, so wrap it (the standard vImage Swift idiom).
          vImage_Flags(kvImageNoFlags)
        )
      }
    }
  }
}
