import XCTest
@testable import CatCore

final class CatFaceRigTests: XCTestCase {
    /// 正面を向いた顔（ピクセル座標・y 下向き）。目の間隔 100、目は幅 40・高さ `eyeH`
    private func landmarks(eyeH: Double = 14, lipsGap: Double = 0, rotate angle: Double = 0) -> FaceLandmarks {
        func eye(_ cx: Double) -> [Vec2] {
            [Vec2(cx - 20, 300), Vec2(cx, 300 - eyeH / 2), Vec2(cx + 20, 300), Vec2(cx, 300 + eyeH / 2)]
        }
        var lm = FaceLandmarks(
            leftEye: eye(450), rightEye: eye(550),
            nose: [Vec2(500, 320), Vec2(490, 360), Vec2(500, 370), Vec2(510, 360)],
            outerLips: [Vec2(470, 410), Vec2(500, 400), Vec2(530, 410), Vec2(500, 420 + lipsGap)],
            innerLips: [Vec2(475, 410), Vec2(500, 408), Vec2(525, 410), Vec2(500, 412 + lipsGap)]
        )
        if angle != 0 {
            let c = Vec2(500, 300)
            func rot(_ p: Vec2) -> Vec2 {
                let d = p - c
                return c + Vec2(d.x * cos(angle) - d.y * sin(angle), d.x * sin(angle) + d.y * cos(angle))
            }
            lm = FaceLandmarks(leftEye: lm.leftEye.map(rot), rightEye: lm.rightEye.map(rot), nose: lm.nose.map(rot),
                               outerLips: lm.outerLips.map(rot), innerLips: lm.innerLips.map(rot))
        }
        return lm
    }

    func testUprightFaceGeometry() throws {
        let rig = try XCTUnwrap(CatFaceRig(landmarks()))
        XCTAssertEqual(rig.eyeDistance, 100, accuracy: 1e-9)
        XCTAssertEqual(rig.axis.x, 1, accuracy: 1e-9)
        // 画像は y 下向きなので、頭の上方向は -y
        XCTAssertEqual(rig.up.y, -1, accuracy: 1e-9)
        XCTAssertEqual(rig.leftEye.center.x, 450, accuracy: 1e-9)
        XCTAssertEqual(rig.leftEye.width, 40, accuracy: 1e-9)
        // 鼻先は鼻の点のうち一番下
        XCTAssertEqual(rig.nose.y, 370, accuracy: 1e-9)
        XCTAssertEqual(rig.mouth.y, 410, accuracy: 1e-9)
        XCTAssertEqual(rig.mouthWidth, 60, accuracy: 1e-9)
    }

    func testEarsSitAboveEyesSymmetrically() throws {
        let rig = try XCTUnwrap(CatFaceRig(landmarks()))
        for ear in [rig.leftEar, rig.rightEar] {
            XCTAssertLessThan(ear.tip.y, 300 - 100)  // 目より目の間隔ぶん以上上
            XCTAssertLessThan(ear.tip.y, ear.inner.y)
            XCTAssertLessThan(ear.tip.y, ear.outer.y)
        }
        XCTAssertEqual(rig.leftEar.tip.x - 500, -(rig.rightEar.tip.x - 500), accuracy: 1e-9)
        XCTAssertEqual(rig.leftEar.tip.y, rig.rightEar.tip.y, accuracy: 1e-9)
        // 外側の付け根は内側より外にある
        XCTAssertLessThan(rig.leftEar.outer.x, rig.leftEar.inner.x)
        XCTAssertGreaterThan(rig.rightEar.outer.x, rig.rightEar.inner.x)
    }

    func testRolledFaceRotatesEars() throws {
        // 顔を 90° 傾けると（y 下向きで時計回り）、耳は +x 側に出る
        let rig = try XCTUnwrap(CatFaceRig(landmarks(rotate: .pi / 2)))
        XCTAssertEqual(rig.up.x, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(rig.leftEar.tip.x, 500 + 100)
        XCTAssertGreaterThan(rig.rightEar.tip.x, 500 + 100)
    }

    func testEyeOpennessFollowsEyeHeight() throws {
        let open = try XCTUnwrap(CatFaceRig(landmarks(eyeH: 14)))
        let closed = try XCTUnwrap(CatFaceRig(landmarks(eyeH: 2)))
        XCTAssertGreaterThan(open.leftEye.openness, 0.9)
        XCTAssertLessThan(closed.leftEye.openness, 0.1)
    }

    func testMouthOpennessFollowsInnerLips() throws {
        let shut = try XCTUnwrap(CatFaceRig(landmarks(lipsGap: 0)))
        let open = try XCTUnwrap(CatFaceRig(landmarks(lipsGap: 20)))
        XCTAssertLessThan(shut.mouthOpen, 0.1)
        XCTAssertGreaterThan(open.mouthOpen, 0.5)
    }

    func testEyesAreOrderedByImageXEvenIfSwapped() throws {
        var lm = landmarks()
        swap(&lm.leftEye, &lm.rightEye)
        let rig = try XCTUnwrap(CatFaceRig(lm))
        XCTAssertEqual(rig.axis.x, 1, accuracy: 1e-9)
        XCTAssertLessThan(rig.leftEye.center.x, rig.rightEye.center.x)
    }

    func testMissingEyesGiveNil() {
        var lm = landmarks()
        lm.leftEye = []
        XCTAssertNil(CatFaceRig(lm))
    }

    func testLerpMovesHalfway() throws {
        let a = try XCTUnwrap(CatFaceRig(landmarks()))
        var shifted = landmarks()
        shifted = FaceLandmarks(leftEye: shifted.leftEye.map { $0 + Vec2(10, 0) }, rightEye: shifted.rightEye.map { $0 + Vec2(10, 0) },
                                nose: shifted.nose.map { $0 + Vec2(10, 0) }, outerLips: shifted.outerLips.map { $0 + Vec2(10, 0) },
                                innerLips: shifted.innerLips.map { $0 + Vec2(10, 0) })
        let b = try XCTUnwrap(CatFaceRig(shifted))
        let m = a.lerp(to: b, t: 0.5)
        XCTAssertEqual(m.leftEye.center.x, 455, accuracy: 1e-9)
        XCTAssertEqual(m.leftEar.tip.x, a.leftEar.tip.x + 5, accuracy: 1e-9)
    }

    func testLandmarksScaleToPixels() {
        let lm = FaceLandmarks(leftEye: [Vec2(0.5, 0.25)], rightEye: [], nose: [], outerLips: [], innerLips: [])
        XCTAssertEqual(lm.scaled(width: 1280, height: 720).leftEye[0], Vec2(640, 180))
    }
}
