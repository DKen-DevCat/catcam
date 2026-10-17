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

    private func freezingTracker(idleArea: Int = 0) -> Tracker {
        Tracker(config: TrackerConfig(iouThreshold: 0.1, maxMissed: 3, historyLength: 0, historyInterval: 1,
                                      smoothing: 1, freezeWhenIdle: true, idleArea: idleArea))
    }

    func testIdleFreezesTracksInPlace() {
        let t = freezingTracker()
        let first = t.update(blobs: [blob(0.1, 0.1)])
        var tracks: [Track] = []
        for _ in 0..<10 {
            tracks = t.update(blobs: [])
        }
        XCTAssertEqual(tracks.map(\.id), first.map(\.id))
        XCTAssertEqual(tracks[0].alpha, 1)
        XCTAssertTrue(tracks[0].frozen)
    }

    func testIdleRestoresFadingTracks() {
        let t = freezingTracker()
        _ = t.update(blobs: [blob(0.1, 0.1), blob(0.6, 0.6)])
        // 右下だけ見失って薄くなり始める
        let fading = t.update(blobs: [blob(0.1, 0.1)])
        XCTAssertLessThan(fading.first { $0.rect.x > 0.5 }?.alpha ?? 1, 1)
        let frozen = t.update(blobs: [])
        XCTAssertEqual(frozen.count, 2)
        XCTAssertTrue(frozen.allSatisfy { $0.alpha == 1 })
    }

    func testResumingDropsUnmatchedFrozenTracksImmediately() {
        let t = freezingTracker()
        let first = t.update(blobs: [blob(0.1, 0.1), blob(0.6, 0.6)])
        _ = t.update(blobs: [])
        // 左上だけ再び動く。右下の固定ウィンドウは即座に消える
        let resumed = t.update(blobs: [blob(0.11, 0.1)])
        XCTAssertEqual(resumed.count, 1)
        XCTAssertEqual(resumed[0].id, first.first { $0.rect.x < 0.5 }?.id)
        XCTAssertFalse(resumed[0].frozen)
    }

    func testTinyMotionCountsAsIdle() {
        let t = freezingTracker(idleArea: 10)
        let first = t.update(blobs: [Blob(rect: Rect(x: 0.1, y: 0.1, w: 0.1, h: 0.1), area: 50)])
        // 面積の合計が idleArea 未満のノイズは「止まっている」とみなし、固定を崩さない
        let tracks = t.update(blobs: [Blob(rect: Rect(x: 0.7, y: 0.7, w: 0.01, h: 0.01), area: 3)])
        XCTAssertEqual(tracks.map(\.id), first.map(\.id))
        XCTAssertTrue(tracks[0].frozen)
    }

    func testFrozenStaysUntilMotionReachesResumeArea() {
        let t = Tracker(config: TrackerConfig(iouThreshold: 0.1, maxMissed: 3, historyLength: 0, historyInterval: 1,
                                              smoothing: 1, freezeWhenIdle: true, idleArea: 10, resumeArea: 40))
        let first = t.update(blobs: [Blob(rect: Rect(x: 0.1, y: 0.1, w: 0.1, h: 0.1), area: 100)])
        _ = t.update(blobs: [])
        // 固定中は idleArea 以上でも resumeArea 未満なら動き出しとみなさない
        let small = t.update(blobs: [Blob(rect: Rect(x: 0.7, y: 0.7, w: 0.05, h: 0.05), area: 20)])
        XCTAssertEqual(small.map(\.id), first.map(\.id))
        XCTAssertTrue(small[0].frozen)
        // resumeArea 以上で動き出し、固定ウィンドウは消える
        let resumed = t.update(blobs: [Blob(rect: Rect(x: 0.7, y: 0.7, w: 0.1, h: 0.1), area: 50)])
        XCTAssertEqual(resumed.count, 1)
        XCTAssertNotEqual(resumed[0].id, first[0].id)
    }

    func testZeroSmoothingKeepsWindowsWhereTheySpawned() {
        // 動きに追従しない: 重なる動きがある間は同じ場所に残り、離れたら新しく湧く
        let t = Tracker(config: TrackerConfig(iouThreshold: 0.3, maxMissed: 3, historyLength: 0, historyInterval: 1, smoothing: 0))
        let first = t.update(blobs: [blob(0.10, 0.1)])
        let stay = t.update(blobs: [blob(0.12, 0.1)])
        XCTAssertEqual(stay.map(\.id), first.map(\.id))
        XCTAssertEqual(stay[0].rect.x, 0.10, accuracy: 1e-9)

        let moved = t.update(blobs: [blob(0.17, 0.1)])
        XCTAssertEqual(moved.count, 2, "元の場所に残ったまま、新しい場所に湧く")
        XCTAssertEqual(moved.first { $0.id == first[0].id }?.rect.x ?? 0, 0.10, accuracy: 1e-9)
        XCTAssertEqual(moved.first { $0.id != first[0].id }?.rect.x ?? 0, 0.17, accuracy: 1e-9)
    }

    func testSmoothingBlendsTowardNewPosition() {
        let t = Tracker(config: TrackerConfig(iouThreshold: 0.1, maxMissed: 3, historyLength: 0, historyInterval: 1, smoothing: 0.5))
        _ = t.update(blobs: [blob(0.10, 0.1)])
        let tracks = t.update(blobs: [blob(0.14, 0.1)])
        XCTAssertEqual(tracks[0].rect.x, 0.12, accuracy: 1e-9)
    }
}
