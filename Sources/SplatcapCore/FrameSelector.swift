import simd

public struct FrameCandidate {
    public var timestamp: Double
    public var transform: simd_float4x4
    public var sharpness: Float
    public var trackingNormal: Bool

    public init(timestamp: Double, transform: simd_float4x4, sharpness: Float, trackingNormal: Bool) {
        self.timestamp = timestamp
        self.transform = transform
        self.sharpness = sharpness
        self.trackingNormal = trackingNormal
    }
}

/// Decides which camera frames are worth keeping: sharp, well tracked and different from the last kept one.
public struct FrameSelector {
    public let minSharpness: Float
    public let minTranslation: Float
    public let minRotationDegrees: Float
    private var last: simd_float4x4?

    public init(minSharpness: Float, minTranslation: Float, minRotationDegrees: Float) {
        self.minSharpness = minSharpness
        self.minTranslation = minTranslation
        self.minRotationDegrees = minRotationDegrees
    }

    public mutating func accept(_ c: FrameCandidate) -> Bool {
        guard c.trackingNormal, c.sharpness >= minSharpness, Self.isFinite(c.transform) else { return false }
        if let prev = last {
            let moved = simd_distance(Self.translation(prev), Self.translation(c.transform))
            guard moved >= minTranslation || Self.rotationDegrees(prev, c.transform) >= minRotationDegrees else { return false }
        }
        last = c.transform
        return true
    }

    private static func isFinite(_ m: simd_float4x4) -> Bool {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }
    }

    private static func translation(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    private static func rotation(_ m: simd_float4x4) -> simd_quatf {
        let c0 = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        return simd_quatf(simd_float3x3(c0, c1, c2))
    }

    private static func rotationDegrees(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let d = min(abs(simd_dot(rotation(a).vector, rotation(b).vector)), 1)
        return 2 * acos(d) * 180 / .pi
    }
}
