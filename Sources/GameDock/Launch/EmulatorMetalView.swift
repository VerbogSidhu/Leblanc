import Foundation
import MetalKit

/// NSView wrapper around an MTKView that forwards draw calls to MetalRenderer.
/// When no Metal device exists (VM, broken driver), falls back to a software
/// CALayer blit of the latest frame instead of crashing.
final class EmulatorMetalView: NSView, MTKViewDelegate {
    private let mtkView: MTKView?
    private let fallbackView: FallbackFrameView?
    var renderer: MetalRenderer?

    /// Reference to the session frame slot (for now, assigned manually).
    var frameSlot: FrameSlot? {
        didSet {
            renderer?.frameSlot = frameSlot
            fallbackView?.frameSlot = frameSlot
        }
    }

    override init(frame frameRect: NSRect) {
        if let device = MTLCreateSystemDefaultDevice() {
            let mtkView = MTKView(frame: frameRect, device: device)
            mtkView.framebufferOnly = false
            mtkView.colorPixelFormat = .bgra8Unorm
            mtkView.preferredFramesPerSecond = 60
            self.mtkView = mtkView
            self.fallbackView = nil
            super.init(frame: frameRect)
            mtkView.delegate = self
            addSubview(mtkView)
            mtkView.autoresizingMask = [.width, .height]
            self.renderer = MetalRenderer()
            self.renderer?.frameSlot = frameSlot
        } else {
            // Software path: display-link-driven layer blit (no GPU scaling).
            Log.error("EmulatorMetalView: no Metal device — using software frame fallback")
            self.mtkView = nil
            let fallback = FallbackFrameView(frame: frameRect)
            self.fallbackView = fallback
            super.init(frame: frameRect)
            addSubview(fallback)
            fallback.autoresizingMask = [.width, .height]
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        mtkView?.frame = bounds
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // no-op; renderer reads view.drawableSize each frame
    }

    func draw(in view: MTKView) {
        renderer?.draw(in: view)
    }
}

/// Software frame presenter for Metal-less machines: copies the latest
/// FrameSlot frame (tightly-packed BGRA) into a CGImage on a 60 fps timer
/// and shows it aspect-fit in a plain CALayer.
final class FallbackFrameView: NSView {
    var frameSlot: FrameSlot? {
        didSet { lastSeq = 0 }
    }

    private var timer: Timer?
    private var lastSeq: UInt64 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.presentLatest()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    private func presentLatest() {
        guard let slot = frameSlot else { return }
        let seq = slot.latestSeq
        guard seq != lastSeq else { return }
        lastSeq = seq
        // FrameSlot memory is BGRA: byteOrder32Little + skipFirst reads the
        // little-endian word (X R G B) as skip-alpha-first RGB.
        guard let image = slot.withLatest({ ptr, width, height, _, _ -> CGImage? in
            guard let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }
            guard let dst = ctx.data else { return nil }
            memcpy(dst, ptr, width * height * 4)
            return ctx.makeImage()
        }) else { return }
        layer?.contents = image
    }
}
