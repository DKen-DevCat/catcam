public struct MotionConfig: Sendable {
    /// 0..1。高いほど小さな輝度変化も動きとみなす
    public var sensitivity: Double
    /// 膨張後の画素数がこれ未満の塊は捨てる（検出解像度の画素単位）
    public var minArea: Int
    public var maxBlobs: Int
    /// 背景の指数移動平均の係数
    public var backgroundAlpha: Float
    public var dilateIterations: Int

    public init(sensitivity: Double = 0.7, minArea: Int = 20, maxBlobs: Int = 24,
                backgroundAlpha: Float = 0.1, dilateIterations: Int = 2) {
        self.sensitivity = sensitivity
        self.minArea = minArea
        self.maxBlobs = maxBlobs
        self.backgroundAlpha = backgroundAlpha
        self.dilateIterations = dilateIterations
    }

    var threshold: Float { Float(5 + (1 - sensitivity) * 60) }
}

public struct Blob: Equatable, Sendable {
    public var rect: Rect
    /// 膨張後の画素数
    public var area: Int

    public init(rect: Rect, area: Int) {
        self.rect = rect
        self.area = area
    }
}

/// 背景（指数移動平均）との差分で動いた領域を塊として返す
public final class MotionDetector {
    public var config: MotionConfig
    private var background: [Float] = []
    private var size = (w: 0, h: 0)

    public init(config: MotionConfig = MotionConfig()) {
        self.config = config
    }

    public func process(_ img: GrayImage) -> [Blob] {
        if size != (img.width, img.height) || background.isEmpty {
            size = (img.width, img.height)
            background = img.pixels.map(Float.init)
            return []
        }

        let t = config.threshold, a = config.backgroundAlpha
        var mask = BinaryMask(width: img.width, height: img.height)
        for i in 0..<img.pixels.count {
            let v = Float(img.pixels[i])
            mask.bits[i] = abs(v - background[i]) > t
            background[i] += (v - background[i]) * a
        }
        for _ in 0..<config.dilateIterations {
            mask = Morphology.dilate(mask)
        }

        let fw = Double(img.width), fh = Double(img.height)
        return ConnectedComponents.find(mask)
            .filter { $0.area >= config.minArea }
            .sorted { $0.area > $1.area }
            .prefix(config.maxBlobs)
            .map { c in
                Blob(rect: Rect(x: Double(c.minX) / fw, y: Double(c.minY) / fh,
                                w: Double(c.maxX - c.minX + 1) / fw, h: Double(c.maxY - c.minY + 1) / fh),
                     area: c.area)
            }
    }
}

extension Array where Element == Blob {
    /// 顔の矩形に大部分が覆われている塊を除く（顔は別系統で扱うため）
    public func excluding(faces: [Rect], maxCoverage: Double = 0.5) -> [Blob] {
        filter { b in faces.allSatisfy { b.rect.coverage(by: $0) <= maxCoverage } }
    }
}
