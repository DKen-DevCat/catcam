import AVFoundation
import CatCore
import Metal
import Vision

/// 実行環境の確認（`CatCam --doctor`）
enum Doctor {
    static func run() {
        print("catcam \(CatCore.version)")
        print("metal:", MTLCreateSystemDefaultDevice()?.name ?? "unavailable")
        print("vision animal pose revision:", VNDetectAnimalBodyPoseRequest().revision)
        print("cameras:", CameraSource.availableDevices().map(\.localizedName))
        print("video effects:", videoEffectsSummary())
        print("camera auth before:", AVCaptureDevice.authorizationStatus(for: .video).rawValue)
        let sem = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .video) { granted in
            print("camera granted:", granted)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 60)
    }

    /// コントロールセンターのビデオエフェクトの状態。どれかが有効だとプロセス内で重い検出が走る
    static func videoEffectsSummary() -> String {
        [
            "reactions=\(AVCaptureDevice.reactionEffectsEnabled)",
            "gestures=\(AVCaptureDevice.reactionEffectGesturesEnabled)",
            "portrait=\(AVCaptureDevice.isPortraitEffectEnabled)",
            "studioLight=\(AVCaptureDevice.isStudioLightEnabled)",
            "centerStage=\(AVCaptureDevice.isCenterStageEnabled)",
            // 背景エフェクトは macOS 15 の API で SDK(14.4) に無いので、実行時に問い合わせる
            "background=\(classFlag("backgroundReplacementEnabled").map(String.init) ?? "n/a")",
        ].joined(separator: " ")
    }

    /// AVCaptureDevice のクラスプロパティ（Bool）を名前で読む。無ければ nil
    private static func classFlag(_ key: String) -> Bool? {
        let cls: AnyObject = AVCaptureDevice.self
        let getter = "is" + key.prefix(1).uppercased() + key.dropFirst()
        guard cls.responds(to: NSSelectorFromString(getter)) else { return nil }
        return cls.value(forKey: key) as? Bool
    }
}
