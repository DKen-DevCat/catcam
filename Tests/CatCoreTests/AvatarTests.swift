import XCTest
import simd
@testable import CatCore

final class AvatarTests: XCTestCase {
    /// 根元 → 腕の付け根 → 前腕 の 3 本だけの骨（Blender 座標: Z 上、正面 -Y）
    private func skeleton() -> AvatarSkeleton {
        AvatarSkeleton(bones: [
            AvatarBone(name: "spine", parent: -1, head: SIMD3(0, 0, 0), tail: SIMD3(0, 0, 1)),
            AvatarBone(name: "upper_arm.L", parent: 0, head: SIMD3(0.5, 0, 1), tail: SIMD3(1.5, 0, 1)),
            AvatarBone(name: "forearm.L", parent: 1, head: SIMD3(1.5, 0, 1), tail: SIMD3(2.5, 0, 1)),
        ])
    }

    private func assertNear(_ a: SIMD3<Float>, _ b: SIMD3<Float>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), 1e-4, "\(a) != \(b)", file: file, line: line)
    }

    func testRestPoseGivesIdentitySkin() {
        let s = skeleton()
        let m = s.skinMatrices(local: s.restPose)
        for x in m {
            XCTAssertLessThan(simd_length(x.columns.0 - SIMD4(1, 0, 0, 0)) + simd_length(x.columns.3 - SIMD4(0, 0, 0, 1)), 1e-6)
        }
    }

    func testParentRotationCarriesChild() {
        let s = skeleton()
        var pose = s.restPose
        // 腕の付け根を -Y 軸まわりに 90°（+X → +Z、腕を真上に上げる）
        pose[1] = simd_quatf(angle: .pi / 2, axis: SIMD3(0, -1, 0))
        let m = s.skinMatrices(local: pose)
        // 前腕の先（2.5, 0, 1）は、付け根（0.5, 0, 1）の真上 2 に来る
        let tip = m[2] * SIMD4(2.5, 0, 1, 1)
        assertNear(SIMD3(tip.x, tip.y, tip.z), SIMD3(0.5, 0, 3))
        // 付け根の位置そのものは動かない
        let root = m[1] * SIMD4(0.5, 0, 1, 1)
        assertNear(SIMD3(root.x, root.y, root.z), SIMD3(0.5, 0, 1))
    }

    func testWorldDirectionSetsBoneDirectionRegardlessOfParent() {
        let s = skeleton()
        var pose = s.restPose
        pose[0] = simd_quatf(angle: 0.3, axis: SIMD3(0, -1, 0))
        // 前腕を画面上で真下（モデルの -Z）に向ける
        s.point(&pose, bone: 2, toward: SIMD2(0, -1))
        let m = s.skinMatrices(local: pose)
        let head = m[2] * SIMD4(1.5, 0, 1, 1), tail = m[2] * SIMD4(2.5, 0, 1, 1)
        let d = simd_normalize(SIMD3(tail.x - head.x, tail.y - head.y, tail.z - head.z))
        assertNear(d, SIMD3(0, 0, -1))
    }

    func testBoneLookupByName() {
        XCTAssertEqual(skeleton().index(of: "forearm.L"), 2)
        XCTAssertNil(skeleton().index(of: "tail"))
    }

    // MARK: - 人の姿勢からの割り当て

    private func poser() -> AvatarPoser {
        AvatarPoser(skeleton: AvatarSkeleton(bones: [
            AvatarBone(name: "spine", parent: -1, head: SIMD3(0, 0, 0), tail: SIMD3(0, 0, 0.8)),
            AvatarBone(name: "spine.003", parent: 0, head: SIMD3(0, 0, 0.4), tail: SIMD3(0, 0, 0.8)),
            AvatarBone(name: "Head", parent: 1, head: SIMD3(0, 0, 0.9), tail: SIMD3(0, 0, 1.8)),
            AvatarBone(name: "upper_arm.L", parent: 1, head: SIMD3(0.4, 0, 0.6), tail: SIMD3(0.9, 0, 0.6)),
            AvatarBone(name: "forearm.L", parent: 3, head: SIMD3(0.9, 0, 0.6), tail: SIMD3(1.2, 0, 0.6)),
            AvatarBone(name: "upper_arm.R", parent: 1, head: SIMD3(-0.4, 0, 0.6), tail: SIMD3(-0.9, 0, 0.6)),
            AvatarBone(name: "forearm.R", parent: 5, head: SIMD3(-0.9, 0, 0.6), tail: SIMD3(-1.2, 0, 0.6)),
        ]), eyeCenter: SIMD3(0, -0.5, 1.4), eyeDistance: 0.7, headScale: 1.7)
    }

    /// 正面を向いた顔（ピクセル座標・y 下向き）。目の間隔 100
    private func face(roll: Double = 0, noseShift: Double = 0) -> CatFaceRig {
        var lm = FaceLandmarks(
            leftEye: [Vec2(430, 300), Vec2(470, 300), Vec2(450, 296), Vec2(450, 304)],
            rightEye: [Vec2(530, 300), Vec2(570, 300), Vec2(550, 296), Vec2(550, 304)],
            nose: [Vec2(500 + noseShift, 330), Vec2(500 + noseShift, 365)],
            outerLips: [Vec2(470, 400), Vec2(530, 400)], innerLips: [Vec2(480, 400), Vec2(520, 400)])
        if roll != 0 {
            let c = Vec2(500, 300)
            let r = { (p: Vec2) -> Vec2 in
                let d = p - c
                return c + Vec2(d.x * cos(roll) - d.y * sin(roll), d.x * sin(roll) + d.y * cos(roll))
            }
            lm = FaceLandmarks(leftEye: lm.leftEye.map(r), rightEye: lm.rightEye.map(r), nose: lm.nose.map(r),
                               outerLips: lm.outerLips.map(r), innerLips: lm.innerLips.map(r))
        }
        return CatFaceRig(lm)!
    }

    func testPlacementPutsModelEyesOnFaceEyes() throws {
        let out = try XCTUnwrap(poser().pose(face: face(), body: nil))
        // モデルの目の中心 (0, 1.4) が画像の (500, 300) に来る
        let p = out.project(SIMD3(0, -0.5, 1.4))
        XCTAssertEqual(p.x, 500, accuracy: 1e-3)
        XCTAssertEqual(p.y, 300, accuracy: 1e-3)
        // 目の間隔 100px × headScale 1.7 / モデルの目の間隔 0.7
        XCTAssertEqual(out.scale, 100 * 1.7 / 0.7, accuracy: 1e-3)
    }

    func testHeadRollFollowsFace() throws {
        let p = poser()
        let out = try XCTUnwrap(p.pose(face: face(roll: 0.3), body: nil))
        let m = p.skeleton.skinMatrices(local: out.local)
        let head = p.skeleton.index(of: "Head")!
        // 画像 y 下向きで時計回りに 0.3 傾けると、モデルの頭のてっぺんは画像の右（+X）に倒れる
        let top = m[head] * SIMD4(0, 0, 1.8, 1)
        XCTAssertGreaterThan(top.x, 0.2)
    }

    func testHeadYawFollowsNose() throws {
        let p = poser()
        let out = try XCTUnwrap(p.pose(face: face(noseShift: 30), body: nil))
        let m = p.skeleton.skinMatrices(local: out.local)
        // 鼻が画像の右に寄ったら、顔の正面（-Y）も +X 側を向く
        let nose = m[p.skeleton.index(of: "Head")!] * SIMD4(0, -0.6, 1.3, 1)
        XCTAssertGreaterThan(nose.x, 0.1)
    }

    func testRotatedHeadStillPutsEyesOnFace() throws {
        let p = poser()
        let f = face(roll: 0.2, noseShift: 25)
        let out = try XCTUnwrap(p.pose(face: f, body: nil))
        let eye = try XCTUnwrap(p.debugJoints(pose: out, face: f, body: nil).first { $0.name == "目" })
        XCTAssertLessThan(try XCTUnwrap(eye.error), 0.5)
    }

    func testArmsFollowBodyJoints() throws {
        let p = poser()
        // 人の左腕（画像の右側）: 肩 (600,450) → 肘 (600,550) 真下 → 手首 (700,550) 右
        let body = BodyJoints(leftShoulder: Vec2(600, 450), leftElbow: Vec2(600, 550), leftWrist: Vec2(700, 550),
                              rightShoulder: Vec2(400, 450), rightElbow: nil, rightWrist: nil)
        let out = try XCTUnwrap(p.pose(face: face(), body: body))
        let m = p.skeleton.skinMatrices(local: out.local)
        func dir(_ name: String) -> SIMD3<Float> {
            let b = p.skeleton.bones[p.skeleton.index(of: name)!]
            let h = m[p.skeleton.index(of: name)!] * SIMD4(b.head, 1), t = m[p.skeleton.index(of: name)!] * SIMD4(b.tail, 1)
            return simd_normalize(SIMD3(t.x - h.x, t.y - h.y, t.z - h.z))
        }
        // 肘と手首は人の位置にそのまま重なる
        let joints = p.debugJoints(pose: out, face: face(), body: body)
        for name in ["左肘", "左手首"] {
            let j = try XCTUnwrap(joints.first { $0.name == name })
            XCTAssertLessThan(try XCTUnwrap(j.error), 0.5, name)
        }
        assertNear(dir("forearm.L"), SIMD3(1, 0, 0))
        // 取れていない腕は下ろした姿勢にする
        XCTAssertLessThan(dir("upper_arm.R").z, -0.5)
    }

    func testNoFaceGivesNil() {
        XCTAssertNil(poser().pose(face: nil, body: nil))
    }
}

