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
        assertNear(dir("upper_arm.L"), SIMD3(0, 0, -1))
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
