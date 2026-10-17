import XCTest
@testable import CatCore

final class RectTests: XCTestCase {
    func testIoUOfIdenticalRectsIsOne() {
        let r = Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.2)
        XCTAssertEqual(r.iou(r), 1, accuracy: 1e-9)
    }

    func testIoUOfDisjointRectsIsZero() {
        let a = Rect(x: 0, y: 0, w: 0.1, h: 0.1)
        let b = Rect(x: 0.5, y: 0.5, w: 0.1, h: 0.1)
        XCTAssertEqual(a.iou(b), 0)
    }

    func testIoUOfHalfOverlapIsOneThird() {
        let a = Rect(x: 0, y: 0, w: 2, h: 1)
        let b = Rect(x: 1, y: 0, w: 2, h: 1)
        XCTAssertEqual(a.iou(b), 1.0 / 3.0, accuracy: 1e-9)
    }

    func testCoverageIsIntersectionOverOwnArea() {
        let small = Rect(x: 0, y: 0, w: 1, h: 1)
        let big = Rect(x: 0, y: 0, w: 4, h: 4)
        XCTAssertEqual(small.coverage(by: big), 1, accuracy: 1e-9)
        XCTAssertEqual(big.coverage(by: small), 1.0 / 16.0, accuracy: 1e-9)
    }

    func testLerpMovesHalfway() {
        let a = Rect(x: 0, y: 0, w: 2, h: 2)
        let b = Rect(x: 2, y: 2, w: 4, h: 4)
        XCTAssertEqual(a.lerp(to: b, t: 0.5), Rect(x: 1, y: 1, w: 3, h: 3))
    }
}
