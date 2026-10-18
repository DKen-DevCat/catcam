import Foundation
import simd

/// 3D アバターの骨 1 本（Blender の座標: Z 上、正面 -Y）
public struct AvatarBone: Equatable, Sendable {
    public var name: String
    /// 親の骨の番号。根元は -1。親は必ず子より前に並ぶ
    public var parent: Int
    public var head: SIMD3<Float>
    public var tail: SIMD3<Float>

    public init(name: String, parent: Int, head: SIMD3<Float>, tail: SIMD3<Float>) {
        self.name = name
        self.parent = parent
        self.head = head
        self.tail = tail
    }
}

/// 骨の姿勢から頂点の変形行列を作る。
/// 各骨の回転は「親から見た回転」で、骨の根元（head）を中心に回す。親の回転は子に積み重なる
public struct AvatarSkeleton: Sendable {
    public let bones: [AvatarBone]

    public init(bones: [AvatarBone]) {
        self.bones = bones
    }

    public var restPose: [simd_quatf] { Array(repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: bones.count) }

    public func index(of name: String) -> Int? { bones.firstIndex { $0.name == name } }

    /// 各骨の、全体から見た回転
    public func worldRotations(local: [simd_quatf]) -> [simd_quatf] {
        var w = local
        for (i, b) in bones.enumerated() where b.parent >= 0 {
            w[i] = w[b.parent] * local[i]
        }
        return w
    }

    /// 頂点に掛ける行列（休止姿勢の座標 → 変形後の座標）。
    /// `stretch` は骨ごとの長さの倍率（骨の向きにだけ伸ばす。太さは変えない）
    public func skinMatrices(local: [simd_quatf], stretch: [Float]? = nil) -> [simd_float4x4] {
        let w = worldRotations(local: local)
        let heads = posedHeads(local: local, stretch: stretch)
        return bones.indices.map { i in
            Self.translation(heads[i]) * simd_float4x4(w[i]) * stretchMatrix(i, stretch) * Self.translation(-bones[i].head)
        }
    }

    /// 変形後の各骨の根元の位置
    public func posedHeads(local: [simd_quatf], stretch: [Float]? = nil) -> [SIMD3<Float>] {
        let w = worldRotations(local: local)
        var heads = bones.map(\.head)
        for (i, b) in bones.enumerated() where b.parent >= 0 {
            let offset = stretchMatrix(b.parent, stretch) * SIMD4(b.head - bones[b.parent].head, 0)
            heads[i] = heads[b.parent] + w[b.parent].act(SIMD3(offset.x, offset.y, offset.z))
        }
        return heads
    }

    private func stretchMatrix(_ i: Int, _ stretch: [Float]?) -> simd_float4x4 {
        guard let k = stretch?[i], k != 1 else { return matrix_identity_float4x4 }
        let u = simd_normalize(bones[i].tail - bones[i].head)
        let m3 = matrix_identity_float3x3 + (k - 1) * simd_float3x3(columns: (u * u.x, u * u.y, u * u.z))
        return simd_float4x4(columns: (SIMD4(m3.columns.0, 0), SIMD4(m3.columns.1, 0), SIMD4(m3.columns.2, 0), SIMD4(0, 0, 0, 1)))
    }

    /// 骨を、正面から見た画面（モデルの XZ 平面、x 右・y 上）で `dir` の向きにする。親の回転は打ち消す
    public func point(_ pose: inout [simd_quatf], bone i: Int, toward dir: SIMD2<Float>) {
        let rest = bones[i].tail - bones[i].head
        let angle = atan2(dir.y, dir.x) - atan2(rest.z, rest.x)
        // +X を +Z へ回すのは -Y 軸まわり
        let world = simd_quatf(angle: angle, axis: SIMD3(0, -1, 0))
        let parentWorld = bones[i].parent >= 0 ? worldRotations(local: pose)[bones[i].parent] : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        pose[i] = parentWorld.inverse * world
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }
}

/// 手の 21 点の並び（Vision の手の関節と同じ）。各指は付け根 → 第 2 関節 → 第 1 関節 → 指先の 4 点
public enum HandJoint {
    public static let wrist = 0
    /// 親指は CMC → MP → IP → 指先
    public static let thumb = 1
    public static let index = 5
    public static let middle = 9
    public static let ring = 13
    public static let little = 17
    public static let count = 21
    /// モデルの骨の名前と、その指の 4 点の先頭
    public static let fingers: [(name: String, start: Int)] = [
        ("thumb", thumb), ("index", index), ("middle", middle), ("ring", ring), ("little", little),
    ]
}

