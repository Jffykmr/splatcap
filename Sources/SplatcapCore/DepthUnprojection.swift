import simd

public struct DepthPoint {
    public var x: Int
    public var y: Int
    public var position: SIMD3<Float>
}

public enum DepthUnprojection {
    /// World-space points from a depth map (metres along the optical axis); keeps pixels with
    /// confidence >= `minConfidence`. `intrinsics` describe the full image, they are scaled to the depth size.
    public static func points(depth: [Float], confidence: [UInt8], width: Int, height: Int,
                              intrinsics: PinholeIntrinsics, cameraToWorld: simd_float4x4,
                              minConfidence: UInt8 = 2, stride step: Int = 4) -> [DepthPoint] {
        guard depth.count == width * height, confidence.count == depth.count, step > 0, intrinsics.width > 0 else { return [] }
        let s = Float(width) / Float(intrinsics.width)
        let fx = intrinsics.fx * s, fy = intrinsics.fy * s, cx = intrinsics.cx * s, cy = intrinsics.cy * s
        var out: [DepthPoint] = []
        for y in Swift.stride(from: 0, to: height, by: step) {
            for x in Swift.stride(from: 0, to: width, by: step) {
                let i = y * width + x
                let d = depth[i]
                guard confidence[i] >= minConfidence, d.isFinite, d > 0 else { continue }
                let cam = SIMD4<Float>((Float(x) - cx) * d / fx, -(Float(y) - cy) * d / fy, -d, 1)
                let w = cameraToWorld * cam
                out.append(DepthPoint(x: x, y: y, position: SIMD3(w.x, w.y, w.z)))
            }
        }
        return out
    }
}
