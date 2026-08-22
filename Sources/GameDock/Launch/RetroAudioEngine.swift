import Foundation
import AVFoundation
import CLibretro

/*
 * Lock-free interleaved (L,R) ring buffer handed to AVAudioEngine.
 *
 * The producer is the libretro core thread; the consumer is AVAudioEngine's
 * realtime render thread. That thread runs priority-boosted on the shared
 * audio server — blocking it (e.g. on an NSLock held by lower-priority work)
 * underruns the OUTPUT DEVICE for the whole system, glitching every app's
 * audio. So this ring uses acquire/release atomics (gd_atomics.h) and never
 * takes a lock on either side. Classic SPSC: one producer, one consumer,
 * monotonic indices, power-of-two capacity with index masking.
 */
final class RetroAudioRingBuffer {
    private let storage: UnsafeMutablePointer<Int16>
    private let writeIdxPtr: UnsafeMutablePointer<Int64>
    private let readIdxPtr: UnsafeMutablePointer<Int64>
    private let capacitySamples: Int   // power of two
    private let mask: Int64
    let channels = 2

    init(capacitySamples: Int) {
        // Round up to a power of two so monotonic indices can be masked.
        var cap = 2
        while cap < max(capacitySamples, 2) { cap <<= 1 }
        self.capacitySamples = cap
        self.mask = Int64(cap - 1)
        self.storage = UnsafeMutablePointer<Int16>.allocate(capacity: cap)
        self.storage.initialize(repeating: 0, count: cap)
        self.writeIdxPtr = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        self.readIdxPtr = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        self.writeIdxPtr.pointee = 0
        self.readIdxPtr.pointee = 0
    }

    deinit {
        storage.deinitialize(count: capacitySamples)
        storage.deallocate()
        writeIdxPtr.deallocate()
        readIdxPtr.deallocate()
    }

    /// Core thread (batch): append interleaved samples; drop-oldest on
    /// overflow so the newest audio always wins. Returns `frames` consumed
    /// (mirrors shim_audio_batch contract: we always accept everything).
    @discardableResult
    func writeBatch(_ ptr: UnsafePointer<Int16>?, frames: Int) -> Int {
        guard let ptr, frames > 0 else { return frames }
        let needed = frames * channels
        var w = gd_atomic_load_i64(writeIdxPtr)
        var r = gd_atomic_load_i64(readIdxPtr)
        let excess = needed - (capacitySamples - Int(w - r))
        if excess > 0 {
            r += Int64(excess)   // drop oldest to make room
            gd_atomic_store_i64(readIdxPtr, r)
        }
        for i in 0..<needed {
            storage[Int((w &+ Int64(i)) & mask)] = ptr[i]
        }
        gd_atomic_store_i64(writeIdxPtr, w &+ Int64(needed))
        return frames
    }

    /// Core thread (single sample pair).
    func writeSample(_ l: Int16, _ r: Int16) {
        var w = gd_atomic_load_i64(writeIdxPtr)
        var rd = gd_atomic_load_i64(readIdxPtr)
        if channels - (capacitySamples - Int(w - rd)) > 0 {
            rd += Int64(channels)
            gd_atomic_store_i64(readIdxPtr, rd)
        }
        storage[Int(w & mask)] = l
        storage[Int((w &+ 1) & mask)] = r
        gd_atomic_store_i64(writeIdxPtr, w &+ Int64(channels))
    }

    /// Audio render thread (RT-safe: no locks, no allocation). Copies up to
    /// `maxSamples` interleaved samples, zero-filling silence on underrun.
    /// Returns samples written (always `maxSamples`).
    func read(_ out: UnsafeMutablePointer<Int16>, maxSamples: Int) -> Int {
        let w = gd_atomic_load_i64(writeIdxPtr)
        let r = gd_atomic_load_i64(readIdxPtr)
        let n = min(maxSamples, Int(w - r))
        for i in 0..<n {
            out[i] = storage[Int((r &+ Int64(i)) & mask)]
        }
        for i in n..<maxSamples {
            out[i] = 0
        }
        gd_atomic_store_i64(readIdxPtr, r &+ Int64(n))
        return maxSamples
    }

