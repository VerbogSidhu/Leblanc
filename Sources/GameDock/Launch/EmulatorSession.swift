import Foundation
import CLibretro
import Darwin

// MARK: - @convention(c) callback globals (never capturing)
//
// These are top-level non-capturing functions routed to the single active
// session via EmulatorSession.active. The shim stores them by reference.

private func gd_video(_ ctx: UnsafeMutableRawPointer?, _ data: UnsafeRawPointer?,
                      _ width: UInt32, _ height: UInt32, _ pitch: Int) {
    EmulatorSession.active?.handleVideo(data, width: Int(width), height: Int(height), pitch: pitch)
}

private func gd_audio(_ ctx: UnsafeMutableRawPointer?, _ left: Int16, _ right: Int16) {
    EmulatorSession.active?.handleAudioSample(left, right)
}

private func gd_audio_batch(_ ctx: UnsafeMutableRawPointer?, _ data: UnsafePointer<Int16>?,
                            _ frames: Int) -> Int {
    return EmulatorSession.active?.handleAudioBatch(data, frames: frames) ?? frames
}

private func gd_input_poll(_ ctx: UnsafeMutableRawPointer?) {
    EmulatorSession.active?.handleInputPoll()
}

private func gd_input_state(_ ctx: UnsafeMutableRawPointer?, _ port: UInt32,
                            _ device: UInt32, _ index: UInt32, _ id: UInt32) -> Int16 {
    return EmulatorSession.active?.handleInputState(port: port, device: device, index: index, id: id) ?? 0
}

private func gd_environment(_ ctx: UnsafeMutableRawPointer?, _ cmd: UInt32,
                            _ data: UnsafeMutableRawPointer?) -> Bool {
    return EmulatorSession.active?.handleEnvironment(cmd: cmd, data: data) ?? false
}

private func gd_log(_ ctx: UnsafeMutableRawPointer?, _ level: Int32, _ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    let text = String(cString: message)
    switch level {
    case 0: Log.debug(text)
    case 2: Log.warn(text)
    case 3: Log.error(text)
    default: Log.info(text)
    }
}

// MARK: - EmulatorSession

/// Orchestrates a single libretro core: loads it, registers callbacks,
/// drives retro_run() on its own thread, and exposes frame/audio/input state.
final class EmulatorSession {
    enum State { case idle, loaded, running, stopping, stopped }

    // ABI constants from the canonical libretro header.
    static let RETRO_API_VERSION: UInt32 = 1
    static let RETRO_DEVICE_JOYPAD: UInt32 = 1
    static let RETRO_DEVICE_ANALOG: UInt32 = 5
    static let RETRO_DEVICE_ID_ANALOG_X: UInt32 = 0
    static let RETRO_DEVICE_ID_ANALOG_Y: UInt32 = 1
    static let RETRO_DEVICE_ID_JOYPAD_RIGHT: UInt32 = 7

    /// The single session currently driving a core (process-wide).
    private static var _active: EmulatorSession?
    private static let activeLock = NSLock()

    static var active: EmulatorSession? {
        get {
            activeLock.lock()
            defer { activeLock.unlock() }
            return _active
        }
    }

    static func setActive(_ session: EmulatorSession?) {
        activeLock.lock()
        defer { activeLock.unlock() }
        _active = session
    }

    let corePath: String
    let romPath: String?
    let romData: Data?

    /// Display name for the running game (shown in the emulator overlay).
    let title: String

    private(set) var core: RetroCore?
    private(set) var state = State.idle
    private(set) var systemInfo: retro_system_info?
    private(set) var avInfo: retro_system_av_info?

    let frameSlot = FrameSlot()
    let audioRing: RetroAudioRingBuffer
    let inputSnapshot = InputSnapshot()

    // Stable env string buffers.
    private var environment = RetroEnvironment()

    private var audioEngine: RetroAudioEngine?

    private var runThread: Thread?
    private let stopRequestedFlag = ManagedAtomic(false)
    private let threadDone = DispatchSemaphore(value: 0)

    var loadedGame: Bool = false

