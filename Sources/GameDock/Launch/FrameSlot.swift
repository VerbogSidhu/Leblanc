import Foundation

/// Thread-safe slot holding the most recently converted video frame.
///
/// The core thread writes (via `push`) and the render thread reads (via
/// `withLatest`). Only the latest frame is retained; duplicate frames
/// (`data == nil`) are skipped silently, matching GET_CAN_DUPE semantics.
final class FrameSlot {
    private let lock = NSLock()
    private var buffer: UnsafeMutableRawPointer? = nil
    private var capacity = 0

    private(set) var width = 0
    private(set) var height = 0
    private(set) var pitch = 0
    private(set) var format: RetroPixelFormat = .xrgb8888
    /// Incremented per real (non-dupe) frame copy. Lets the renderer skip
    /// re-upload when nothing changed.
    private(set) var seq: UInt64 = 0

    /// Core thread: copy `src` (raw rows of `pitch` bytes) and convert to
    /// tightly-packed BGRA. Reallocs only when the byte count grows.
    func push(_ src: UnsafeRawPointer?, width: Int, height: Int, pitch: Int, format: RetroPixelFormat) {
        guard let src, width > 0, height > 0, pitch > 0 else {
            // Dupe frame (data == nil): keep the last frame, do not bump seq.
            return
        }

        lock.lock()
        defer { lock.unlock() }

        let dstBytes = width * height * 4
        if buffer == nil || capacity < dstBytes {
            buffer?.deallocate()
            buffer = UnsafeMutableRawPointer.allocate(byteCount: dstBytes, alignment: 16)
            capacity = dstBytes
        }

        guard let dst = buffer else { return }

        PixelConverter.convert(
            format: format,
            src: src,
            width: width,
            height: height,
            srcRowBytes: pitch,
            dst: dst
        )

        self.width = width
        self.height = height
        self.pitch = pitch
        self.format = format
        self.seq += 1
    }

    /// Render thread: run `body` with the current frame under the slot lock.
    /// Returns nil if no frame has been pushed yet.
    func withLatest<T>(_ body: (UnsafeRawPointer, Int, Int, Int, UInt64) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer, width > 0, height > 0 else { return nil }
        return body(buffer, width, height, width * 4, seq)
    }

    /// Convenience for the self-test: latest seq without exposing the pointer.
    var latestSeq: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return seq
    }

    deinit {
        buffer?.deallocate()
        buffer = nil
    }
}