final class AvatarIdleTests: XCTestCase {
    /// 根元と、真上に立つ 2 本の尻尾
    private let skeleton = AvatarSkeleton(bones: [
        AvatarBone(name: "spine", parent: -1, head: SIMD3(0, 0, 0), tail: SIMD3(0, 0, 1)),
        AvatarBone(name: "TailBase", parent: 0, head: SIMD3(0, 0.5, 0), tail: SIMD3(0, 0.5, 1)),
        AvatarBone(name: "TailBase.001", parent: 1, head: SIMD3(0, 0.5, 1), tail: SIMD3(0, 0.5, 2)),
    ])

    private func pose() -> AvatarPose {
        AvatarPose(local: skeleton.restPose, origin: SIMD2(100, 200), scale: 50, mouthOpen: 0)
    }

    private func tailTipX(_ p: AvatarPose) -> Float {
        (skeleton.skinMatrices(local: p.local)[2] * SIMD4(0, 0.5, 2, 1)).x
    }

    func testTailSwaysLeftAndRight() {
        let idle = AvatarIdle(skeleton: skeleton)
        let xs = stride(from: 0.0, to: 4.0, by: 0.1).map { tailTipX(idle.apply(pose(), time: $0)) }
        XCTAssertGreaterThan(xs.max()!, 0.05)
        XCTAssertLessThan(xs.min()!, -0.05)
        // 揺れは小さく（尻尾の長さ 2 に対して 0.6 以内）
        XCTAssertLessThan(xs.map(abs).max()!, 0.6)
    }

