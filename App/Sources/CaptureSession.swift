import ARKit
import AVFoundation
import CoreImage
import ImageIO
import SplatcapCore
import UIKit

/// Records an ARKit session as a Nerfstudio dataset in Documents/<timestamp>/ (one subfolder per ARKit segment after the first).
final class CaptureSession: NSObject, ARSessionDelegate, ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case continuous = "Continua"
        case detail = "Dettaglio"
        var id: String { rawValue }
    }

    @Published var frameCount = 0
    @Published var reliablePointsPercent = 0
    @Published var fps = 0
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var isPreviewing = false
    @Published var trackingText = "-"
    @Published var lastImageInfo = "-"
    @Published var detailBlockMs = 0
    @Published var sessionName = "-"
    @Published var lastError: String?

    let session = ARSession()
    /// Called on the main queue for every ARKit frame (the live view draws its overlay from it).
    var onFrame: ((ARFrame) -> Void)?

    private static let minInterval = 0.2
    private static let detailInterval = 1.5
    private static let jpegQuality = 0.95
    private static let maxSeedPoints = 2_000_000

    // main-thread state
    private var mode = Mode.continuous
    private var config: ARWorldTrackingConfiguration?
    private var previewMode: Mode?
    private var interrupted = false
    private var inFlight = false
    private var lastAttempt = -1.0
    private var latestDepthFrame: ARFrame?
    private var detailTimer: Timer?
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
    private var selector = CaptureSession.newSelector()
    private var sharpness = SharpnessTracker()
    private var seed: [(SIMD3<Float>, SIMD3<UInt8>)] = []
    private var counter = 0
    private var logHandle: FileHandle?

    private static func newSelector() -> FrameSelector {
        FrameSelector(minSharpness: 0.5, minTranslation: 0.08, minRotationDegrees: 4)
    }

    // MARK: control

    func start(mode: Mode) {
        guard !isRunning else { return }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            lastError = "Questo dispositivo non ha il LiDAR (sceneDepth non supportato)."
            return
        }
        self.mode = mode
        lastError = nil
        frameCount = 0
        isPaused = false
        interrupted = false
        inFlight = false
        lastAttempt = -1
        latestDepthFrame = nil

        let dir = Self.newSessionDirectory()
        sessionName = dir.lastPathComponent
        workQueue.sync {
            root = dir
            segment = 1
            counter = 0
            seed = []
            selector = Self.newSelector()
            sharpness = SharpnessTracker()
            openExporter(in: dir)
            logHandle = Self.openLog(dir.appendingPathComponent("capture_log.jsonl"))
        }

        preview(mode: mode)
        isRunning = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        UIApplication.shared.isIdleTimerDisabled = true
        // Let auto exposure settle for a second, then freeze exposure, focus and white balance for consistent frames.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.lockCamera() }
        if mode == .detail {
            detailTimer = Timer.scheduledTimer(withTimeInterval: Self.detailInterval, repeats: true) { [weak self] _ in self?.captureDetail() }
        }
    }

    /// Runs ARKit without recording, so the live view works before the first capture. No-op if already running in this mode.
    func preview(mode: Mode) {
        guard !isRunning, !(isPreviewing && previewMode == mode) else { return }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            lastError = "Questo dispositivo non ha il LiDAR (sceneDepth non supportato)."
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = .sceneDepth
        configuration.videoFormat = Self.videoFormat(for: mode)
        config = configuration
        previewMode = mode
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isPreviewing = true
    }

    func pause() { isPaused = true }
    func resume() { isPaused = false }

    func stop() {
        guard isRunning else { return }
        detailTimer?.invalidate()
        detailTimer = nil
        isRunning = false
        isPaused = false
        unlockCamera()
        UIApplication.shared.isIdleTimerDisabled = false
        workQueue.async { [weak self] in self?.closeSegment() }
    }

    // MARK: ARSessionDelegate (main queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        tick(frame)
        guard isRunning, !isPaused, !interrupted else { return }
        if mode == .detail {
            latestDepthFrame = frame
            return
        }
        guard !inFlight, frame.timestamp - lastAttempt >= Self.minInterval, case .normal = frame.camera.trackingState else { return }
        lastAttempt = frame.timestamp
        inFlight = true
        enqueue(frame: frame, depthFrame: frame, turns: currentTurns(), detailSeconds: nil)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        interrupted = true
        workQueue.async { [weak self] in self?.closeSegment() }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard isPreviewing, let config else { return }
        // Poses from before the interruption cannot be trusted: restart tracking and write a new segment folder.
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
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

    private func captureDetail() {
        guard isRunning, !isPaused, !interrupted, !inFlight, let depthFrame = latestDepthFrame,
              case .normal = depthFrame.camera.trackingState else { return }
        inFlight = true
        let turns = currentTurns()
        let started = Date()
        session.captureHighResolutionFrame { [weak self] frame, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.detailBlockMs = Int(Date().timeIntervalSince(started) * 1000)
                guard let frame else {
                    self.lastError = error?.localizedDescription
                    self.inFlight = false
                    return
                }
                self.enqueue(frame: frame, depthFrame: depthFrame, turns: turns, detailSeconds: depthFrame.timestamp)
            }
        }
    }

    private func enqueue(frame: ARFrame, depthFrame: ARFrame, turns: Int, detailSeconds: Double?) {
        workQueue.async { [weak self] in
            self?.process(frame: frame, depthFrame: depthFrame, turns: turns, depthTimestamp: detailSeconds)
            DispatchQueue.main.async { self?.inFlight = false }
        }
    }

    // MARK: processing (work queue)

    private func process(frame: ARFrame, depthFrame: ARFrame, turns: Int, depthTimestamp: Double?) {
        guard let exporter, let depthData = depthFrame.sceneDepth,
              let depth = Self.readDepth(depthData.depthMap), let conf = Self.readConfidence(depthData.confidenceMap),
              depth.width == conf.width, depth.height == conf.height else { return }

        let buffer = frame.capturedImage
        let candidate = FrameCandidate(timestamp: frame.timestamp, transform: frame.camera.transform,
                                       sharpness: sharpness.normalized(Self.lumaVariance(buffer)), trackingNormal: true)
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
        addSeed(depthFrame: depthFrame, depth: depth, conf: conf)
        writeLog(name: name, frame: frame, depthTimestamp: depthTimestamp, sharpness: candidate.sharpness, jpegBytes: jpeg.count, turns: turns)
        let info = "\(up.width)x\(up.height) \(jpeg.count / 1024) KB"
        DispatchQueue.main.async {
            self.frameCount += 1
            self.lastImageInfo = info
        }
    }

    private func addSeed(depthFrame: ARFrame, depth: (data: [Float], width: Int, height: Int), conf: (data: [UInt8], width: Int, height: Int)) {
        guard seed.count < Self.maxSeedPoints else { return }
        let k = depthFrame.camera.intrinsics
        let res = depthFrame.camera.imageResolution
        let intr = PinholeIntrinsics(fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1], width: Int(res.width), height: Int(res.height))
        let points = DepthUnprojection.points(depth: depth.data, confidence: conf.data, width: depth.width, height: depth.height,
                                              intrinsics: intr, cameraToWorld: depthFrame.camera.transform)
        guard !points.isEmpty, let rgb = Self.rgbSampler(depthFrame.capturedImage) else { return }
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
        selector = Self.newSelector()
        sharpness = SharpnessTracker()
        openExporter(in: root.appendingPathComponent("segment_\(segment)"))
    }

    private func writeLog(name: String, frame: ARFrame, depthTimestamp: Double?, sharpness: Float, jpegBytes: Int, turns: Int) {
        var entry: [String: Any] = ["name": name, "segment": segment, "timestamp": frame.timestamp, "sharpness": sharpness,
                                    "jpegBytes": jpegBytes, "quarterTurns": turns, "mode": mode.rawValue]
        if let depthTimestamp { entry["depthTimestamp"] = depthTimestamp }
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

    private static func videoFormat(for mode: Mode) -> ARConfiguration.VideoFormat {
        if mode == .detail, let f = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing { return f }
        let best = ARWorldTrackingConfiguration.supportedVideoFormats.max { a, b in
            let pa = a.imageResolution.width * a.imageResolution.height, pb = b.imageResolution.width * b.imageResolution.height
            return pa != pb ? pa < pb : a.framesPerSecond < b.framesPerSecond
        }
        return best ?? ARWorldTrackingConfiguration().videoFormat
    }

    private func lockCamera() {
        guard isRunning, let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            device.unlockForConfiguration()
        } catch {
            lastError = "Blocco fotocamera non riuscito: \(error.localizedDescription)"
        }
    }

    private func unlockCamera() {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            device.unlockForConfiguration()
        } catch {
            lastError = "Sblocco fotocamera non riuscito: \(error.localizedDescription)"
        }
    }

    // MARK: pixel buffer reading

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
