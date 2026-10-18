import CatCore
import CoreVideo
import MetalKit

/// GPU に渡す偽ウィンドウ 1 枚分。Metal 側の `Instance` と同じレイアウト
private struct WindowInstance {
    /// 中身（タイトルバーを除く）の矩形。ピクセル、左上原点
    var frame: SIMD4<Float>
    /// x: 不透明度, y: 種類（0 動き / 1 顔）, z: 猫あり, w: 猫を左右反転
    var params: SIMD4<Float>
    /// 猫アトラス上の切り抜きの範囲（正規化・左上原点）
    var catUV: SIMD4<Float> = .zero
    /// 中身の矩形に対する猫の配置（0..1）
    var catLocal: SIMD4<Float> = .zero
}

private struct Uniforms {
    var viewport: SIMD2<Float>
    /// 画面の正規化座標 s → ミラー前のカメラ正規化座標 = s * camK + camB
    var camK: SIMD2<Float>
    var camB: SIMD2<Float>
    var titleH: Float
    var radius: Float
    var shadow: Float
    var mirror: Float
    var scale: Float
    /// 1 なら人物マスクで中身を切り抜く
    var hasMask: Float = 0
    /// BackgroundMode の rawValue
    var bgMode: Float = 0
    /// 1 なら人物を猫フィルタ（毛並み・猫の顔）で描く
    var filterOn: Float = 0
    var rigCount: Float = 0
    /// 1 なら人物の代わりに 3D アバターを出す
    var avatarOn: Float = 0
    /// カメラ映像のピクセル数（毛並みと猫の顔はカメラのピクセル座標で描く）
    var camSize: SIMD2<Float> = .zero
    var pad2: SIMD2<Float> = .zero
    var style = CatStyle.GPU()
}

/// 猫の顔 1 つ分。Metal 側の `Rig` と同じレイアウト
private struct RigGPU {
    /// 中心 xy, 人の目の幅, 開き具合
    var eyeL: SIMD4<Float> = .zero
    var eyeR: SIMD4<Float> = .zero
    /// 左目→右目の向き xy, 頭の上の向き xy
    var frame: SIMD4<Float> = .zero
    /// 鼻先 xy, 口の中心 xy
    var noseMouth: SIMD4<Float> = .zero
    /// 目の間隔, 口の幅, 口の開き具合
    var misc: SIMD4<Float> = .zero
    /// 耳の内側の付け根 xy, 外側の付け根 xy
    var earL: SIMD4<Float> = .zero
    var earR: SIMD4<Float> = .zero
    /// 左耳の先 xy, 右耳の先 xy
    var tips: SIMD4<Float> = .zero

    static let maxCount = 2

    init() {}

    init(_ r: CatFaceRig) {
        func v(_ a: Vec2, _ b: Vec2) -> SIMD4<Float> { SIMD4(Float(a.x), Float(a.y), Float(b.x), Float(b.y)) }
        eyeL = SIMD4(Float(r.leftEye.center.x), Float(r.leftEye.center.y), Float(r.leftEye.width), Float(r.leftEye.openness))
        eyeR = SIMD4(Float(r.rightEye.center.x), Float(r.rightEye.center.y), Float(r.rightEye.width), Float(r.rightEye.openness))
        frame = v(r.axis, r.up)
        noseMouth = v(r.nose, r.mouth)
        misc = SIMD4(Float(r.eyeDistance), Float(r.mouthWidth), Float(r.mouthOpen), 0)
        earL = v(r.leftEar.inner, r.leftEar.outer)
        earR = v(r.rightEar.inner, r.rightEar.outer)
        tips = v(r.leftEar.tip, r.rightEar.tip)
    }
}

