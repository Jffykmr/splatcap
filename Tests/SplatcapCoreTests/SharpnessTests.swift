import XCTest
@testable import SplatcapCore

final class SharpnessTests: XCTestCase {
    private func variance(_ pixels: [UInt8], _ w: Int, _ h: Int) -> Float {
        pixels.withUnsafeBufferPointer { Sharpness.laplacianVariance(luma: $0.baseAddress!, width: w, height: h, bytesPerRow: w) }
    }

    func testFlatImageHasZeroVariance() {
        XCTAssertEqual(variance([UInt8](repeating: 128, count: 64 * 64), 64, 64), 0)
    }

    func testCheckerboardIsSharperThanSoftRamp() {
        var checker = [UInt8](), ramp = [UInt8]()
        for y in 0..<64 { for x in 0..<64 { checker.append((x + y) % 2 == 0 ? 0 : 255); ramp.append(UInt8(x * 4)) } }
        XCTAssertGreaterThan(variance(checker, 64, 64), variance(ramp, 64, 64) + 1000)
    }

    func testTinyImageIsHandled() {
        XCTAssertEqual(variance([1, 2, 3, 4], 2, 2), 0)
    }

    func testTrackerNormalizesAgainstRecentPeak() {
        var t = SharpnessTracker()
        XCTAssertEqual(t.normalized(100), 1)
        XCTAssertEqual(t.normalized(100), 1)
        XCTAssertEqual(t.normalized(20), 0.2, accuracy: 0.01)
    }

    func testTrackerTreatsFeaturelessSceneAsSharpAndIgnoresNaN() {
        var t = SharpnessTracker()
        XCTAssertEqual(t.normalized(0), 1)
        XCTAssertEqual(t.normalized(.nan), 0)
    }
}