/// 人の体の関節（画像のピクセル座標・y 下向き）。left は本人の左（左右反転前の画像では右側に写る）
public struct BodyJoints: Equatable, Sendable {
    public var leftShoulder, leftElbow, leftWrist: Vec2?
    public var rightShoulder, rightElbow, rightWrist: Vec2?
    /// 手の 21 点（`HandJoint` の並び）。取れなかった点は nil
    public var leftHand: [Vec2?]?
    public var rightHand: [Vec2?]?

    public init(leftShoulder: Vec2?, leftElbow: Vec2?, leftWrist: Vec2?,
                rightShoulder: Vec2?, rightElbow: Vec2?, rightWrist: Vec2?) {
        self.leftShoulder = leftShoulder
        self.leftElbow = leftElbow
        self.leftWrist = leftWrist
        self.rightShoulder = rightShoulder
        self.rightElbow = rightElbow
        self.rightWrist = rightWrist
    }

    public func scaled(width: Double, height: Double) -> BodyJoints {
        func s(_ p: Vec2?) -> Vec2? { p.map { Vec2($0.x * width, $0.y * height) } }
        var r = BodyJoints(leftShoulder: s(leftShoulder), leftElbow: s(leftElbow), leftWrist: s(leftWrist),
                           rightShoulder: s(rightShoulder), rightElbow: s(rightElbow), rightWrist: s(rightWrist))
        r.leftHand = leftHand?.map(s)
        r.rightHand = rightHand?.map(s)
        return r
    }
}

/// アバターの姿勢と、画像上の置き場所
public struct AvatarPose: Sendable {
    public var local: [simd_quatf]
    /// モデルの (X, Z) を画像の (originX + X·scale, originY − Z·scale) に写す
    public var origin: SIMD2<Float>
    public var scale: Float
    /// 0 閉じている 〜 1 大きく開いている
    public var mouthOpen: Float
    /// 骨ごとの長さの倍率（手に届かせるために腕を伸ばす）
    public var stretch: [Float]

    public init(local: [simd_quatf], origin: SIMD2<Float>, scale: Float, mouthOpen: Float, stretch: [Float]? = nil) {
        self.local = local
        self.origin = origin
        self.scale = scale
        self.mouthOpen = mouthOpen
        self.stretch = stretch ?? Array(repeating: 1, count: local.count)
    }

    /// 画像のピクセル座標をモデルの (X, Z) に戻す
    public func unproject(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2((p.x - origin.x) / scale, (origin.y - p.y) / scale)
    }

    public func project(_ p: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2(origin.x + p.x * scale, origin.y - p.z * scale)
    }

    /// 前の姿勢へ寄せて滑らかにする
    public func blended(from prev: AvatarPose?, t: Float) -> AvatarPose {
        guard let prev, prev.local.count == local.count else { return self }
        var r = self
        r.local = zip(prev.local, local).map { simd_slerp($0, $1, t) }
        r.origin = prev.origin + (origin - prev.origin) * t
        r.scale = prev.scale + (scale - prev.scale) * t
        r.mouthOpen = prev.mouthOpen + (mouthOpen - prev.mouthOpen) * t
        if prev.stretch.count == stretch.count {
            r.stretch = zip(prev.stretch, stretch).map { $0 + ($1 - $0) * t }
        }
        return r
    }
}

/// 人の顔と体の関節からアバターの姿勢を決める（VTuber と同じ考え方: 見た目はモデル、動きは人から）
public struct AvatarPoser: Sendable {
    public let skeleton: AvatarSkeleton
    /// モデルの両目の中点と目の間隔。ここを人の目に合わせて置く
    public var eyeCenter: SIMD3<Float>
    public var eyeDistance: Float
    /// 人の顔より何倍大きく描くか（モデルは頭でっかちなので、人の顔を覆うよう大きめにする）
    public var headScale: Float

    public init(skeleton: AvatarSkeleton, eyeCenter: SIMD3<Float>, eyeDistance: Float, headScale: Float) {
        self.skeleton = skeleton
        self.eyeCenter = eyeCenter
        self.eyeDistance = eyeDistance
        self.headScale = headScale
    }

