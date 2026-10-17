import CatCore
import CoreVideo
import Metal
import QuartzCore

/// 描画に必要なその時点の状態一式
struct Scene {
    var pixelBuffer: CVPixelBuffer?
    /// 動きのウィンドウ（顔の部分は除く）
    var tracks: [Track] = []
    /// 顔全体 1 枚と、目・鼻・口のパーツ
    var faces: [Face] = []
    /// 人物マスク。nil なら切り抜かずにカメラ映像をそのまま出す
    var personMask: CVPixelBuffer?
    var personMaskVersion = 0
}

/// カメラフレームごとに 縮小 → 動き検出 → 追跡 を行い、最新の Scene を公開する
final class Pipeline {
    let queue = DispatchQueue(label: "catcam.capture", qos: .userInteractive)
    let stats = Stats()
    /// true ならカメラのメタデータ出力の顔を使う。false なら自前の Vision で検出する
    var useSystemFaces = false
    /// 両方の顔検出結果を毎秒ログに出す（座標系の確認用）
    var compareFaces = false
    var faceEnabled = true
    /// 人物だけを対象にする（動き検出の絞り込みと描画の切り抜き）。queue 上で読む
    var personEnabled = true
    private let downsampler = Downsampler(width: 160, height: 90)
    private let motion = MotionDetector()
    /// ウィンドウの最大サイズ（映像の高さに対する比率）。queue 上でのみ触る
    private var maxWindow = 0.25
    // 動きが止まったらウィンドウをその場に固定し、再び動いたら動いた部分だけに入れ替える
    private let tracker = Tracker(config: TrackerConfig(freezeWhenIdle: true, idleArea: 30))
    private let faceSmoother = FaceSmoother(smoothing: 0.5)
    private lazy var faceDetector = FaceDetector(device: MTLCreateSystemDefaultDevice()) { [stats] ms in stats.recordFace(ms: ms) }
    private lazy var segmenter = PersonSegmenter(gateWidth: 160, gateHeight: 90) { [stats] ms in stats.recordPerson(ms: ms) }
    // 以下 2 つは queue 上でのみ触る
    private var systemFaces: [Rect] = []
    private var systemFacesTime: CFTimeInterval = 0
    private var lastCompareLog: CFTimeInterval = 0
    private let lock = NSLock()
    private var current = Scene()

    var scene: Scene {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// 設定変更はキャプチャキュー上で反映する（検出処理と競合させない）
    func updateMotionConfig(_ change: @escaping (inout MotionConfig) -> Void) {
        queue.async { [self] in change(&motion.config) }
    }

    func setMaxWindow(_ v: Double) {
        queue.async { [self] in maxWindow = v }
    }

    func setPersonEnabled(_ on: Bool) {
        queue.async { [self] in personEnabled = on }
    }

    /// キャプチャキュー上で呼ばれる
    func receiveSystemFaces(_ rects: [Rect]) {
        systemFaces = rects
        systemFacesTime = CACurrentMediaTime()
    }

    /// キャプチャキュー上で呼ばれる
    func process(_ pb: CVPixelBuffer) {
        let t0 = CACurrentMediaTime()
        // 高さ基準の比率を幅にも換算し、ほぼ正方形を上限にする
        let aspect = Double(CVPixelBufferGetHeight(pb)) / Double(CVPixelBufferGetWidth(pb))
        motion.config.maxBlobWidth = maxWindow * aspect
        motion.config.maxBlobHeight = maxWindow
        let gray = downsampler.gray(pb)
        let faces = faceSmoother.update(currentFaces(pb, now: t0))
        var person: PersonSegmenter.Result?
        if personEnabled {
            person = segmenter.latest(maxAge: 0.5)
            segmenter.submitIfIdle(pb)
        }
        // 顔は専用のウィンドウで出すので、顔の動きは動きのウィンドウにしない
        let blobs = motion.process(gray, gate: person?.gate).excluding(faces: faces.map { $0.rect.padded(0.15) })
        let tracks = tracker.update(blobs: blobs)
        stats.recordFrame(ms: (CACurrentMediaTime() - t0) * 1000, blobs: blobs.count, tracks: tracks.count)

        lock.lock()
        current = Scene(pixelBuffer: pb, tracks: tracks, faces: faces,
                        personMask: person?.mask, personMaskVersion: person?.version ?? 0)
        lock.unlock()
    }

    private func currentFaces(_ pb: CVPixelBuffer, now: CFTimeInterval) -> [Face] {
        guard faceEnabled else { return [] }
        // システムの顔検出は矩形のみでパーツは取れない
        let system = (now - systemFacesTime <= 0.3 ? systemFaces : []).map { Face(rect: $0, parts: []) }
        if useSystemFaces && !compareFaces { return system }

        let vision = faceDetector.latest(maxAge: 0.3)
        faceDetector.submitIfIdle(pb)
        if compareFaces, now - lastCompareLog >= 1 {
            lastCompareLog = now
            func fmt(_ r: Rect?) -> String {
                r.map { String(format: "x=%.2f y=%.2f w=%.2f h=%.2f", $0.x, $0.y, $0.w, $0.h) } ?? "-"
            }
            print("faces system[\(fmt(system.first?.rect))] vision[\(fmt(vision.first?.rect))]")
        }
        return useSystemFaces ? system : vision
    }
}
