/// 正規化座標（0..1、原点は左上）の矩形
public struct Rect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    public var area: Double { w * h }

    public func intersectionArea(_ o: Rect) -> Double {
        let iw = min(maxX, o.maxX) - max(x, o.x)
        let ih = min(maxY, o.maxY) - max(y, o.y)
        return iw > 0 && ih > 0 ? iw * ih : 0
    }

    public func iou(_ o: Rect) -> Double {
        let inter = intersectionArea(o)
        let union = area + o.area - inter
        return union > 0 ? inter / union : 0
    }

    /// 自分の面積のうち `o` に覆われている割合
    public func coverage(by o: Rect) -> Double {
        area > 0 ? intersectionArea(o) / area : 0
    }

    public func lerp(to o: Rect, t: Double) -> Rect {
        Rect(x: x + (o.x - x) * t, y: y + (o.y - y) * t, w: w + (o.w - w) * t, h: h + (o.h - h) * t)
    }
}
