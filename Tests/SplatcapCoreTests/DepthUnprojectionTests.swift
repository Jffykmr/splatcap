import XCTest
import simd
@testable import SplatcapCore

final class DepthUnprojectionTests: XCTestCase {
    private let intr = PinholeIntrinsics(fx: 100, fy: 100, cx: 128, cy: 96, width: 256, height: 192)
    private let n = 256 * 192

    func testPrincipalPointProjectsOnOpticalAxis() {
        let pts = DepthUnprojection.points(depth: [Float](repeating: 2, count: n), confidence: [UInt8](repeating: 2, count: n),
                                           width: 256, height: 192, intrinsics: intr, cameraToWorld: matrix_identity_float4x4, stride: 1)
        let centre = pts.first { $0.x == 128 && $0.y == 96 }!
        XCTAssertEqual(centre.position, SIMD3<Float>(0, 0, -2))
        let right = pts.first { $0.x == 129 && $0.y == 96 }!
        XCTAssertGreaterThan(right.position.x, 0)
        let below = pts.first { $0.x == 128 && $0.y == 97 }!
        XCTAssertLessThan(below.position.y, 0)
    }

    func testTranslationMovesPoints() {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(1, 2, 3, 1)
        let pts = DepthUnprojection.points(depth: [Float](repeating: 2, count: n), confidence: [UInt8](repeating: 2, count: n),
                                           width: 256, height: 192, intrinsics: intr, cameraToWorld: m, stride: 1)
        XCTAssertEqual(pts.first { $0.x == 128 && $0.y == 96 }!.position, SIMD3<Float>(1, 2, 1))
    }

    func testDropsLowConfidenceAndInvalidDepth() {
        var conf = [UInt8](repeating: 2, count: n)
        var depth = [Float](repeating: 2, count: n)
        for i in 0..<(n / 2) { conf[i] = 1 }
        depth[n - 1] = .nan
        depth[n - 2] = 0
        let pts = DepthUnprojection.points(depth: depth, confidence: conf, width: 256, height: 192, intrinsics: intr,
                                           cameraToWorld: matrix_identity_float4x4, stride: 1)
        XCTAssertEqual(pts.count, n / 2 - 2)
    }

    func testScalesFullImageIntrinsicsToDepthSize() {
        let full = PinholeIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 720, width: 1920, height: 1440)
        let pts = DepthUnprojection.points(depth: [Float](repeating: 3, count: n), confidence: [UInt8](repeating: 2, count: n),
                                           width: 256, height: 192, intrinsics: full, cameraToWorld: matrix_identity_float4x4, stride: 1)
        // principal point of the depth map is (128, 96)
        XCTAssertEqual(pts.first { $0.x == 128 && $0.y == 96 }!.position.x, 0, accuracy: 1e-4)
        // one depth pixel = 1920/256 = 7.5 image pixels = 3 * 7.5 / 1500 metres at 3 m
        let one = pts.first { $0.x == 129 && $0.y == 96 }!.position.x
        XCTAssertEqual(one, 3 * 7.5 / 1500, accuracy: 1e-5)
    }

    func testMismatchedSizesReturnNothing() {
        XCTAssertTrue(DepthUnprojection.points(depth: [1, 2, 3], confidence: [2, 2], width: 3, height: 1, intrinsics: intr,
                                               cameraToWorld: matrix_identity_float4x4).isEmpty)
    }
}
