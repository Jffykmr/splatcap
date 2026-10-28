import XCTest
import simd
@testable import SplatcapCore

final class OrientationTests: XCTestCase {
    private let intr = PinholeIntrinsics(fx: 100, fy: 200, cx: 30, cy: 40, width: 300, height: 400)

    private func pose() -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(1, 2, 3))))
        m.columns.3 = SIMD4<Float>(0.5, -1.0, 2.0, 1)
        return m
    }

    private func project(_ m: simd_float4x4, _ i: PinholeIntrinsics, _ p: SIMD3<Float>) -> SIMD2<Float> {
        let c = m.inverse * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD2(i.fx * c.x / -c.z + i.cx, i.cy - i.fy * c.y / -c.z)
    }

    func testIntrinsicsOneTurn() {
        XCTAssertEqual(Orientation.intrinsics(intr, quarterTurnsClockwise: 1),
                       PinholeIntrinsics(fx: 200, fy: 100, cx: 360, cy: 30, width: 400, height: 300))
    }

    func testFourTurnsAreIdentity() {
        XCTAssertEqual(Orientation.intrinsics(intr, quarterTurnsClockwise: 4), intr)
        let m = pose()
        XCTAssertEqual(Orientation.cameraToWorld(m, quarterTurnsClockwise: 4), m)
    }

    func testProjectionFollowsImageRotation() {
        let m = pose(), p = m * SIMD4<Float>(0.3, -0.2, -2.5, 1)
        let world = SIMD3<Float>(p.x, p.y, p.z)
        let uv = project(m, intr, world)
        let w = Float(intr.width), h = Float(intr.height)
        let expected: [Int: SIMD2<Float>] = [1: SIMD2(h - uv.y, uv.x), 2: SIMD2(w - uv.x, h - uv.y), 3: SIMD2(uv.y, w - uv.x)]
        for (k, e) in expected {
            let got = project(Orientation.cameraToWorld(m, quarterTurnsClockwise: k), Orientation.intrinsics(intr, quarterTurnsClockwise: k), world)
            XCTAssertEqual(got.x, e.x, accuracy: 1e-3, "turns \(k)")
            XCTAssertEqual(got.y, e.y, accuracy: 1e-3, "turns \(k)")
        }
    }

    func testRotateGridClockwise() {
        let r = Orientation.rotateGrid(["a", "b", "c", "d", "e", "f"], width: 3, height: 2, quarterTurnsClockwise: 1)
        XCTAssertEqual(r.data, ["d", "a", "e", "b", "f", "c"])
        XCTAssertEqual(r.width, 2)
        XCTAssertEqual(r.height, 3)
        let back = Orientation.rotateGrid(r.data, width: r.width, height: r.height, quarterTurnsClockwise: 3)
        XCTAssertEqual(back.data, ["a", "b", "c", "d", "e", "f"])
    }

    func testZUpMapsArkitUpToZ() {
        let up = Orientation.zUp * SIMD4<Float>(0, 1, 0, 0)
        XCTAssertEqual(up, SIMD4<Float>(0, 0, 1, 0))
        let forward = Orientation.zUp * SIMD4<Float>(0, 0, -1, 0)
        XCTAssertEqual(forward, SIMD4<Float>(0, 1, 0, 0))
    }
}
