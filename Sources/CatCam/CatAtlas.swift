import CatCore
import Foundation
import MetalKit

/// catlib-builder が作った猫ライブラリ（index.json と shape_atlas.png）を読み込む
final class CatAtlas {
    let index: CatLibraryIndex
    let texture: MTLTexture
    let matcher: CatMatcher

    /// 開発中はパッケージ直下の catlib/ を使う
    static let defaultDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("catlib")

    init(directory: URL, device: MTLDevice) throws {
        index = try JSONDecoder().decode(CatLibraryIndex.self,
                                         from: Data(contentsOf: directory.appendingPathComponent("index.json")))
        // カメラ側と同じく sRGB 変換をかけずに読む
        texture = try MTKTextureLoader(device: device).newTexture(
            URL: directory.appendingPathComponent("shape_atlas.png"),
            options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue]
        )
        matcher = CatMatcher(shapes: index.entries.map(\.shape))
    }
}
