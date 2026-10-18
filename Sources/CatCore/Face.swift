/// 顔全体の矩形と、目・鼻・口などのパーツの矩形（すべて正規化座標・左上原点）
public struct Face: Equatable, Sendable {
    public var rect: Rect
    public var parts: [Rect]
    /// 猫の顔を組み立てるための点列（正規化座標）。取れない検出器では nil
    public var landmarks: FaceLandmarks?

    public init(rect: Rect, parts: [Rect], landmarks: FaceLandmarks? = nil) {
        self.rect = rect
        self.parts = parts
        self.landmarks = landmarks
    }
}

extension Rect {
    /// 点群を囲む最小の矩形
    public static func bounding(_ points: [(x: Double, y: Double)]) -> Rect? {
        guard let first = points.first else { return nil }
        var lo = first, hi = first
        for p in points.dropFirst() {
            lo = (min(lo.x, p.x), min(lo.y, p.y))
            hi = (max(hi.x, p.x), max(hi.y, p.y))
        }
        return Rect(x: lo.x, y: lo.y, w: hi.x - lo.x, h: hi.y - lo.y)
    }

    /// 短辺が長辺の `ratio` 倍以上になるよう、中心を保ったまま短辺を広げる（細長い目の枠を見やすくする）
    public func withMinAspect(_ ratio: Double) -> Rect {
        var r = self
        if h < w * ratio {
            r.h = w * ratio
            r.y = y + (h - r.h) / 2
        } else if w < h * ratio {
            r.w = h * ratio
            r.x = x + (w - r.w) / 2
        }
        return r
    }
}

/// 検出のたびに揺れる顔とパーツの位置を、前回の位置へ寄せて滑らかにする
public final class FaceSmoother {
    public var smoothing: Double
    private var previous: [Face] = []

    public init(smoothing: Double) {
        self.smoothing = smoothing
    }

    public func update(_ faces: [Face]) -> [Face] {
        let out = faces.map { f -> Face in
            guard let prev = previous.max(by: { $0.rect.iou(f.rect) < $1.rect.iou(f.rect) }),
                  prev.rect.iou(f.rect) > 0.1 else { return f }
            let parts = prev.parts.count == f.parts.count
                ? zip(prev.parts, f.parts).map { $0.lerp(to: $1, t: smoothing) }
                : f.parts
            return Face(rect: prev.rect.lerp(to: f.rect, t: smoothing), parts: parts, landmarks: f.landmarks)
        }
        previous = out
        return out
    }
}
