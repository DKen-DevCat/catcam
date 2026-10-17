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
    /// 動きが止まったら、その時点のトラックをその場に固定する。再び動いたら、対応しない固定トラックは即座に消す
    public var freezeWhenIdle: Bool
    /// 塊の面積の合計がこれ未満なら「止まっている」とみなす（ノイズで固定が崩れないように）
    public var idleArea: Int

    public init(iouThreshold: Double = 0.1, maxMissed: Int = 12, historyLength: Int = 4,
                historyInterval: Int = 3, smoothing: Double = 0.6,
                freezeWhenIdle: Bool = false, idleArea: Int = 0) {
        self.iouThreshold = iouThreshold
        self.maxMissed = maxMissed
        self.historyLength = historyLength
        self.historyInterval = historyInterval
        self.smoothing = smoothing
        self.freezeWhenIdle = freezeWhenIdle
        self.idleArea = idleArea
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
    /// 動きが止まってその場に固定されている
    public var frozen = false
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
        if config.freezeWhenIdle, blobs.reduce(0, { $0 + $1.area }) < max(config.idleArea, 1) {
            // 見失いかけのものも含め、直前のウィンドウ群をそのまま残す
            for i in tracks.indices {
                tracks[i].frozen = true
                tracks[i].missed = 0
                tracks[i].alpha = 1
            }
            return tracks
        }

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
            t.frozen = false
            tracks[p.t] = t
        }

        for ti in tracks.indices where !trackUsed.contains(ti) {
            tracks[ti].missed += 1
            tracks[ti].alpha = 1 - Double(tracks[ti].missed) / Double(config.maxMissed + 1)
        }
        tracks.removeAll { $0.missed > config.maxMissed || ($0.frozen && $0.missed > 0) }

        for (bi, b) in blobs.enumerated() where !blobUsed.contains(bi) {
            tracks.append(Track(id: nextID, rect: b.rect, history: [], age: 1, missed: 0, alpha: 1))
            nextID += 1
        }
        return tracks
    }
}
