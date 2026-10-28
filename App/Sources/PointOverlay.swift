import ARKit
import UIKit

/// Draws the current LiDAR depth map (confidence 2 only) as dots on top of the camera image.
/// Each depth pixel is projected to the screen with ARKit's display transform, so no 3D scene is involved.
/// Colour = distance: yellow near, violet at 5 m.
final class PointOverlayView: UIView {
    private static let bucketCount = 12
    private static let pixelStride = 2
    private static let farMetres: Float = 5
    private static let palette: [CGColor] = (0..<bucketCount).map { i in
        let t = CGFloat(i) / CGFloat(bucketCount - 1)
        return UIColor(hue: 0.17 + 0.58 * t, saturation: 0.85, brightness: 1, alpha: 1).cgColor
    }

    private let queue = DispatchQueue(label: "splatcap.overlay")
    private var busy = false
    private var tick = 0
    private var buckets: [[CGPoint]] = Array(repeating: [], count: PointOverlayView.bucketCount)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Call on the main queue with each ARKit frame.
    func update(frame: ARFrame) {
        tick += 1
        guard tick % 2 == 0, !busy, bounds.width > 0, let d = frame.sceneDepth,
              let depth = CaptureSession.readDepth(d.depthMap), let conf = CaptureSession.readConfidence(d.confidenceMap),
              depth.width == conf.width, depth.height == conf.height else { return }
        busy = true
        let size = bounds.size
        let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.interfaceOrientation ?? .portrait
        let transform = frame.displayTransform(for: orientation, viewportSize: size)
        queue.async { [weak self] in
            let count = Self.bucketCount
            var out = [[CGPoint]](repeating: [], count: count)
            for y in Swift.stride(from: 0, to: depth.height, by: Self.pixelStride) {
                for x in Swift.stride(from: 0, to: depth.width, by: Self.pixelStride) {
                    let i = y * depth.width + x
                    let metres = depth.data[i]
                    guard conf.data[i] >= 2, metres.isFinite, metres > 0 else { continue }
                    let n = CGPoint(x: (Double(x) + 0.5) / Double(depth.width), y: (Double(y) + 0.5) / Double(depth.height)).applying(transform)
                    let bucket = min(Int(metres / Self.farMetres * Float(count)), count - 1)
                    out[bucket].append(CGPoint(x: n.x * size.width, y: n.y * size.height))
                }
            }
            DispatchQueue.main.async {
                self?.buckets = out
                self?.busy = false
                self?.setNeedsDisplay()
            }
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for (i, points) in buckets.enumerated() {
            ctx.setFillColor(Self.palette[i])
            for p in points { ctx.fill(CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)) }
        }
    }
}
