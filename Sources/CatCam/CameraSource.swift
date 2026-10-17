import AVFoundation
import CatCore

final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate {
    enum Failure: Error {
        case noCamera
        case cannotAddInput
    }

    let deviceName: String
    /// システムの顔検出結果を受け取れるか。受け取れるなら自前の Vision 顔検出は不要
    private(set) var providesFaces = false
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let onFrame: (CVPixelBuffer) -> Void
    private let onFaces: ([Rect]) -> Void

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified
        ).devices
    }

    /// `onFrame` と `onFaces` は `queue` 上で呼ばれる。顔の矩形は左上原点の正規化座標
    init(nameHint: String?, queue: DispatchQueue,
         onFrame: @escaping (CVPixelBuffer) -> Void, onFaces: @escaping ([Rect]) -> Void) throws {
        let devices = Self.availableDevices()
        let hinted = nameHint.flatMap { h in devices.first { $0.localizedName.localizedCaseInsensitiveContains(h) } }
        guard let device = hinted ?? devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first else {
            throw Failure.noCamera
        }
        deviceName = device.localizedName
        self.onFrame = onFrame
        self.onFaces = onFaces
        super.init()

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Failure.cannotAddInput }
        session.addInput(input)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)

        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            if metadataOutput.availableMetadataObjectTypes.contains(.face) {
                metadataOutput.metadataObjectTypes = [.face]
                metadataOutput.setMetadataObjectsDelegate(self, queue: queue)
                providesFaces = true
            }
        }
        session.commitConfiguration()
    }

    /// 起動はブロッキングなのでメインスレッド以外から呼ぶ
    func start() {
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(pb)
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        onFaces(metadataObjects.compactMap { o in
            guard o.type == .face else { return nil }
            let b = o.bounds
            return Rect(x: b.minX, y: b.minY, w: b.width, h: b.height)
        })
    }
}
