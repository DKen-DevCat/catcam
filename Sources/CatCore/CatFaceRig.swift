import Foundation

public struct Vec2: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, k: Double) -> Vec2 { Vec2(a.x * k, a.y * k) }
    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    public var length: Double { (x * x + y * y).squareRoot() }

    public func lerp(to o: Vec2, t: Double) -> Vec2 { self + (o - self) * t }

    static func mean(_ ps: [Vec2]) -> Vec2 {
        ps.reduce(Vec2(0, 0), +) * (1 / Double(ps.count))
    }
}

/// 顔のランドマークの点列（y 下向き。正規化座標でもピクセル座標でもよい）
public struct FaceLandmarks: Equatable, Sendable {
    public var leftEye: [Vec2]
    public var rightEye: [Vec2]
    public var nose: [Vec2]
    public var outerLips: [Vec2]
    public var innerLips: [Vec2]

    public init(leftEye: [Vec2], rightEye: [Vec2], nose: [Vec2], outerLips: [Vec2], innerLips: [Vec2]) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.nose = nose
        self.outerLips = outerLips
        self.innerLips = innerLips
    }

    /// 正規化座標をピクセル座標に直す（猫の顔は縦横同じ尺度で組み立てたいので）
    public func scaled(width: Double, height: Double) -> FaceLandmarks {
        func s(_ ps: [Vec2]) -> [Vec2] { ps.map { Vec2($0.x * width, $0.y * height) } }
        return FaceLandmarks(leftEye: s(leftEye), rightEye: s(rightEye), nose: s(nose),
                             outerLips: s(outerLips), innerLips: s(innerLips))
    }
}

/// 人の顔のランドマークから組み立てた、猫の顔パーツの配置（ピクセル座標・y 下向き）。
/// 描画側はこれをもとに目・鼻・口・ヒゲ・耳を描く
public struct CatFaceRig: Equatable, Sendable {
    public struct Eye: Equatable, Sendable {
        public var center: Vec2
        /// 人の目の横幅
        public var width: Double
        /// 0 閉じている 〜 1 開いている
        public var openness: Double
    }

    public struct Ear: Equatable, Sendable {
        /// 顔の中心側の付け根
        public var inner: Vec2
        /// 外側の付け根
        public var outer: Vec2
        public var tip: Vec2
    }

    /// 画像上で左に見える目（`axis` の負の側）
    public var leftEye: Eye
    public var rightEye: Eye
    /// 左目 → 右目の単位ベクトル
    public var axis: Vec2
    /// 頭のてっぺんへ向かう単位ベクトル
    public var up: Vec2
    public var eyeDistance: Double
    /// 鼻先
    public var nose: Vec2
    public var mouth: Vec2
    public var mouthWidth: Double
    /// 0 閉じている 〜 1 大きく開いている
    public var mouthOpen: Double
    public var leftEar: Ear
    public var rightEar: Ear