    public func pose(face: CatFaceRig?, body: BodyJoints?) -> AvatarPose? {
        guard let face else { return nil }
        var pose = skeleton.restPose

        // 上体の傾き: 両肩の線の傾き
        if let spine = skeleton.index(of: "spine.003"), let l = body?.leftShoulder, let r = body?.rightShoulder {
            let d = SIMD2(Float(l.x - r.x), Float(-(l.y - r.y)))
            pose[spine] = simd_quatf(angle: atan2(d.y, d.x), axis: SIMD3(0, -1, 0))
        }

        // 頭: 傾き（目の線）、左右の向き（鼻の横ずれ）、上下の向き（鼻の縦の位置）
        if let head = skeleton.index(of: "Head") {
            let roll = Float(atan2(-face.axis.y, face.axis.x))
            let mid = (face.leftEye.center + face.rightEye.center) * 0.5
            let rel = face.nose - mid
            let side = Float(rel.dot(face.axis) / face.eyeDistance)
            let down = Float(-rel.dot(face.up) / face.eyeDistance)
            let yaw = asin(min(max(side / 0.9, -0.95), 0.95))
            let pitch = min(max((down - 0.65) * 1.2, -0.5), 0.5)
            let world = simd_quatf(angle: roll, axis: SIMD3(0, -1, 0))
                * simd_quatf(angle: yaw, axis: SIMD3(0, 0, 1))
                * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
            let parent = skeleton.bones[head].parent
            let parentWorld = parent >= 0 ? skeleton.worldRotations(local: pose)[parent] : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            pose[head] = parentWorld.inverse * world
        }

        // 置き場所: モデルの目の中点を人の目の中点に重ね、目の間隔で大きさを決める
        let scale = Float(face.eyeDistance) * headScale / eyeDistance
        let mid = (face.leftEye.center + face.rightEye.center) * 0.5
        let origin = SIMD2(Float(mid.x) - eyeCenter.x * scale, Float(mid.y) + eyeCenter.z * scale)
        var out = AvatarPose(local: pose, origin: origin, scale: scale, mouthOpen: Float(face.mouthOpen))

        // 腕: 肘まで取れていれば向きをそのまま写す。手首だけなら、手首に前腕の先が来るよう肘の曲げを逆算する。
        // どちらもなければ下ろしておく
        for (side, shoulder, elbow, wrist, hand) in [("L", body?.leftShoulder, body?.leftElbow, body?.leftWrist, body?.leftHand),
                                                     ("R", body?.rightShoulder, body?.rightElbow, body?.rightWrist, body?.rightHand)] {
            defer { if let hand { fingers(&out, side: side, hand: hand) } }
            guard let upper = skeleton.index(of: "upper_arm.\(side)"), let fore = skeleton.index(of: "forearm.\(side)") else { continue }
            let outward: Float = side == "L" ? 1 : -1
            func dir(_ a: Vec2, _ b: Vec2) -> SIMD2<Float> { SIMD2(Float(b.x - a.x), Float(-(b.y - a.y))) }
            _ = shoulder
            if let e = elbow {
                // 肘が取れていれば、肘と手首を人の位置にそのまま重ねる（肩はモデルの肩のまま）
                place(&out, upper: upper, fore: fore, elbow: out.unproject(SIMD2(Float(e.x), Float(e.y))),
                      wrist: wrist.map { out.unproject(SIMD2(Float($0.x), Float($0.y))) })
            } else if let w = wrist {
                let target = out.unproject(SIMD2(Float(w.x), Float(w.y)))
                if let h = hand, let a = h[HandJoint.wrist], let b = h[HandJoint.middle], (a.x != b.x || a.y != b.y) {
                    // 肘は取れないので、前腕は手と同じ向きとみなして手首から逆にたどる
                    let d = simd_normalize(SIMD2(Float(b.x - a.x), Float(-(b.y - a.y))))
                    reach(&out, upper: upper, fore: fore, target: target, forearmDirection: d)
                } else {
                    reach(&out, upper: upper, fore: fore, target: target)
                }
            } else {
                skeleton.point(&out.local, bone: upper, toward: SIMD2(0.35 * outward, -1))
                skeleton.point(&out.local, bone: fore, toward: SIMD2(0.2 * outward, -1))
            }
        }
        return out
    }

