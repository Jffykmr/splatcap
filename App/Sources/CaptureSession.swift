import ARKit
import AVFoundation
import CoreImage
import ImageIO
import SplatcapCore
import UIKit

/// Records an ARKit session as a Nerfstudio dataset in Documents/<timestamp>/ (one subfolder per ARKit segment after the first).
/// Both modes read the top-resolution video stream, so there is no shutter sound and no pause in the preview.
final class CaptureSession: NSObject, ARSessionDelegate, ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case continuous = "Continua"
        case detail = "Dettaglio"
        var id: String { rawValue }
    }

    private struct Profile {
        let minInterval: Double
        let maxBlurPixels: Float
        let minTranslation: Float
        let minRotationDegrees: Float
    }

    @Published var frameCount = 0
    @Published var reliablePointsPercent = 0
    @Published var fps = 0
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var isPreviewing = false
    @Published var trackingText = "-"
    @Published var exposureText = "-"
    @Published var lastImageInfo = "-"
    @Published var sessionName = "-"
    @Published var lastError: String?

    let session = ARSession()
    /// Called on the main queue for every ARKit frame (the live view draws its overlay from it).
    var onFrame: ((ARFrame) -> Void)?

    private static let jpegQuality = 0.95
    private static let maxSeedPoints = 2_000_000

    // main-thread state
    private var mode = Mode.continuous
    private var config: ARWorldTrackingConfiguration?
    private var interrupted = false
    private var inFlight = false
    private var lastAttempt = -1.0
    private var previousPose: (transform: simd_float4x4, timestamp: Double)?
    private var fpsTicks = 0
    private var fpsWindowStart = Date()
    private var lastReliableCheck = 0.0
    private var lastTurns = 1

    // work-queue state
    private let workQueue = DispatchQueue(label: "splatcap.work")
    private let ciContext = CIContext()
    private var root: URL?
    private var segment = 1
    private var exporter: SessionExporter?
    private var selector = CaptureSession.newSelector(.continuous)
    private var sharpness = SharpnessTracker()
    private var seed: [(SIMD3<Float>, SIMD3<UInt8>)] = []
    private var counter = 0
    private var logHandle: FileHandle?

    private static func profile(_ mode: Mode) -> Profile {
        switch mode {
        case .continuous: return Profile(minInterval: 0.1, maxBlurPixels: 1.5, minTranslation: 0.08, minRotationDegrees: 4)
        case .detail: return Profile(minInterval: 0.1, maxBlurPixels: 0.8, minTranslation: 0.04, minRotationDegrees: 2)
        }
    }

    private static func newSelector(_ mode: Mode) -> FrameSelector {
        let p = profile(mode)
        return FrameSelector(minSharpness: 0.5, minTranslation: p.minTranslation, minRotationDegrees: p.minRotationDegrees,
                             maxBlurPixels: p.maxBlurPixels)
    }

    // MARK: control

    func start(mode: Mode) {
        guard !isRunning else { return }
        self.mode = mode
        lastError = nil
        frameCount = 0
        isPaused = false
        interrupted = false
        inFlight = false
        lastAttempt = -1

        let dir = Self.newSessionDirectory()
        sessionName = dir.lastPathComponent
        workQueue.sync {
            root = dir
            segment = 1
            counter = 0
            seed = []
            selector = Self.newSelector(mode)
            sharpness = SharpnessTracker()
            openExporter(in: dir)
            logHandle = Self.openLog(dir.appendingPathComponent("capture_log.jsonl"))
        }

        preview()
        guard isPreviewing else { return }
        isRunning = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        UIApplication.shared.isIdleTimerDisabled = true
        // Freeze only the white balance, so colours stay consistent. Exposure and focus stay automatic:
        // a locked focus blurs the frames when the distance changes, a locked exposure lengthens the shutter in the dark.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.lockWhiteBalance(true) }
    }

    /// Runs ARKit without recording, so the live view works before the first capture. No-op if already running.
    func preview() {
        guard !isPreviewing else { return }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            lastError = "Questo dispositivo non ha il LiDAR (sceneDepth non supportato)."
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = .sceneDepth
        configuration.videoFormat = Self.videoFormat()
        config = configuration
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isPreviewing = true
    }

    func pause() { isPaused = true }
    func resume() { isPaused = false }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        isPaused = false
        lockWhiteBalance(false)
        UIApplication.shared.isIdleTimerDisabled = false
        workQueue.async { [weak self] in self?.closeSegment() }
    }

    // MARK: ARSessionDelegate (main queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        tick(frame)
        let previous = previousPose
        previousPose = (frame.camera.transform, frame.timestamp)
        guard isRunning, !isPaused, !interrupted, !inFlight, let previous,
              frame.timestamp - lastAttempt >= Self.profile(mode).minInterval,
              case .normal = frame.camera.trackingState else { return }
        let blur = MotionBlur.pixels(previous: previous.transform, current: frame.camera.transform,
                                     seconds: frame.timestamp - previous.timestamp, exposure: frame.camera.exposureDuration,
                                     focalPixels: frame.camera.intrinsics[0][0], depth: Self.centreDepth(frame))
        guard blur <= Self.profile(mode).maxBlurPixels else { return }
        lastAttempt = frame.timestamp
        inFlight = true
        enqueue(frame: frame, blur: blur, turns: currentTurns())
    }

    func sessionWasInterrupted(_ session: ARSession) {
        interrupted = true
        workQueue.async { [weak self] in self?.closeSegment() }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard isPreviewing, let config else { return }
        // Poses from before the interruption cannot be trusted: restart tracking and write a new segment folder.
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        previousPose = nil
        if isRunning { workQueue.async { [weak self] in self?.openNextSegment() } }
        interrupted = false
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        lastError = error.localizedDescription
        interrupted = true
        workQueue.async { [weak self] in self?.closeSegment() }
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { false }

    // MARK: frame intake (main queue)

    private func tick(_ frame: ARFrame) {
        onFrame?(frame)
        fpsTicks += 1
        let now = Date()
        if now.timeIntervalSince(fpsWindowStart) >= 1 {
            fps = fpsTicks
            fpsTicks = 0
            fpsWindowStart = now
            let e = frame.camera.exposureDuration
            exposureText = e > 0 ? "1/\(Int((1 / e).rounded())) s" : "-"
        }
        switch frame.camera.trackingState {
        case .normal: trackingText = "normale"
        case .notAvailable: trackingText = "non disponibile"
        case .limited(let reason): trackingText = "limitato (\(reason))"
        }
        if frame.timestamp - lastReliableCheck >= 0.5, let d = frame.sceneDepth {
            lastReliableCheck = frame.timestamp
            if let conf = Self.readConfidence(d.confidenceMap), !conf.data.isEmpty {
                reliablePointsPercent = conf.data.reduce(0) { $0 + ($1 == 2 ? 1 : 0) } * 100 / conf.data.count
            }
        }
    }

    private func currentTurns() -> Int {
        switch UIDevice.current.orientation {
        case .landscapeLeft: lastTurns = 0 // sensor-native orientation
        case .portrait: lastTurns = 1
        case .landscapeRight: lastTurns = 2
        case .portraitUpsideDown: lastTurns = 3
        default: break
        }
        return lastTurns
    }

    private func enqueue(frame: ARFrame, blur: Float, turns: Int) {
        workQueue.async { [weak self] in
            self?.process(frame: frame, blur: blur, turns: turns)
            DispatchQueue.main.async { self?.inFlight = false }
        }
    }

    // MARK: processing (work queue)

    private func process(frame: ARFrame, blur: Float, turns: Int) {
        guard let exporter, let depthData = frame.sceneDepth,
              let depth = Self.readDepth(depthData.depthMap), let conf = Self.readConfidence(depthData.confidenceMap),
              depth.width == conf.width, depth.height == conf.height else { return }

        let buffer = frame.capturedImage
        let candidate = FrameCandidate(timestamp: frame.timestamp, transform: frame.camera.transform,
                                       sharpness: sharpness.normalized(Self.lumaVariance(buffer)), trackingNormal: true, blurPixels: blur)
        guard selector.accept(candidate), let jpeg = encodeJPEG(buffer, turns: turns) else { return }

        let k = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let intr = PinholeIntrinsics(fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1], width: Int(res.width), height: Int(res.height))
        let up = Orientation.intrinsics(intr, quarterTurnsClockwise: turns)
        let pose = Orientation.zUp * Orientation.cameraToWorld(frame.camera.transform, quarterTurnsClockwise: turns)
        let d = Orientation.rotateGrid(depth.data, width: depth.width, height: depth.height, quarterTurnsClockwise: turns)
        let c = Orientation.rotateGrid(conf.data, width: conf.width, height: conf.height, quarterTurnsClockwise: turns)

        counter += 1
        let name = String(format: "frame_%05d", counter)
        let exported = ExportedFrame(name: name, cameraToWorld: pose, fx: up.fx, fy: up.fy, cx: up.cx, cy: up.cy, width: up.width, height: up.height)
        do {
            try exporter.append(frame: exported, jpeg: jpeg, depth: d.data, confidence: c.data, depthWidth: d.width, depthHeight: d.height)
        } catch {
            DispatchQueue.main.async { self.lastError = "Scrittura fallita: \(error.localizedDescription)" }
            return
        }
        addSeed(frame: frame, depth: depth, conf: conf)
        writeLog(name: name, frame: frame, sharpness: candidate.sharpness, blur: blur, jpegBytes: jpeg.count, turns: turns)
        let info = "\(up.width)x\(up.height) \(jpeg.count / 1024) KB"
        DispatchQueue.main.async {
            self.frameCount += 1
            self.lastImageInfo = info
        }
    }

    private func addSeed(frame: ARFrame, depth: (data: [Float], width: Int, height: Int), conf: (data: [UInt8], width: Int, height: Int)) {
        guard seed.count < Self.maxSeedPoints else { return }
        let k = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let intr = PinholeIntrinsics(fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1], width: Int(res.width), height: Int(res.height))
        let points = DepthUnprojection.points(depth: depth.data, confidence: conf.data, width: depth.width, height: depth.height,
                                              intrinsics: intr, cameraToWorld: frame.camera.transform)
        guard !points.isEmpty, let rgb = Self.rgbSampler(frame.capturedImage) else { return }
        for p in points {
            let w = Orientation.zUp * SIMD4<Float>(p.position.x, p.position.y, p.position.z, 1)
            let color = rgb(Float(p.x) / Float(depth.width), Float(p.y) / Float(depth.height))
            seed.append((SIMD3(w.x, w.y, w.z), color))
        }
    }

    private func encodeJPEG(_ buffer: CVPixelBuffer, turns: Int) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer)
        switch turns {
        case 1: image = image.oriented(.right)
        case 2: image = image.oriented(.down)
        case 3: image = image.oriented(.left)
        default: break
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return ciContext.jpegRepresentation(of: image, colorSpace: space,
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: Self.jpegQuality])
    }

    // MARK: segments and files (work queue)

    private func openExporter(in dir: URL) {
        do { exporter = try SessionExporter(directory: dir) } catch {
            exporter = nil
            DispatchQueue.main.async { self.lastError = "Cartella non scrivibile: \(error.localizedDescription)" }
        }
    }

    private func closeSegment() {
        guard let e = exporter else { return }
        do { try e.finish(seed: seed) } catch {
            DispatchQueue.main.async { self.lastError = "Chiusura sessione fallita: \(error.localizedDescription)" }
        }
        exporter = nil
        seed = []
    }

    private func openNextSegment() {
        guard let root else { return }
        segment += 1
        selector = Self.newSelector(mode)
        sharpness = SharpnessTracker()
        openExporter(in: root.appendingPathComponent("segment_\(segment)"))
    }

    private func writeLog(name: String, frame: ARFrame, sharpness: Float, blur: Float, jpegBytes: Int, turns: Int) {
        let entry: [String: Any] = ["name": name, "segment": segment, "timestamp": frame.timestamp, "sharpness": sharpness,
                                    "blurPixels": blur, "exposureSeconds": frame.camera.exposureDuration,
                                    "jpegBytes": jpegBytes, "quarterTurns": turns, "mode": mode.rawValue]
        guard let data = try? JSONSerialization.data(withJSONObject: entry), let h = logHandle else { return }
        h.write(data + Data("\n".utf8))
    }

    private static func openLog(_ url: URL) -> FileHandle? {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }

    private static func newSessionDirectory() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Splatcap_" + f.string(from: Date()))
    }

    // MARK: camera setup

    private static func videoFormat() -> ARConfiguration.VideoFormat {
        let best = ARWorldTrackingConfiguration.supportedVideoFormats.max { a, b in
            let pa = a.imageResolution.width * a.imageResolution.height, pb = b.imageResolution.width * b.imageResolution.height
            return pa != pb ? pa < pb : a.framesPerSecond < b.framesPerSecond
        }
        return best ?? ARWorldTrackingConfiguration().videoFormat
    }

    private func lockWhiteBalance(_ locked: Bool) {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        let target: AVCaptureDevice.WhiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance
        do {
            try device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(target) { device.whiteBalanceMode = target }
            device.unlockForConfiguration()
        } catch {
            lastError = "Bilanciamento del bianco non modificabile: \(error.localizedDescription)"
        }
    }

    // MARK: pixel buffer reading

    /// Mean of a few centre samples of the depth map, in metres; 2 m when there is no usable measurement.
    private static func centreDepth(_ frame: ARFrame) -> Float {
        guard let map = frame.sceneDepth?.depthMap else { return 2 }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return 2 }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), bpr = CVPixelBufferGetBytesPerRow(map)
        var sum: Float = 0, n: Float = 0
        for (dx, dy) in [(0, 0), (-20, 0), (20, 0), (0, -20), (0, 20)] {
            let x = w / 2 + dx, y = h / 2 + dy
            guard x >= 0, x < w, y >= 0, y < h else { continue }
            let v = base.advanced(by: y * bpr).assumingMemoryBound(to: Float.self)[x]
            if v.isFinite, v > 0 { sum += v; n += 1 }
        }
        return n > 0 ? sum / n : 2
    }

    static func readDepth(_ map: CVPixelBuffer) -> (data: [Float], width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), bpr = CVPixelBufferGetBytesPerRow(map)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: Float.self)
            for x in 0..<w { out[y * w + x] = row[x] }
        }
        return (out, w, h)
    }

    static func readConfidence(_ map: CVPixelBuffer?) -> (data: [UInt8], width: Int, height: Int)? {
        guard let map else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), bpr = CVPixelBufferGetBytesPerRow(map)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { out[y * w + x] = row[x] }
        }
        return (out, w, h)
    }

    private static func lumaVariance(_ buffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0 }
        return Sharpness.laplacianVariance(luma: base.assumingMemoryBound(to: UInt8.self),
                                           width: CVPixelBufferGetWidthOfPlane(buffer, 0), height: CVPixelBufferGetHeightOfPlane(buffer, 0),
                                           bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
    }

    /// Returns a closure that reads the colour at normalised image coordinates; copies the planes so the buffer can be released.
    private static func rgbSampler(_ buffer: CVPixelBuffer) -> ((Float, Float) -> SIMD3<UInt8>)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), cBpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cw = CVPixelBufferGetWidthOfPlane(buffer, 1), ch = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let luma = Data(bytes: yBase, count: yBpr * h), chroma = Data(bytes: cBase, count: cBpr * ch)
        return { u, v in
            let x = min(max(Int(u * Float(w)), 0), w - 1), y = min(max(Int(v * Float(h)), 0), h - 1)
            let cx = min(x / 2, cw - 1), cy = min(y / 2, ch - 1)
            let yy = Float(luma[y * yBpr + x]) - 16
            let cb = Float(chroma[cy * cBpr + cx * 2]) - 128, cr = Float(chroma[cy * cBpr + cx * 2 + 1]) - 128
            func clamp(_ f: Float) -> UInt8 { UInt8(min(max(f, 0), 255)) }
            return SIMD3(clamp(1.164 * yy + 1.596 * cr), clamp(1.164 * yy - 0.392 * cb - 0.813 * cr), clamp(1.164 * yy + 2.017 * cb))
        }
    }
}