    public init?(_ lm: FaceLandmarks) {
        guard !lm.leftEye.isEmpty, !lm.rightEye.isEmpty else { return nil }
        var a = Vec2.mean(lm.leftEye), b = Vec2.mean(lm.rightEye)
        var aPts = lm.leftEye, bPts = lm.rightEye
        let d = (b - a).length
        guard d > 0 else { return nil }
        var axis = (b - a) * (1 / d)
        var up = Vec2(axis.y, -axis.x)
        // 目の左右は顔の向きで決める: 頭の上方向が鼻・口と逆を向くように並べる。鼻がなければ画像の x 順
        let below = lm.nose.isEmpty ? nil : Vec2.mean(lm.nose)
        let flip = below.map { up.dot((a + b) * 0.5 - $0) < 0 } ?? (axis.x < 0)
        if flip {
            swap(&a, &b)
            swap(&aPts, &bPts)
            axis = axis * -1
            up = up * -1
        }

        func eye(_ c: Vec2, _ pts: [Vec2]) -> Eye {
            let xs = pts.map { ($0 - c).dot(axis) }, ys = pts.map { ($0 - c).dot(up) }
            let w = (xs.max() ?? 0) - (xs.min() ?? 0), h = (ys.max() ?? 0) - (ys.min() ?? 0)
            let ratio = w > 0 ? h / w : 0
            return Eye(center: c, width: w, openness: Self.clamp01((ratio - 0.08) / 0.17))
        }
        leftEye = eye(a, aPts)
        rightEye = eye(b, bPts)
        self.axis = axis
        self.up = up
        eyeDistance = d

        let mid = (a + b) * 0.5
        let down = up * -1
        nose = lm.nose.max { $0.dot(down) < $1.dot(down) } ?? mid + down * (0.7 * d)
        if lm.outerLips.isEmpty {
            mouth = nose + down * (0.4 * d)
            mouthWidth = 0.5 * d
            mouthOpen = 0
        } else {
            mouth = Vec2.mean(lm.outerLips)
            let xs = lm.outerLips.map { $0.dot(axis) }
            mouthWidth = (xs.max() ?? 0) - (xs.min() ?? 0)
            let ys = lm.innerLips.map { $0.dot(up) }
            let gap = (ys.max() ?? 0) - (ys.min() ?? 0)
            mouthOpen = mouthWidth > 0 ? Self.clamp01((gap / mouthWidth - 0.08) / 0.3) : 0
        }

        // 耳は目の間隔を単位に、額より上（髪のあたり）から生やす
        func ear(_ side: Double) -> Ear {
            let base = mid + up * (1.2 * d) + axis * (side * 0.62 * d)
            return Ear(inner: base - axis * (side * 0.36 * d),
                       outer: base + axis * (side * 0.36 * d) - up * (0.18 * d),
                       tip: base + up * (1.05 * d) + axis * (side * 0.22 * d))
        }
        leftEar = ear(-1)
        rightEar = ear(1)
    }

    public func lerp(to o: CatFaceRig, t: Double) -> CatFaceRig {
        func e(_ a: Eye, _ b: Eye) -> Eye {
            Eye(center: a.center.lerp(to: b.center, t: t), width: a.width + (b.width - a.width) * t,
                openness: a.openness + (b.openness - a.openness) * t)
        }
        func ear(_ a: Ear, _ b: Ear) -> Ear {
            Ear(inner: a.inner.lerp(to: b.inner, t: t), outer: a.outer.lerp(to: b.outer, t: t), tip: a.tip.lerp(to: b.tip, t: t))
        }
        var r = self
        r.leftEye = e(leftEye, o.leftEye)
        r.rightEye = e(rightEye, o.rightEye)
        let ax = axis.lerp(to: o.axis, t: t)
        r.axis = ax * (1 / max(ax.length, 1e-9))
        r.up = Vec2(r.axis.y, -r.axis.x)
        r.eyeDistance = eyeDistance + (o.eyeDistance - eyeDistance) * t
        r.nose = nose.lerp(to: o.nose, t: t)
        r.mouth = mouth.lerp(to: o.mouth, t: t)
        r.mouthWidth = mouthWidth + (o.mouthWidth - mouthWidth) * t
        r.mouthOpen = mouthOpen + (o.mouthOpen - mouthOpen) * t
        r.leftEar = ear(leftEar, o.leftEar)
        r.rightEar = ear(rightEar, o.rightEar)
        return r
    }

    /// 前回の配置のうち一番近い顔へ寄せて滑らかにする（検出は 15Hz・描画は 30fps なので、間を埋める役も兼ねる）
    public static func smooth(previous: [CatFaceRig], current: [CatFaceRig], t: Double) -> [CatFaceRig] {
        current.map { c in
            let mid = (c.leftEye.center + c.rightEye.center) * 0.5
            guard let p = previous.min(by: {
                (($0.leftEye.center + $0.rightEye.center) * 0.5 - mid).length < (($1.leftEye.center + $1.rightEye.center) * 0.5 - mid).length
            }), ((p.leftEye.center + p.rightEye.center) * 0.5 - mid).length < c.eyeDistance else { return c }
            return p.lerp(to: c, t: t)
        }
    }

    private static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}
