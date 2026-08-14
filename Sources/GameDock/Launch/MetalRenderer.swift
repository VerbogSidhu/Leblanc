import Foundation
import Metal
import MetalKit

/// Swift mirror of the MSL FrameUniforms struct (must match layout).
private struct FrameUniforms {
    var scale: SIMD2<Float>
}

/// Owns the Metal device/queue/pipeline/texture and draws the latest frame
/// (aspect-fit letterboxed) into an MTKView.
final class MetalRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var textureWidth = 0
    private var textureHeight = 0
    private var lastSeq: UInt64 = 0

    weak var frameSlot: FrameSlot?

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut {
        float4 pos [[position]];
        float2 uv;
    };

    struct FrameUniforms {
        // aspect-fit scale applied to the fullscreen quad (1,1 = stretch)
        float2 scale;
    };

    vertex VOut vs(uint vid [[vertex_id]],
                   constant FrameUniforms &u [[buffer(0)]]) {
        VOut out;
        float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        float2 uvs[4] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 0.0)
        };
        out.pos = float4(positions[vid] * u.scale, 0.0, 1.0);
        out.uv = uvs[vid];
        return out;
    }

    fragment float4 fs(VOut in [[stage_in]],
                       texture2d<float> tex [[texture(0)]],
                       sampler s [[sampler(0)]]) {
        return tex.sample(s, in.uv);
    }
    """

    private var cachedSampler: MTLSamplerState?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        guard let library = try? device.makeLibrary(source: MetalRenderer.shaderSource, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vs")
        descriptor.fragmentFunction = library.makeFunction(name: "fs")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.pipelineState = pipeline
    }

    func draw(in view: MTKView) {
        guard let frameSlot else { return }
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }

        // Copy latest frame under the slot lock and upload it.
        var frameSize: (width: Int, height: Int)?
        frameSlot.withLatest { ptr, width, height, rowBytes, seq in
            if seq != lastSeq {
                ensureTexture(width: width, height: height)
                if let texture {
                    texture.replace(
                        region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: ptr,
                        bytesPerRow: rowBytes
                    )
                    lastSeq = seq
                }
            }
            frameSize = (width, height)
        }

        if let texture, let frameSize {
            // Aspect-fit letterbox: scale the quad so the frame's aspect ratio
            // is preserved within the view's aspect ratio.
            let viewSize = view.drawableSize
            guard viewSize.width > 0, viewSize.height > 0 else { return }
            let viewAspect = viewSize.width / viewSize.height
            let frameAspect = CGFloat(frameSize.width) / CGFloat(frameSize.height)

            var scale: SIMD2<Float>
            if frameAspect > viewAspect {
                scale = SIMD2(1.0, Float(viewAspect / frameAspect))
            } else {
                scale = SIMD2(Float(frameAspect / viewAspect), 1.0)
            }

            var uniforms = FrameUniforms(scale: scale)
            let uniformBuffer = device.makeBuffer(bytes: &uniforms, length: MemoryLayout<FrameUniforms>.size, options: .storageModeShared)!

            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samplerState(), index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func ensureTexture(width: Int, height: Int) {
        guard width != textureWidth || height != textureHeight || texture == nil else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        texture = device.makeTexture(descriptor: descriptor)
        textureWidth = width
        textureHeight = height
    }

    private func samplerState() -> MTLSamplerState {
        if let cached = cachedSampler { return cached }
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        let state = device.makeSamplerState(descriptor: desc)!
        cachedSampler = state
        return state
    }
}