    func testBreathingBobsSlightly() {
        let idle = AvatarIdle(skeleton: skeleton)
        let ys = stride(from: 0.0, to: 4.0, by: 0.1).map { idle.apply(pose(), time: $0).origin.y }
        XCTAssertGreaterThan(ys.max()! - ys.min()!, 0.2)
        // 大きさの 2% 以内
        XCTAssertLessThan(ys.map { abs($0 - 200) }.max()!, 50 * 0.02 + 1e-3)
    }

    func testKeepsTrackedRotationsOfOtherBones() {
        let idle = AvatarIdle(skeleton: skeleton)
        var p = pose()
        p.local[0] = simd_quatf(angle: 0.3, axis: SIMD3(0, 0, 1))
        XCTAssertEqual(idle.apply(p, time: 1.3).local[0], p.local[0])
    }
}

final class AvatarReachTests: XCTestCase {
    private let bones = [
        AvatarBone(name: "spine", parent: -1, head: SIMD3(0, 0, 0), tail: SIMD3(0, 0, 0.8)),
        AvatarBone(name: "spine.003", parent: 0, head: SIMD3(0, 0, 0.4), tail: SIMD3(0, 0, 0.8)),
        AvatarBone(name: "Head", parent: 1, head: SIMD3(0, 0, 0.9), tail: SIMD3(0, 0, 1.8)),
        AvatarBone(name: "upper_arm.L", parent: 1, head: SIMD3(0.4, 0, 0.6), tail: SIMD3(0.9, 0, 0.6)),
        AvatarBone(name: "forearm.L", parent: 3, head: SIMD3(0.9, 0, 0.6), tail: SIMD3(1.3, 0, 0.6)),
        AvatarBone(name: "upper_arm.R", parent: 1, head: SIMD3(-0.4, 0, 0.6), tail: SIMD3(-0.9, 0, 0.6)),
        AvatarBone(name: "forearm.R", parent: 5, head: SIMD3(-0.9, 0, 0.6), tail: SIMD3(-1.3, 0, 0.6)),
    ]

