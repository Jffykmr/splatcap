import XCTest
import simd
@testable import SplatcapCore

final class FrameSelectorTests: XCTestCase {
    private func candidate(t: Double = 0, x: Float = 0, yawDeg: Float = 0, sharpness: Float = 1, normal: Bool = true) -> FrameCandidate {
        let q = simd_quatf(angle: yawDeg * .pi / 180, axis: SIMD3(0, 1, 0))
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4(x, 0, 0, 1)
        return FrameCandidate(timestamp: t, transform: m, sharpness: sharpness, trackingNormal: normal)
    }

    private func selector() -> FrameSelector {
        FrameSelector(minSharpness: 0.5, minTranslation: 0.1, minRotationDegrees: 5)
    }

    func testRejectsWhenTrackingNotNormal() {
        var s = selector()
        XCTAssertFalse(s.accept(candidate(normal: false)))
        XCTAssertTrue(s.accept(candidate()))
    }

    func testRejectsBlurred() {
        var s = selector()
        XCTAssertFalse(s.accept(candidate(sharpness: 0.1)))
    }

    func testRejectsNearDuplicate() {
        var s = selector()
        XCTAssertTrue(s.accept(candidate(t: 0)))
        XCTAssertFalse(s.accept(candidate(t: 1, x: 0.01, yawDeg: 1)))
    }

    func testAcceptsAfterTranslationOrRotation() {
        var s = selector()
        XCTAssertTrue(s.accept(candidate(t: 0)))
        XCTAssertTrue(s.accept(candidate(t: 1, x: 0.2)))
        XCTAssertTrue(s.accept(candidate(t: 2, x: 0.2, yawDeg: 10)))
    }

    func testRejectsEstimatedMotionBlur() {
        var s = FrameSelector(minSharpness: 0.5, minTranslation: 0.1, minRotationDegrees: 5, maxBlurPixels: 1.5)
        var blurry = candidate()
        blurry.blurPixels = 4
        XCTAssertFalse(s.accept(blurry))
        var fine = candidate()
        fine.blurPixels = 0.5
        XCTAssertTrue(s.accept(fine))
    }

    func testNaNBlurIsRejectedWhenLimited() {
        var s = FrameSelector(minSharpness: 0.5, minTranslation: 0.1, minRotationDegrees: 5, maxBlurPixels: 1.5)
        var c = candidate()
        c.blurPixels = .nan
        XCTAssertFalse(s.accept(c))
    }

    func testRejectsNonFiniteTransform() {
        var s = selector()
        XCTAssertFalse(s.accept(candidate(x: .nan)))
    }
}
