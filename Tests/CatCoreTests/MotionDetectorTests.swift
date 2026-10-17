import XCTest
@testable import CatCore

final class MotionDetectorTests: XCTestCase {
    private let w = 40, h = 20

    private func frame(fill: UInt8 = 50, squares: [(x: Int, y: Int, size: Int)] = []) -> GrayImage {
        var img = GrayImage(width: w, height: h, fill: fill)
        for s in squares {
            for y in s.y..<(s.y + s.size) {
                for x in s.x..<(s.x + s.size) {
                    img[x, y] = 200
                }
            }
        }
        return img
    }

    private func detector(minArea: Int = 1, maxBlobs: Int = 10) -> MotionDetector {
        MotionDetector(config: MotionConfig(sensitivity: 0.7, minArea: minArea, maxBlobs: maxBlobs))
    }

    func testFirstFrameOnlyInitializesBackground() {
        let d = detector()
        XCTAssertTrue(d.process(frame(squares: [(5, 5, 4)])).isEmpty)
    }

    func testStaticSceneHasNoMotion() {
        let d = detector()
        _ = d.process(frame())
        XCTAssertTrue(d.process(frame()).isEmpty)
    }

    func testBrightSquareBecomesOneBlobAroundIt() throws {
        let d = detector()
        _ = d.process(frame())
        let blobs = d.process(frame(squares: [(10, 6, 4)]))
        XCTAssertEqual(blobs.count, 1)
        let r = try XCTUnwrap(blobs.first).rect
        // 膨張 2 回で各辺 2px 広がる: x 8..15, y 4..11
        XCTAssertEqual(r.x, 8.0 / Double(w), accuracy: 1e-9)
        XCTAssertEqual(r.y, 4.0 / Double(h), accuracy: 1e-9)
        XCTAssertEqual(r.w, 8.0 / Double(w), accuracy: 1e-9)
        XCTAssertEqual(r.h, 8.0 / Double(h), accuracy: 1e-9)
    }

    func testBlobsSmallerThanMinAreaAreDropped() {
        let d = detector(minArea: 30)
        _ = d.process(frame())
        // 1px の変化は膨張後 5×5=25px で minArea 未満
        XCTAssertTrue(d.process(frame(squares: [(10, 10, 1)])).isEmpty)
    }

    func testMaxBlobsKeepsLargestFirst() {
        let d = detector(maxBlobs: 1)
        _ = d.process(frame())
        let blobs = d.process(frame(squares: [(2, 2, 2), (25, 5, 6)]))
        XCTAssertEqual(blobs.count, 1)
        XCTAssertGreaterThan(blobs[0].rect.x, 0.5)
    }

    func testBackgroundAbsorbsPersistentChange() {
        let d = detector()
        _ = d.process(frame())
        let moved = frame(squares: [(10, 6, 4)])
        var last: [Blob] = []
        for _ in 0..<60 {
            last = d.process(moved)
        }
        XCTAssertTrue(last.isEmpty, "静止した物体はいずれ背景に溶ける")
    }

    func testGateIgnoresMotionOutsidePerson() {
        let d = detector()
        _ = d.process(frame())
        var person = BinaryMask(width: w, height: h)
        for y in 0..<h {
            for x in 20..<w {
                person[x, y] = true
            }
        }
        // 左の四角は人物外、右の四角は人物内
        let blobs = d.process(frame(squares: [(3, 6, 4), (28, 6, 4)]), gate: person)
        XCTAssertEqual(blobs.count, 1)
        XCTAssertGreaterThan(blobs[0].rect.x, 0.5)
    }

    func testGateWithDifferentSizeIsIgnored() {
        let d = detector()
        _ = d.process(frame())
        let blobs = d.process(frame(squares: [(3, 6, 4)]), gate: BinaryMask(width: 2, height: 2))
        XCTAssertEqual(blobs.count, 1, "サイズが合わないマスクでは絞り込まない")
    }

    func testBlobsMostlyInsideFaceAreExcluded() {
        let inFace = Blob(rect: Rect(x: 0.2, y: 0.2, w: 0.1, h: 0.1), area: 1)
        // 顔に覆われるのは 4 割
        let halfIn = Blob(rect: Rect(x: 0.36, y: 0.2, w: 0.1, h: 0.1), area: 1)
        let outside = Blob(rect: Rect(x: 0.7, y: 0.7, w: 0.1, h: 0.1), area: 1)
        let face = Rect(x: 0.15, y: 0.15, w: 0.25, h: 0.25)
        let kept = [inFace, halfIn, outside].excluding(faces: [face])
        XCTAssertEqual(kept, [halfIn, outside])
    }

    func testHigherSensitivityDetectsSmallerChange() {
        func detects(sensitivity: Double) -> Bool {
            let d = MotionDetector(config: MotionConfig(sensitivity: sensitivity, minArea: 1, maxBlobs: 10))
            _ = d.process(GrayImage(width: w, height: h, fill: 50))
            var img = GrayImage(width: w, height: h, fill: 50)
            img[5, 5] = 80
            return !d.process(img).isEmpty
        }
        XCTAssertTrue(detects(sensitivity: 0.9))
        XCTAssertFalse(detects(sensitivity: 0.2))
    }
}