    func testStretchLengthensBoneAndMovesChild() {
        let s = AvatarSkeleton(bones: bones)
        var stretch = [Float](repeating: 1, count: bones.count)
        stretch[3] = 2
        let m = s.skinMatrices(local: s.restPose, stretch: stretch)
        // 上腕の先（= 前腕の根元）が 0.5 → 1.0 離れる
        let elbow = m[4] * SIMD4(0.9, 0, 0.6, 1)
        XCTAssertEqual(elbow.x, 1.4, accuracy: 1e-5)
        // 上腕の太さ方向（Z）は伸びない
        let side = m[3] * SIMD4(0.4, 0, 0.7, 1)
        XCTAssertEqual(side.z, 0.7, accuracy: 1e-5)
    }

    private func poser() -> AvatarPoser {
        AvatarPoser(skeleton: AvatarSkeleton(bones: bones), eyeCenter: SIMD3(0, -0.5, 1.4), eyeDistance: 0.7, headScale: 0.7)
    }

    private func face() -> CatFaceRig {
        CatFaceRig(FaceLandmarks(
            leftEye: [Vec2(430, 300), Vec2(470, 300), Vec2(450, 296), Vec2(450, 304)],
            rightEye: [Vec2(530, 300), Vec2(570, 300), Vec2(550, 296), Vec2(550, 304)],
            nose: [Vec2(500, 330), Vec2(500, 365)],
            outerLips: [Vec2(470, 400), Vec2(530, 400)], innerLips: [Vec2(480, 400), Vec2(520, 400)]))!
    }

    /// 前腕の先（手首）が画像のどこに来たか
    private func wristOnImage(_ p: AvatarPoser, _ out: AvatarPose, side: String = "L") -> SIMD2<Float> {
        let i = p.skeleton.index(of: "forearm.\(side)")!
        let w = p.skeleton.skinMatrices(local: out.local, stretch: out.stretch)[i] * SIMD4(p.skeleton.bones[i].tail, 1)
        return out.project(SIMD3(w.x, w.y, w.z))
    }

    func testHandWithinReachPutsWristOnHand() throws {
        let p = poser()
        // scale = 100 * 0.7 / 0.7 = 100px。肩 (0.4, 0.6) は画像の (540, 380) あたり。腕の長さは 0.9 = 90px
        let target = Vec2(560, 330)
        let out = try XCTUnwrap(p.pose(face: face(), body: BodyJoints(leftShoulder: nil, leftElbow: nil, leftWrist: target,
                                                                        rightShoulder: nil, rightElbow: nil, rightWrist: nil)))
        let w = wristOnImage(p, out)
        XCTAssertEqual(w.x, 560, accuracy: 0.5)
        XCTAssertEqual(w.y, 330, accuracy: 0.5)
        XCTAssertEqual(out.stretch[3], 1)
    }

    func testFarHandStretchesArmToReach() throws {
        let p = poser()
        let target = Vec2(800, 380)
        let out = try XCTUnwrap(p.pose(face: face(), body: BodyJoints(leftShoulder: nil, leftElbow: nil, leftWrist: target,
                                                                        rightShoulder: nil, rightElbow: nil, rightWrist: nil)))
        let w = wristOnImage(p, out)
        XCTAssertEqual(w.x, 800, accuracy: 0.5)
        XCTAssertEqual(w.y, 380, accuracy: 0.5)
        XCTAssertGreaterThan(out.stretch[3], 1)
    }

    func testElbowBendsDownward() throws {
        let p = poser()
        let out = try XCTUnwrap(p.pose(face: face(), body: BodyJoints(leftShoulder: nil, leftElbow: nil, leftWrist: Vec2(560, 330),
                                                                        rightShoulder: nil, rightElbow: nil, rightWrist: nil)))
        let i = p.skeleton.index(of: "upper_arm.L")!
        let e = p.skeleton.skinMatrices(local: out.local, stretch: out.stretch)[i] * SIMD4(p.skeleton.bones[i].tail, 1)
        let elbow = out.project(SIMD3(e.x, e.y, e.z))
        // 肩と手を結ぶ線より下（画像 y が大きい）に肘がある
        let shoulder = out.project(SIMD3(0.4, 0, 0.6))
        let t = (elbow.x - shoulder.x) / (560 - shoulder.x)
        XCTAssertGreaterThan(elbow.y, shoulder.y + (330 - shoulder.y) * t)
    }
}

