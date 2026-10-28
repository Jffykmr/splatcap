import simd

public enum MotionBlur {
    /// Expected motion blur in image pixels from how fast the camera moved between two poses.
    /// Rotation blurs every pixel by about angularSpeed * focal * exposure; translation blurs by
    /// linearSpeed * focal / depth * exposure. Returns 0 when the time step is not usable.
    public static func pixels(previous: simd_float4x4, current: simd_float4x4, seconds dt: Double,
                              exposure: Double, focalPixels: Float, depth: Float) -> Float {
        guard dt > 0, exposure > 0, focalPixels > 0 else { return 0 }
        let radians = FrameSelector.rotationDegrees(previous, current) * .pi / 180
        let metres = simd_distance(FrameSelector.translation(previous), FrameSelector.translation(current))
        let seconds = Float(dt)
        let angularSpeed = radians / seconds, linearSpeed = metres / seconds
        let perSecond = angularSpeed * focalPixels + linearSpeed * focalPixels / max(depth, 0.3)
        return perSecond * Float(exposure)
    }
}
