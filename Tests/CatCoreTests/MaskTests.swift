import XCTest
@testable import CatCore

final class MaskTests: XCTestCase {
    private func mask(_ rows: [String]) -> BinaryMask {
        var m = BinaryMask(width: rows[0].count, height: rows.count)
        for (y, row) in rows.enumerated() {
            for (x, c) in row.enumerated() where c == "#" {
                m[x, y] = true
            }
        }
        return m
    }

    // MARK: - Morphology

    func testDilateGrowsSinglePixelTo3x3() {
        let d = Morphology.dilate(mask([
            ".....",
            ".....",
            "..#..",
            ".....",
            ".....",
        ]))
        XCTAssertEqual(d, mask([
            ".....",
            ".###.",
            ".###.",
            ".###.",
            ".....",
        ]))
    }

    func testDilateClampsAtEdges() {
        let d = Morphology.dilate(mask([
            "#..",
            "...",
        ]))
        XCTAssertEqual(d, mask([
            "##.",
            "##.",
        ]))
    }

    func testDilateBridgesOnePixelGap() {
        let d = Morphology.dilate(mask(["#.#"]))
        XCTAssertEqual(d, mask(["###"]))
    }

    // MARK: - ConnectedComponents

    func testEmptyMaskHasNoComponents() {
        XCTAssertTrue(ConnectedComponents.find(mask(["...", "..."])).isEmpty)
    }

    func testSeparateBlobsAreCountedSeparately() {
        let cs = ConnectedComponents.find(mask([
            "##...",
            "##..#",
            "....#",
        ]))
        XCTAssertEqual(cs.count, 2)
        XCTAssertEqual(Set(cs.map(\.area)), [4, 2])
    }

    func testDiagonalPixelsAreEightConnected() {
        let cs = ConnectedComponents.find(mask([
            "#..",
            ".#.",
            "..#",
        ]))
        XCTAssertEqual(cs.count, 1)
        XCTAssertEqual(cs[0].area, 3)
    }

    func testLShapeBoundingBoxAndArea() {
        let cs = ConnectedComponents.find(mask([
            ".....",
            ".#...",
            ".#...",
            ".###.",
        ]))
        XCTAssertEqual(cs, [Component(minX: 1, minY: 1, maxX: 3, maxY: 3, area: 5)])
    }

    func testUShapeMergesIntoOneComponent() {
        // 2 本の縦棒が下で合流する。1 パス目では別ラベルになり union-find で統合される形
        let cs = ConnectedComponents.find(mask([
            "#...#",
            "#...#",
            "#####",
        ]))
        XCTAssertEqual(cs.count, 1)
        XCTAssertEqual(cs[0].area, 9)
    }
}
