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
    /// Renderer-owned scratch copy of the latest frame. Filled under the
    /// FrameSlot lock (a plain memcpy) so the slow texture upload happens
    /// after the lock is released — no hitching while the core thread waits.
    private var staging: UnsafeMutableRawPointer?
    private var stagingCapacity = 0
    /// One shared uniform buffer reused every frame (created lazily).
    private var uniformBuffer: MTLBuffer?
    private var uniformBufferFailedLogged = false

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

        // Copy the latest frame into our staging buffer under the slot lock
        // (memcpy only); the texture upload happens after the lock is freed.
        var pendingUpload: (width: Int, height: Int, rowBytes: Int, seq: UInt64)?
        frameSlot.withLatest { ptr, width, height, rowBytes, seq in
            guard seq != lastSeq else { return }
            let bytes = height * rowBytes
            if staging == nil || stagingCapacity < bytes {
                staging?.deallocate()
                staging = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
                stagingCapacity = bytes
            }
            guard let staging else { return }
            memcpy(staging, ptr, bytes)
            pendingUpload = (width, height, rowBytes, seq)
        }

        if let upload = pendingUpload {
            ensureTexture(width: upload.width, height: upload.height)
            if let texture, let staging {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, upload.width, upload.height),
                    mipmapLevel: 0,
                    withBytes: staging,
                    bytesPerRow: upload.rowBytes
                )
                lastSeq = upload.seq
            }
        }

        if let texture {
            // Aspect-fit letterbox: scale the quad so the frame's aspect ratio
            // is preserved within the view's aspect ratio.
            let viewSize = view.drawableSize
            guard viewSize.width > 0, viewSize.height > 0 else {
                encoder.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }
            let viewAspect = viewSize.width / viewSize.height
            let frameAspect = CGFloat(textureWidth) / CGFloat(textureHeight)

            var scale: SIMD2<Float>
            if frameAspect > viewAspect {
                scale = SIMD2(1.0, Float(viewAspect / frameAspect))
            } else {
                scale = SIMD2(Float(frameAspect / viewAspect), 1.0)
            }

            if uniformBuffer == nil {
                uniformBuffer = device.makeBuffer(
                    length: MemoryLayout<FrameUniforms>.size,
                    options: .storageModeShared
                )
                if uniformBuffer == nil, !uniformBufferFailedLogged {
                    uniformBufferFailedLogged = true
                    Log.error("MetalRenderer: uniform buffer allocation failed — draws skipped")
                }
            }

            if let uniformBuffer {
                var uniforms = FrameUniforms(scale: scale)
                memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<FrameUniforms>.size)
                encoder.setRenderPipelineState(pipelineState)
                encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(samplerState(), index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
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

    deinit {
        staging?.deallocate()
        staging = nil
    }
}
