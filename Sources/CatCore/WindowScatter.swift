/// 動きの塊（マス目に分けたもの）から、出す窓の矩形を決める。
/// マス目そのままだと小さい窓が隙間なく整列してしまうので、窓は中くらいの大きさにそろえ、
/// 大きさ・縦横比・位置を塊ごとにばらつかせ、どの窓もほかの窓と必ず重なるように寄せる
public struct WindowScatter: Sendable {
    /// 窓の高さ（`base` に対する比率）の範囲。幅も同じ範囲で別々にばらつく
    public var minSize: Double
    public var maxSize: Double
    /// 塊の中心からのずれ（窓の大きさに対する比率）
    public var jitter: Double
    /// 重なりとみなす、互いの面積に対する重なりの割合の下限
    public var minOverlap: Double

    public init(minSize: Double = 0.8, maxSize: Double = 1.2, jitter: Double = 0.15, minOverlap: Double = 0.2) {
        self.minSize = minSize
        self.maxSize = maxSize
        self.jitter = jitter
        self.minOverlap = minOverlap
    }

    /// `base` は窓の高さの基準（映像の高さに対する比率）、`aspect` は映像の高さ / 幅。
    /// `existing` は表示中の窓で、新しい窓はこれにも重なればよい。並びは `rects` と同じ
    public func windows(for rects: [Rect], base: Double, aspect: Double, existing: [Rect] = []) -> [Rect] {
        var ws = rects.map { r -> Rect in
            // 同じ場所の塊には毎回同じばらつきを出す（フレームごとに窓が震えないように）
            let cx = r.x + r.w / 2, cy = r.y + r.h / 2
            let qx = Int((cx * 32).rounded(.down)), qy = Int((cy * 32).rounded(.down))
            let h = base * lerp(Self.noise(qx, qy, 0)), w = base * aspect * lerp(Self.noise(qx, qy, 1))
            let x = cx + (Self.noise(qx, qy, 2) * 2 - 1) * jitter * w - w / 2
            let y = cy + (Self.noise(qx, qy, 3) * 2 - 1) * jitter * h - h / 2
            return Rect(x: min(max(x, 0), max(1 - w, 0)), y: min(max(y, 0), max(1 - h, 0)), w: w, h: h)
        }
        for i in ws.indices {
            let others = existing + ws.indices.filter { $0 != i }.map { ws[$0] }
            guard !others.isEmpty, !others.contains(where: { overlaps(ws[i], $0) }) else { continue }
            // 一番近い窓へ、重なるまで少しずつ寄せる。中心が重なれば必ず重なる
            let c = center(ws[i])
            let target = others.min { dist(center($0), c) < dist(center($1), c) }!
            let tc = center(target)
            for k in 1...20 {
                let t = Double(k) / 20
                let moved = Rect(x: ws[i].x + (tc.x - c.x) * t, y: ws[i].y + (tc.y - c.y) * t, w: ws[i].w, h: ws[i].h)
                if overlaps(moved, target) || k == 20 {
                    ws[i] = moved
                    break
                }
            }
        }
        return ws
    }

    private func lerp(_ t: Double) -> Double { minSize + (maxSize - minSize) * t }

    private func overlaps(_ a: Rect, _ b: Rect) -> Bool {
        min(a.coverage(by: b), b.coverage(by: a)) >= minOverlap
    }

    private func center(_ r: Rect) -> (x: Double, y: Double) { (r.x + r.w / 2, r.y + r.h / 2) }
    private func dist(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    /// 整数の組から 0..1 の値を決める（同じ入力なら同じ値）
    static func noise(_ x: Int, _ y: Int, _ k: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= UInt64(k) &* 0x1656_67B1_9E37_79F9
        h ^= h >> 31
        h &*= 0xBF58_476D_1CE4_E5B9
        h ^= h >> 29
        return Double(h >> 11) / Double(1 << 53)
    }
}
