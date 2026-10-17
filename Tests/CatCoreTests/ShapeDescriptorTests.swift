import XCTest
@testable import CatCore

final class ShapeDescriptorTests: XCTestCase {
    private func filled(_ w: Int, _ h: Int, _ isOn: (Int, Int) -> Bool) -> BinaryMask {
        var m = BinaryMask(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w where isOn(x, y) {
                m[x, y] = true
            }
        }
        return m
    }

    func testFullSquareSetsAllBits() {
        let m = filled(32, 32) { _, _ in true }
        let d = ShapeDescriptor(mask: m, box: Component(minX: 0, minY: 0, maxX: 31, maxY: 31, area: 32 * 32))
        XCTAssertEqual(d.bits.map { $0.nonzeroBitCount }.reduce(0, +), 256)
        XCTAssertEqual(d.aspect, 1, accuracy: 1e-9)
        XCTAssertEqual(d.fill, 1, accuracy: 1e-9)
    }

    func testLeftHalfSetsOnlyLeftColumns() {
        let m = filled(32, 32) { x, _ in x < 16 }
        let d = ShapeDescriptor(mask: m, box: Component(minX: 0, minY: 0, maxX: 31, maxY: 31, area: 16 * 32))
        for row in 0..<16 {
            for col in 0..<16 {
                XCTAssertEqual(d.bit(col: col, row: row), col < 8, "col \(col) row \(row)")
            }
        }
        XCTAssertEqual(d.fill, 0.5, accuracy: 1e-9)
    }

    func testOnlyBoxRegionIsUsed() {
        // 箱の外の画素は無視する
        let m = filled(40, 20) { x, _ in x >= 20 }
        let d = ShapeDescriptor(mask: m, box: Component(minX: 20, minY: 0, maxX: 39, maxY: 9, area: 200))
        XCTAssertEqual(d.bits.map { $0.nonzeroBitCount }.reduce(0, +), 256)
        XCTAssertEqual(d.aspect, 2, accuracy: 1e-9)
    }

    func testHammingDistance() {
        let all = ShapeDescriptor(bits: [.max, .max, .max, .max], aspect: 1, fill: 1)
        let none = ShapeDescriptor(bits: [0, 0, 0, 0], aspect: 1, fill: 0)
        XCTAssertEqual(all.hamming(all), 0)
        XCTAssertEqual(all.hamming(none), 256)
    }

    func testMirroredFlipsColumns() {
        let m = filled(32, 32) { x, _ in x < 8 }
        let d = ShapeDescriptor(mask: m, box: Component(minX: 0, minY: 0, maxX: 31, maxY: 31, area: 8 * 32))
        let flipped = d.mirrored()
        XCTAssertTrue(flipped.bit(col: 15, row: 3))
        XCTAssertFalse(flipped.bit(col: 0, row: 3))
        XCTAssertEqual(flipped.mirrored(), d)
    }
}
