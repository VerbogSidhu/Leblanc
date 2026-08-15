import Foundation
import CLibretro
import Darwin
import OpenGL

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

// Hardware-render callbacks we hand to the core inside the retro_hw_render_callback
// struct (SET_HW_RENDER). Non-capturing closures; route through EmulatorSession.active.

private let gd_get_framebuffer: retro_hw_get_current_framebuffer_t = {
    UInt(EmulatorSession.active?.glBridge?.fbo ?? 0)
}

private let gd_noop_proc: retro_proc_address_t = {}

private let gd_get_proc_address: retro_hw_get_proc_address_t = { name in
    guard let name else { return gd_noop_proc }
    let symbol = String(cString: name)
    // macOS exports every GL function as a real symbol — resolve directly so
    // the core calls real code (a no-op stub corrupts return values and crashes
    // cores like PPSSPP during context_reset).
    if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) {
        return unsafeBitCast(sym, to: retro_proc_address_t.self)
    }
    // Extension functions: CGLGetProcAddress (not exposed to Swift; dlsym it).
    if let cglSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGLGetProcAddress") {
        typealias CGLGetProcAddressFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
        let cglGetProcAddress = unsafeBitCast(cglSymbol, to: CGLGetProcAddressFn.self)
        if let ptr = cglGetProcAddress(name) {
            return unsafeBitCast(ptr, to: retro_proc_address_t.self)
        }
    }
    Log.debug("GLBridge: no proc for \(symbol)")
    return gd_noop_proc
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
    let inputSnapshot: InputSnapshot

    // Hardware-render bridge (PPSSPP / melonDS-GL).
    private(set) var glBridge: GLHardwareBridge?
    private var hwContextReset: retro_hw_context_reset_t?
    private var hwContextDestroy: retro_hw_context_destroy_t?
    private var hwRenderActive = false
    private var hwContextResetDone = false
    private var hwWidth = 0
    private var hwHeight = 0
    private var hwReadbackBuffer: UnsafeMutableRawPointer?
    private var hwReadbackCapacity = 0

    // Stable env string buffers.
    private var environment = RetroEnvironment()

    private var audioEngine: RetroAudioEngine?

    private var runThread: Thread?
    private let stopRequestedFlag = ManagedAtomic(false)
    private let threadDone = DispatchSemaphore(value: 0)
    /// True when the core thread failed to stop (join timed out) — teardown
    /// must then skip dlclose/deinit to avoid unmapping a live core.
    private var coreThreadStuck = false

    /// UI-requested core actions, executed on the core thread after the next
    /// retro_run (retro_serialize/unserialize/reset must never race retro_run).
    private enum CoreCommand { case saveState, loadState, reset }
    private var pendingCommand: CoreCommand?
    private let commandLock = NSLock()
    /// Paused (sleep/lid close): the run loop skips retro_run until resumed.
    private let pausedFlag = ManagedAtomic(false)

    var loadedGame: Bool = false

    /// RetroAchievements client (nil unless RA credentials are configured).
    private(set) var rcService: RCClientService?

    /// RetroAchievements toast queue (owned here for stable UI observation,
    /// pushed-to by the rcService's core-thread event handler).
    let raToasts = RAToastModel()

    /// Optional RA console id + settings, supplied by the GUI launch path.
    /// The self-test leaves these nil so RA stays disabled headlessly.
    private let raConsoleID: UInt32?
    private let raSettings: SettingsStore?

    init(corePath: String, romPath: String?, romData: Data?, title: String = "", inputSnapshot: InputSnapshot? = nil,
         raConsoleID: UInt32? = nil, raSettings: SettingsStore? = nil) {
        self.corePath = corePath
        self.romPath = romPath
        self.romData = romData
        self.title = title
        // The GUI path passes ControllerManager.snapshot so gamepad input
        // reaches the core; the self-test passes its own (or none).
        self.inputSnapshot = inputSnapshot ?? InputSnapshot()
        self.audioRing = RetroAudioRingBuffer(capacitySamples: 44_100 * 2)
        self.raConsoleID = raConsoleID
        self.raSettings = raSettings
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

        // Cores report 0x0 av_info before load; re-query now that the game is
        // mounted (PPSSPP also announces the real size via SET_GEOMETRY).
        var avAfter = retro_system_av_info()
        core.retroGetSystemAVInfo?(&avAfter)
        if avAfter.geometry.base_width > 0, avAfter.geometry.base_height > 0 {
            self.avInfo = avAfter
            environment.targetRefreshRate = Float(avAfter.timing.fps > 0 ? avAfter.timing.fps : 60.0)
            Log.info("core av_info after load: \(avAfter.geometry.base_width)x\(avAfter.geometry.base_height) "
                + "fps=\(avAfter.timing.fps)")
        }

        // The core may set a pixel format during load; default stays the last
        // one set (or xrgb8888). frameSlot's format is updated per push anyway.
        state = .loaded

        startRetroAchievements()
    }

    // MARK: - RetroAchievements

    /// Creates + logs in the RA client if credentials are configured, and caches
    /// libretro memory regions for runtime achievement reads.
    private func startRetroAchievements() {
        guard let raConsoleID, let raSettings else { return }
        guard let service = RCClientService.make(settings: raSettings, consoleID: raConsoleID, toasts: raToasts) else {
            Log.debug("RA: credentials not configured — achievements disabled")
            return
        }
        service.create()
        service.applySettings(raSettings)
        if let core {
            service.cacheRegions(from: core)
        }
        service.beginLogin()
        service.beginLoadGame(path: romPath, data: romData ?? Data())
        self.rcService = service
        Log.info("RA: client created for console \(raConsoleID)")
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
            // Paused (sleep/lid close): skip core work entirely until resumed.
            if pausedFlag.load() {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            // Hardware-render cores draw into our GL FBO; prepare it first.
            if hwRenderActive, let bridge = glBridge {
                let (fw, fh) = renderTargetSize()
                if fw > 0, fh > 0 {
                    bridge.prepareFrame(width: fw, height: fh)
                }
                // PPSSPP sets up its GL resources in context_reset, which must
                // run AFTER load_game returns (its context object is only
                // finalized then) — defer it to just before the first frame.
                if !hwContextResetDone, let reset = hwContextReset {
                    hwContextResetDone = true
                    Log.info("GLBridge: deferred context_reset before first frame")
                    bridge.runContextReset(reset)
                }
            }

            core?.retroRun?()

            // Pump RetroAchievements after each frame (runtime reads + async
            // server-response delivery both happen on this core thread).
            rcService?.doFrame()

            // Read the rendered frame back from GL and push it through the
            // standard frame pipeline (bgraz → PixelConverter → Metal).
            if hwRenderActive, let bridge = glBridge {
                let (fw, fh) = renderTargetSize()
                if fw > 0, fh > 0 {
                    readBackHardwareFrame(bridge: bridge, width: fw, height: fh)
                }
            }

            // Execute any UI-requested core action now that retro_run has
            // finished (save/load/reset must not race the core).
            if let cmd = takeCommand() {
                switch cmd {
                case .saveState: runSaveState()
                case .loadState: runLoadState()
                case .reset:
                    core?.retroReset?()
                    pushToast("Game reset")
                }
            }

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
        // Timeout so a stuck core can't freeze the UI.
        if runThread != nil {
            let result = threadDone.wait(timeout: .now() + 2.0)
            if result == .timedOut {
                coreThreadStuck = true
                Log.warn("EmulatorSession: core thread did not stop within 2s — skipping dlclose to avoid UAF")
            }
        }
        state = .stopped
    }

    // MARK: - UI-requested core actions (save state / load state / reset)
    //
    // These queue a command executed on the core thread right after the next
    // retro_run — libretro serialization/reset must never run concurrently
    // with the core. Save files land in AppPaths.savesDir as <rom-stem>.state.

    func requestSaveState() { setCommand(.saveState) }
    func requestLoadState() { setCommand(.loadState) }
    func requestReset() { setCommand(.reset) }

    private func setCommand(_ cmd: CoreCommand) {
        commandLock.lock()
        pendingCommand = cmd
        commandLock.unlock()
    }

    private func takeCommand() -> CoreCommand? {
        commandLock.lock()
        defer { commandLock.unlock() }
        let cmd = pendingCommand
        pendingCommand = nil
        return cmd
    }

    private func runSaveState() {
        guard let core, let retroSerialize = core.retroSerialize,
              let retroSerializeSize = core.retroSerializeSize else {
            pushToast("Save states not supported by this core")
            return
        }
        let size = retroSerializeSize()
        guard size > 0, size < 512 * 1024 * 1024 else {
            pushToast("Save states not supported by this core")
            return
        }
        var data = Data(count: size)
        let ok = data.withUnsafeMutableBytes { (rb: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = rb.baseAddress else { return false }
            return retroSerialize(base, size)
        }
        guard ok, let url = stateFileURL() else {
            pushToast("Failed to save state")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            Log.info("EmulatorSession: state saved → \(url.lastPathComponent)")
            pushToast("State saved")
        } catch {
            Log.error("EmulatorSession: state save failed — \(error.localizedDescription)")
            pushToast("Failed to save state")
        }
    }

    private func runLoadState() {
        guard let core, let retroUnserialize = core.retroUnserialize,
              let url = stateFileURL(),
              let data = try? Data(contentsOf: url) else {
            pushToast("No saved state for this game")
            return
        }
        let ok = data.withUnsafeBytes { (rb: UnsafeRawBufferPointer) -> Bool in
            guard let base = rb.baseAddress else { return false }
            return retroUnserialize(base, data.count)
        }
        Log.info("EmulatorSession: state load \(ok ? "ok" : "failed") ← \(url.lastPathComponent)")
        pushToast(ok ? "State loaded" : "Failed to load state")
    }

    /// Deterministic state path: <rom-stem>.state under the saves dir.
    private func stateFileURL() -> URL? {
        let stem: String
        if let romPath {
            stem = ((romPath as NSString).deletingPathExtension as NSString).lastPathComponent
        } else {
            stem = title
        }
        let safe = stem.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return AppPaths.savesDir.appendingPathComponent("\(safe).state")
    }

    private func pushToast(_ text: String) {
        let toast = RAToast(title: text, kind: .status)
        DispatchQueue.main.async { [weak self] in
            self?.raToasts.push(toast)
        }
    }

    // MARK: - Pause / resume (sleep / lid close)

    /// Stops emulation work (core loop skips retro_run, audio engine stops).
    /// Used on NSWorkspace.willSleep; the core thread stays alive and resumes
    /// in place — no desync from a sleep cycle.
    func pause() {
        pausedFlag.store(true)
        audioEngine?.stop()
        Log.info("EmulatorSession: paused")
    }

    func resume() {
        pausedFlag.store(false)
        if let engine = audioEngine {
            DispatchQueue.global(qos: .userInitiated).async {
                do { try engine.start() } catch { Log.warn("audio resume failed: \(error)") }
            }
        }
        Log.info("EmulatorSession: resumed")
    }

    // MARK: - Teardown
    //
    // Must run after the core thread has joined, on a different thread.
    // dlclose must be LAST (unmap after retro_deinit no longer references it).
    func teardown() {
        audioEngine?.stop()
        audioEngine = nil

        if let rcService {
            rcService.unloadGame()
            rcService.destroy()
            self.rcService = nil
        }

        if hwRenderActive, let bridge = glBridge {
            bridge.runContextDestroy(hwContextDestroy)
        }

        if coreThreadStuck {
            // The core thread never stopped; unmapping the dylib or freeing GL
            // state under it would crash. Leak this session's core safely.
            EmulatorSession.setActive(nil)
            core = nil
            glBridge = nil
            hwRenderActive = false
            state = .idle
            return
        }

        if loadedGame {
            core?.retroUnloadGame?()
            loadedGame = false
        }
        core?.retroDeinit?()
        core?.unload()
        core = nil

        glBridge?.destroy()
        glBridge = nil
        hwContextReset = nil
        hwContextDestroy = nil
        hwRenderActive = false
        if let buf = hwReadbackBuffer {
            buf.deallocate()
        }
        hwReadbackBuffer = nil
        hwReadbackCapacity = 0

        EmulatorSession.setActive(nil)
        state = .idle
    }

    // MARK: - Callback handlers (core thread)

    func handleVideo(_ data: UnsafeRawPointer?, width: Int, height: Int, pitch: Int) {
        if let data {
            frameSlot.push(data, width: width, height: height, pitch: pitch, format: environment.pixelFormat)
        } else if hwRenderActive {
            // Core announces a completed GL frame (data == nil). Record the
            // render target size; the actual readback happens after retro_run.
            if width > 0, height > 0 {
                hwWidth = width
                hwHeight = height
            }
        }
    }

    /// Best-known render target size: video callback size → SET_GEOMETRY → av_info
    /// → current FBO size.
    private func renderTargetSize() -> (Int, Int) {
        let geometryW = environment.geometryWidth
        let geometryH = environment.geometryHeight
        let avW = Int(avInfo?.geometry.base_width ?? 0)
        let avH = Int(avInfo?.geometry.base_height ?? 0)
        let fboW = glBridge?.fboWidth ?? 0
        let fboH = glBridge?.fboHeight ?? 0
        let w = hwWidth > 0 ? hwWidth : (geometryW > 0 ? geometryW : (avW > 0 ? avW : fboW))
        let h = hwHeight > 0 ? hwHeight : (geometryH > 0 ? geometryH : (avH > 0 ? avH : fboH))
        return (max(w, 1), max(h, 1))
    }

    private func readBackHardwareFrame(bridge: GLHardwareBridge, width: Int, height: Int) {
        let needed = width * height * 4
        if hwReadbackBuffer == nil || hwReadbackCapacity < needed {
            hwReadbackBuffer?.deallocate()
            hwReadbackBuffer = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
            hwReadbackCapacity = needed
        }
        guard let hwReadbackBuffer else { return }
        bridge.readPixels(into: hwReadbackBuffer, width: width, height: height)
        frameSlot.push(
            hwReadbackBuffer, width: width, height: height,
            pitch: width * 4, format: .xrgb8888
        )
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
        if cmd == UInt32(RETRO_ENVIRONMENT_SET_HW_RENDER.rawValue) {
            return handleHWRenderRequest(data)
        }
        return environment.handle(cmd: cmd, data: data)
    }

    /// RETRO_ENVIRONMENT_SET_HW_RENDER: create a GL context + FBO for the core
    /// and hand it our get_current_framebuffer/get_proc_address callbacks.
    private func handleHWRenderRequest(_ data: UnsafeMutableRawPointer?) -> Bool {
        guard let data else { return false }
        let cbPtr = data.assumingMemoryBound(to: retro_hw_render_callback.self)
        let request = cbPtr.pointee
        Log.info("GLBridge: core requests HW render type=\(request.context_type.rawValue) "
            + "v\(request.version_major).\(request.version_minor) depth=\(request.depth)")

        // We only host OpenGL contexts. Decline Vulkan/D3D/etc so the core can
        // fall back (or error clearly) instead of us faking a wrong context.
        let supported = request.context_type == RETRO_HW_CONTEXT_OPENGL
            || request.context_type == RETRO_HW_CONTEXT_OPENGL_CORE
        guard supported else {
            Log.warn("GLBridge: unsupported HW context type \(request.context_type.rawValue) — declining")
            return false
        }

        if let old = glBridge {
            old.destroy()
            glBridge = nil
        }
        guard let bridge = GLHardwareBridge(
            contextType: Int32(request.context_type.rawValue),
            major: request.version_major,
            minor: request.version_minor
        ) else {
            Log.error("GLBridge: context creation failed")
            return false
        }
        bridge.requestedDepth = request.depth
        bridge.bottomLeftOrigin = request.bottom_left_origin
        glBridge = bridge
        hwRenderActive = true
        hwContextReset = request.context_reset
        hwContextDestroy = request.context_destroy

        // Fill the frontend-provided callbacks into the core's struct.
        cbPtr.pointee.get_current_framebuffer = gd_get_framebuffer
        cbPtr.pointee.get_proc_address = gd_get_proc_address

        // Do NOT call context_reset here: PPSSPP finalizes its graphics
        // context object only after load_game returns, and context_reset
        // virtual-calls into it (verified empirically: calling it inside this
        // env handler segfaults). Defer to just before the first retro_run.
        hwContextResetDone = false

        // Seed the FBO at a sensible size. PPSSPP renders at the FBO's size
        // and never announces its own (no SET_GEOMETRY, av_info stays 0x0),
        // so a 1x1 seed yields 1x1 output.
        let (seedW, seedH) = renderTargetSize()
        let w = seedW > 1 ? seedW : 480   // PSP native resolution fallback
        let h = seedH > 1 ? seedH : 272
        bridge.ensureFramebuffer(width: w, height: h)
        return true
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
