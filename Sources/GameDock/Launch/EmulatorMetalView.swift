import Foundation
import MetalKit

/// NSView wrapper around an MTKView that forwards draw calls to MetalRenderer.
final class EmulatorMetalView: NSView, MTKViewDelegate {
    private let mtkView: MTKView
    var renderer: MetalRenderer?

    /// Reference to the session frame slot (for now, assigned manually).
    var frameSlot: FrameSlot? {
        didSet {
            renderer?.frameSlot = frameSlot
        }
    }

    override init(frame frameRect: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        let mtkView = MTKView(frame: frameRect, device: device)
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        self.mtkView = mtkView
        super.init(frame: frameRect)
        mtkView.delegate = self
        addSubview(mtkView)
        mtkView.autoresizingMask = [.width, .height]
        self.renderer = MetalRenderer()
        self.renderer?.frameSlot = frameSlot
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        mtkView.frame = bounds
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // no-op; renderer reads view.drawableSize each frame
    }

    func draw(in view: MTKView) {
        renderer?.draw(in: view)
    }
}