    /// Samples currently buffered. Diagnostic only — safe from any thread.
    var availableSamples: Int {
        Int(gd_atomic_load_i64(writeIdxPtr) - gd_atomic_load_i64(readIdxPtr))
    }

    /// Only call while BOTH threads are quiescent (engine stopped, core
    /// joined) — e.g. between sessions. There is no synchronization here.
    func reset() {
        writeIdxPtr.pointee = 0
        readIdxPtr.pointee = 0
    }
}

/// Pull-based audio source: AVAudioSourceNode drains the ring buffer.
///
/// The source node uses Apple's standard render format (float32, NON-
/// interleaved) rather than an exotic Int16-interleaved one: that keeps the
/// engine graph free of extra format converters, which historically misbehave
/// and add load on the RT thread. The Int16→float conversion happens inline
/// in the block against preallocated scratch — no allocations, no locks on
/// the realtime path.
final class RetroAudioEngine {
    /// Generous scratch for one render callback (real callbacks are typically
    /// 256–1024 frames). If a device ever asks for more we clamp and accept a
    /// short read rather than allocate.
    private static let maxFramesPerCallback = 4096

    private let engine = AVAudioEngine()
    private let ring: RetroAudioRingBuffer
    private var sourceNode: AVAudioSourceNode?
    private var scratch: UnsafeMutablePointer<Int16>
    private var isRunning = false
    private let sampleRate: Double
    /// Serializes start()/stop(): they're called from different threads (start
    /// on a background queue from EmulatorSession.start, stop on main from
    /// teardown) and must never interleave — a stop racing a start could leave
    /// the engine running after detach, or start after teardown.
    private let lifecycleQueue = DispatchQueue(label: "com.leblanc.audio.lifecycle")

    init(sampleRate: Double, ring: RetroAudioRingBuffer) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 44_100.0
        self.ring = ring
        self.scratch = UnsafeMutablePointer<Int16>.allocate(
            capacity: Self.maxFramesPerCallback * 2
        )
    }

    func start() throws {
        var thrown: Error?
        lifecycleQueue.sync {
            do { try startLocked() } catch { thrown = error }
        }
        if let thrown { throw thrown }
    }

    private func startLocked() throws {
        guard !isRunning else { return }

        // Standard non-interleaved float32 — what AVAudioSourceNode handles
        // natively; the engine converts to the device rate downstream.
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        )!

        let sourceNode = AVAudioSourceNode(format: format, renderBlock: renderBlock())
        self.sourceNode = sourceNode

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Detach so a later retry doesn't double-attach the node.
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
            self.sourceNode = nil
            throw error
        }
        isRunning = true
    }

    func stop() {
        lifecycleQueue.sync {
            guard isRunning else { return }
            engine.stop()
            if let sourceNode {
                engine.detach(sourceNode)
                self.sourceNode = nil
            }
            isRunning = false
        }
    }

    private func renderBlock() -> AVAudioSourceNodeRenderBlock {
        // Captured once: blocks run on the RT thread, so everything they
        // touch must already exist — no allocation, no locking in here.
        let ring = self.ring
        let scratch = self.scratch
        let maxFrames = Self.maxFramesPerCallback
        let channels = ring.channels
        return { _, _, frameCount, audioBufferList -> OSStatus in
            let frames = min(Int(frameCount), maxFrames)
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            // Standard format: one deinterleaved float32 buffer per channel.
            guard abl.count >= channels,
                  frames > 0,
                  Int(abl[0].mDataByteSize) >= frames * MemoryLayout<Float>.size,
                  Int(abl[1].mDataByteSize) >= frames * MemoryLayout<Float>.size,
                  let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            _ = ring.read(scratch, maxSamples: frames * channels)
            let scale: Float = 1.0 / 32768.0
            for i in 0..<frames {
                left[i] = Float(scratch[i * 2]) * scale
                right[i] = Float(scratch[i * 2 + 1]) * scale
            }
            return noErr
        }
    }

    deinit {
        stop()
        scratch.deallocate()
    }
}
