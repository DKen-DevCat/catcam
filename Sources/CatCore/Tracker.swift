public struct TrackerConfig: Sendable {
    public var iouThreshold: Double
    /// 見失ってからこのフレーム数を超えたら消す
    public var maxMissed: Int
    /// 残像として保持する過去位置の数
    public var historyLength: Int
    /// 何フレームごとに過去位置を記録するか
    public var historyInterval: Int
    /// 新しい位置への追従率（1 で即座に追従）
    public var smoothing: Double

    public init(iouThreshold: Double = 0.1, maxMissed: Int = 12, historyLength: Int = 4,
                historyInterval: Int = 3, smoothing: Double = 0.6) {
        self.iouThreshold = iouThreshold
        self.maxMissed = maxMissed
        self.historyLength = historyLength
        self.historyInterval = historyInterval
        self.smoothing = smoothing
    }
}

public struct Track: Equatable, Sendable {
    public let id: Int
    public var rect: Rect
    /// 古い順
    public var history: [Rect]
    public var age: Int
    public var missed: Int
    public var alpha: Double
}

/// 塊にフレーム間で同じ ID を振る。IoU の大きい組から貪欲に対応付ける
public final class Tracker {
    public var config: TrackerConfig
    public private(set) var tracks: [Track] = []
    private var nextID = 1

    public init(config: TrackerConfig = TrackerConfig()) {
        self.config = config
    }

    public func update(blobs: [Blob]) -> [Track] {
        var pairs: [(t: Int, b: Int, iou: Double)] = []
        for (ti, t) in tracks.enumerated() {
            for (bi, b) in blobs.enumerated() {
                let v = t.rect.iou(b.rect)
                if v >= config.iouThreshold { pairs.append((ti, bi, v)) }
            }
        }
        pairs.sort { $0.iou > $1.iou }

        var trackUsed = Set<Int>(), blobUsed = Set<Int>()
        for p in pairs where !trackUsed.contains(p.t) && !blobUsed.contains(p.b) {
            trackUsed.insert(p.t)
            blobUsed.insert(p.b)
            var t = tracks[p.t]
            if config.historyLength > 0, t.age % config.historyInterval == 0 {
                t.history.append(t.rect)
                if t.history.count > config.historyLength {
                    t.history.removeFirst(t.history.count - config.historyLength)
                }
            }
            t.rect = t.rect.lerp(to: blobs[p.b].rect, t: config.smoothing)
            t.age += 1
            t.missed = 0
            t.alpha = 1
            tracks[p.t] = t
        }

        for ti in tracks.indices where !trackUsed.contains(ti) {
            tracks[ti].missed += 1
            tracks[ti].alpha = 1 - Double(tracks[ti].missed) / Double(config.maxMissed + 1)
        }
        tracks.removeAll { $0.missed > config.maxMissed }

        for (bi, b) in blobs.enumerated() where !blobUsed.contains(bi) {
            tracks.append(Track(id: nextID, rect: b.rect, history: [], age: 1, missed: 0, alpha: 1))
            nextID += 1
        }
        return tracks
    }
}