final class AvatarFingerTests: XCTestCase {
    /// 腕 2 本 + 手 + 人差し指 3 節 + 親指 3 節（左手だけ）
    private func skeleton() -> AvatarSkeleton {
        var b = [
            AvatarBone(name: "spine", parent: -1, head: SIMD3(0, 0, 0), tail: SIMD3(0, 0, 0.8)),
            AvatarBone(name: "Head", parent: 0, head: SIMD3(0, 0, 0.9), tail: SIMD3(0, 0, 1.8)),
            AvatarBone(name: "upper_arm.L", parent: 0, head: SIMD3(0.4, 0, 0.6), tail: SIMD3(0.9, 0, 0.6)),
            AvatarBone(name: "forearm.L", parent: 2, head: SIMD3(0.9, 0, 0.6), tail: SIMD3(1.3, 0, 0.6)),
            AvatarBone(name: "hand.L", parent: 3, head: SIMD3(1.3, 0, 0.6), tail: SIMD3(1.5, 0, 0.6)),
        ]
        var parent = 4
        for k in 1...3 {
            let x = 1.6 + Float(k - 1) * 0.1
            b.append(AvatarBone(name: "index.\(k).L", parent: parent, head: SIMD3(x, 0, 0.65), tail: SIMD3(x + 0.1, 0, 0.65)))
            parent = b.count - 1
        }
        parent = 4
        for k in 1...3 {
            let z = 0.65 + Float(k - 1) * 0.08
            b.append(AvatarBone(name: "thumb.\(k).L", parent: parent, head: SIMD3(1.4, 0, z), tail: SIMD3(1.45, 0, z + 0.08)))
            parent = b.count - 1
        }
        return AvatarSkeleton(bones: b)
    }

    private func face() -> CatFaceRig {
        CatFaceRig(FaceLandmarks(
            leftEye: [Vec2(430, 300), Vec2(470, 300), Vec2(450, 296), Vec2(450, 304)],
            rightEye: [Vec2(530, 300), Vec2(570, 300), Vec2(550, 296), Vec2(550, 304)],
            nose: [Vec2(500, 330), Vec2(500, 365)],
            outerLips: [Vec2(470, 400), Vec2(530, 400)], innerLips: [Vec2(480, 400), Vec2(520, 400)]))!
    }

    private func direction(_ s: AvatarSkeleton, _ out: AvatarPose, _ name: String) -> SIMD3<Float> {
        let i = s.index(of: name)!
        let m = s.skinMatrices(local: out.local, stretch: out.stretch)[i]
        let h = m * SIMD4(s.bones[i].head, 1), t = m * SIMD4(s.bones[i].tail, 1)
        return simd_normalize(SIMD3(t.x - h.x, t.y - h.y, t.z - h.z))
    }

    func testFingerBonesFollowHandPoints() throws {
        let s = skeleton()
        let p = AvatarPoser(skeleton: s, eyeCenter: SIMD3(0, -0.5, 1.4), eyeDistance: 0.7, headScale: 0.7)
        // 手首 (600,400)。中指の付け根は真上 → 手の骨は上向き。人差し指は付け根から右へ、2 節目から下へ曲がる
        var hand = [Vec2?](repeating: nil, count: HandJoint.count)
        hand[HandJoint.wrist] = Vec2(600, 400)
        hand[HandJoint.middle] = Vec2(600, 350)
        hand[HandJoint.index] = Vec2(590, 350)
        hand[HandJoint.index + 1] = Vec2(610, 350)
        hand[HandJoint.index + 2] = Vec2(610, 370)
        hand[HandJoint.index + 3] = Vec2(610, 390)
        // 親指は 1 節目だけ取れていて、左上へ
        hand[HandJoint.thumb] = Vec2(590, 380)
        hand[HandJoint.thumb + 1] = Vec2(580, 370)
        var body = BodyJoints(leftShoulder: nil, leftElbow: nil, leftWrist: Vec2(600, 400),
                              rightShoulder: nil, rightElbow: nil, rightWrist: nil)
        body.leftHand = hand
        let out = try XCTUnwrap(p.pose(face: face(), body: body))
        XCTAssertLessThan(simd_length(direction(s, out, "hand.L") - SIMD3(0, 0, 1)), 1e-3)
        XCTAssertLessThan(simd_length(direction(s, out, "index.1.L") - SIMD3(1, 0, 0)), 1e-3)
        XCTAssertLessThan(simd_length(direction(s, out, "index.2.L") - SIMD3(0, 0, -1)), 1e-3)
        XCTAssertLessThan(simd_length(direction(s, out, "index.3.L") - SIMD3(0, 0, -1)), 1e-3)
        XCTAssertLessThan(simd_length(direction(s, out, "thumb.1.L") - simd_normalize(SIMD3(-1, 0, 1))), 1e-3)
        // 取れていない親指の 2 節目は 1 節目と同じ向きのまま（休止姿勢のまっすぐ）
        XCTAssertLessThan(simd_length(direction(s, out, "thumb.2.L") - direction(s, out, "thumb.1.L")), 1e-3)
    }

