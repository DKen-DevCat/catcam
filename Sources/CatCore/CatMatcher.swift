import Foundation

/// 形が最も近い猫を選ぶ。各猫の左右反転も候補にする
public struct CatMatcher: Sendable {
    public struct Match: Equatable, Sendable {
        public let index: Int
        /// 猫を左右反転して使う
        public let mirrored: Bool
        public let distance: Double
    }

    private let candidates: [(index: Int, mirrored: Bool, shape: ShapeDescriptor)]

    public init(shapes: [ShapeDescriptor]) {
        candidates = shapes.enumerated().flatMap { i, s in [(i, false, s), (i, true, s.mirrored())] }
    }

    /// シルエットの不一致率・縦横比の対数差・埋まり具合の差の重み付き和。0 が完全一致
    public static func distance(_ a: ShapeDescriptor, _ b: ShapeDescriptor) -> Double {
        Double(a.hamming(b)) / 256 + 0.5 * abs(log(a.aspect / b.aspect)) + 0.3 * abs(a.fill - b.fill)
    }

    /// `excluding` の猫（画面に出ている猫など）は選ばない
    public func best(for query: ShapeDescriptor, excluding: Set<Int> = []) -> Match? {
        var best: Match?
        for c in candidates where !excluding.contains(c.index) {
            let d = Self.distance(query, c.shape)
            if d < best?.distance ?? .infinity {
                best = Match(index: c.index, mirrored: c.mirrored, distance: d)
            }
        }
        return best
    }
}
