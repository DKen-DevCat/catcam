import XCTest
@testable import CatCore

final class WindowScatterTests: XCTestCase {
    private let scatter = WindowScatter()
    private let aspect = 0.5625  // 16:9 の高さ / 幅

    func testTinyMotionStillGetsMediumWindow() throws {
        let w = try XCTUnwrap(scatter.windows(for: [Rect(x: 0.5, y: 0.5, w: 0.01, h: 0.01)], base: 0.25, aspect: aspect).first)
        XCTAssertGreaterThanOrEqual(w.h, 0.25 * scatter.minSize - 1e-9)
        XCTAssertGreaterThanOrEqual(w.w, 0.25 * aspect * scatter.minSize - 1e-9)
        XCTAssertLessThanOrEqual(w.h, 0.25 * scatter.maxSize + 1e-9)
    }

    func testSameInputGivesSameWindows() {
        let rects = [Rect(x: 0.3, y: 0.4, w: 0.1, h: 0.2), Rect(x: 0.4, y: 0.4, w: 0.1, h: 0.2)]
        XCTAssertEqual(scatter.windows(for: rects, base: 0.25, aspect: aspect),
                       scatter.windows(for: rects, base: 0.25, aspect: aspect))
    }

    func testRowOfCellsIsNotNeatlyAligned() {
        // 横に並んだ同じ大きさのマス → 窓は高さも上端も揃わない
        let cells = (0..<4).map { Rect(x: 0.3 + Double($0) * 0.1, y: 0.6, w: 0.1, h: 0.2) }
        let ws = scatter.windows(for: cells, base: 0.25, aspect: aspect)
        XCTAssertGreaterThan(Set(ws.map { ($0.y * 1000).rounded() }).count, 2)
        XCTAssertGreaterThan(Set(ws.map { ($0.h * 1000).rounded() }).count, 2)
    }

    func testEveryWindowOverlapsAnother() {
        // 離れた塊でも、どれかの窓に重なるよう寄せる
        let rects = [Rect(x: 0.1, y: 0.1, w: 0.05, h: 0.05), Rect(x: 0.8, y: 0.8, w: 0.05, h: 0.05),
                     Rect(x: 0.1, y: 0.8, w: 0.05, h: 0.05)]
        let ws = scatter.windows(for: rects, base: 0.25, aspect: aspect)
        for (i, w) in ws.enumerated() {
            let best = ws.enumerated().filter { $0.offset != i }.map { w.coverage(by: $0.element) }.max() ?? 0
            XCTAssertGreaterThanOrEqual(best, scatter.minOverlap - 1e-9, "窓\(i)")
        }
    }

    func testNewWindowIsPulledOntoExistingOne() {
        let existing = [Rect(x: 0.1, y: 0.1, w: 0.15, h: 0.25)]
        let w = scatter.windows(for: [Rect(x: 0.8, y: 0.7, w: 0.05, h: 0.05)], base: 0.25, aspect: aspect, existing: existing)[0]
        XCTAssertGreaterThanOrEqual(w.coverage(by: existing[0]), scatter.minOverlap - 1e-9)
    }

    func testWindowsStayOnScreen() {
        let ws = scatter.windows(for: [Rect(x: 0, y: 0, w: 0.02, h: 0.02), Rect(x: 0.98, y: 0.98, w: 0.02, h: 0.02)],
                                 base: 0.25, aspect: aspect)
        for w in ws {
            XCTAssertGreaterThanOrEqual(w.x, 0)
            XCTAssertGreaterThanOrEqual(w.y, 0)
            XCTAssertLessThanOrEqual(w.maxX, 1 + 1e-9)
            XCTAssertLessThanOrEqual(w.maxY, 1 + 1e-9)
        }
    }
}
