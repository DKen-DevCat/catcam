import CatCore
import CoreVideo
import Metal
import MetalPerformanceShaders
import QuartzCore
import Vision

/// Vision の顔ランドマーク検出を専用キューで間引きながら回す。処理中に来たフレームは捨てる。
/// Vision の CPU コストの大半は入力の前処理なので、GPU で縮小してから渡す
final class FaceDetector {
    var minInterval: CFTimeInterval = 1.0 / 10
    private let queue = DispatchQueue(label: "catcam.face", qos: .userInitiated)
    // 毎回作るとリビジョン解決などの初期化コストが乗るので使い回す（queue 上でのみ触る）
    private let request = VNDetectFaceLandmarksRequest()
    private let sequenceHandler = VNSequenceRequestHandler()
    private let scaler: GPUScaler?
    private let lock = NSLock()
    private var busy = false
    private var lastSubmit: CFTimeInterval = 0
    private var faces: [Face] = []
    private var resultTime: CFTimeInterval = 0
    private let onDuration: (Double) -> Void

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
            try? sequenceHandler.perform([request], on: input, orientation: .up)
            let found = (request.results ?? []).map(Self.face)
            let t1 = CACurrentMediaTime()
            lock.lock()
            faces = found
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

    /// Vision は左下原点で、ランドマークは顔の枠に対する相対座標。左上原点の画像座標に直す
    private static func face(_ o: VNFaceObservation) -> Face {
        let b = o.boundingBox
        let parts = [o.landmarks?.leftEye, o.landmarks?.rightEye, o.landmarks?.nose, o.landmarks?.outerLips]
            .compactMap { region -> Rect? in
                guard let region else { return nil }
                let points = region.normalizedPoints.map { p in
                    (x: Double(b.minX + p.x * b.width), y: Double(1 - (b.minY + p.y * b.height)))
                }
                return Rect.bounding(points)?.padded(0.35).withMinAspect(0.6)
            }
        return Face(rect: Rect(x: b.minX, y: 1 - b.maxY, w: b.width, h: b.height), parts: parts)
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
