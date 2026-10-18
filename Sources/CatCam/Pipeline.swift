import CatCore
import CoreVideo
import Metal
import QuartzCore

/// 描画に必要なその時点の状態一式
struct Scene {
    var pixelBuffer: CVPixelBuffer?
    /// 動きのウィンドウ（顔の部分は除く）
    var tracks: [Track] = []
    /// 動きのウィンドウ ID → 差し替える猫
    var cats: [Int: CatMatcher.Match] = [:]
    /// 顔（パーツは M4 の猫顔合わせ用に保持するだけで、ウィンドウにはしない）
    var faces: [Face] = []
    /// 顔のウィンドウ。動きと同じく湧いた場所から動かない
    var faceTracks: [Track] = []
    /// 顔が顔ウィンドウからはみ出した部分を埋める小さいウィンドウ
    var faceFillTracks: [Track] = []
    /// 人物マスク。nil なら切り抜かずにカメラ映像をそのまま出す
    var personMask: CVPixelBuffer?
    var personMaskVersion = 0
    /// 猫フィルタで顔に描く猫のパーツの配置（カメラのピクセル座標）
    var rigs: [CatFaceRig] = []
    /// 3D アバターの姿勢と置き場所（カメラのピクセル座標）。顔が取れていなければ nil
    var avatar: AvatarPose?
    /// デバッグ表示: 人の関節（水色）と、対応するアバターの関節（ピンク）
    var debugJoints: [AvatarDebugJoint] = []
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
    // ウィンドウは動いた場所に湧くだけで追従しない（smoothing 0）。重なる動きが続く間は残り、離れたら新しく湧く。
    // 動きが止まったらその場に固定し、再び動いたら動いた部分だけに入れ替える
    // 止まった判定は検出解像度 160×90 の約 1%、動き出しは約 2%（呼吸やノイズで固定が崩れないように）
    private let tracker = Tracker(config: TrackerConfig(iouThreshold: 0.3, historyLength: 0, smoothing: 0,
                                                        freezeWhenIdle: true, idleArea: 150, resumeArea: 300))
    private let faceSmoother = FaceSmoother(smoothing: 0.5)
    // 顔も追従しない。顔が枠から外れるほど動いたら新しい場所に湧き、古い枠は消えていく
    private let faceTracker = Tracker(config: TrackerConfig(iouThreshold: 0.3, historyLength: 0, smoothing: 0))
    // はみ出し部分の小さいウィンドウも湧いた場所から動かない
    private let faceFillTracker = Tracker(config: TrackerConfig(iouThreshold: 0.3, historyLength: 0, smoothing: 0))
    /// はみ出し部分を埋めるウィンドウの最大サイズ（通常の最大サイズに対する比率）
    private let faceFillScale = 0.35
    // 以下は queue 上でのみ触る。ウィンドウは動かないので、猫は湧いた瞬間の形で一度だけ選ぶ
    private var catMatcher: CatMatcher?
    private var catsEnabled = true
    private var cats: [Int: CatMatcher.Match] = [:]
    /// queue 上でのみ触る。前フレームの配置へ寄せて、15Hz の検出を 30fps で滑らかにつなぐ
    private var rigs: [CatFaceRig] = []
    // 以下 2 つは queue 上でのみ触る
    private var poser: AvatarPoser?
    private var idle: AvatarIdle?
    private var avatarPose: AvatarPose?
    private var avatarSeen: CFTimeInterval = 0
    /// 手を見失った時に、頭の後ろに回ったのか画面の外に出たのかを見分けて残す
    private var handHold = HandHold()
    /// true なら人とアバターの関節を Scene に入れ、毎秒ログに出す
    var debugJoints = false
    private var lastDebugLog: CFTimeInterval = 0
    private var debug: [AvatarDebugJoint] = []
    private var lastBehind = (false, false)
    private lazy var faceDetector: FaceDetector = {
        let d = FaceDetector(device: MTLCreateSystemDefaultDevice()) { [stats] ms in stats.recordFace(ms: ms) }
        d.onJoints = { [stats] s in stats.recordJoints(s) }
        return d
    }()
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

    func setCatMatcher(_ m: CatMatcher?) {
        queue.async { [self] in catMatcher = m }
    }

    func setCatsEnabled(_ on: Bool) {
        queue.async { [self] in catsEnabled = on }
    }