    func testElbowFollowsHandDirection() throws {
        let s = skeleton()
        let p = AvatarPoser(skeleton: s, eyeCenter: SIMD3(0, -0.5, 1.4), eyeDistance: 0.7, headScale: 0.7)
        // 手を真上に向けて、肩の右上に掲げる。前腕は真上を向き、手首は手の位置に来る
        var hand = [Vec2?](repeating: nil, count: HandJoint.count)
        hand[HandJoint.wrist] = Vec2(640, 300)
        hand[HandJoint.middle] = Vec2(640, 260)
        var body = BodyJoints(leftShoulder: nil, leftElbow: nil, leftWrist: Vec2(640, 300),
                              rightShoulder: nil, rightElbow: nil, rightWrist: nil)
        body.leftHand = hand
        let out = try XCTUnwrap(p.pose(face: face(), body: body))
        XCTAssertLessThan(simd_length(direction(s, out, "forearm.L") - SIMD3(0, 0, 1)), 1e-3)
        let i = s.index(of: "forearm.L")!
        let w = s.skinMatrices(local: out.local, stretch: out.stretch)[i] * SIMD4(s.bones[i].tail, 1)
        let wrist = out.project(SIMD3(w.x, w.y, w.z))
        XCTAssertEqual(wrist.x, 640, accuracy: 0.5)
        XCTAssertEqual(wrist.y, 300, accuracy: 0.5)
    }

    func testFingerSegmentsTakeHumanLengths() throws {
        let s = skeleton()
        let p = AvatarPoser(skeleton: s, eyeCenter: SIMD3(0, -0.5, 1.4), eyeDistance: 0.7, headScale: 0.7)
        // scale = 100px / モデル 1。人差し指の各節は人で 30px（モデルでは 0.1 = 10px）なので 3 倍に伸ばす
        var hand = [Vec2?](repeating: nil, count: HandJoint.count)
        hand[HandJoint.wrist] = Vec2(600, 400)
        hand[HandJoint.middle] = Vec2(600, 340)
        for k in 0...3 { hand[HandJoint.index + k] = Vec2(600, 340 - Double(k) * 30) }
        var body = BodyJoints(leftShoulder: nil, leftElbow: nil, leftWrist: Vec2(600, 400),
                              rightShoulder: nil, rightElbow: nil, rightWrist: nil)
        body.leftHand = hand
        let out = try XCTUnwrap(p.pose(face: face(), body: body))
        for k in 1...3 {
            XCTAssertEqual(out.stretch[s.index(of: "index.\(k).L")!], 3, accuracy: 1e-3)
        }
        // 手の骨は、手首 → 中指の付け根（人 60px）に合わせる。モデルの手首 → 指の付け根は 0.3 くらい
        XCTAssertGreaterThan(out.stretch[s.index(of: "hand.L")!], 1.5)
    }

