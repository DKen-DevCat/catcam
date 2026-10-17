/// 8bit グレースケール画像
public struct GrayImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height))
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }
}

public struct BinaryMask: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var bits: [Bool]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bits = [Bool](repeating: false, count: width * height)
    }

    public subscript(x: Int, y: Int) -> Bool {
        get { bits[y * width + x] }
        set { bits[y * width + x] = newValue }
    }
}

public enum Morphology {
    /// 3×3 の膨張。画像外は false とみなす
    public static func dilate(_ m: BinaryMask) -> BinaryMask {
        let w = m.width, h = m.height
        // 横方向 → 縦方向の分離可能な 2 パス
        var horizontal = BinaryMask(width: w, height: h)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where m.bits[row + x] {
                horizontal.bits[row + x] = true
                if x > 0 { horizontal.bits[row + x - 1] = true }
                if x < w - 1 { horizontal.bits[row + x + 1] = true }
            }
        }
        var out = BinaryMask(width: w, height: h)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where horizontal.bits[row + x] {
                out.bits[row + x] = true
                if y > 0 { out.bits[row - w + x] = true }
                if y < h - 1 { out.bits[row + w + x] = true }
            }
        }
        return out
    }
}

/// 連結成分。座標は画素単位で max は含む
public struct Component: Equatable, Sendable {
    public var minX: Int
    public var minY: Int
    public var maxX: Int
    public var maxY: Int
    public var area: Int

    public init(minX: Int, minY: Int, maxX: Int, maxY: Int, area: Int) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
        self.area = area
    }
}

public enum ConnectedComponents {
    /// 8 近傍の連結成分を 2 パス + union-find で求める
    public static func find(_ m: BinaryMask) -> [Component] {
        label(m).components
    }

    /// `find` に加えて画素ごとのラベルを返す。ラベルは `components` の添字 + 1、背景は 0
    public static func label(_ m: BinaryMask) -> (labels: [Int32], components: [Component]) {
        let w = m.width, h = m.height
        var labels = [Int32](repeating: 0, count: w * h)
        var parent: [Int32] = [0]

        func root(_ a: Int32) -> Int32 {
            var a = a
            while parent[Int(a)] != a {
                parent[Int(a)] = parent[Int(parent[Int(a)])]
                a = parent[Int(a)]
            }
            return a
        }

        for y in 0..<h {
            for x in 0..<w where m.bits[y * w + x] {
                var found: Int32 = 0
                // 走査済みの近傍: 西・北西・北・北東
                for (dx, dy) in [(-1, 0), (-1, -1), (0, -1), (1, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0 else { continue }
                    let l = labels[ny * w + nx]
                    guard l != 0 else { continue }
                    if found == 0 {
                        found = root(l)
                    } else {
                        let a = root(found), b = root(l)
                        if a != b { parent[Int(max(a, b))] = min(a, b) }
                        found = min(a, b)
                    }
                }
                if found == 0 {
                    found = Int32(parent.count)
                    parent.append(found)
                }
                labels[y * w + x] = found
            }
        }

        // 根ごとに出現順の添字を振り、ラベルを「添字 + 1」に書き換えながら集計する
        var indexOfRoot = [Int32](repeating: -1, count: parent.count)
        var components: [Component] = []
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let l = labels[i]
                guard l != 0 else { continue }
                let r = Int(root(l))
                if indexOfRoot[r] < 0 {
                    indexOfRoot[r] = Int32(components.count)
                    components.append(Component(minX: x, minY: y, maxX: x, maxY: y, area: 0))
                }
                let ci = Int(indexOfRoot[r])
                components[ci].minX = min(components[ci].minX, x)
                components[ci].maxX = max(components[ci].maxX, x)
                components[ci].maxY = y
                components[ci].area += 1
                labels[i] = Int32(ci + 1)
            }
        }
        return (labels, components)
    }
}
