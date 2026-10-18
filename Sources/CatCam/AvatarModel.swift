import CatCore
import Foundation
import MetalKit
import simd

/// tools/blender/export_avatar.py が書き出したモデル（avatar.json / avatar.bin / テクスチャ）を読み込む
final class AvatarModel {
    private struct Meta: Decodable {
        struct Bone: Decodable {
            let name: String
            let parent: Int
            let head: [Float]
            let tail: [Float]
        }

        let vertexCount: Int
        let indexCount: Int
        let floatsPerVertex: Int
        let texture: String
        let bones: [Bone]
    }

    static let floatsPerVertex = 22

    let skeleton: AvatarSkeleton
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let texture: MTLTexture

    /// 開発中はパッケージ直下の models/out/ を使う
    static let defaultDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("models/out")

    init(directory: URL, device: MTLDevice) throws {
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: directory.appendingPathComponent("avatar.json")))
        guard meta.floatsPerVertex == Self.floatsPerVertex else {
            throw NSError(domain: "catcam", code: 10, userInfo: [NSLocalizedDescriptionKey: "avatar.bin の頂点形式が違う"])
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("avatar.bin"))
        let vertexBytes = meta.vertexCount * meta.floatsPerVertex * 4
        guard data.count == vertexBytes + meta.indexCount * 4,
              let vb = data.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: vertexBytes) }),
              let ib = data.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress! + vertexBytes, length: meta.indexCount * 4) })
        else {
            throw NSError(domain: "catcam", code: 11, userInfo: [NSLocalizedDescriptionKey: "avatar.bin の大きさが合わない"])
        }
        vertexBuffer = vb
        indexBuffer = ib
        indexCount = meta.indexCount
        skeleton = AvatarSkeleton(bones: meta.bones.map {
            AvatarBone(name: $0.name, parent: $0.parent, head: SIMD3($0.head[0], $0.head[1], $0.head[2]),
                       tail: SIMD3($0.tail[0], $0.tail[1], $0.tail[2]))
        })
        // カメラ側と同じく sRGB 変換をかけずに読む
        texture = try MTKTextureLoader(device: device).newTexture(
            URL: directory.appendingPathComponent(meta.texture),
            options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue, .generateMipmaps: true]
        )
    }

    /// 毒チワワ用の置き方。目の位置・間隔は build_chihuahua.py の目のパーツに合わせる
    func makePoser() -> AvatarPoser {
        AvatarPoser(skeleton: skeleton, eyeCenter: SIMD3(0, -0.52, 1.42), eyeDistance: 0.74, headScale: 1.6)
    }
}
