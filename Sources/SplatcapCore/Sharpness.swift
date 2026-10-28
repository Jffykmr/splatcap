public enum Sharpness {
    /// Variance of the 4-neighbour Laplacian over a centred window of an 8-bit luma plane. Higher = sharper.
    public static func laplacianVariance(luma: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, window: Int = 512) -> Float {
        let w = min(window, width), h = min(window, height)
        guard w > 2, h > 2 else { return 0 }
        let x0 = (width - w) / 2, y0 = (height - h) / 2
        var sum = 0.0, sumSq = 0.0, count = 0.0
        for y in (y0 + 1)..<(y0 + h - 1) {
            let row = luma + y * bytesPerRow
            let above = row - bytesPerRow, below = row + bytesPerRow
            for x in (x0 + 1)..<(x0 + w - 1) {
                let l = 4 * Int(row[x]) - Int(above[x]) - Int(below[x]) - Int(row[x - 1]) - Int(row[x + 1])
                sum += Double(l)
                sumSq += Double(l * l)
                count += 1
            }
        }
        let mean = sum / count
        return Float(max(sumSq / count - mean * mean, 0))
    }
}

/// Turns a raw Laplacian variance into 0...1 relative to the recent sharpest view of the scene,
/// so a plain wall is not rejected but a motion-blurred frame is.
public struct SharpnessTracker {
    private var peak: Float = 0
    private let decay: Float

    public init(decay: Float = 0.97) { self.decay = decay }

    public mutating func normalized(_ variance: Float) -> Float {
        guard variance.isFinite else { return 0 }
        peak = max(variance, peak * decay)
        return peak > 0 ? min(variance / peak, 1) : 1
    }
}
