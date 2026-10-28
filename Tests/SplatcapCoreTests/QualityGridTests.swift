import XCTest
import simd
@testable import SplatcapCore

final class QualityGridTests: XCTestCase {
    private func obs(_ p: SIMD3<Float>, distance: Float, angleDeg: Float = 0, sharpness: Float = 1, conf: UInt8 = 2) -> Observation {
        let a = angleDeg * .pi / 180
        return Observation(position: p, distance: distance, viewDirection: SIMD3(sin(a), 0, -cos(a)), sharpness: sharpness, lidarConfidence: conf)
    }

    func testUnseenCellIsNil() {
        let g = QualityGrid(cellSize: 0.1, maxCells: 1000)
        XCTAssertNil(g.score(at: SIMD3(1, 1, 1)))
        XCTAssertNil(g.band(at: SIMD3(1, 1, 1)))
    }

    func testScoreGrowsWithDistinctNearViews() {
        let p = SIMD3<Float>(0.5, 0.5, 0.5)
        let far = QualityGrid(cellSize: 0.1, maxCells: 1000)
        far.add(obs(p, distance: 5))
        XCTAssertEqual(far.band(at: p), .low)

        let near = QualityGrid(cellSize: 0.1, maxCells: 1000)
        near.add(obs(p, distance: 0.5, angleDeg: 0))
        near.add(obs(p, distance: 0.5, angleDeg: 30))
        near.add(obs(p, distance: 0.5, angleDeg: 60))
        XCTAssertEqual(near.band(at: p), .good)
        XCTAssertGreaterThan(near.score(at: p)!, far.score(at: p)!)
    }

    func testBlurredViewsDoNotCountAsDistinctViews() {
        let p = SIMD3<Float>(0.5, 0.5, 0.5)
        let g = QualityGrid(cellSize: 0.1, maxCells: 1000)
        for a in [Float(0), 30, 60] { g.add(obs(p, distance: 0.5, angleDeg: a, sharpness: 0.1)) }
        XCTAssertNotEqual(g.band(at: p), .good)
    }

    func testMemoryBoundedByMaxCells() {
        let g = QualityGrid(cellSize: 0.1, maxCells: 1000)
        for i in 0..<100_000 { g.add(obs(SIMD3(Float(i) * 0.2, 0, 0), distance: 1)) }
        XCTAssertLessThanOrEqual(g.cellCount, 1000)
    }

    func testNonFinitePositionIsIgnored() {
        let g = QualityGrid(cellSize: 0.1, maxCells: 1000)
        g.add(obs(SIMD3(.nan, 0, 0), distance: 1))
        g.add(obs(SIMD3(.infinity, 0, 0), distance: 1))
        XCTAssertEqual(g.cellCount, 0)
    }
}
