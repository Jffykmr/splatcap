import XCTest
import simd
@testable import SplatcapCore

final class MotionBlurTests: XCTestCase {
    private func pose(yaw: Float = 0, x: Float = 0) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(x, 0, 0, 1)
        return m
    }

    func testStationaryCameraHasNoBlur() {
        XCTAssertEqual(MotionBlur.pixels(previous: pose(), current: pose(), seconds: 0.03, exposure: 0.01, focalPixels: 2000, depth: 2), 0, accuracy: 1e-3)
    }

    func testRotationBlurScalesWithSpeedExposureAndFocal() {
        // 0.01 rad in 0.01 s = 1 rad/s; 1 rad/s * 2000 px * 0.01 s = 20 px
        let b = MotionBlur.pixels(previous: pose(), current: pose(yaw: 0.01), seconds: 0.01, exposure: 0.01, focalPixels: 2000, depth: 2)
        XCTAssertEqual(b, 20, accuracy: 0.5)
    }

    func testTranslationBlurDependsOnDepth() {
        // 0.1 m in 0.1 s = 1 m/s; at 2 m: 1 * 2000 / 2 * 0.01 = 10 px; at 4 m: 5 px
        let near = MotionBlur.pixels(previous: pose(), current: pose(x: 0.1), seconds: 0.1, exposure: 0.01, focalPixels: 2000, depth: 2)
        let far = MotionBlur.pixels(previous: pose(), current: pose(x: 0.1), seconds: 0.1, exposure: 0.01, focalPixels: 2000, depth: 4)
        XCTAssertEqual(near, 10, accuracy: 0.1)
        XCTAssertEqual(far, 5, accuracy: 0.1)
    }

    func testUnusableTimeStepGivesZero() {
        XCTAssertEqual(MotionBlur.pixels(previous: pose(), current: pose(x: 1), seconds: 0, exposure: 0.01, focalPixels: 2000, depth: 2), 0)
        XCTAssertEqual(MotionBlur.pixels(previous: pose(), current: pose(x: 1), seconds: 0.1, exposure: 0, focalPixels: 2000, depth: 2), 0)
    }
}