    /// nil ならアバターの姿勢を計算しない
    func setAvatarPoser(_ p: AvatarPoser?) {
        queue.async { [self] in
            poser = p
            idle = p.map { AvatarIdle(skeleton: $0.skeleton) }
            avatarPose = nil
            faceDetector.handsEnabled = p != nil
        }
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
        let size = (w: Double(CVPixelBufferGetWidth(pb)), h: Double(CVPixelBufferGetHeight(pb)))
        rigs = CatFaceRig.smooth(previous: rigs,
                                 current: faces.compactMap { $0.landmarks.flatMap { CatFaceRig($0.scaled(width: size.w, height: size.h)) } },
                                 t: 0.6)
        var person: PersonSegmenter.Result?
        if personEnabled {
            person = segmenter.latest(maxAge: 0.5)
            segmenter.submitIfIdle(pb)
        }
        // 顔は専用のウィンドウで出すので、顔の動きは動きのウィンドウにしない
        updateAvatar(size: size, now: t0)
        let blobs = motion.process(gray, gate: person?.gate).excluding(faces: faces.map { $0.rect.padded(0.15) })
        let tracks = tracker.update(blobs: blobs)
        assignCats(tracks: tracks, blobs: blobs)
        let faceTracks = faceTracker.update(blobs: faces.map { Blob(rect: $0.rect.padded(0.15), area: 0) })
        let faceFillTracks = faceFillTracker.update(blobs: faceFill(faces: faces, windows: faceTracks, aspect: aspect))
        stats.recordFrame(ms: (CACurrentMediaTime() - t0) * 1000, blobs: blobs.count, tracks: tracks.count,
                          area: blobs.reduce(0) { $0 + $1.area }, frozen: tracks.contains { $0.frozen })

        lock.lock()
        current = Scene(pixelBuffer: pb, tracks: tracks, cats: catsEnabled ? cats : [:], faces: faces, faceTracks: faceTracks, faceFillTracks: faceFillTracks,
                        personMask: person?.mask, personMaskVersion: person?.version ?? 0, rigs: rigs,
                        avatar: avatarPose.map { idle?.apply($0, time: t0) ?? $0 },
                        debugJoints: debugJoints && avatarPose != nil ? debug : [])
        lock.unlock()
    }

    /// 顔（と取れれば体）からアバターの姿勢を決める。検出は 15Hz なので毎フレーム寄せて滑らかにする。
    /// 顔を一瞬見失っても消えないよう、0.5 秒は前の姿勢を残す
    private func updateAvatar(size: (w: Double, h: Double), now: CFTimeInterval) {
        guard let poser else { return }
        let hands = handHold.update(faceDetector.latestHands(maxAge: 0.3)?.scaled(width: size.w, height: size.h), face: rigs.first, now: now)
        if let target = poser.pose(face: rigs.first, body: hands) {
            avatarPose = target.blended(from: avatarPose, t: 0.5)
            avatarSeen = now
            if debugJoints, let shown = avatarPose {
                debug = poser.debugJoints(pose: shown, face: rigs.first, body: hands)
                // 頭の後ろ判定に入った瞬間・出た瞬間はすぐログに出す（毎秒のログだと見逃す）
                let behind = (hands.leftBehindHead, hands.rightBehindHead)
                if behind != lastBehind {
                    print("behind 左=\(behind.0 ? "奥" : "前") 右=\(behind.1 ? "奥" : "前")  左手首\(hands.leftWrist.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) } ?? "--") 右手首\(hands.rightWrist.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) } ?? "--")")
                    lastBehind = behind
                }
                logDebug(now: now)
            }
        } else if now - avatarSeen > 0.5 {
            avatarPose = nil
        }
    }

    /// 例: "joints 左手首 H(612,388) A(615,390) Δ3 | 左肘 H-- A(560,470) | ..."
    private func logDebug(now: CFTimeInterval) {
        guard now - lastDebugLog >= 1 else { return }
        lastDebugLog = now
        func f(_ p: SIMD2<Float>?) -> String { p.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) } ?? "--" }
        let parts = debug.map { j in
            let h = f(j.human.map { SIMD2(Float($0.x), Float($0.y)) })
            return "\(j.name) H\(h) A\(f(j.avatar))" + (j.error.map { String(format: " Δ%.0f", $0) } ?? "")
        }
        print("joints " + parts.joined(separator: " | "))
    }

    /// 新しく湧いたウィンドウに、湧いた瞬間の塊の形で猫を割り当てる。画面に出ている猫とは重複させない
    private func assignCats(tracks: [Track], blobs: [Blob]) {
        let alive = Set(tracks.map(\.id))
        cats = cats.filter { alive.contains($0.key) }
        guard let catMatcher else { return }
        var used = Set(cats.values.map(\.index))
        for t in tracks where cats[t.id] == nil {
            // 追従しない設定なので、湧いた直後のトラックの矩形は塊の矩形と一致する
            guard let shape = blobs.first(where: { $0.rect == t.rect })?.shape,
                  let match = catMatcher.best(for: shape, excluding: used) else { continue }
            cats[t.id] = match
            used.insert(match.index)
        }
    }

    /// 顔のうち、今表示中の顔ウィンドウに覆われていない部分を小さいマスに分けて返す。
    /// 細すぎる帯は捨てる（わずかなズレで小窓が湧かないように）
    private func faceFill(faces: [Face], windows: [Track], aspect: Double) -> [Blob] {
        let live = windows.filter { $0.missed == 0 }.map(\.rect)
        let maxH = maxWindow * faceFillScale, maxW = maxH * aspect
        return faces.map(\.rect).subtracting(live)
            .filter { min($0.w / aspect, $0.h) >= 0.012 }
            .flatMap { $0.tiled(maxW: maxW, maxH: maxH) }
            .map { Blob(rect: $0, area: 0) }
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
