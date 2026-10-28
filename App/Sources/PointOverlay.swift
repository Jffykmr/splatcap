import ARKit
import SceneKit
import SplatcapCore
import simd
import UIKit

/// Draws the recent LiDAR points (confidence 2 only) as a point cloud anchored in the ARKit world,
/// coloured by distance so it stays visible over the camera image: yellow near, violet at 5 m.
final class PointOverlay {
    let node = SCNNode()

    private static let framesKept = 8
    private static let updateEvery = 3
    private static let depthStride = 3
    private static let farMetres: Float = 5

    private let queue = DispatchQueue(label: "splatcap.overlay")
    private var busy = false // main thread
    private var tick = 0 // main thread
    private var ring: [[(SIMD3<Float>, SIMD3<Float>)]] = [] // queue-confined: position, rgb 0...1

    func update(frame: ARFrame) {
        tick += 1
        guard tick % Self.updateEvery == 0, !busy, case .normal = frame.camera.trackingState, let d = frame.sceneDepth,
              let depth = CaptureSession.readDepth(d.depthMap), let conf = CaptureSession.readConfidence(d.confidenceMap) else { return }
        busy = true
        let pose = frame.camera.transform
        let k = frame.camera.intrinsics, res = frame.camera.imageResolution
        let intr = PinholeIntrinsics(fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1], width: Int(res.width), height: Int(res.height))
        let origin = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        queue.async { [weak self] in
            guard let self else { return }
            let pts = DepthUnprojection.points(depth: depth.data, confidence: conf.data, width: depth.width, height: depth.height,
                                               intrinsics: intr, cameraToWorld: pose, stride: Self.depthStride)
            ring.append(pts.map { ($0.position, Self.colour(distance: simd_distance($0.position, origin))) })
            if ring.count > Self.framesKept { ring.removeFirst() }
            let geometry = Self.geometry(ring.flatMap { $0 })
            DispatchQueue.main.async {
                self.node.geometry = geometry
                self.busy = false
            }
        }
    }

    private static func colour(distance: Float) -> SIMD3<Float> {
        let t = min(max(distance / farMetres, 0), 1)
        let c = UIColor(hue: CGFloat(0.17 + 0.58 * t), saturation: 0.85, brightness: 1, alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: nil)
        return SIMD3(Float(r), Float(g), Float(b))
    }

    private static func geometry(_ points: [(SIMD3<Float>, SIMD3<Float>)]) -> SCNGeometry? {
        guard !points.isEmpty else { return nil }
        let vertices = points.map { SCNVector3($0.0.x, $0.0.y, $0.0.z) }
        let rgba = points.flatMap { [$0.1.x, $0.1.y, $0.1.z, 1] }
        let colours = SCNGeometrySource(data: rgba.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .color,
                                        vectorCount: points.count, usesFloatComponents: true, componentsPerVector: 4,
                                        bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: 16)
        let element = SCNGeometryElement(indices: (0..<Int32(points.count)).map { $0 }, primitiveType: .point)
        element.pointSize = 5
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 5
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), colours], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        geometry.materials = [material]
        return geometry
    }
}
