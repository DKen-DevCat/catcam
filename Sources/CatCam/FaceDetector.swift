import CatCore
import CoreVideo
import Metal
import MetalPerformanceShaders
import QuartzCore
import Vision

/// Vision の顔ランドマーク検出を専用キューで間引きながら回す。処理中に来たフレームは捨てる。
/// Vision の CPU コストの大半は入力の前処理なので、GPU で縮小してから渡す
final class FaceDetector {
    // 猫の顔パーツを顔に追従させるため 15Hz（10Hz だと動いた時に遅れが見える）
    var minInterval: CFTimeInterval = 1.0 / 15
    private let queue = DispatchQueue(label: "catcam.face", qos: .userInitiated)
    // 毎回作るとリビジョン解決などの初期化コストが乗るので使い回す（queue 上でのみ触る）
    private let request = VNDetectFaceLandmarksRequest()
    // アバターの前足を動かすための手。体全体の関節はカメラに近いと取れないので、手だけを顔と同じ縮小画像で一緒に探す
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    var handsEnabled = false
    // 肘と肩は体全体の関節検出から取る。カメラに近いと取れないことが多いが、取れた時は推定より優先する
    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private let sequenceHandler = VNSequenceRequestHandler()
    private let scaler: GPUScaler?
    private let lock = NSLock()
    private var busy = false
    private var lastSubmit: CFTimeInterval = 0
    private var faces: [Face] = []
    private var hands: BodyJoints?
    private var resultTime: CFTimeInterval = 0
    private let onDuration: (Double) -> Void

    /// 手の検出状況の要約（診断ログ用）
    var onJoints: ((String) -> Void)?

    init(device: MTLDevice?, onDuration: @escaping (Double) -> Void) {
        scaler = device.flatMap { GPUScaler(device: $0, width: 480, height: 270) }
        self.onDuration = onDuration
    }

    func submitIfIdle(_ pb: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        lock.lock()
        guard !busy, now - lastSubmit >= minInterval else {
            lock.unlock()
            return
        }
        busy = true
        lastSubmit = now
        lock.unlock()

        queue.async { [self] in
            let t0 = CACurrentMediaTime()
            let input = scaler?.scale(pb) ?? pb
            let withHands = handsEnabled
            try? sequenceHandler.perform(withHands ? [request, handRequest, bodyRequest] : [request], on: input, orientation: .up)
            let found = (request.results ?? []).map(Self.face)
            var joints = withHands ? Self.hands(handRequest.results ?? [], faceX: found.first.map { $0.rect.x + $0.rect.w / 2 }) : nil
            if withHands, let body = bodyRequest.results?.first {
                Self.merge(body, into: &joints)
            }
            if withHands { onJoints?(Self.summary(handRequest.results ?? []) + " " + Self.summary(bodyRequest.results?.first)) }
            let t1 = CACurrentMediaTime()
            lock.lock()
            faces = found
            hands = joints
            resultTime = t1
            busy = false
            lock.unlock()
            onDuration((t1 - t0) * 1000)
        }
    }

    /// `maxAge` 秒より古い結果は捨てる
    func latest(maxAge: CFTimeInterval) -> [Face] {
        lock.lock()
        defer { lock.unlock() }
        return CACurrentMediaTime() - resultTime <= maxAge ? faces : []
    }

    /// 手首の位置だけを入れた関節（`maxAge` 秒より古い結果は捨てる）
    func latestHands(maxAge: CFTimeInterval) -> BodyJoints? {
        lock.lock()
        defer { lock.unlock() }
        return CACurrentMediaTime() - resultTime <= maxAge ? hands : nil
    }

    /// 体全体の関節から肩と肘を足す。手首は手の検出で取れなかった時だけ使う
    private static func merge(_ o: VNHumanBodyPoseObservation, into j: inout BodyJoints?) {
        func p(_ name: VNHumanBodyPoseObservation.JointName) -> Vec2? {
            guard let r = try? o.recognizedPoint(name), r.confidence > 0.2 else { return nil }
            return Vec2(Double(r.location.x), Double(1 - r.location.y))
        }
        var b = j ?? BodyJoints(leftShoulder: nil, leftElbow: nil, leftWrist: nil, rightShoulder: nil, rightElbow: nil, rightWrist: nil)
        b.leftShoulder = p(.leftShoulder)
        b.rightShoulder = p(.rightShoulder)
        b.leftElbow = p(.leftElbow)
        b.rightElbow = p(.rightElbow)
        b.leftWrist = b.leftWrist ?? p(.leftWrist)
        b.rightWrist = b.rightWrist ?? p(.rightWrist)
        j = b
    }

