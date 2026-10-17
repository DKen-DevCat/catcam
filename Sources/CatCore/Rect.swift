extension Array where Element == Rect {
    /// 各矩形から `others` に覆われた部分を順に取り除く
    public func subtracting(_ others: [Rect]) -> [Rect] {
        others.reduce(self) { rest, o in rest.flatMap { $0.subtracting(o) } }
    }
}

/// 正規化座標（0..1、原点は左上）の矩形
public struct Rect: Equatable, Codable, Sendable {
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

    /// 幅・高さがそれぞれ最大値以下になるよう等分割する。収まっていればそのまま
    public func tiled(maxW: Double, maxH: Double) -> [Rect] {
        let nx = max(1, Int((w / maxW).rounded(.up))), ny = max(1, Int((h / maxH).rounded(.up)))
        if nx == 1 && ny == 1 { return [self] }
        let cw = w / Double(nx), ch = h / Double(ny)
        return (0..<ny).flatMap { j in
            (0..<nx).map { i in Rect(x: x + Double(i) * cw, y: y + Double(j) * ch, w: cw, h: ch) }
        }
    }

    /// 自分から `o` と重なる部分を除いた残りを、重ならない最大 4 つの帯（上・下・左・右）で返す
    public func subtracting(_ o: Rect) -> [Rect] {
        guard intersectionArea(o) > 0 else { return [self] }
        let ix0 = max(x, o.x), ix1 = min(maxX, o.maxX)
        let iy0 = max(y, o.y), iy1 = min(maxY, o.maxY)
        return [
            Rect(x: x, y: y, w: w, h: iy0 - y),
            Rect(x: x, y: iy1, w: w, h: maxY - iy1),
            Rect(x: x, y: iy0, w: ix0 - x, h: iy1 - iy0),
            Rect(x: ix1, y: iy0, w: maxX - ix1, h: iy1 - iy0),
        ].filter { $0.w > 1e-12 && $0.h > 1e-12 }
    }

    public func lerp(to o: Rect, t: Double) -> Rect {
        Rect(x: x + (o.x - x) * t, y: y + (o.y - y) * t, w: w + (o.w - w) * t, h: h + (o.h - h) * t)
    }
}
