import XCTest
@testable import CatCore

final class CatMatcherTests: XCTestCase {
    private func shape(_ w: Int, _ h: Int, _ isOn: (Int, Int) -> Bool = { _, _ in true }) -> ShapeDescriptor {
        var m = BinaryMask(width: w, height: h)
        var area = 0
        for y in 0..<h {
            for x in 0..<w where isOn(x, y) {
                m[x, y] = true
                area += 1
            }
        }
        return ShapeDescriptor(mask: m, box: Component(minX: 0, minY: 0, maxX: w - 1, maxY: h - 1, area: area))
    }

    func testPicksIdenticalShape() {
        let tall = shape(10, 40), wide = shape(40, 10), square = shape(20, 20)
        let m = CatMatcher(shapes: [tall, wide, square])
        XCTAssertEqual(m.best(for: square)?.index, 2)
        XCTAssertEqual(m.best(for: square)?.distance ?? 1, 0, accuracy: 1e-9)
    }

    func testTallQueryPrefersTallCat() {
        let m = CatMatcher(shapes: [shape(40, 12), shape(12, 40)])
        XCTAssertEqual(m.best(for: shape(10, 30))?.index, 1)
    }

    func testExcludedIndexFallsBackToNextBest() {
        let m = CatMatcher(shapes: [shape(12, 40), shape(40, 12), shape(11, 40)])
        XCTAssertEqual(m.best(for: shape(12, 40), excluding: [0])?.index, 2)
    }

    func testMirroredCatMatchesMirroredShape() {
        // 左に寄った L 字の猫しかいない時、右に寄った形には反転して当てる
        let leftHeavy = shape(20, 20) { x, y in x < 6 || y > 14 }
        let rightHeavy = shape(20, 20) { x, y in x > 13 || y > 14 }
        let m = CatMatcher(shapes: [leftHeavy])
        let hit = m.best(for: rightHeavy)
        XCTAssertEqual(hit?.index, 0)
        XCTAssertEqual(hit?.mirrored, true)
        XCTAssertEqual(m.best(for: leftHeavy)?.mirrored, false)
    }

    func testEmptyLibraryReturnsNil() {
        XCTAssertNil(CatMatcher(shapes: []).best(for: shape(4, 4)))
    }

    func testMotionBlobsCarryTheirShape() {
        let d = MotionDetector(config: MotionConfig(sensitivity: 0.7, minArea: 1, maxBlobs: 10, dilateIterations: 0))
        _ = d.process(GrayImage(width: 40, height: 20, fill: 50))
        var img = GrayImage(width: 40, height: 20, fill: 50)
        for y in 2..<6 {
            for x in 2..<14 { img[x, y] = 200 }
        }
        let blob = d.process(img).first
        XCTAssertEqual(blob?.shape?.aspect ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(blob?.shape?.fill ?? 0, 1, accuracy: 1e-9)
    }
}
