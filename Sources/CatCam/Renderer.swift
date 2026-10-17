import CatCore
import CoreVideo
import MetalKit

/// GPU に渡す偽ウィンドウ 1 枚分。Metal 側の `Instance` と同じレイアウト
private struct WindowInstance {
    /// 中身（タイトルバーを除く）の矩形。ピクセル、左上原点
    var frame: SIMD4<Float>
    var alpha: Float
    var kind: Float
    var pad: SIMD2<Float> = .zero
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
}

/// 全画面オーバーレイに偽ウィンドウを描く。全ウィンドウが同じカメラテクスチャを参照するのでコピーは発生しない
final class Renderer: NSObject, MTKViewDelegate {
    var mirror: Bool
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
              let cmd = commandQueue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        let scene = source.scene
        var cvTexture: CVMetalTexture?
        if let pb = scene.pixelBuffer {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, .bgra8Unorm, w, h, 0, &cvTexture)
            if let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) {
                let scale = Float(view.window?.backingScaleFactor ?? 2)
                var u = uniforms(viewport: view.drawableSize, camera: CGSize(width: w, height: h), scale: scale)
                let mask = updateMask(scene)
                u.hasMask = mask == nil ? 0 : 1
                var instances = self.instances(for: scene, uniforms: u)
                if !instances.isEmpty,
                   let buffer = device.makeBuffer(bytes: &instances, length: MemoryLayout<WindowInstance>.stride * instances.count) {
                    encoder.setRenderPipelineState(pipelineState)
                    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
                    encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.setFragmentTexture(mask ?? texture, index: 1)
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
            mirror: mirror ? 1 : 0, scale: scale
        )
    }

    private func instances(for scene: Scene, uniforms u: Uniforms) -> [WindowInstance] {
        var out: [WindowInstance] = []
        func add(_ r: Rect, alpha: Double, kind: Float, minSize: Float) {
            guard alpha > 0.01 else { return }
            out.append(WindowInstance(frame: screenFrame(r, u, minSize: minSize * u.scale), alpha: Float(alpha), kind: kind))
        }
        for t in scene.tracks {
            // 残像: 古いほど薄く、奥に描く
            let n = Double(t.history.count + 1)
            for (i, h) in t.history.enumerated() {
                add(h, alpha: t.alpha * 0.6 * Double(i + 1) / n, kind: 0, minSize: 36)
            }
            add(t.rect, alpha: t.alpha, kind: 0, minSize: 36)
        }
        for f in scene.faceTracks {
            add(f.rect, alpha: f.alpha, kind: 1, minSize: 80)
        }
        return out
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

    struct Instance { float4 frame; float alpha; float kind; float2 pad; };
    struct Uniforms {
        float2 viewport; float2 camK; float2 camB;
        float titleH; float radius; float shadow; float mirror; float scale; float hasMask;
    };
    struct VOut { float4 position [[position]]; float2 pixel; uint inst [[flat]]; };

    // タイトルバー込みのウィンドウ全体の矩形
    static float4 bodyRect(Instance i, constant Uniforms &u) {
        return float4(i.frame.x, i.frame.y - u.titleH, i.frame.z, i.frame.w + u.titleH);
    }

    static float sdRoundBox(float2 p, float2 c, float2 hs, float r) {
        float2 q = abs(p - c) - hs + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
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
                                    texture2d<float> personMask [[texture(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        Instance i = inst[in.inst];
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
            col = cam.sample(s, uv).rgb;
            if (u.hasMask > 0.5) {
                // 人物以外は暗いすりガラス風にして、背景の部屋を見せない
                float m = smoothstep(0.3, 0.7, personMask.sample(s, uv).r);
                col = mix(float3(0.08, 0.08, 0.09), col, m);
                contentAlpha = mix(0.22, 1.0, m);
            }
        }

        float a = inside * i.alpha * contentAlpha;
        float body = inside * i.alpha;
        return float4(col * a, a + shadow * (1 - body) * i.alpha);
    }
    """
}

extension Rect {
    /// 各辺を幅・高さの `f` 倍ずつ広げる
    func padded(_ f: Double) -> Rect {
        Rect(x: x - w * f, y: y - h * f, w: w * (1 + 2 * f), h: h * (1 + 2 * f))
    }
}
