public struct MotionConfig: Sendable {
    /// 0..1。高いほど小さな輝度変化も動きとみなす
    public var sensitivity: Double
    /// 膨張後の画素数がこれ未満の塊は捨てる（検出解像度の画素単位）
    public var minArea: Int
    public var maxBlobs: Int
    /// 背景の指数移動平均の係数
    public var backgroundAlpha: Float
    public var dilateIterations: Int
    /// 塊の最大幅・高さ（画像に対する比率）。超える塊はマス目に分割して複数の塊にする
    public var maxBlobWidth: Double
    public var maxBlobHeight: Double

    public init(sensitivity: Double = 0.7, minArea: Int = 20, maxBlobs: Int = 40,
                backgroundAlpha: Float = 0.1, dilateIterations: Int = 2,
                maxBlobWidth: Double = 1, maxBlobHeight: Double = 1) {
        self.sensitivity = sensitivity
        self.minArea = minArea
        self.maxBlobs = maxBlobs
        self.backgroundAlpha = backgroundAlpha
        self.dilateIterations = dilateIterations
        self.maxBlobWidth = maxBlobWidth
        self.maxBlobHeight = maxBlobHeight
    }

    var threshold: Float { Float(5 + (1 - sensitivity) * 60) }
}

public struct Blob: Equatable, Sendable {
    public var rect: Rect
    /// 膨張後の画素数
    public var area: Int
    /// 形の特徴量（猫を選ぶのに使う）
    public var shape: ShapeDescriptor?

    public init(rect: Rect, area: Int, shape: ShapeDescriptor? = nil) {
        self.rect = rect
        self.area = area
        self.shape = shape
    }
}

/// 背景（指数移動平均）との差分で動いた領域を塊として返す
public final class MotionDetector {
    public var config: MotionConfig
    private var background: [Float] = []
    /// 画素ごとに最後に動いたフレーム番号
    private var lastMoved: [Int] = []
    private var frameIndex = 0
    private var size = (w: 0, h: 0)

    public init(config: MotionConfig = MotionConfig()) {
        self.config = config
    }

    /// `gate` を渡すと、その true の画素で起きた動きだけを拾う（人物マスクで背景の動きを無視する用途）。
    /// サイズが `img` と違うマスクは無視する。
    /// `holdRegions` の中では、直近 `holdFrames` フレーム以内に動いた画素も動いているとみなす（顔の小さな動きを残す用途）
    public func process(_ img: GrayImage, gate: BinaryMask? = nil,
                        holdRegions: [Rect] = [], holdFrames: Int = 0) -> [Blob] {
        if size != (img.width, img.height) || background.isEmpty {
            size = (img.width, img.height)
            background = img.pixels.map(Float.init)
            lastMoved = [Int](repeating: Int.min / 2, count: img.pixels.count)
            return []
        }
        frameIndex += 1

        let t = config.threshold, a = config.backgroundAlpha
        let gate = gate.flatMap { $0.width == img.width && $0.height == img.height ? $0 : nil }
        var mask = BinaryMask(width: img.width, height: img.height)
        for i in 0..<img.pixels.count {
            let v = Float(img.pixels[i])
            if abs(v - background[i]) > t && (gate?.bits[i] ?? true) {
                mask.bits[i] = true
                lastMoved[i] = frameIndex
            }
            background[i] += (v - background[i]) * a
        }
        if holdFrames > 0 {
            applyHold(to: &mask, regions: holdRegions, frames: holdFrames)
        }
        for _ in 0..<config.dilateIterations {
            mask = Morphology.dilate(mask)
        }

        let (labels, components) = ConnectedComponents.label(mask)
        let maxW = max(1, Int(config.maxBlobWidth * Double(img.width)))
        let maxH = max(1, Int(config.maxBlobHeight * Double(img.height)))
        var pieces: [(c: Component, label: Int32)] = []
        for (ci, c) in components.enumerated() where c.area >= config.minArea {
            let label = Int32(ci + 1)
            pieces += split(c, label: label, labels: labels, width: img.width, maxW: maxW, maxH: maxH).map { ($0, label) }
        }

        let fw = Double(img.width), fh = Double(img.height), w = img.width
        return pieces
            .sorted { $0.c.area > $1.c.area }
            .prefix(config.maxBlobs)
            .map { p in
                let c = p.c
                return Blob(rect: Rect(x: Double(c.minX) / fw, y: Double(c.minY) / fh,
                                       w: Double(c.maxX - c.minX + 1) / fw, h: Double(c.maxY - c.minY + 1) / fh),
                            area: c.area,
                            shape: ShapeDescriptor(box: c) { x, y in labels[y * w + x] == p.label })
            }
    }

    /// 領域内（画素の中心で判定）で直近 `frames` フレーム以内に動いた画素を立てる
    private func applyHold(to mask: inout BinaryMask, regions: [Rect], frames: Int) {
        let w = mask.width, h = mask.height
        for r in regions {
            let x0 = max(0, Int((r.x * Double(w) - 0.5).rounded(.up)))
            let x1 = min(w - 1, Int((r.maxX * Double(w) - 0.5).rounded(.down)))
            let y0 = max(0, Int((r.y * Double(h) - 0.5).rounded(.up)))
            let y1 = min(h - 1, Int((r.maxY * Double(h) - 0.5).rounded(.down)))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 where frameIndex - lastMoved[y * w + x] <= frames {
                    mask.bits[y * w + x] = true
                }
            }
        }
    }

    /// 最大サイズを超える成分を等分のマス目に分け、マスごとに中の画素へぴったり合う矩形を返す。
    /// 画素の少ないマス（空のマスを含む）は捨てる
    private func split(_ c: Component, label: Int32, labels: [Int32], width: Int, maxW: Int, maxH: Int) -> [Component] {
        let bw = c.maxX - c.minX + 1, bh = c.maxY - c.minY + 1
        let nx = (bw + maxW - 1) / maxW, ny = (bh + maxH - 1) / maxH
        if nx == 1 && ny == 1 { return [c] }

        var cells = [Component?](repeating: nil, count: nx * ny)
        for y in c.minY...c.maxY {
            let cj = (y - c.minY) * ny / bh
            for x in c.minX...c.maxX where labels[y * width + x] == label {
                let k = cj * nx + (x - c.minX) * nx / bw
                if var cell = cells[k] {
                    cell.minX = min(cell.minX, x)
                    cell.maxX = max(cell.maxX, x)
                    cell.minY = min(cell.minY, y)
                    cell.maxY = max(cell.maxY, y)
                    cell.area += 1
                    cells[k] = cell
                } else {
                    cells[k] = Component(minX: x, minY: y, maxX: x, maxY: y, area: 1)
                }
            }
        }
        let minCellArea = max(1, config.minArea / 4)
        return cells.compactMap { $0 }.filter { $0.area >= minCellArea }
    }
}

extension Array where Element == Blob {
    /// 顔の矩形に大部分が覆われている塊を除く（顔は別系統で扱うため）
    public func excluding(faces: [Rect], maxCoverage: Double = 0.5) -> [Blob] {
        filter { b in faces.allSatisfy { b.rect.coverage(by: $0) <= maxCoverage } }
    }
}
