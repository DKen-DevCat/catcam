import CatCore
import CoreVideo
import QuartzCore
import Vision

/// Vision の人物セグメンテーション（Google Meet の背景ぼかしと同種）を専用キューで間引きながら回す
final class PersonSegmenter {
    struct Result {
        /// 人物らしさ 0..255 の 1 チャンネル画像。描画時の切り抜きに使う
        let mask: CVPixelBuffer
        /// 動き検出と同じ解像度の二値マスク
        let gate: BinaryMask
        let version: Int
    }

    var minInterval: CFTimeInterval = 1.0 / 15
    private let gateSize: (w: Int, h: Int)
    private let queue = DispatchQueue(label: "catcam.person", qos: .userInitiated)
    // queue 上でのみ触る。シーケンスハンドラはフレーム間でマスクを平滑化してくれる
    private let request: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private let sequenceHandler = VNSequenceRequestHandler()
    private let lock = NSLock()
    private var busy = false
    private var lastSubmit: CFTimeInterval = 0
    private var result: Result?
    private var resultTime: CFTimeInterval = 0
    private let onDuration: (Double) -> Void

    init(gateWidth: Int, gateHeight: Int, onDuration: @escaping (Double) -> Void) {
        gateSize = (gateWidth, gateHeight)
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
            try? sequenceHandler.perform([request], on: pb, orientation: .up)
            let mask = request.results?.first?.pixelBuffer
            let gate = mask.map { Self.downsample($0, width: gateSize.w, height: gateSize.h) }
            let t1 = CACurrentMediaTime()
            lock.lock()
            if let mask, let gate {
                result = Result(mask: mask, gate: gate, version: (result?.version ?? 0) + 1)
                resultTime = t1
            }
            busy = false
            lock.unlock()
            onDuration((t1 - t0) * 1000)
        }
    }

    /// `maxAge` 秒より古い結果は捨てる
    func latest(maxAge: CFTimeInterval) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        return CACurrentMediaTime() - resultTime <= maxAge ? result : nil
    }

    /// 最近傍で縮小して 50% で二値化する
    private static func downsample(_ mask: CVPixelBuffer, width: Int, height: Int) -> BinaryMask {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        var out = BinaryMask(width: width, height: height)
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return out }
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let mw = CVPixelBufferGetWidth(mask), mh = CVPixelBufferGetHeight(mask)
        for y in 0..<height {
            let row = base + ((2 * y + 1) * mh / (2 * height)) * rowBytes
            for x in 0..<width {
                out.bits[y * width + x] = row[(2 * x + 1) * mw / (2 * width)] > 127
            }
        }
        return out
    }
}
