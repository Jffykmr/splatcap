import CoreGraphics
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

public struct ExportedFrame {
    public var name: String
    public var cameraToWorld: simd_float4x4
    public var fx, fy, cx, cy: Float
    public var width: Int
    public var height: Int

    public init(name: String, cameraToWorld: simd_float4x4, fx: Float, fy: Float, cx: Float, cy: Float, width: Int, height: Int) {
        self.name = name
        self.cameraToWorld = cameraToWorld
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }
}

public enum SessionExporterError: Error {
    case wrongDepthSize(Int)
    case pngEncodingFailed
}

/// Writes a Nerfstudio dataset (images/, depths/, transforms.json, sparse_pc.ply) that Spirula Studio opens directly.
/// Frames are written as given: callers apply any world or camera rotation beforehand.
public final class SessionExporter {
    public static let depthWidth = 256
    public static let depthHeight = 192
    static let intrinsicsTolerance: Float = 1e-3
    static let eagerTransformsFrames = 10

    private let directory: URL
    private var frames: [ExportedFrame] = []

    public init(directory: URL) throws {
        self.directory = directory
        for sub in ["images", "depths"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    /// `depthWidth` x `depthHeight` is the depth grid as stored (192 x 256 after a quarter-turn rotation).
    public func append(frame: ExportedFrame, jpeg: Data, depth: [Float], confidence: [UInt8],
                       depthWidth: Int = SessionExporter.depthWidth, depthHeight: Int = SessionExporter.depthHeight) throws {
        let n = depthWidth * depthHeight
        guard n > 0, depth.count == n, confidence.count == n else { throw SessionExporterError.wrongDepthSize(depth.count) }
        try jpeg.write(to: directory.appendingPathComponent("images/\(frame.name).jpg"), options: .atomic)
        try Self.depthPng(depth: depth, confidence: confidence, width: depthWidth, height: depthHeight)
            .write(to: directory.appendingPathComponent("depths/\(frame.name).png"), options: .atomic)
        frames.append(frame)
        // Rewrite on each of the first frames, then every 10th, so a killed app still leaves a loadable dataset.
        if frames.count <= Self.eagerTransformsFrames || frames.count % Self.eagerTransformsFrames == 0 {
            try writeTransforms()
        }
    }

    public func finish(seed: [(SIMD3<Float>, SIMD3<UInt8>)]) throws {
        if !frames.isEmpty { try writeTransforms() }
        guard !seed.isEmpty else { return }
        let header = "ply\nformat binary_little_endian 1.0\nelement vertex \(seed.count)\n"
            + "property float x\nproperty float y\nproperty float z\n"
            + "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
        var data = Data(header.utf8)
        for (p, c) in seed {
            for v in [p.x, p.y, p.z] { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
            data.append(contentsOf: [c.x, c.y, c.z])
        }
        try data.write(to: directory.appendingPathComponent("sparse_pc.ply"), options: .atomic)
    }

    private func intrinsics(_ f: ExportedFrame) -> [String: Any] {
        ["fl_x": Double(f.fx), "fl_y": Double(f.fy), "cx": Double(f.cx), "cy": Double(f.cy), "w": f.width, "h": f.height]
    }

    private func writeTransforms() throws {
        guard let first = frames.first else { return }
        let tol = Self.intrinsicsTolerance
        let shared = frames.allSatisfy { f in
            abs(f.fx - first.fx) <= tol && abs(f.fy - first.fy) <= tol && abs(f.cx - first.cx) <= tol
                && abs(f.cy - first.cy) <= tol && f.width == first.width && f.height == first.height
        }
        var doc: [String: Any] = ["camera_model": "PINHOLE"]
        if shared { doc.merge(intrinsics(first)) { a, _ in a } }
        doc["frames"] = frames.map { f -> [String: Any] in
            let m = f.cameraToWorld
            let rows = (0..<4).map { r in (0..<4).map { c in Double(m[c][r]) } }
            var e: [String: Any] = ["file_path": "images/\(f.name).jpg", "transform_matrix": rows]
            if !shared { e.merge(intrinsics(f)) { a, _ in a } }
            return e
        }
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("transforms.json"), options: .atomic)
    }

    /// 16-bit grayscale PNG in millimetres; 0 where confidence < 2 or the value is unusable.
    static func depthPng(depth: [Float], confidence: [UInt8], width: Int, height: Int) throws -> Data {
        var mm = [UInt16](repeating: 0, count: depth.count)
        for i in 0..<depth.count where confidence[i] >= 2 && depth[i].isFinite && depth[i] > 0 && depth[i] < 65.535 {
            mm[i] = UInt16((depth[i] * 1000).rounded())
        }
        let bytes = mm.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } // big-endian samples
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16,
                                  bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw SessionExporterError.pngEncodingFailed }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw SessionExporterError.pngEncodingFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw SessionExporterError.pngEncodingFailed }
        return out as Data
    }
}
