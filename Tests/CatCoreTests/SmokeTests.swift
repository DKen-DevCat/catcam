import XCTest
@testable import CatCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(CatCore.version, "0.0.1")
    }
}
