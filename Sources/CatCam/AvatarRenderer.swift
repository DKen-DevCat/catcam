import CatCore
import Metal
import simd

/// アバターを、カメラ映像と同じ大きさの透明なテクスチャに描く。窓はこれを人物の代わりに覗く
final class AvatarRenderer {
    private struct Uniforms {
        var size: SIMD2<Float>
        var origin: SIMD2<Float>
        var scale: Float
        var mouthOpen: Float
        var pad: SIMD2<Float> = .zero
    }

    let model: AvatarModel
    private(set) var target: MTLTexture?
    private var depth: MTLTexture?
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    init(model: AvatarModel, device: MTLDevice) throws {
        self.model = model
        self.device = device
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "avatar_vertex")
        desc.fragmentFunction = library.makeFunction(name: "avatar_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.depthAttachmentPixelFormat = .depth32Float
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: ds) else {
            throw NSError(domain: "catcam", code: 12, userInfo: [NSLocalizedDescriptionKey: "depth state unavailable"])
        }
        depthState = state
    }

    /// `pose` が nil なら透明のまま
    func encode(_ cmd: MTLCommandBuffer, pose: AvatarPose?, width: Int, height: Int) -> MTLTexture? {
        prepareTargets(width: width, height: height)
        guard let target, let depth else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        if let pose {
            var bones = model.skeleton.skinMatrices(local: pose.local, stretch: pose.stretch)
            var u = Uniforms(size: SIMD2(Float(width), Float(height)), origin: pose.origin, scale: pose.scale, mouthOpen: pose.mouthOpen)
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            enc.setCullMode(.back)
            enc.setFrontFacing(.counterClockwise)
            enc.setVertexBuffer(model.vertexBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&bones, length: MemoryLayout<simd_float4x4>.stride * bones.count, index: 1)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
            enc.setFragmentTexture(model.texture, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: model.indexCount, indexType: .uint32,
                                      indexBuffer: model.indexBuffer, indexBufferOffset: 0)
        }
        enc.endEncoding()
        return target
    }

    private func prepareTargets(width: Int, height: Int) {
        guard target?.width != width || target?.height != height else { return }
        let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        c.usage = [.renderTarget, .shaderRead]
        c.storageMode = .private
        target = device.makeTexture(descriptor: c)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .private
        depth = device.makeTexture(descriptor: d)
    }

    // 頂点は float × 22（export_avatar.py を参照）。座標は Blender のまま（Z 上・正面 -Y）
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float2 size; float2 origin; float scale; float mouthOpen; float2 pad; };
    struct VOut { float4 position [[position]]; float3 normal; float2 uv; float4 color; float gloss; };

    vertex VOut avatar_vertex(uint vid [[vertex_id]], const device float *v [[buffer(0)]],
                              constant float4x4 *bones [[buffer(1)]], constant Uniforms &u [[buffer(2)]]) {
        const device float *p = v + vid * 22;
        float3 pos = float3(p[0], p[1], p[2]);
        // 口は人の口の開きに合わせて上下に伸ばす（上の縁はそのまま、下へ開く）
        if (p[13] > 0.5) pos.z = 1.1 + (pos.z - 1.1) * (1.0 + 3.0 * u.mouthOpen);
        float4x4 m = bones[int(p[14])] * p[18] + bones[int(p[15])] * p[19] + bones[int(p[16])] * p[20] + bones[int(p[17])] * p[21];
        float4 w = m * float4(pos, 1);
        float3 n = normalize((m * float4(p[3], p[4], p[5], 0)).xyz);
        float2 px = float2(u.origin.x + w.x * u.scale, u.origin.y - w.z * u.scale);
        VOut o;
        // 奥行きは Y（正面 -Y が手前）
        o.position = float4(px.x / u.size.x * 2 - 1, 1 - px.y / u.size.y * 2, clamp(0.5 + w.y * 0.1, 0.0, 1.0), 1);
        o.normal = n;
        o.uv = float2(p[6], p[7]);
        o.color = float4(p[8], p[9], p[10], p[11]);
        o.gloss = p[12];
        return o;
    }

    fragment float4 avatar_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float3 base = in.color.w > 0.5 ? tex.sample(s, in.uv).rgb : in.color.rgb;
        float3 n = normalize(in.normal);
        // 正面やや左上からの光 + 環境光。艶のある所（目・鼻・口）だけ鏡面反射を足す
        float3 l = normalize(float3(-0.35, -1.0, 0.7));
        float diff = 0.5 + 0.6 * max(dot(n, l), 0.0);
        float3 h = normalize(l + float3(0, -1, 0));
        float spec = pow(max(dot(n, h), 0.0), 60.0) * in.gloss;
        return float4(base * diff + spec, 1);
    }
    """
}
