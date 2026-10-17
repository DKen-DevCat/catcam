/// catlib/index.json の中身。builder が書き、アプリが読む
public struct CatLibraryIndex: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var name: String
        /// アトラス上の切り抜きの範囲（正規化座標・左上原点）
        public var uv: Rect
        public var shape: ShapeDescriptor

        public init(name: String, uv: Rect, shape: ShapeDescriptor) {
            self.name = name
            self.uv = uv
            self.shape = shape
        }
    }

    public var atlasSize: Int
    public var cellSize: Int
    public var entries: [Entry]

    public init(atlasSize: Int, cellSize: Int, entries: [Entry]) {
        self.atlasSize = atlasSize
        self.cellSize = cellSize
        self.entries = entries
    }
}