/// 猫フィルタの色。種類を足すときは `presets` に足す
struct CatStyle {
    var name: String
    /// 毛の一番暗い色と、明るいところで足す色
    var furBase: SIMD3<Float>
    var furHighlight: SIMD3<Float>
    var eye: SIMD3<Float>
    var earInner: SIMD3<Float>
    var nose: SIMD3<Float>
    /// 口の線・閉じた目の線
    var line: SIMD3<Float>
    var whisker: SIMD3<Float>

    static let presets = [
        CatStyle(name: "黒猫", furBase: SIMD3(0.012, 0.012, 0.016), furHighlight: SIMD3(0.24, 0.24, 0.28),
                 eye: SIMD3(0.92, 0.74, 0.16), earInner: SIMD3(0.20, 0.12, 0.13), nose: SIMD3(0.10, 0.08, 0.09),
                 line: SIMD3(0.30, 0.28, 0.30), whisker: SIMD3(0.92, 0.92, 0.90)),
        CatStyle(name: "グレー", furBase: SIMD3(0.10, 0.10, 0.11), furHighlight: SIMD3(0.62, 0.62, 0.66),
                 eye: SIMD3(0.55, 0.78, 0.30), earInner: SIMD3(0.55, 0.38, 0.40), nose: SIMD3(0.45, 0.30, 0.33),
                 line: SIMD3(0.08, 0.08, 0.09), whisker: SIMD3(0.95, 0.95, 0.93)),
        CatStyle(name: "白猫", furBase: SIMD3(0.42, 0.40, 0.38), furHighlight: SIMD3(0.62, 0.62, 0.62),
                 eye: SIMD3(0.35, 0.62, 0.90), earInner: SIMD3(0.88, 0.62, 0.64), nose: SIMD3(0.88, 0.55, 0.58),
                 line: SIMD3(0.30, 0.24, 0.24), whisker: SIMD3(0.98, 0.98, 0.98)),
    ]

    /// Metal 側の `Style` と同じレイアウト
    struct GPU {
        var furBase: SIMD4<Float> = .zero
        var furHighlight: SIMD4<Float> = .zero
        var eye: SIMD4<Float> = .zero
        var earInner: SIMD4<Float> = .zero
        var nose: SIMD4<Float> = .zero
        var line: SIMD4<Float> = .zero
        var whisker: SIMD4<Float> = .zero
    }

    var gpu: GPU {
        func v(_ c: SIMD3<Float>) -> SIMD4<Float> { SIMD4(c, 1) }
        return GPU(furBase: v(furBase), furHighlight: v(furHighlight), eye: v(eye), earInner: v(earInner),
                   nose: v(nose), line: v(line), whisker: v(whisker))
    }
}

/// ウィンドウの中の、人物以外の部分の見せ方
enum BackgroundMode: Int, CaseIterable {
    case transparent, glass, blur, original

    var label: String {
        switch self {
        case .transparent: "透明（人物だけ）"
        case .glass: "すりガラス"
        case .blur: "ぼかし"
        case .original: "そのまま（人物切り抜きなし・軽い）"
        }
    }

    /// 人物セグメンテーションが要るか
    var needsPersonMask: Bool { self != .original }
}

/// 全画面オーバーレイに偽ウィンドウを描く。全ウィンドウが同じカメラテクスチャを参照するのでコピーは発生しない
final class Renderer: NSObject, MTKViewDelegate {
    var mirror: Bool
    var backgroundMode = BackgroundMode.glass
    var cats: CatAtlas?
    /// nil なら猫フィルタを使わない
    var catStyle: CatStyle?
    /// 窓を出さず、映像全体を 1 枚で出す（猫フィルタの見た目確認用）
    var fullFrame = false
    /// 人物の代わりに描く 3D アバター。nil なら使わない
    var avatar: AvatarRenderer?
    var avatarOn = false
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let source: Pipeline
    // 人物マスクは小さい（数百 KB）ので、更新された時だけ CPU からテクスチャに書き込む
    private var maskTexture: MTLTexture?
    private var maskVersion = -1

