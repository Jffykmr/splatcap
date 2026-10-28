import XCTest
import simd
@testable import SplatcapCore

final class SessionExporterTests: XCTestCase {
    private struct Input: Decodable {
        let name: String
        let matrix: [[Double]]
        let fx, fy, cx, cy: Double
        let width, height: Int
    }

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/golden")

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
    private let depth = [Float](repeating: 1.2345, count: 256 * 192)
    private let conf = [UInt8](repeating: 2, count: 256 * 192)

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("splatcap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func loadInputs(_ tag: String) throws -> [ExportedFrame] {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("inputs_\(tag).json"))
        return try JSONDecoder().decode([Input].self, from: data).map { i in
            // matrix is row-major; simd_float4x4 is column-major
            var m = simd_float4x4()
            for r in 0..<4 { for c in 0..<4 { m[c][r] = Float(i.matrix[r][c]) } }
            return ExportedFrame(name: i.name, cameraToWorld: m, fx: Float(i.fx), fy: Float(i.fy), cx: Float(i.cx), cy: Float(i.cy), width: i.width, height: i.height)
        }
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private func number(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? .nan }

    private func assertSameTransforms(_ a: [String: Any], _ b: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a["camera_model"] as? String, b["camera_model"] as? String, file: file, line: line)
        for k in ["fl_x", "fl_y", "cx", "cy", "w", "h"] where b[k] != nil || a[k] != nil {
            XCTAssertEqual(number(a[k]), number(b[k]), accuracy: 1e-3, "key \(k)", file: file, line: line)
        }
        let fa = a["frames"] as! [[String: Any]], fb = b["frames"] as! [[String: Any]]
        XCTAssertEqual(fa.count, fb.count, file: file, line: line)
        for (x, y) in zip(fa, fb) {
            XCTAssertEqual(x["file_path"] as? String, y["file_path"] as? String, file: file, line: line)
            let mx = (x["transform_matrix"] as! [[Double]]).flatMap { $0 }
            let my = (y["transform_matrix"] as! [[Double]]).flatMap { $0 }
            XCTAssertEqual(mx.count, 16, file: file, line: line)
            for (p, q) in zip(mx, my) { XCTAssertEqual(p, q, accuracy: 1e-5, file: file, line: line) }
            for k in ["fl_x", "fl_y", "cx", "cy"] where x[k] != nil || y[k] != nil {
                XCTAssertEqual(number(x[k]), number(y[k]), accuracy: 1e-3, "frame key \(k)", file: file, line: line)
            }
        }
    }

    func testTransformsMatchPythonGolden() throws {
        for tag in ["shared", "perframe"] {
            let dir = tempDir()
            let ex = try SessionExporter(directory: dir)
            for f in try loadInputs(tag) { try ex.append(frame: f, jpeg: jpeg, depth: depth, confidence: conf) }
            try ex.finish(seed: [])
            assertSameTransforms(try json(dir.appendingPathComponent("transforms.json")),
                                 try json(Self.fixtures.appendingPathComponent("transforms_\(tag).json")))
        }
    }

    func testPartialSessionIsExportable() throws {
        let dir = tempDir()
        let ex = try SessionExporter(directory: dir)
        let inputs = try loadInputs("shared")
        for i in 0..<5 {
            var f = inputs[i % inputs.count]
            f.name = "p\(i)"
            try ex.append(frame: f, jpeg: jpeg, depth: depth, confidence: conf)
        }
        let frames = try json(dir.appendingPathComponent("transforms.json"))["frames"] as! [Any]
        XCTAssertEqual(frames.count, 5)
    }

    func testEmptySeedOmitsPly() throws {
        let dir = tempDir()
        let ex = try SessionExporter(directory: dir)
        try ex.finish(seed: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sparse_pc.ply").path))
    }

    func testSeedPlyHasHeaderAndFifteenBytesPerPoint() throws {
        let dir = tempDir()
        let ex = try SessionExporter(directory: dir)
        try ex.finish(seed: [(SIMD3<Float>(1, 2, 3), SIMD3<UInt8>(10, 200, 30))])
        let raw = try Data(contentsOf: dir.appendingPathComponent("sparse_pc.ply"))
        let end = raw.range(of: Data("end_header\n".utf8))!.upperBound
        XCTAssertEqual(raw.count - end, 15)
        XCTAssertEqual(Array(raw[(end + 12)...]), [10, 200, 30])
    }

    func testDepthPngIs16BitGrayscaleNamedLikeImage() throws {
        let dir = tempDir()
        let ex = try SessionExporter(directory: dir)
        let f = try loadInputs("shared")[0]
        try ex.append(frame: f, jpeg: jpeg, depth: depth, confidence: conf)
        let png = try Data(contentsOf: dir.appendingPathComponent("depths/\(f.name).png"))
        XCTAssertEqual(Array(png[1...3]), Array("PNG".utf8))
        XCTAssertEqual(png[24], 16) // bit depth
        XCTAssertEqual(png[25], 0)  // grayscale
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("images/\(f.name).jpg").path))
    }

    func testRotatedDepthGridIsWrittenWithItsOwnSize() throws {
        let dir = tempDir()
        let ex = try SessionExporter(directory: dir)
        let f = try loadInputs("shared")[0]
        try ex.append(frame: f, jpeg: jpeg, depth: depth, confidence: conf, depthWidth: 192, depthHeight: 256)
        let png = try Data(contentsOf: dir.appendingPathComponent("depths/\(f.name).png"))
        func be32(_ o: Int) -> Int { (Int(png[o]) << 24) | (Int(png[o + 1]) << 16) | (Int(png[o + 2]) << 8) | Int(png[o + 3]) }
        XCTAssertEqual(be32(16), 192)
        XCTAssertEqual(be32(20), 256)
    }

    func testWrongDepthSizeThrows() throws {
        let ex = try SessionExporter(directory: tempDir())
        let f = try loadInputs("shared")[0]
        XCTAssertThrowsError(try ex.append(frame: f, jpeg: Data(), depth: [1, 2, 3], confidence: [2, 2, 2]))
    }
}