    /// 例: "体 肘L0.42 肘R--"
    private static func summary(_ o: VNHumanBodyPoseObservation?) -> String {
        guard let o else { return "体0" }
        func c(_ n: VNHumanBodyPoseObservation.JointName) -> String {
            guard let r = try? o.recognizedPoint(n), r.confidence > 0 else { return "--" }
            return String(format: "%.2f", r.confidence)
        }
        return "体 肘L\(c(.leftElbow)) 肘R\(c(.rightElbow))"
    }

    /// `HandJoint` の並び
    private static let handJointNames: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    /// 例: "手2 L0.92 R0.88"（L/R は本人から見た左右、数字は手首の信頼度）
    private static func summary(_ obs: [VNHumanHandPoseObservation]) -> String {
        "手\(obs.count)" + obs.map { o in
            let side = o.chirality == .left ? "L" : o.chirality == .right ? "R" : "?"
            return String(format: " %@%.2f", side, (try? o.recognizedPoint(.wrist).confidence).map(Double.init) ?? 0)
        }.joined()
    }

    /// 手首を本人から見た左右に振り分ける。左右が分からない手は、顔より画像の右にあれば左手とみなす
    /// （左右反転前の画像では本人の左が右側に写る）。正規化座標・左上原点
    private static func hands(_ obs: [VNHumanHandPoseObservation], faceX: Double?) -> BodyJoints {
        var j = BodyJoints(leftShoulder: nil, leftElbow: nil, leftWrist: nil, rightShoulder: nil, rightElbow: nil, rightWrist: nil)
        for o in obs {
            guard let r = try? o.recognizedPoint(.wrist), r.confidence > 0.3 else { continue }
            let p = Vec2(Double(r.location.x), Double(1 - r.location.y))
            let points: [Vec2?] = handJointNames.map { name in
                guard let q = try? o.recognizedPoint(name), q.confidence > 0.3 else { return nil }
                return Vec2(Double(q.location.x), Double(1 - q.location.y))
            }
            let isLeft: Bool
            switch o.chirality {
            case .left: isLeft = true
            case .right: isLeft = false
            default: isLeft = p.x > (faceX ?? 0.5)
            }
            if isLeft {
                j.leftWrist = p
                j.leftHand = points
            } else {
                j.rightWrist = p
                j.rightHand = points
            }
        }
        return j
    }

    /// Vision は左下原点で、ランドマークは顔の枠に対する相対座標。左上原点の画像座標に直す
    private static func face(_ o: VNFaceObservation) -> Face {
        let b = o.boundingBox
        func points(_ region: VNFaceLandmarkRegion2D?) -> [Vec2] {
            (region?.normalizedPoints ?? []).map { p in
                Vec2(Double(b.minX + p.x * b.width), Double(1 - (b.minY + p.y * b.height)))
            }
        }
        let lm = o.landmarks
        let landmarks = FaceLandmarks(leftEye: points(lm?.leftEye), rightEye: points(lm?.rightEye), nose: points(lm?.nose),
                                      outerLips: points(lm?.outerLips), innerLips: points(lm?.innerLips))
        let parts = [o.landmarks?.leftEye, o.landmarks?.rightEye, o.landmarks?.nose, o.landmarks?.outerLips]
            .compactMap { region -> Rect? in
                guard let region else { return nil }
                let points = region.normalizedPoints.map { p in
                    (x: Double(b.minX + p.x * b.width), y: Double(1 - (b.minY + p.y * b.height)))
                }
                return Rect.bounding(points)?.padded(0.35).withMinAspect(0.6)
            }
        return Face(rect: Rect(x: b.minX, y: 1 - b.maxY, w: b.width, h: b.height), parts: parts, landmarks: landmarks)
    }
}

/// BGRA の CVPixelBuffer を GPU で縮小し、プールから取った CVPixelBuffer に書き出す
private final class GPUScaler {
    private let queue: MTLCommandQueue
    private let cache: CVMetalTextureCache
    private let pool: CVPixelBufferPool
    private let filter: MPSImageBilinearScale

    init?(device: MTLDevice, width: Int, height: Int) {
        guard let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        let usage = MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue
        CVMetalTextureCacheCreate(nil, nil, device, [kCVMetalTextureUsage: usage] as CFDictionary, &cache)
        var pool: CVPixelBufferPool?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        guard let cache, let pool else { return nil }
        self.queue = queue
        self.cache = cache
        self.pool = pool
        filter = MPSImageBilinearScale(device: device)
    }

    func scale(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        var dst: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
        guard let dst, let srcTex = texture(src), let dstTex = texture(dst),
              let cmd = queue.makeCommandBuffer() else { return nil }
        filter.encode(commandBuffer: cmd, sourceTexture: srcTex, destinationTexture: dstTex)
        cmd.commit()
        cmd.waitUntilCompleted()
        return dst
    }

    private func texture(_ pb: CVPixelBuffer) -> MTLTexture? {
        var tex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &tex)
        return tex.flatMap(CVMetalTextureGetTexture)
    }
}
