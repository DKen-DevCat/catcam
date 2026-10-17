import AVFoundation
import CatCore
import Foundation
import Metal
import Vision

// M0: ツールチェーンと実行環境の確認用。M1 でアプリ本体に置き換える
if CommandLine.arguments.contains("--doctor") {
    print("catcam \(CatCore.version)")
    print("metal:", MTLCreateSystemDefaultDevice()?.name ?? "unavailable")
    print("vision animal pose joints:", VNDetectAnimalBodyPoseRequest().revision)
    let cams = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
        mediaType: .video, position: .unspecified
    ).devices
    print("cameras:", cams.map(\.localizedName))
    print("camera auth before:", AVCaptureDevice.authorizationStatus(for: .video).rawValue)
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { granted in
        print("camera granted:", granted)
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 60)
}
