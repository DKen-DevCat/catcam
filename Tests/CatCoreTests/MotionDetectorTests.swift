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

    func testLargeBlobIsSplitIntoTilesNoLargerThanMax() {
        let d = MotionDetector(config: MotionConfig(sensitivity: 0.7, minArea: 1, maxBlobs: 50,
                                                    dilateIterations: 0, maxBlobWidth: 0.25, maxBlobHeight: 1))
        _ = d.process(frame())
        // 幅 30px の横長の棒（最大幅は 40 * 0.25 = 10px）
        var img = frame()
        for y in 8..<12 {
            for x in 5..<35 {
                img[x, y] = 200
            }
        }
        let blobs = d.process(img)
        XCTAssertEqual(blobs.count, 3)
        for b in blobs {
            XCTAssertLessThanOrEqual(b.rect.w, 0.25 + 1e-9)
        }
        XCTAssertEqual(blobs.map(\.area).reduce(0, +), 30 * 4)
    }

    func testSplitDropsEmptyCellsAndFitsTightly() {
        let d = MotionDetector(config: MotionConfig(sensitivity: 0.7, minArea: 1, maxBlobs: 50,
                                                    dilateIterations: 0, maxBlobWidth: 0.25, maxBlobHeight: 0.5))
        _ = d.process(frame())
        // L 字: 縦棒 x=2..3, y=0..19 と 横棒 x=2..21, y=18..19。右上の 2 マスは空
        var img = frame()
        for y in 0..<20 {
            for x in 2..<4 { img[x, y] = 200 }
        }
        for y in 18..<20 {
            for x in 2..<22 { img[x, y] = 200 }
        }
        let blobs = d.process(img)
        // 20x20 の bbox を 2x2 に分割 → 右上は空なので 3 枚
        XCTAssertEqual(blobs.count, 3)
        // 右下のマスは横棒だけにぴったり合う（y=18..19）
        let bottomRight = blobs.first { $0.rect.x > 0.25 }
        XCTAssertEqual(bottomRight?.rect.y ?? 0, 18.0 / Double(h), accuracy: 1e-9)
        XCTAssertEqual(bottomRight?.rect.h ?? 0, 2.0 / Double(h), accuracy: 1e-9)
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