    init(view: MTKView, source: Pipeline, mirror: Bool) throws {
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            throw NSError(domain: "catcam", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal unavailable"])
        }
        self.device = device
        commandQueue = queue
        self.source = source
        self.mirror = mirror

        // SwiftPM で .metal をビルドしないよう、シェーダはソース文字列から実行時にコンパイルする
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "window_vertex")
        desc.fragmentFunction = library.makeFunction(name: "window_fragment")
        let color = desc.colorAttachments[0]!
        color.pixelFormat = view.colorPixelFormat
        // 乗算済みアルファで合成する
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineState = try device.makeRenderPipelineState(descriptor: desc)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else {
            throw NSError(domain: "catcam", code: 2, userInfo: [NSLocalizedDescriptionKey: "texture cache unavailable"])
        }
        textureCache = cache
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = commandQueue.makeCommandBuffer() else { return }

        let scene = source.scene
        // アバターは窓より先に、カメラと同じ大きさのテクスチャへ描いておく
        var avatarTexture: MTLTexture?
        if avatarOn, let avatar, let pb = scene.pixelBuffer {
            avatarTexture = avatar.encode(cmd, pose: scene.avatar,
                                          width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        }
        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        var cvTexture: CVMetalTexture?
        if let pb = scene.pixelBuffer {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, .bgra8Unorm, w, h, 0, &cvTexture)
            if let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) {
                let scale = Float(view.window?.backingScaleFactor ?? 2)
                var u = uniforms(viewport: view.drawableSize, camera: CGSize(width: w, height: h), scale: scale)
                let mask = updateMask(scene)
                u.hasMask = mask == nil || !(backgroundMode.needsPersonMask || catStyle != nil) ? 0 : 1
                u.bgMode = Float(backgroundMode.rawValue)
                u.avatarOn = avatarTexture == nil ? 0 : 1
                if let catStyle {
                    u.filterOn = 1
                    u.style = catStyle.gpu
                }
                var rigs = scene.rigs.prefix(RigGPU.maxCount).map(RigGPU.init)
                u.rigCount = Float(rigs.count)
                rigs += Array(repeating: RigGPU(), count: RigGPU.maxCount - rigs.count)
                var instances = self.instances(for: scene, uniforms: u)
                if !instances.isEmpty,
                   let buffer = device.makeBuffer(bytes: &instances, length: MemoryLayout<WindowInstance>.stride * instances.count) {
                    encoder.setRenderPipelineState(pipelineState)
                    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
                    encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&rigs, length: MemoryLayout<RigGPU>.stride * rigs.count, index: 2)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.setFragmentTexture(mask ?? texture, index: 1)
                    encoder.setFragmentTexture(cats?.texture ?? texture, index: 2)
                    encoder.setFragmentTexture(avatarTexture ?? texture, index: 3)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
                }
            }
        }
        encoder.endEncoding()
        cmd.present(drawable)
        // GPU が使い終わるまでカメラのバッファを保持する
        cmd.addCompletedHandler { _ in _ = cvTexture }
        cmd.commit()
        source.stats.recordRender()
    }

    private func updateMask(_ scene: Scene) -> MTLTexture? {
        guard let pb = scene.personMask else { return nil }
        if scene.personMaskVersion == maskVersion, let maskTexture { return maskTexture }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if maskTexture?.width != w || maskTexture?.height != h {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
            desc.usage = .shaderRead
            maskTexture = device.makeTexture(descriptor: desc)
        }
        guard let maskTexture else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(pb) {
            maskTexture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                                withBytes: base, bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        maskVersion = scene.personMaskVersion
        return maskTexture
    }

    /// カメラ映像を画面いっぱいに（はみ出す側を切って）対応付ける
    private func uniforms(viewport: CGSize, camera: CGSize, scale: Float) -> Uniforms {
        let screenAspect = viewport.width / viewport.height, camAspect = camera.width / camera.height
        var k = SIMD2<Float>(1, 1)
        if camAspect > screenAspect {
            k.x = Float(screenAspect / camAspect)
        } else {
            k.y = Float(camAspect / screenAspect)
        }
        return Uniforms(
            viewport: SIMD2(Float(viewport.width), Float(viewport.height)),
            camK: k, camB: (SIMD2(1, 1) - k) / 2,
            titleH: 22 * scale, radius: 9 * scale, shadow: 18 * scale,
            mirror: mirror ? 1 : 0, scale: scale, camSize: SIMD2(Float(camera.width), Float(camera.height))
        )
    }

    private func instances(for scene: Scene, uniforms u: Uniforms) -> [WindowInstance] {
        if fullFrame {
            // 角の丸みとタイトルバーが画面の外に出るよう少し大きくする
            let r = u.radius
            return [WindowInstance(frame: SIMD4(-r, 0, u.viewport.x + 2 * r, u.viewport.y + r), params: SIMD4(1, 0, 0, 0))]
        }
        var out: [WindowInstance] = []
        func add(_ r: Rect, alpha: Double, kind: Float, minSize: Float, cat: CatMatcher.Match? = nil) {
            guard alpha > 0.01 else { return }
            let frame = screenFrame(r, u, minSize: minSize * u.scale)
            var w = WindowInstance(frame: frame, params: SIMD4(Float(alpha), kind, 0, 0))
            if let cat, let entry = cats?.index.entries[cat.index] {
                // 形はカメラ座標で選んでいるので、画面を左右反転して表示するなら猫も反転させる
                w.params.z = 1
                w.params.w = cat.mirrored != mirror ? 1 : 0
                w.catUV = SIMD4(Float(entry.uv.x), Float(entry.uv.y), Float(entry.uv.w), Float(entry.uv.h))
                w.catLocal = Self.fit(catAspect: entry.uv.w / entry.uv.h, into: Double(frame.z / frame.w))
            }
            out.append(w)
        }
        for t in scene.tracks {
            add(t.rect, alpha: t.alpha, kind: 0, minSize: 36, cat: scene.cats[t.id])
        }
        for f in scene.faceTracks {
            add(f.rect, alpha: f.alpha, kind: 1, minSize: 80)
        }
        // はみ出し部分の小窓は顔ウィンドウの上に重ねる
        for f in scene.faceFillTracks {
            add(f.rect, alpha: f.alpha, kind: 0, minSize: 24)
        }
        return out
    }

    /// 猫を中身いっぱいに引き伸ばす。ただし縦横の歪みは 1.25 倍までにし、超える分は余白にする
    private static func fit(catAspect: Double, into windowAspect: Double) -> SIMD4<Float> {
        let ratio = windowAspect / catAspect, limit = 1.25
        if ratio > limit {
            let w = limit / ratio
            return SIMD4(Float((1 - w) / 2), 0, Float(w), 1)
        }
        if ratio < 1 / limit {
            let h = ratio * limit
            return SIMD4(0, Float(1 - h), 1, Float(h))  // 縦に余る時は下に寄せる（床に立つ見た目）
        }
        return SIMD4(0, 0, 1, 1)
    }

    private func screenFrame(_ r: Rect, _ u: Uniforms, minSize: Float) -> SIMD4<Float> {
        let x = mirror ? 1 - r.x - r.w : r.x
        var origin = (SIMD2(Float(x), Float(r.y)) - u.camB) / u.camK * u.viewport
        var size = SIMD2(Float(r.w), Float(r.h)) / u.camK * u.viewport
        // 小さすぎる塊は中心を保ったまま最小サイズに広げる
        let grown = SIMD2(max(size.x, minSize), max(size.y, minSize))
        origin -= (grown - size) / 2
        size = grown
        return SIMD4(origin.x, origin.y, size.x, size.y)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Instance { float4 frame; float4 params; float4 catUV; float4 catLocal; };
    struct Style { float4 furBase; float4 furHighlight; float4 eye; float4 earInner; float4 nose; float4 line; float4 whisker; };
    struct Uniforms {
        float2 viewport; float2 camK; float2 camB;
        float titleH; float radius; float shadow; float mirror; float scale; float hasMask;
        float bgMode; float filterOn; float rigCount; float avatarOn;
        float2 camSize; float2 pad2;
        Style style;
    };
    struct Rig { float4 eyeL; float4 eyeR; float4 frame; float4 noseMouth; float4 misc; float4 earL; float4 earR; float4 tips; };
    struct VOut { float4 position [[position]]; float2 pixel; uint inst [[flat]]; };

    // タイトルバー込みのウィンドウ全体の矩形
    static float4 bodyRect(Instance i, constant Uniforms &u) {
        return float4(i.frame.x, i.frame.y - u.titleH, i.frame.z, i.frame.w + u.titleH);
    }

    static float sdRoundBox(float2 p, float2 c, float2 hs, float r) {
        float2 q = abs(p - c) - hs + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    // ---- 猫フィルタ ----

    static float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    static float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 w = f * f * (3 - 2 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), w.x),
                   mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), w.x), w.y);
    }

    static float fill(float d, float aa) { return 1 - smoothstep(-aa, aa, d); }

    // 縦に伸ばしたノイズで毛の筋を作り、カメラの明るさで陰影を付ける（体の立体感は元映像から借りる）
    static float3 furColor(float2 px, float l, constant Style &st) {
        // 細い毛の筋（縦長のノイズ）を控えめに乗せ、毛束の大きいムラで明るさを揺らす
        float strands = 0.6 * vnoise(px * float2(0.6, 0.06)) + 0.4 * vnoise(px * float2(1.4, 0.15));
        float clump = vnoise(px * 0.04);
        return st.furBase.rgb + st.furHighlight.rgb * pow(l, 1.6) * (0.75 + 0.35 * strands + 0.3 * clump);
    }

    // 人物マスクを読む位置を毛の筋ごとに上下へずらし、輪郭を毛羽立たせる
    static float2 furFuzz(float2 px) {
        return float2((vnoise(px * 0.12) - 0.5) * 5, (vnoise(float2(px.x * 0.5, px.y * 0.08)) - 0.5) * 10);
    }

    static float sdSegment(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
    }

    static float sdTriangle(float2 p, float2 p0, float2 p1, float2 p2) {
        float2 e0 = p1 - p0, e1 = p2 - p1, e2 = p0 - p2;
        float2 v0 = p - p0, v1 = p - p1, v2 = p - p2;
        float2 pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
        float2 pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
        float2 pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
        float s = sign(e0.x * e2.y - e0.y * e2.x);
        float2 d = min(min(float2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
                           float2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))),
                           float2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)));
        return -sqrt(d.x) * sign(d.y);
    }

    static void drawEar(float2 p, float2 inner, float2 outer, float2 tip, float d, constant Style &st,
                        thread float3 &col, thread float &alpha) {
        float a = fill(sdTriangle(p, inner, tip, outer) + 0.03 * d, 1.0);
        if (a <= 0) return;
        // 内側の薄い色は、付け根寄りに縮めた三角形
        float2 c = (inner + outer + tip) / 3 - (tip - (inner + outer) * 0.5) * 0.08;
        float ai = fill(sdTriangle(c + (p - c) / 0.58, inner, tip, outer) * 0.58, 2.0) * 0.9;
        float3 fur = furColor(p, 0.45, st);
        col = mix(col, mix(fur, st.earInner.rgb * (0.7 + 0.5 * vnoise(p * float2(0.3, 0.06))), ai), a);
        alpha = max(alpha, a);
    }

    // 縦長の瞳孔のアーモンド形の目。人の目の位置に、人より大きめに描く
    static void drawEye(float2 p, float4 e, float2 ax, float2 up, float d, constant Style &st, thread float3 &col) {
        float2 q = p - e.xy;
        float2 l = float2(dot(q, ax), dot(q, up));
        float a = 0.27 * d;
        float open = clamp(e.w, 0.0, 1.0);
        float b = a * 0.82 * max(open, 0.06);
        float de = (length(float2(l.x / a, l.y / b)) - 1) * b;
        float inEye = fill(de, 1.0);
        if (inEye > 0) {
            float rr = length(float2(l.x / a, l.y / (a * 0.82)));
            float3 iris = mix(st.eye.rgb * 1.15, st.eye.rgb * 0.6, smoothstep(0.15, 1.0, rr));
            iris *= 0.88 + 0.12 * sin(atan2(l.y, l.x) * 26.0);
            float pw = a * (0.12 + 0.1 * (1 - open)), ph = a * 0.78;
            iris = mix(iris, float3(0.01), fill((length(float2(l.x / pw, l.y / ph)) - 1) * pw, 1.0));
            iris = mix(iris, float3(1), fill(length(l - float2(-0.28 * a, 0.3 * a)) - 0.11 * a, 1.0) * 0.9);
            iris = mix(iris, float3(0.0), smoothstep(-0.12 * a, 0.0, de) * 0.85);
            col = mix(col, iris, inEye);
        }
        if (open < 0.3) {
            // 閉じた目は下向きの弧
            float t = clamp(l.x / a, -1.0, 1.0);
            float dl = length(float2(l.x - t * a, l.y + 0.12 * a * (1 - t * t)));
            col = mix(col, st.line.rgb, fill(dl - 0.035 * a, 1.0) * (1 - open / 0.3));
        }
    }

    static void drawCatFace(float2 p, Rig r, constant Style &st, thread float3 &col, thread float &alpha) {
        float d = r.misc.x;
        float2 mid = (r.eyeL.xy + r.eyeR.xy) * 0.5;
        if (length(p - mid) > 3.0 * d) return;
        float2 ax = r.frame.xy, up = r.frame.zw;

        drawEar(p, r.earL.xy, r.earL.zw, r.tips.xy, d, st, col, alpha);
        drawEar(p, r.earR.xy, r.earR.zw, r.tips.zw, d, st, col, alpha);
        drawEye(p, r.eyeL, ax, up, d, st, col);
        drawEye(p, r.eyeR, ax, up, d, st, col);

        // 鼻から下は鼻先を原点にした顔の座標で描く
        float2 q = p - r.noseMouth.xy;
        float2 l = float2(dot(q, ax), dot(q, up));
        float lw = 0.014 * d + 0.6;

        // 口を開けたら口の中を見せる
        float open = r.misc.z;
        if (open > 0.05) {
            float2 c = float2(0, -0.24 * d);
            float2 hs = float2(0.15 * d, 0.2 * d * open + 0.01 * d);
            float dm = (length((l - c) / hs) - 1) * min(hs.x, hs.y);
            float3 inside = mix(float3(0.22, 0.03, 0.06), float3(0.78, 0.36, 0.42), smoothstep(c.y, c.y - hs.y, l.y) * 0.8);
            col = mix(col, inside, fill(dm, 1.0));
        }
        // ω の口
        float dl = sdSegment(l, float2(0, -0.04 * d), float2(0, -0.13 * d));
        for (int s = -1; s <= 1; s += 2) {
            float2 c = float2(0.075 * d * s, -0.13 * d);
            float arc = abs(length(l - c) - 0.075 * d);
            dl = min(dl, l.y < c.y ? arc : 1e5);
        }
        col = mix(col, st.line.rgb, fill(dl - lw, 1.0));

        // 鼻（逆三角形・上側にだけ光を入れる）
        float dn = sdTriangle(l, float2(-0.12 * d, 0.07 * d), float2(0.12 * d, 0.07 * d), float2(0, -0.04 * d)) - 0.02 * d;
        float3 nose = st.nose.rgb + 0.18 * smoothstep(0.0, 0.07 * d, l.y);
        col = mix(col, nose, fill(dn, 1.0));

        // ヒゲ: 左右 3 本ずつ、外へ向かって少し垂れる
        for (int s = -1; s <= 1; s += 2) {
            for (int k = -1; k <= 1; k++) {
                float2 a0 = float2(0.18 * d * s, -0.09 * d - 0.045 * d * k);
                float2 dir = normalize(float2(s, -0.22 * k));
                float2 a1 = a0 + dir * 0.5 * d - float2(0, 0.03 * d);
                float2 a2 = a0 + dir * 1.0 * d - float2(0, 0.12 * d);
                float dw = min(sdSegment(l, a0, a1), sdSegment(l, a1, a2));
                float t = clamp(dot(l - a0, dir) / d, 0.0, 1.0);
                float w = fill(dw - (0.006 * d + 0.4) * (1 - 0.6 * t), 0.8) * (1 - t * t) * 0.85;
                col = mix(col, st.whisker.rgb, w);
                alpha = max(alpha, w);
            }
        }
    }

    vertex VOut window_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              constant Instance *inst [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
        float4 b = bodyRect(inst[iid], u);
        // 影の分だけ広げた四角形を描き、内外の判定はフラグメントで行う
        float2 lo = b.xy - u.shadow;
        float2 hi = b.xy + b.zw + u.shadow + float2(0, u.shadow * 0.5);
        const float2 corners[6] = { float2(0,0), float2(1,0), float2(0,1), float2(1,0), float2(1,1), float2(0,1) };
        float2 p = mix(lo, hi, corners[vid]);
        VOut o;
        o.pixel = p;
        o.inst = iid;
        o.position = float4(p.x / u.viewport.x * 2 - 1, 1 - p.y / u.viewport.y * 2, 0, 1);
        return o;
    }

    fragment float4 window_fragment(VOut in [[stage_in]], constant Instance *inst [[buffer(0)]],
                                    constant Uniforms &u [[buffer(1)]], texture2d<float> cam [[texture(0)]],
                                    texture2d<float> personMask [[texture(1)]], texture2d<float> catAtlas [[texture(2)]],
                                    constant Rig *rigs [[buffer(2)]], texture2d<float> avatarTex [[texture(3)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        Instance i = inst[in.inst];
        float alpha = i.params.x;
        bool hasCat = i.params.z > 0.5;
        float4 b = bodyRect(i, u);
        float2 c = b.xy + b.zw * 0.5, hs = b.zw * 0.5;

        float d = sdRoundBox(in.pixel, c, hs, u.radius);
        float inside = 1 - smoothstep(-0.5 * u.scale, 0.5 * u.scale, d);
        float ds = sdRoundBox(in.pixel, c + float2(0, u.shadow * 0.3), hs, u.radius);
        float shadow = 0.45 * (1 - smoothstep(-u.shadow * 0.3, u.shadow, ds));

        float3 col;
        float contentAlpha = 1;
        if (in.pixel.y < i.frame.y) {
            // タイトルバーと信号ボタン（非アクティブ色）
            col = float3(0.16, 0.16, 0.17);
            float cy = b.y + u.titleH * 0.5;
            for (int k = 0; k < 3; k++) {
                float2 dc = float2(b.x + u.scale * (13 + 20 * k), cy);
                float dot = 1 - smoothstep(5.5 * u.scale, 6.5 * u.scale, length(in.pixel - dc));
                col = mix(col, float3(0.36, 0.36, 0.38), dot);
            }
            // 中身との境目の線
            col = mix(col, float3(0.05), step(i.frame.y - u.scale, in.pixel.y));
        } else {
            float2 uv = in.pixel / u.viewport * u.camK + u.camB;
            if (u.mirror > 0.5) uv.x = 1 - uv.x;
            float3 camCol = cam.sample(s, uv).rgb;
            float2 px = uv * u.camSize;
            bool filt = u.filterOn > 0.5;
            // 人物の部分に出す色。猫フィルタなら毛並み
            float3 person = camCol;
            if (filt) {
                // 陰影はぼかした明るさから取る。そのままだと人の目鼻立ちや服の柄が毛並みに透けて見える
                float l = 0;
                for (int k = 0; k < 8; k++) {
                    float ang = 6.2831853 * (float(k) + 0.5) / 8.0;
                    l += dot(cam.sample(s, uv + 0.014 * float2(cos(ang), sin(ang) * 16.0 / 9.0)).rgb, float3(0.299, 0.587, 0.114));
                }
                person = furColor(px, l / 8.0, u.style);
            }
            col = camCol;
            float m = 1;
            bool masked = false;
            if (u.avatarOn > 0.5) {
                // 3D アバター: 人物の代わりにアバターを出す。人物の切り抜きは使わない
                float4 av = avatarTex.sample(s, uv);
                person = av.rgb;
                m = av.a;
                masked = true;
            } else if (u.hasMask > 0.5) {
                // 猫に差し替えるウィンドウでは人物を消し、背景だけにする
                float2 muv = filt ? uv + furFuzz(px) / u.camSize : uv;
                m = hasCat ? 0.0 : smoothstep(0.3, 0.7, personMask.sample(s, muv).r);
                masked = true;
            }
            if (masked) {
                int mode = int(u.bgMode + 0.5);
                if (mode == 0) {
                    // 透明: 人物だけ
                    col = person;
                    contentAlpha = m;
                } else if (mode == 1) {
                    // すりガラス: 暗く薄く残してウィンドウの形は見せる
                    col = mix(float3(0.08, 0.08, 0.09), person, m);
                    contentAlpha = mix(0.22, 1.0, m);
                } else if (mode == 3) {
                    // そのまま: 背景はカメラ映像（猫フィルタ・アバターの時だけここに来る）
                    col = mix(camCol, person, m);
                } else {
                    // ぼかし: 周囲 12 点の平均（2 重の輪）
                    float3 acc = 0;
                    for (int k = 0; k < 12; k++) {
                        float ang = 6.2831853 * float(k) / 6.0;
                        float rad = k < 6 ? 0.012 : 0.024;
                        acc += cam.sample(s, uv + rad * float2(cos(ang), sin(ang) * 16.0 / 9.0)).rgb;
                    }
                    col = mix(acc / 12.0, person, m);
                }
            }
            if (filt) {
                for (int k = 0; k < int(u.rigCount + 0.5); k++) drawCatFace(px, rigs[k], u.style, col, contentAlpha);
            }
            if (hasCat) {
                float2 local = (in.pixel - i.frame.xy) / i.frame.zw;
                float2 cl = (local - i.catLocal.xy) / i.catLocal.zw;
                if (all(cl >= 0.0) && all(cl <= 1.0)) {
                    if (i.params.w > 0.5) cl.x = 1 - cl.x;
                    float4 cat = catAtlas.sample(s, i.catUV.xy + cl * i.catUV.zw);
                    col = mix(col, cat.rgb, cat.a);
                    contentAlpha = cat.a + contentAlpha * (1 - cat.a);
                }
            }
        }

        float a = inside * alpha * contentAlpha;
        float body = inside * alpha;
        return float4(col * a, a + shadow * (1 - body) * alpha);
    }
    """
}

extension Rect {
    /// 各辺を幅・高さの `f` 倍ずつ広げる
    func padded(_ f: Double) -> Rect {
        Rect(x: x - w * f, y: y - h * f, w: w * (1 + 2 * f), h: h * (1 + 2 * f))
    }
}
