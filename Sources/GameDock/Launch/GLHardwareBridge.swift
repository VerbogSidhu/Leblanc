import AppKit
import CLibretro
import Foundation
import OpenGL
import OpenGL.GL3

/// Minimal OpenGL context + FBO bridge for cores that require hardware
/// rendering (PPSSPP, melonDS-GL). The core renders into our FBO on the core
/// thread; after `retro_run` we `glReadPixels` (BGRA) into a CPU buffer that
/// feeds the existing FrameSlot → PixelConverter → Metal pipeline.
///
/// This is the same architecture RetroArch uses on macOS (GL context for the
/// core, pixels cross into the Metal frontend) — simplified to a readback
/// instead of IOSurface interop, which is plenty for PSP-class resolutions and
/// keeps the whole render path in one place.
final class GLHardwareBridge {
    private var context: NSOpenGLContext?
    private var pixelFormat: NSOpenGLPixelFormat?

    private(set) var fbo: GLuint = 0
    private var colorTex: GLuint = 0
    private var depthRB: GLuint = 0
    private(set) var fboWidth = 0
    private(set) var fboHeight = 0
    /// Sticky: once an FBO allocation fails we stop retrying every frame
    /// (regen churn) — the bridge is dead until a new one is created.
    private var fboFailed = false

    var requestedDepth = false
    var bottomLeftOrigin = false

    var isReady: Bool { context != nil }

    init?(contextType: Int32, major: UInt32, minor: UInt32) {
        let profileValue: NSOpenGLPixelFormatAttribute
        if contextType == Int32(RETRO_HW_CONTEXT_OPENGL_CORE.rawValue) {
            profileValue = NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core)
            Log.info("GLBridge: core profile 3.2 (requested \(major).\(minor))")
        } else if contextType == Int32(RETRO_HW_CONTEXT_OPENGL.rawValue) {
            profileValue = NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersionLegacy)
            Log.info("GLBridge: legacy profile 2.1")
        } else {
            profileValue = NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core)
            Log.warn("GLBridge: unhandled context type \(contextType) — trying core 3.2")
        }

        let attrs: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile),
            profileValue,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), 24,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADepthSize), 24,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated),
            0,
        ]
        guard let pf = NSOpenGLPixelFormat(attributes: attrs) else {
            Log.error("GLBridge: no pixel format")
            return nil
        }
        pixelFormat = pf
        guard let ctx = NSOpenGLContext(format: pf, share: nil) else {
            Log.error("GLBridge: no context")
            return nil
        }
        context = ctx
    }

    // MARK: - Context

    /// Makes this context current on the calling thread (must be the thread
    /// that will run the core).
    func makeCurrent() {
        context?.makeCurrentContext()
    }

    /// Calls the core's context_reset callback (we must do this after creating
    /// the context, with it current).
    func runContextReset(_ reset: retro_hw_context_reset_t?) {
        guard let reset else { return }
        makeCurrent()
        reset()
    }

    // MARK: - Framebuffer

    /// Creates/recreates the FBO at the given size (bound when the core runs).
    @discardableResult
    func ensureFramebuffer(width: Int, height: Int) -> Bool {
        guard let context else { return false }
        guard width > 0, height > 0 else { return false }
        if fboFailed {
            // Sticky failure: no log here — prepareFrame() calls us every
            // frame and the original error was already reported once.
            return false
        }
        guard width != fboWidth || height != fboHeight || fbo == 0 else { return true }

        destroyFramebuffer()
        context.makeCurrentContext()

        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)

        glGenTextures(1, &colorTex)
        glBindTexture(GLenum(GL_TEXTURE_2D), colorTex)
        glTexImage2D(
            GLenum(GL_TEXTURE_2D), 0, GLint(GL_RGBA8),
            GLsizei(width), GLsizei(height), 0,
            GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil
        )
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), colorTex, 0)

        if requestedDepth {
            glGenRenderbuffers(1, &depthRB)
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), depthRB)
            glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_DEPTH_COMPONENT24), GLsizei(width), GLsizei(height))
            glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_DEPTH_ATTACHMENT), GLenum(GL_RENDERBUFFER), depthRB)
        }

        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            Log.error("GLBridge: FBO incomplete (status \(status)) — deleting objects, failing sticky")
            destroyFramebuffer()
            fboFailed = true
            return false
        }
        fboWidth = width
        fboHeight = height
        Log.info("GLBridge: FBO \(width)x\(height) ready (fbo=\(fbo))")
        return true
    }

    /// Binds the FBO + viewport; call before retro_run. Recreates the FBO if
    /// the render target size changed (cores may switch internal resolution).
    func prepareFrame(width: Int, height: Int) {
        guard let context else { return }
        if width != fboWidth || height != fboHeight || fbo == 0 {
            _ = ensureFramebuffer(width: width, height: height)
        }
        context.makeCurrentContext()
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glViewport(0, 0, GLsizei(width), GLsizei(height))
    }

    // MARK: - Readback

    /// Reads the rendered frame (BGRA, top-down) into dst (width*height*4 bytes).
    /// GL framebuffers are bottom-up, so rows are flipped here.
    func readPixels(into dst: UnsafeMutableRawPointer, width: Int, height: Int) {
        guard let context else { return }
        context.makeCurrentContext()
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), fbo)
        glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 1)
        glReadPixels(0, 0, GLsizei(width), GLsizei(height), GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), dst)

        // In-place vertical flip (GL origin is bottom-left).
        let rowBytes = width * 4
        let tmp = UnsafeMutableRawPointer.allocate(byteCount: rowBytes, alignment: 1)
        defer { tmp.deallocate() }
        for y in 0..<(height / 2) {
            let top = dst.advanced(by: y * rowBytes)
            let bottom = dst.advanced(by: (height - 1 - y) * rowBytes)
            memcpy(tmp, top, rowBytes)
            memcpy(top, bottom, rowBytes)
            memcpy(bottom, tmp, rowBytes)
        }
    }

    // MARK: - Teardown

    func runContextDestroy(_ destroy: retro_hw_context_destroy_t?) {
        guard let destroy else { return }
        makeCurrent()
        destroy()
    }

    func destroy() {
        if let context {
            context.makeCurrentContext()
            destroyFramebuffer()
            NSOpenGLContext.clearCurrentContext()
        }
        context = nil
        pixelFormat = nil
    }

    private func destroyFramebuffer() {
        if depthRB != 0 {
            glDeleteRenderbuffers(1, &depthRB)
            depthRB = 0
        }
        if colorTex != 0 {
            glDeleteTextures(1, &colorTex)
            colorTex = 0
        }
        if fbo != 0 {
            glDeleteFramebuffers(1, &fbo)
            fbo = 0
        }
        fboWidth = 0
        fboHeight = 0
    }

    deinit {
        if context != nil { destroy() }
    }
}