    /// 手の骨は手首 → 中指の付け根の向きと長さに、指の各節は検出した隣り合う 2 点の向きと長さにする。
    /// 取れていない点にかかる節は親の向きのまま（まっすぐ）にする
    private func fingers(_ out: inout AvatarPose, side: String, hand: [Vec2?]) {
        func dir(_ a: Vec2?, _ b: Vec2?) -> SIMD2<Float>? {
            guard let a, let b else { return nil }
            return SIMD2(Float(b.x - a.x), Float(-(b.y - a.y)))
        }
        // 長さも人に合わせる（画像上の長さ ÷ モデルでの長さ）。モデルの手の大きさのままだと指先がずれる
        func fit(_ i: Int, _ d: SIMD2<Float>, modelLength: Float) {
            skeleton.point(&out.local, bone: i, toward: d)
            out.stretch[i] = min(max(simd_length(d) / out.scale / modelLength, 0.2), 5)
        }
        let bones = skeleton.bones
        if let i = skeleton.index(of: "hand.\(side)"), let d = dir(hand[HandJoint.wrist], hand[HandJoint.middle]) {
            // 手の骨の長さは、手首から中指の付け根まで
            let base = skeleton.index(of: "middle.1.\(side)").map { bones[$0].head } ?? bones[i].tail
            fit(i, d, modelLength: simd_length(base - bones[i].head))
        }
        for (name, start) in HandJoint.fingers {
            for k in 1...3 {
                guard let i = skeleton.index(of: "\(name).\(k).\(side)") else { continue }
                if let d = dir(hand[start + k - 1], hand[start + k]) {
                    fit(i, d, modelLength: simd_length(bones[i].tail - bones[i].head))
                } else {
                    out.local[i] = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                    out.stretch[i] = 1
                }
            }
        }
    }

    /// 上腕の先を `elbow` に、前腕の先を `wrist` に置く（骨を 0.2 倍まで伸び縮みさせて長さを合わせる）。手首がなければ前腕はまっすぐ
    private func place(_ out: inout AvatarPose, upper: Int, fore: Int, elbow: SIMD2<Float>, wrist: SIMD2<Float>?) {
        let b = skeleton.bones
        let l1 = simd_length(b[upper].tail - b[upper].head), l2 = simd_length(b[fore].tail - b[fore].head)
        let h = skeleton.posedHeads(local: out.local, stretch: out.stretch)[upper]
        let toElbow = elbow - SIMD2(h.x, h.z)
        guard simd_length(toElbow) > 1e-4 else { return }
        out.stretch[upper] = max(0.2, simd_length(toElbow) / l1)
        skeleton.point(&out.local, bone: upper, toward: toElbow)
        if let wrist, simd_length(wrist - elbow) > 1e-4 {
            out.stretch[fore] = max(0.2, simd_length(wrist - elbow) / l2)
            skeleton.point(&out.local, bone: fore, toward: wrist - elbow)
        } else {
            out.stretch[fore] = 1
            skeleton.point(&out.local, bone: fore, toward: toElbow)
        }
    }

    /// 人の関節と、それに対応するアバターの関節の画像上の位置（デバッグ表示・ログ用）。
    /// アバターの位置は骨の根元・先から求める。人の側が取れていなければ nil
    public func debugJoints(pose: AvatarPose, face: CatFaceRig?, body: BodyJoints?) -> [AvatarDebugJoint] {
        let m = skeleton.skinMatrices(local: pose.local, stretch: pose.stretch)
        func at(_ name: String, tail: Bool) -> SIMD2<Float>? {
            guard let i = skeleton.index(of: name) else { return nil }
            let p = m[i] * SIMD4(tail ? skeleton.bones[i].tail : skeleton.bones[i].head, 1)
            return pose.project(SIMD3(p.x, p.y, p.z))
        }
        var out: [AvatarDebugJoint] = []
        if let face {
            let mid = (face.leftEye.center + face.rightEye.center) * 0.5
            let headIndex = skeleton.index(of: "Head")
            let eye = headIndex.map { m[$0] * SIMD4(eyeCenter, 1) }
            out.append(AvatarDebugJoint(name: "目", human: mid, avatar: eye.map { pose.project(SIMD3($0.x, $0.y, $0.z)) }))
        }
        for (side, label, elbow, wrist, hand) in [("L", "左", body?.leftElbow, body?.leftWrist, body?.leftHand),
                                                  ("R", "右", body?.rightElbow, body?.rightWrist, body?.rightHand)] {
            out.append(AvatarDebugJoint(name: "\(label)肘", human: elbow, avatar: at("upper_arm.\(side)", tail: true)))
            out.append(AvatarDebugJoint(name: "\(label)手首", human: wrist, avatar: at("forearm.\(side)", tail: true)))
            for (finger, jp) in [("thumb", "親指先"), ("index", "人差指先"), ("middle", "中指先"), ("little", "小指先")] {
                let start = HandJoint.fingers.first { $0.name == finger }!.start
                out.append(AvatarDebugJoint(name: "\(label)\(jp)", human: hand?[start + 3], avatar: at("\(finger).3.\(side)", tail: true)))
            }
        }
        return out
    }