    init(corePath: String, romPath: String?, romData: Data?, title: String = "") {
        self.corePath = corePath
        self.romPath = romPath
        self.romData = romData
        self.title = title
        self.audioRing = RetroAudioRingBuffer(capacitySamples: 44_100 * 2)
    }

    // MARK: - Load

    enum SessionError: Error {
        case loadGameFailed
    }

    func load() throws {
        try AppPaths.ensureDirectories()

        let core = RetroCore(path: corePath)
        try core.load()
        self.core = core

        // Register callbacks before retro_init.
        let cb = shim_callbacks_t(
            ctx: nil,
            video: gd_video,
            audio: gd_audio,
            audio_batch: gd_audio_batch,
            input_poll: gd_input_poll,
            input_state: gd_input_state,
            environment: gd_environment,
            log: gd_log
        )
        shim_set_callbacks(cb)

        shim_install()

        // Make this session the active one BEFORE retro_init so the core's
        // environment/input callbacks during init and load_game can reach us.
        EmulatorSession.setActive(self)

        // Environment strings must be stable BEFORE retro_init: cores query
        // GET_SYSTEM_DIRECTORY / GET_SAVE_DIRECTORY / GET_LIBRETRO_PATH
        // during init and load_game.
        environment.systemDirectory = AppPaths.appSupport.path
        environment.saveDirectory = AppPaths.savesDir.path
        environment.libretroPath = corePath

        guard let retroInit = core.retroInit else { fatalError("retro_init missing") }
        retroInit()

        // System info.
        var info = retro_system_info()
        core.retroGetSystemInfo?(&info)
        self.systemInfo = info
        Log.info("core: \(info.library_name.map { String(cString: $0) } ?? "?") v\(info.library_version.map { String(cString: $0) } ?? "?") need_fullpath=\(info.need_fullpath)")

        // AV info.
        var av = retro_system_av_info()
        core.retroGetSystemAVInfo?(&av)
        self.avInfo = av
        environment.targetRefreshRate = Float(av.timing.fps > 0 ? av.timing.fps : 60.0)

        // Load game.
        let needFullpath = info.need_fullpath
        var loaded = false
        if needFullpath {
            if let romPath {
                var gi = retro_game_info()
                let cstr = Array(romPath.utf8CString)
                loaded = cstr.withUnsafeBufferPointer { buf in
                    gi.path = buf.baseAddress
                    return core.retroLoadGame?(&gi) ?? false
                }
            } else {
                loaded = false
            }
        } else if let romData {
            loaded = romData.withUnsafeBytes { (rb: UnsafeRawBufferPointer) -> Bool in
                guard let base = rb.baseAddress else { return false }
                var gi = retro_game_info()
                gi.data = UnsafeRawPointer(base)
                gi.size = romData.count
                return core.retroLoadGame?(&gi) ?? false
            }
        } else if let romPath, let data = try? Data(contentsOf: URL(fileURLWithPath: romPath)), !data.isEmpty {
            // Cores with need_fullpath == false still get the ROM bytes when a
            // path was provided (we read it ourselves).
            loaded = data.withUnsafeBytes { (rb: UnsafeRawBufferPointer) -> Bool in
                guard let base = rb.baseAddress else { return false }
                var gi = retro_game_info()
                gi.data = UnsafeRawPointer(base)
                gi.size = data.count
                return core.retroLoadGame?(&gi) ?? false
            }
        } else if environment.supportNoGame {
            loaded = core.retroLoadGame?(nil) ?? false
        } else {
            loaded = false
        }

        guard loaded else {
            throw SessionError.loadGameFailed
        }
        loadedGame = true

        core.retroSetControllerPortDevice?(0, EmulatorSession.RETRO_DEVICE_JOYPAD)

        // The core may set a pixel format during load; default stays the last
        // one set (or xrgb8888). frameSlot's format is updated per push anyway.
        state = .loaded
    }

    // MARK: - Run loop

