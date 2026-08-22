import Foundation
import AVFoundation

/// Lock-protected interleaved (L,R) ring buffer fed by the core thread's
/// audio callbacks and drained by the audio render thread.
final class RetroAudioRingBuffer {
    private let lock = NSLock()
    private var storage: [Int16]
    private var readIdx = 0
    private var writeIdx = 0
    private var count = 0          // number of samples (not frames)
    let channels = 2

    init(capacitySamples: Int) {
        self.storage = Array(repeating: 0, count: max(capacitySamples, 2))
    }

    /// Core thread (batch): append interleaved samples; drop-oldest on overflow.
    /// Returns frames consumed (mirrors shim_audio_batch contract).
    @discardableResult
    func writeBatch(_ ptr: UnsafePointer<Int16>?, frames: Int) -> Int {
        guard let ptr, frames > 0 else { return frames }
        lock.lock()
        defer { lock.unlock() }

        let sampleCount = frames * channels
        for i in 0..<sampleCount {
            storage[writeIdx] = ptr[i]
            writeIdx = (writeIdx + 1) % storage.count
            if count < storage.count {
                count += 1
            } else {
                // drop oldest
                readIdx = (readIdx + 1) % storage.count
            }
        }
        return frames
    }

    /// Core thread (single sample).
    func writeSample(_ l: Int16, _ r: Int16) {
        lock.lock()
        defer { lock.unlock() }
        storage[writeIdx] = l
        writeIdx = (writeIdx + 1) % storage.count
        if count < storage.count {
            count += 1
        } else {
            readIdx = (readIdx + 1) % storage.count
        }
        storage[writeIdx] = r
        writeIdx = (writeIdx + 1) % storage.count
        if count < storage.count {
            count += 1
        } else {
            readIdx = (readIdx + 1) % storage.count
        }
    }

    /// Audio render thread: copy up to `maxSamples` interleaved samples,
    /// zero-filling (silence) on underflow. Returns samples written.
    func read(_ out: UnsafeMutablePointer<Int16>, maxSamples: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let toRead = min(maxSamples, count)
        for i in 0..<toRead {
            out[i] = storage[readIdx]
            readIdx = (readIdx + 1) % storage.count
        }
        count -= toRead
        if toRead < maxSamples {
            for i in toRead..<maxSamples {
                out[i] = 0
            }
        }
        return maxSamples
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        readIdx = 0
        writeIdx = 0
        count = 0
    }

    var availableSamples: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Pull-based audio source: AVAudioSourceNode drains the ring buffer.
final class RetroAudioEngine {
    private let engine = AVAudioEngine()
    private let ring: RetroAudioRingBuffer
    private var sourceNode: AVAudioSourceNode?
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

        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: true
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
        // Capture ring weakly-ish: source node blocks are invoked on the audio
        // thread, so we retain ring directly (session outlives the engine).
        let ring = self.ring
        return { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let dataPtr = abl[0].mData else { return noErr }
            let buf = dataPtr.assumingMemoryBound(to: Int16.self)
            let maxSamples = Int(frameCount) * 2
            _ = ring.read(buf, maxSamples: maxSamples)
            return noErr
        }
    }

    deinit {
        stop()
    }
}
