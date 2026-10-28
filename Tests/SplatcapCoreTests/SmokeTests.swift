import XCTest
@testable import SplatcapCore

final class SmokeTests: XCTestCase {
    func testCoreVersion() {
        XCTAssertEqual(SplatcapCore.version, "0.1.0")
    }
}