    func testFingerBaseMovesToDetectedKnuckle() throws {
        let s = skeleton()
        let p = AvatarPoser(skeleton: s, eyeCenter: SIMD3(0, -0.5, 1.4), eyeDistance: 0.7, headScale: 0.7)
        // 人差し指の付け根を、中指の付け根から大きく横にずらす。指先までの 4 点がすべて人の位置に重なる
        var hand = [Vec2?](repeating: nil, count: HandJoint.count)
        hand[HandJoint.wrist] = Vec2(600, 400)
        hand[HandJoint.middle] = Vec2(600, 340)
        for k in 0...3 { hand[HandJoint.index + k] = Vec2(560 - Double(k) * 10, 345 - Double(k) * 25) }
        var body = BodyJoints(leftShoulder: nil, leftElbow: nil, leftWrist: Vec2(600, 400),
                              rightShoulder: nil, rightElbow: nil, rightWrist: nil)
        body.leftHand = hand
        let out = try XCTUnwrap(p.pose(face: face(), body: body))
        let m = s.skinMatrices(local: out.local, stretch: out.stretch, offsets: out.offsets)
        for k in 1...3 {
            let i = s.index(of: "index.\(k).L")!
            let h = m[i] * SIMD4(s.bones[i].head, 1), t = m[i] * SIMD4(s.bones[i].tail, 1)
            let hp = out.project(SIMD3(h.x, h.y, h.z)), tp = out.project(SIMD3(t.x, t.y, t.z))
            XCTAssertLessThan(simd_length(hp - SIMD2(Float(hand[HandJoint.index + k - 1]!.x), Float(hand[HandJoint.index + k - 1]!.y))), 0.5)
            XCTAssertLessThan(simd_length(tp - SIMD2(Float(hand[HandJoint.index + k]!.x), Float(hand[HandJoint.index + k]!.y))), 0.5)
        }
    }

    func testDetectedHandComesInFrontOfFace() throws {
        let s = skeleton()
        let p = AvatarPoser(skeleton: s, eyeCenter: SIMD3(0, -0.5, 1.4), eyeDistance: 0.7, headScale: 0.7)
        var hand = [Vec2?](repeating: nil, count: HandJoint.count)
        hand[HandJoint.wrist] = Vec2(500, 330)
        hand[HandJoint.middle] = Vec2(500, 280)
        var body = BodyJoints(leftShoulder: nil, leftElbow: nil, leftWrist: Vec2(500, 330),
                              rightShoulder: nil, rightElbow: nil, rightWrist: nil)
        body.leftHand = hand
        let out = try XCTUnwrap(p.pose(face: face(), body: body))
        let heads = s.posedHeads(local: out.local, stretch: out.stretch, offsets: out.offsets)
        // 顔の一番手前（鼻先 -0.8 くらい）より手前（Y がより小さい）に手が来る
        XCTAssertLessThan(heads[s.index(of: "hand.L")!].y, -1.0)
        XCTAssertLessThan(heads[s.index(of: "index.1.L")!].y, -1.0)
        // 取れていない右腕は動かさない（右腕の骨はこの骨組みにないので左だけ確認）
    }

    func testScaledScalesHandPoints() {
        var b = BodyJoints(leftShoulder: nil, leftElbow: nil, leftWrist: nil, rightShoulder: nil, rightElbow: nil, rightWrist: nil)
        var h = [Vec2?](repeating: nil, count: HandJoint.count)
        h[0] = Vec2(0.5, 0.5)
        b.rightHand = h
        XCTAssertEqual(b.scaled(width: 100, height: 10).rightHand?[0], Vec2(50, 5))
    }
}

final class HandHoldTests: XCTestCase {
    /// 目の中点 (500,300)、目の間隔 100 の顔
    private func face() -> CatFaceRig {
        CatFaceRig(FaceLandmarks(
            leftEye: [Vec2(430, 300), Vec2(470, 300), Vec2(450, 296), Vec2(450, 304)],
            rightEye: [Vec2(530, 300), Vec2(570, 300), Vec2(550, 296), Vec2(550, 304)],
            nose: [Vec2(500, 330), Vec2(500, 365)],
            outerLips: [Vec2(470, 400), Vec2(530, 400)], innerLips: [Vec2(480, 400), Vec2(520, 400)]))!
    }

    private func joints(leftWrist: Vec2?) -> BodyJoints {
        BodyJoints(leftShoulder: nil, leftElbow: nil, leftWrist: leftWrist, rightShoulder: nil, rightElbow: nil, rightWrist: nil)
    }

    /// 手の検出で取れた手（指の点つき）
    private func visible(_ w: Vec2) -> BodyJoints {
        var j = joints(leftWrist: w)
        j.leftHand = [Vec2?](repeating: w, count: HandJoint.count)
        return j
    }

