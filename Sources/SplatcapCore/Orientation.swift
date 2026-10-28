import simd

public struct PinholeIntrinsics: Equatable {
    public var fx, fy, cx, cy: Float
    public var width: Int
    public var height: Int

    public init(fx: Float, fy: Float, cx: Float, cy: Float, width: Int, height: Int) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }
}

/// Makes ARKit data match upright photos and a Z-up world, so Spirula's auto-level works without EXIF.
/// Camera convention throughout: +X right, +Y up, looking along -Z (ARKit and Nerfstudio).
public enum Orientation {
    /// ARKit world has +Y up; Spirula and Nerfstudio datasets use +Z up.
    public static let zUp = simd_float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, -1, 0, 0), SIMD4<Float>(0, 0, 0, 1)))

    /// New camera axes after rotating the image 90 degrees clockwise: x' = y, y' = -x, z' = z.
    private static let cameraStep = simd_float4x4(columns: (
        SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(-1, 0, 0, 0), SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, 0, 0, 1)))

    private static func turns(_ k: Int) -> Int { ((k % 4) + 4) % 4 }

    public static func cameraToWorld(_ m: simd_float4x4, quarterTurnsClockwise k: Int) -> simd_float4x4 {
        var r = m
        for _ in 0..<turns(k) { r = r * cameraStep }
        return r
    }

    public static func intrinsics(_ i: PinholeIntrinsics, quarterTurnsClockwise k: Int) -> PinholeIntrinsics {
        var r = i
        for _ in 0..<turns(k) {
            r = PinholeIntrinsics(fx: r.fy, fy: r.fx, cx: Float(r.height) - r.cy, cy: r.cx, width: r.height, height: r.width)
        }
        return r
    }

    /// Rotates a row-major grid (depth, confidence) clockwise; width and height swap on odd turns.
    public static func rotateGrid<T>(_ a: [T], width: Int, height: Int, quarterTurnsClockwise k: Int) -> (data: [T], width: Int, height: Int) {
        precondition(a.count == width * height, "grid size does not match width x height")
        var data = a, w = width, h = height
        for _ in 0..<turns(k) {
            var out = data
            for y in 0..<h {
                for x in 0..<w { out[x * h + (h - 1 - y)] = data[y * w + x] }
            }
            data = out
            swap(&w, &h)
        }
        return (data, w, h)
    }
}
