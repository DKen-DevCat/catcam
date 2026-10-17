import XCTest
@testable import CatCore

final class FaceTests: XCTestCase {
    func testBoundingRectOfPoints() {
        let r = Rect.bounding([(0.2, 0.3), (0.4, 0.1), (0.3, 0.5)])
        XCTAssertEqual(r?.x ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(r?.y ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r?.w ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(r?.h ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertNil(Rect.bounding([]))
    }

    func testMinAspectGrowsThinRectAroundCenter() {
        // 目のように横長な枠を、高さが幅の 0.6 倍以上になるよう上下に広げる
        let r = Rect(x: 0.1, y: 0.2, w: 0.2, h: 0.04).withMinAspect(0.6)
        XCTAssertEqual(r.h, 0.12, accuracy: 1e-9)
        XCTAssertEqual(r.y + r.h / 2, 0.22, accuracy: 1e-9)
        XCTAssertEqual(r.w, 0.2, accuracy: 1e-9)
    }

    func testMinAspectGrowsTallRectSideways() {
        // 鼻のように縦長な枠は、幅が高さの 0.6 倍以上になるよう左右に広げる
        let r = Rect(x: 0.1, y: 0.2, w: 0.02, h: 0.2).withMinAspect(0.6)
        XCTAssertEqual(r.w, 0.12, accuracy: 1e-9)
        XCTAssertEqual(r.x + r.w / 2, 0.11, accuracy: 1e-9)
    }

    func testSmootherBlendsSameFaceAndParts() {
        let s = FaceSmoother(smoothing: 0.5)
        let a = Face(rect: Rect(x: 0.2, y: 0.2, w: 0.2, h: 0.2), parts: [Rect(x: 0.25, y: 0.25, w: 0.04, h: 0.02)])
        let b = Face(rect: Rect(x: 0.22, y: 0.2, w: 0.2, h: 0.2), parts: [Rect(x: 0.27, y: 0.25, w: 0.04, h: 0.02)])
        _ = s.update([a])
        let out = s.update([b])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].rect.x, 0.21, accuracy: 1e-9)
        XCTAssertEqual(out[0].parts[0].x, 0.26, accuracy: 1e-9)
    }

    func testSmootherStartsFreshForDistantFace() {
        let s = FaceSmoother(smoothing: 0.5)
        _ = s.update([Face(rect: Rect(x: 0.1, y: 0.1, w: 0.1, h: 0.1), parts: [])])
        let far = Face(rect: Rect(x: 0.7, y: 0.7, w: 0.1, h: 0.1), parts: [])
        XCTAssertEqual(s.update([far]), [far])
    }
}