    /// 前腕を `forearmDirection` に向けて先を `target` に置き、上腕は肩からその肘へ向ける。
    /// 長さが合わない分は骨を伸び縮みさせる（上腕は縮めない。前腕は半分まで縮める）
    private func reach(_ out: inout AvatarPose, upper: Int, fore: Int, target: SIMD2<Float>, forearmDirection d: SIMD2<Float>) {
        let b = skeleton.bones
        let l1 = simd_length(b[upper].tail - b[upper].head), l2 = simd_length(b[fore].tail - b[fore].head)
        let h = skeleton.posedHeads(local: out.local, stretch: out.stretch)[upper]
        let s = SIMD2(h.x, h.z)
        let toElbow = target - d * l2 - s
        guard simd_length(toElbow) > 1e-4 else { return reach(&out, upper: upper, fore: fore, target: target) }
        let k1 = max(1, simd_length(toElbow) / l1)
        let elbow = s + simd_normalize(toElbow) * l1 * k1
        let toWrist = target - elbow
        out.stretch[upper] = k1
        out.stretch[fore] = max(0.5, simd_length(toWrist) / l2)
        skeleton.point(&out.local, bone: upper, toward: toElbow)
        skeleton.point(&out.local, bone: fore, toward: simd_length(toWrist) > 1e-4 ? toWrist : d)
    }

    /// 上腕と前腕の 2 本で、前腕の先を `target`（モデルの XZ 平面）に届かせる。肘は下向きに曲げる。
    /// 届かなければ 2 本とも同じ割合で伸ばす
    private func reach(_ out: inout AvatarPose, upper: Int, fore: Int, target: SIMD2<Float>) {
        let b = skeleton.bones
        let l1 = simd_length(b[upper].tail - b[upper].head), l2 = simd_length(b[fore].tail - b[fore].head)
        let h = skeleton.posedHeads(local: out.local, stretch: out.stretch)[upper]
        let s = SIMD2(h.x, h.z)
        let v = target - s
        let d = simd_length(v)
        guard d > 1e-4 else { return }
        if d >= (l1 + l2) * 0.999 {
            skeleton.point(&out.local, bone: upper, toward: v)
            skeleton.point(&out.local, bone: fore, toward: v)
            let k = d / (l1 + l2)
            out.stretch[upper] = k
            out.stretch[fore] = k
            return
        }
        out.stretch[upper] = 1
        out.stretch[fore] = 1
        // 余弦定理で肩の角度のずれを出し、肘が下に来る側を選ぶ
        let a = atan2(v.y, v.x)
        let delta = acos(min(max((l1 * l1 + d * d - l2 * l2) / (2 * l1 * d), -1), 1))
        let candidates = [a + delta, a - delta].map { s + l1 * SIMD2(cos($0), sin($0)) }
        let elbow = candidates[0].y < candidates[1].y ? candidates[0] : candidates[1]
        skeleton.point(&out.local, bone: upper, toward: elbow - s)
        skeleton.point(&out.local, bone: fore, toward: target - elbow)
    }
}

/// 人の動きが止まっていても生きて見えるよう、尻尾を左右にゆらし、呼吸で体を少し上下させる
public struct AvatarIdle: Sendable {
    /// 尻尾の骨（根元から先へ）
    private let tail: [Int]

    public init(skeleton: AvatarSkeleton) {
        tail = skeleton.bones.indices.filter { skeleton.bones[$0].name.hasPrefix("TailBase") }
    }

    public func apply(_ pose: AvatarPose, time: Double) -> AvatarPose {
        var p = pose
        // 尻尾: 前後の軸（Y）まわりに少しずつ回し、先へ行くほど遅れて揺れる（しなる）
        for (k, i) in tail.enumerated() {
            let angle = Float(0.045 * sin(time * 2.4 - Double(k) * 0.6))
            p.local[i] = p.local[i] * simd_quatf(angle: angle, axis: SIMD3(0, 1, 0))
        }
        // 呼吸: 約 4 秒周期で、大きさの 1.5% だけ上下する
        p.origin.y += Float(sin(time * 1.6)) * pose.scale * 0.015
        return p
    }
}

/// デバッグ用: 人の関節と、対応するアバターの関節（画像のピクセル座標）
public struct AvatarDebugJoint: Sendable {
    public var name: String
    public var human: Vec2?
    public var avatar: SIMD2<Float>?

    /// 両方あるときのずれ（px）
    public var error: Float? {
        guard let human, let avatar else { return nil }
        return simd_length(avatar - SIMD2(Float(human.x), Float(human.y)))
    }
}
