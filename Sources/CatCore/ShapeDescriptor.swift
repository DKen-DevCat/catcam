/// 形の特徴量。動いた塊と猫の切り抜きを同じ定義で比べるために使う
public struct ShapeDescriptor: Equatable, Codable, Sendable {
    /// 箱を 16×16 に区切り、各マスの中心画素が前景なら 1。行優先で 256 ビット（UInt64 × 4）
    public var bits: [UInt64]
    /// 箱の幅 / 高さ
    public var aspect: Double
    /// 前景画素数 / 箱の面積
    public var fill: Double

    public static let grid = 16

    public init(bits: [UInt64], aspect: Double, fill: Double) {
        precondition(bits.count == 4)
        self.bits = bits
        self.aspect = aspect
        self.fill = fill
    }

    /// `box` の範囲だけを見て特徴量を作る。`box.area` は前景画素数
    public init(mask: BinaryMask, box: Component) {
        self.init(box: box) { x, y in mask[x, y] }
    }

    /// 前景の判定を関数で与える版（連結成分のラベルで、同じ箱に入った別の成分を除くため）
    public init(box: Component, isOn: (Int, Int) -> Bool) {
        let g = Self.grid
        let bw = box.maxX - box.minX + 1, bh = box.maxY - box.minY + 1
        var bits = [UInt64](repeating: 0, count: 4)
        for row in 0..<g {
            let y = box.minY + Int((Double(row) + 0.5) * Double(bh) / Double(g))
            for col in 0..<g {
                let x = box.minX + Int((Double(col) + 0.5) * Double(bw) / Double(g))
                if isOn(x, y) {
                    let i = row * g + col
                    bits[i / 64] |= 1 << UInt64(i % 64)
                }
            }
        }
        self.init(bits: bits, aspect: Double(bw) / Double(bh), fill: Double(box.area) / Double(bw * bh))
    }

    public func bit(col: Int, row: Int) -> Bool {
        let i = row * Self.grid + col
        return bits[i / 64] & (1 << UInt64(i % 64)) != 0
    }

    public func hamming(_ o: ShapeDescriptor) -> Int {
        zip(bits, o.bits).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
    }

    /// 左右反転。猫ライブラリを実質 2 倍にするのに使う
    public func mirrored() -> ShapeDescriptor {
        let g = Self.grid
        var out = [UInt64](repeating: 0, count: 4)
        for row in 0..<g {
            for col in 0..<g where bit(col: col, row: row) {
                let i = row * g + (g - 1 - col)
                out[i / 64] |= 1 << UInt64(i % 64)
            }
        }
        return ShapeDescriptor(bits: out, aspect: aspect, fill: fill)
    }
}
