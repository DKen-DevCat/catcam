import XCTest
@testable import CatCore

final class TrackerTests: XCTestCase {
    private func blob(_ x: Double, _ y: Double, _ s: Double = 0.1) -> Blob {
        Blob(rect: Rect(x: x, y: y, w: s, h: s), area: 1)
    }

    private func tracker() -> Tracker {
        Tracker(config: TrackerConfig(iouThreshold: 0.1, maxMissed: 3, historyLength: 2, historyInterval: 1, smoothing: 1))
    }

    func testNewBlobsGetDistinctIDs() {
        let t = tracker()
        let tracks = t.update(blobs: [blob(0.1, 0.1), blob(0.6, 0.6)])
        XCTAssertEqual(Set(tracks.map(\.id)).count, 2)
    }

    func testOverlappingBlobKeepsID() {
        let t = tracker()
        let first = t.update(blobs: [blob(0.1, 0.1)])
        let second = t.update(blobs: [blob(0.12, 0.1)])
        XCTAssertEqual(second.map(\.id), first.map(\.id))
        XCTAssertEqual(second[0].rect.x, 0.12, accuracy: 1e-9)
    }

    func testDistantBlobStartsNewTrack() {
        let t = tracker()
        let first = t.update(blobs: [blob(0.1, 0.1)])
        let second = t.update(blobs: [blob(0.1, 0.1), blob(0.7, 0.7)])
        XCTAssertEqual(second.count, 2)
        XCTAssertTrue(second.contains { $0.id == first[0].id })
    }

    func testEachBlobClaimsAtMostOneTrack() {
        let t = tracker()
        _ = t.update(blobs: [blob(0.1, 0.1), blob(0.15, 0.1)])
        let tracks = t.update(blobs: [blob(0.12, 0.1)])
        XCTAssertEqual(tracks.filter { $0.missed == 0 }.count, 1)
    }

    func testMissingTrackFadesThenDisappears() {
        let t = tracker()
        _ = t.update(blobs: [blob(0.1, 0.1)])
        var tracks = t.update(blobs: [])
        XCTAssertEqual(tracks.count, 1)
        XCTAssertLessThan(tracks[0].alpha, 1)
        tracks = t.update(blobs: [])
        tracks = t.update(blobs: [])
        tracks = t.update(blobs: [])
        XCTAssertTrue(tracks.isEmpty)
    }

    func testHistoryKeepsRecentPositionsUpToLimit() {
        let t = tracker()
        _ = t.update(blobs: [blob(0.10, 0.1)])
        _ = t.update(blobs: [blob(0.11, 0.1)])
        _ = t.update(blobs: [blob(0.12, 0.1)])
        let tracks = t.update(blobs: [blob(0.13, 0.1)])
        XCTAssertEqual(tracks[0].history.map(\.x), [0.11, 0.12])
    }

    func testSmoothingBlendsTowardNewPosition() {
        let t = Tracker(config: TrackerConfig(iouThreshold: 0.1, maxMissed: 3, historyLength: 0, historyInterval: 1, smoothing: 0.5))
        _ = t.update(blobs: [blob(0.10, 0.1)])
        let tracks = t.update(blobs: [blob(0.14, 0.1)])
        XCTAssertEqual(tracks[0].rect.x, 0.12, accuracy: 1e-9)
    }
}
