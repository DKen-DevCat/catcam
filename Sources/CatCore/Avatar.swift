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

    /// 頂点に掛ける行列（休止姿勢の座標 → 変形後の座標）
    public func skinMatrices(local: [simd_quatf]) -> [simd_float4x4] {
        let w = worldRotations(local: local)
        var heads = bones.map(\.head)
        for (i, b) in bones.enumerated() where b.parent >= 0 {
            heads[i] = heads[b.parent] + w[b.parent].act(b.head - bones[b.parent].head)
        }
        return bones.indices.map { i in
            Self.translation(heads[i]) * simd_float4x4(w[i]) * Self.translation(-bones[i].head)
        }
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

/// 人の体の関節（画像のピクセル座標・y 下向き）。left は本人の左（左右反転前の画像では右側に写る）
public struct BodyJoints: Equatable, Sendable {
    public var leftShoulder, leftElbow, leftWrist: Vec2?
    public var rightShoulder, rightElbow, rightWrist: Vec2?

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
        return BodyJoints(leftShoulder: s(leftShoulder), leftElbow: s(leftElbow), leftWrist: s(leftWrist),
                          rightShoulder: s(rightShoulder), rightElbow: s(rightElbow), rightWrist: s(rightWrist))
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

        // 腕: 肩 → 肘 → 手首 の向きをそのまま写す。取れていない腕は下ろしておく
        for (side, shoulder, elbow, wrist) in [("L", body?.leftShoulder, body?.leftElbow, body?.leftWrist),
                                               ("R", body?.rightShoulder, body?.rightElbow, body?.rightWrist)] {
            guard let upper = skeleton.index(of: "upper_arm.\(side)"), let fore = skeleton.index(of: "forearm.\(side)") else { continue }
            let out: Float = side == "L" ? 1 : -1
            func dir(_ a: Vec2, _ b: Vec2) -> SIMD2<Float> { SIMD2(Float(b.x - a.x), Float(-(b.y - a.y))) }
            if let s = shoulder, let e = elbow {
                skeleton.point(&pose, bone: upper, toward: dir(s, e))
                skeleton.point(&pose, bone: fore, toward: wrist.map { dir(e, $0) } ?? dir(s, e))
            } else {
                skeleton.point(&pose, bone: upper, toward: SIMD2(0.35 * out, -1))
                skeleton.point(&pose, bone: fore, toward: SIMD2(0.2 * out, -1))
            }
        }

        // 置き場所: モデルの目の中点を人の目の中点に重ね、目の間隔で大きさを決める
        let scale = Float(face.eyeDistance) * headScale / eyeDistance
        let mid = (face.leftEye.center + face.rightEye.center) * 0.5
        let origin = SIMD2(Float(mid.x) - eyeCenter.x * scale, Float(mid.y) + eyeCenter.z * scale)
        return AvatarPose(local: pose, origin: origin, scale: scale, mouthOpen: Float(face.mouthOpen))
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