    func testVisibleHandIsInFront() {
        var h = HandHold()
        let out = h.update(visible(Vec2(520, 200)), face: face(), now: 0)
        XCTAssertEqual(out.leftWrist, Vec2(520, 200))
        XCTAssertFalse(out.leftBehindHead)
    }

    func testHandLostOverHeadStaysBehindHead() {
        var h = HandHold()
        _ = h.update(visible(Vec2(520, 200)), face: face(), now: 0)
        // 頭の上で見えなくなったら、2 秒たっても最後の位置のまま頭の後ろにいる
        let out = h.update(joints(leftWrist: nil), face: face(), now: 2)
        XCTAssertEqual(out.leftWrist, Vec2(520, 200))
        XCTAssertTrue(out.leftBehindHead)
        // また見えたら手前に戻る
        let back = h.update(visible(Vec2(530, 210)), face: face(), now: 2.1)
        XCTAssertFalse(back.leftBehindHead)
    }

    func testHandLostAwayFromHeadDropsAfterShortHold() {
        var h = HandHold()
        _ = h.update(joints(leftWrist: Vec2(900, 600)), face: face(), now: 0)
        XCTAssertEqual(h.update(joints(leftWrist: nil), face: face(), now: 0.3).leftWrist, Vec2(900, 600))
        XCTAssertNil(h.update(joints(leftWrist: nil), face: face(), now: 0.5).leftWrist)
    }

    func testBodyOnlyWristNearHeadStaysBehind() {
        var h = HandHold()
        var visible = joints(leftWrist: Vec2(520, 200))
        visible.leftHand = [Vec2?](repeating: Vec2(520, 190), count: HandJoint.count)
        _ = h.update(visible, face: face(), now: 0)
        // 手は見えず、体の関節検出だけが頭の後ろあたりの手首を推測で返す → 奥のまま、位置はその推測に合わせる
        let out = h.update(joints(leftWrist: Vec2(540, 230)), face: face(), now: 0.5)
        XCTAssertTrue(out.leftBehindHead)
        XCTAssertEqual(out.leftWrist, Vec2(540, 230))
    }

    func testBodyOnlyWristAwayFromHeadIsInFront() {
        var h = HandHold()
        let out = h.update(joints(leftWrist: Vec2(900, 600)), face: face(), now: 0)
        XCTAssertFalse(out.leftBehindHead)
        XCTAssertEqual(out.leftWrist, Vec2(900, 600))
    }

    func testBehindHeadGivesUpEventually() {
        var h = HandHold()
        _ = h.update(visible(Vec2(520, 200)), face: face(), now: 0)
        XCTAssertNil(h.update(joints(leftWrist: nil), face: face(), now: 10).leftWrist)
    }

    func testPoserPutsBehindHandBehindHead() throws {
        let s = AvatarSkeleton(bones: [
            AvatarBone(name: "spine", parent: -1, head: SIMD3(0, 0, 0), tail: SIMD3(0, 0, 0.8)),
            AvatarBone(name: "Head", parent: 0, head: SIMD3(0, 0, 0.9), tail: SIMD3(0, 0, 1.8)),
            AvatarBone(name: "upper_arm.L", parent: 0, head: SIMD3(0.4, 0, 0.6), tail: SIMD3(0.9, 0, 0.6)),
            AvatarBone(name: "forearm.L", parent: 2, head: SIMD3(0.9, 0, 0.6), tail: SIMD3(1.3, 0, 0.6)),
            AvatarBone(name: "hand.L", parent: 3, head: SIMD3(1.3, 0, 0.6), tail: SIMD3(1.5, 0, 0.6)),
        ])
        let p = AvatarPoser(skeleton: s, eyeCenter: SIMD3(0, -0.5, 1.4), eyeDistance: 0.7, headScale: 0.7)
        var body = joints(leftWrist: Vec2(520, 200))
        body.leftBehindHead = true
        let out = try XCTUnwrap(p.pose(face: face(), body: body))
        let heads = s.posedHeads(local: out.local, stretch: out.stretch, offsets: out.offsets)
        // 頭の一番奥（後頭部 +0.65 くらい）より奥に手が来る
        XCTAssertGreaterThan(heads[s.index(of: "hand.L")!].y, 1.0)
    }
}
