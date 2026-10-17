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

    func testTiledSplitsIntoEqualCellsWithinMax() {
        let tiles = Rect(x: 0.1, y: 0.1, w: 0.5, h: 0.2).tiled(maxW: 0.2, maxH: 0.2)
        XCTAssertEqual(tiles.count, 3)
        for t in tiles {
            XCTAssertEqual(t.w, 0.5 / 3, accuracy: 1e-9)
            XCTAssertEqual(t.h, 0.2, accuracy: 1e-9)
        }
        XCTAssertEqual(tiles.map(\.x).max() ?? 0, 0.1 + 2 * 0.5 / 3, accuracy: 1e-9)
    }

    func testTiledKeepsSmallRectAsIs() {
        let r = Rect(x: 0.1, y: 0.1, w: 0.1, h: 0.1)
        XCTAssertEqual(r.tiled(maxW: 0.2, maxH: 0.2), [r])
    }

    func testSubtractingDisjointKeepsSelf() {
        let r = Rect(x: 0, y: 0, w: 1, h: 1)
        XCTAssertEqual(r.subtracting(Rect(x: 2, y: 2, w: 1, h: 1)), [r])
    }

    func testSubtractingCoveringRectLeavesNothing() {
        XCTAssertTrue(Rect(x: 0.2, y: 0.2, w: 0.1, h: 0.1).subtracting(Rect(x: 0, y: 0, w: 1, h: 1)).isEmpty)
    }

    func testSubtractingRightPartLeavesLeftStrip() {
        let rest = Rect(x: 0, y: 0, w: 4, h: 2).subtracting(Rect(x: 3, y: -1, w: 5, h: 5))
        XCTAssertEqual(rest, [Rect(x: 0, y: 0, w: 3, h: 2)])
    }

    func testSubtractingHoleLeavesFourStripsWithRightArea() {
        let r = Rect(x: 0, y: 0, w: 4, h: 4)
        let hole = Rect(x: 1, y: 1, w: 2, h: 2)
        let rest = r.subtracting(hole)
        XCTAssertEqual(rest.count, 4)
        XCTAssertEqual(rest.map(\.area).reduce(0, +), 16 - 4, accuracy: 1e-9)
        XCTAssertTrue(rest.allSatisfy { $0.intersectionArea(hole) == 0 })
    }

    func testSubtractingSeveralRects() {
        let rest = [Rect(x: 0, y: 0, w: 4, h: 1)].subtracting([Rect(x: 0, y: 0, w: 1, h: 1), Rect(x: 3, y: 0, w: 1, h: 1)])
        XCTAssertEqual(rest, [Rect(x: 1, y: 0, w: 2, h: 1)])
    }

    func testLerpMovesHalfway() {
        let a = Rect(x: 0, y: 0, w: 2, h: 2)
        let b = Rect(x: 2, y: 2, w: 4, h: 4)
        XCTAssertEqual(a.lerp(to: b, t: 0.5), Rect(x: 1, y: 1, w: 3, h: 3))
    }
}
