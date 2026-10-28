import simd

public struct Observation {
    public var position: SIMD3<Float>
    public var distance: Float
    public var viewDirection: SIMD3<Float>
    public var sharpness: Float
    public var lidarConfidence: UInt8

    public init(position: SIMD3<Float>, distance: Float, viewDirection: SIMD3<Float>, sharpness: Float, lidarConfidence: UInt8) {
        self.position = position
        self.distance = distance
        self.viewDirection = viewDirection
        self.sharpness = sharpness
        self.lidarConfidence = lidarConfidence
    }
}

public enum QualityBand { case low, medium, good }

/// Sparse voxel grid: how well each cell of the scene has been observed. Memory is bounded by `maxCells`.
public final class QualityGrid {
    private struct Key: Hashable { let x: Int, y: Int, z: Int }

    private struct Cell {
        var seq: Int
        var sharpDirections: [SIMD3<Float>] = []
        var minDistance: Float = .greatestFiniteMagnitude
        var confidence: UInt8 = 0
    }

    private static let sharpThreshold: Float = 0.5
    private static let minAngleCos: Float = cos(20 * .pi / 180)
    private static let maxViewsCounted = 3

    private let cellSize: Float
    private let maxCells: Int
    private var cells: [Key: Cell] = [:]
    private var counter = 0

    public init(cellSize: Float, maxCells: Int) {
        self.cellSize = cellSize
        self.maxCells = maxCells
    }

    public var cellCount: Int { cells.count }

    public func add(_ o: Observation) {
        guard o.position.x.isFinite, o.position.y.isFinite, o.position.z.isFinite,
              o.distance.isFinite, o.sharpness.isFinite else { return }
        let key = self.key(o.position)
        var cell = cells[key] ?? { counter += 1; return Cell(seq: counter) }()
        cell.minDistance = min(cell.minDistance, o.distance)
        cell.confidence = max(cell.confidence, o.lidarConfidence)
        if o.sharpness >= Self.sharpThreshold, cell.sharpDirections.count < Self.maxViewsCounted {
            let d = simd_normalize(o.viewDirection)
            if d.x.isFinite, !cell.sharpDirections.contains(where: { simd_dot($0, d) > Self.minAngleCos }) {
                cell.sharpDirections.append(d)
            }
        }
        cells[key] = cell
        if cells.count > maxCells { evict() }
    }

    public func score(at p: SIMD3<Float>) -> Float? {
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite, let c = cells[key(p)] else { return nil }
        return Self.score(c)
    }

    public func band(at p: SIMD3<Float>) -> QualityBand? {
        guard let s = score(at: p) else { return nil }
        return s < 0.4 ? .low : (s < 0.75 ? .medium : .good)
    }

    private static func score(_ c: Cell) -> Float {
        let views = Float(c.sharpDirections.count) / Float(maxViewsCounted)
        let near = min(max(1 - (c.minDistance - 0.5) / 2.5, 0), 1)
        let conf = Float(c.confidence) / 2
        return 0.5 * views + 0.3 * near + 0.2 * conf
    }

    private func key(_ p: SIMD3<Float>) -> Key {
        Key(x: Int((p.x / cellSize).rounded(.down)), y: Int((p.y / cellSize).rounded(.down)), z: Int((p.z / cellSize).rounded(.down)))
    }

    /// Drops to 90% of maxCells, discarding highest-scoring (already good) and oldest cells first.
    private func evict() {
        let target = max(maxCells * 9 / 10, 0)
        let order = cells.sorted { a, b in
            let sa = Self.score(a.value), sb = Self.score(b.value)
            return sa != sb ? sa > sb : a.value.seq < b.value.seq
        }
        for (k, _) in order.prefix(cells.count - target) { cells[k] = nil }
    }
}