    func start() {
        guard state == .loaded else { return }
        state = .running
        stopRequestedFlag.store(false)

        // Audio engine: start on a background thread if we have a valid rate.
        let sampleRate = avInfo?.timing.sample_rate ?? 44_100.0
        if sampleRate > 0 {
            let engine = RetroAudioEngine(sampleRate: sampleRate, ring: audioRing)
            self.audioEngine = engine
            DispatchQueue.global(qos: .userInitiated).async {
                do { try engine.start() } catch { Log.warn("audio start failed: \(error)") }
            }
        }

        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "GameDock.Core"
        t.qualityOfService = .userInitiated
        runThread = t
        t.start()
    }

    private func runLoop() {
        let fps = (avInfo?.timing.fps ?? 60.0) > 0 ? (avInfo?.timing.fps ?? 60.0) : 60.0
        let interval = 1.0 / fps

        var next = DispatchTime.now()
        while !stopRequestedFlag.load() {
            core?.retroRun?()

            // Pace against a monotonic clock, avoiding drift.
            let nsPerFrame = UInt64(max(interval, 0.001) * 1_000_000_000)
            next = next + DispatchTimeInterval.nanoseconds(nsPerFrame > Int.max ? Int.max : Int(nsPerFrame))
            let now = DispatchTime.now()
            let remaining = now.uptimeNanoseconds < next.uptimeNanoseconds
                ? next.uptimeNanoseconds - now.uptimeNanoseconds
                : 0
            if remaining > 0 {
                Thread.sleep(forTimeInterval: Double(remaining) / 1_000_000_000)
            } else {
                // Fell behind; resync.
                next = now
            }

            if environment.shutdownRequested {
                environment.shutdownRequested = false
                stopRequestedFlag.store(true)
            }
        }
        threadDone.signal()
    }

    func requestStop() {
        guard state == .running || state == .loaded else { return }
        state = .stopping
        stopRequestedFlag.store(true)
        // Join the core thread (never runs teardown on the core thread itself).
        if runThread != nil {
            threadDone.wait()
        }
        state = .stopped
    }

    // MARK: - Teardown
    //
    // Must run after the core thread has joined, on a different thread.
    // dlclose must be LAST (unmap after retro_deinit no longer references it).
    func teardown() {
        audioEngine?.stop()
        audioEngine = nil

        if loadedGame {
            core?.retroUnloadGame?()
            loadedGame = false
        }
        core?.retroDeinit?()
        core?.unload()
        core = nil

        EmulatorSession.setActive(nil)
        state = .idle
    }

    // MARK: - Callback handlers (core thread)

    func handleVideo(_ data: UnsafeRawPointer?, width: Int, height: Int, pitch: Int) {
        frameSlot.push(data, width: width, height: height, pitch: pitch, format: environment.pixelFormat)
    }

    func handleAudioSample(_ left: Int16, _ right: Int16) {
        audioRing.writeSample(left, right)
    }

    func handleAudioBatch(_ data: UnsafePointer<Int16>?, frames: Int) -> Int {
        return audioRing.writeBatch(data, frames: frames)
    }

    func handleInputPoll() {
        // No-op: InputSnapshot is written by the main thread.
    }

    func handleInputState(port: UInt32, device: UInt32, index: UInt32, id: UInt32) -> Int16 {
        switch device {
        case EmulatorSession.RETRO_DEVICE_JOYPAD:
            return inputSnapshot.readButton(port: Int(port), id: Int(id))
        case EmulatorSession.RETRO_DEVICE_ANALOG:
            // id 0 = X, 1 = Y; index 0 = left stick, 1 = right stick.
            let axis = id == EmulatorSession.RETRO_DEVICE_ID_ANALOG_X ? 0 : 1
            return inputSnapshot.readAnalog(port: Int(port), stick: Int(index), axis: axis)
        default:
            return 0
        }
    }

    func handleEnvironment(cmd: UInt32, data: UnsafeMutableRawPointer?) -> Bool {
        return environment.handle(cmd: cmd, data: data)
    }
}

/// Minimal atomic boolean (thread-safe flag without depending on stdatomics).
final class ManagedAtomic {
    private let lock = NSLock()
    private var value: Bool

    init(_ initial: Bool) {
        self.value = initial
    }

    func store(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
