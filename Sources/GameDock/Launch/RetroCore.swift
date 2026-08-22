import Foundation
import Darwin
import CLibretro

// MARK: - Function pointer typealiases
//
// ⚠️ ABI CRITICAL: these must match the typedefs in Sources/CLibretro's
// libretro.h / shim.h byte-for-byte. A value-preserving unsafeBitCast from a
// dlsym()'d symbol pointer to one of these types is only safe because both
// sides are pointers to @convention(c) functions with identical signatures.
// We use the C-imported struct types (retro_game_info, retro_system_info,
// retro_system_av_info) so the signatures are representable in @convention(c).

typealias RetroEnvironmentFn = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool
typealias RetroVideoRefreshFn = @convention(c) (UnsafeRawPointer?, UInt32, UInt32, Int) -> Void
typealias RetroAudioSampleFn = @convention(c) (Int16, Int16) -> Void
typealias RetroAudioSampleBatchFn = @convention(c) (UnsafePointer<Int16>?, Int) -> Int
typealias RetroInputPollFn = @convention(c) () -> Void
typealias RetroInputStateFn = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> Int16

typealias RetroSetEnvironmentFn = @convention(c) (@escaping RetroEnvironmentFn) -> Void
typealias RetroSetVideoRefreshFn = @convention(c) (@escaping RetroVideoRefreshFn) -> Void
typealias RetroSetAudioSampleFn = @convention(c) (@escaping RetroAudioSampleFn) -> Void
typealias RetroSetAudioBatchFn = @convention(c) (@escaping RetroAudioSampleBatchFn) -> Void
typealias RetroSetInputPollFn = @convention(c) (@escaping RetroInputPollFn) -> Void
typealias RetroSetInputStateFn = @convention(c) (@escaping RetroInputStateFn) -> Void

typealias RetroInitFn = @convention(c) () -> Void
typealias RetroDeinitFn = @convention(c) () -> Void
typealias RetroApiVersionFn = @convention(c) () -> UInt32
typealias RetroGetSystemInfoFn = @convention(c) (UnsafeMutablePointer<retro_system_info>) -> Void
typealias RetroGetSystemAVInfoFn = @convention(c) (UnsafeMutablePointer<retro_system_av_info>) -> Void
typealias RetroSetControllerPortDeviceFn = @convention(c) (UInt32, UInt32) -> Void
typealias RetroResetFn = @convention(c) () -> Void
typealias RetroRunFn = @convention(c) () -> Void
typealias RetroLoadGameFn = @convention(c) (UnsafePointer<retro_game_info>?) -> Bool
typealias RetroLoadGameSpecialFn = @convention(c) (UInt32, UnsafePointer<retro_game_info>?, Int) -> Bool
typealias RetroUnloadGameFn = @convention(c) () -> Void
typealias RetroGetRegionFn = @convention(c) () -> UInt32
typealias RetroGetMemoryDataFn = @convention(c) (UInt32) -> UnsafeMutableRawPointer?
typealias RetroGetMemorySizeFn = @convention(c) (UInt32) -> Int

// Save-state family (canonical libretro signatures; resolved as optionals).
typealias RetroSerializeSizeFn = @convention(c) () -> Int
typealias RetroSerializeFn = @convention(c) (UnsafeMutableRawPointer?, Int) -> Bool
typealias RetroUnserializeFn = @convention(c) (UnsafeRawPointer?, Int) -> Bool

enum RetroCoreError: Error {
    case dlopenFailed(String)
    case missingSymbol(String)
    case apiVersionMismatch(UInt32)
}

// MARK: - RetroCore (dynamic loader)

/// Wraps dlopen/dlsym behind a safe Swift API, giving typed function pointers
/// into a libretro core dylib.
final class RetroCore {
    let path: String
    private(set) var handle: UnsafeMutableRawPointer?

    // Mandatory function pointers (cached in load()).
    private(set) var setEnvironment: RetroSetEnvironmentFn?
    private(set) var setVideoRefresh: RetroSetVideoRefreshFn?
    private(set) var setAudioSample: RetroSetAudioSampleFn?
    private(set) var setAudioBatch: RetroSetAudioBatchFn?
    private(set) var setInputPoll: RetroSetInputPollFn?
    private(set) var setInputState: RetroSetInputStateFn?
    private(set) var retroInit: RetroInitFn?
    private(set) var retroDeinit: RetroDeinitFn?
    private(set) var retroApiVersion: RetroApiVersionFn?
    private(set) var retroGetSystemInfo: RetroGetSystemInfoFn?
    private(set) var retroGetSystemAVInfo: RetroGetSystemAVInfoFn?
    private(set) var retroSetControllerPortDevice: RetroSetControllerPortDeviceFn?
    private(set) var retroRun: RetroRunFn?
    private(set) var retroLoadGame: RetroLoadGameFn?
    private(set) var retroUnloadGame: RetroUnloadGameFn?

    // Optional symbols.
    private(set) var retroReset: RetroResetFn?
    private(set) var retroLoadGameSpecial: RetroLoadGameSpecialFn?
    private(set) var retroGetRegion: RetroGetRegionFn?
    private(set) var retroGetMemoryData: RetroGetMemoryDataFn?
    private(set) var retroGetMemorySize: RetroGetMemorySizeFn?
    private(set) var retroSerializeSize: RetroSerializeSizeFn?
    private(set) var retroSerialize: RetroSerializeFn?
    private(set) var retroUnserialize: RetroUnserializeFn?

    var isLoaded: Bool { handle != nil }

    init(path: String) {
        self.path = path
    }

    /// dlopen + resolve all mandatory symbols. Throws RetroCoreError on failure.
    func load() throws {
        // RTLD_LOCAL: symbols must never leak into the global namespace —
        // with two resident cores (e.g. a quarantined stuck one) a GLOBAL
        // load would let the new core's retro_* shadow the old one's.
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let msg = String(cString: dlerror())
            throw RetroCoreError.dlopenFailed(msg)
        }
        self.handle = h

        // Mandatory symbols — fatal if missing.
        setEnvironment = try require("retro_set_environment")
        setVideoRefresh = try require("retro_set_video_refresh")
        setAudioBatch = try require("retro_set_audio_sample_batch")
        setInputPoll = try require("retro_set_input_poll")
        setInputState = try require("retro_set_input_state")
        retroInit = try require("retro_init")
        retroDeinit = try require("retro_deinit")
        retroApiVersion = try require("retro_api_version")
        retroGetSystemInfo = try require("retro_get_system_info")
        retroGetSystemAVInfo = try require("retro_get_system_av_info")
        retroSetControllerPortDevice = try require("retro_set_controller_port_device")
        retroRun = try require("retro_run")
        retroLoadGame = try require("retro_load_game")
        retroUnloadGame = try require("retro_unload_game")

        // Optional symbols.
        setAudioSample = symbol("retro_set_audio_sample", as: RetroSetAudioSampleFn.self)
        retroReset = symbol("retro_reset", as: RetroResetFn.self)
        retroLoadGameSpecial = symbol("retro_load_game_special", as: RetroLoadGameSpecialFn.self)
        retroGetRegion = symbol("retro_get_region", as: RetroGetRegionFn.self)
        retroGetMemoryData = symbol("retro_get_memory_data", as: RetroGetMemoryDataFn.self)
        retroGetMemorySize = symbol("retro_get_memory_size", as: RetroGetMemorySizeFn.self)
        retroSerializeSize = symbol("retro_get_serialize_size", as: RetroSerializeSizeFn.self)
        retroSerialize = symbol("retro_serialize", as: RetroSerializeFn.self)
        retroUnserialize = symbol("retro_unserialize", as: RetroUnserializeFn.self)

        guard let retroApiVersion else {
            throw RetroCoreError.missingSymbol("retro_api_version")
        }
        let api = retroApiVersion()
        guard api == RETRO_API_VERSION else {
            throw RetroCoreError.apiVersionMismatch(api)
        }
    }

    /// Resolve a single symbol as a generic function pointer; returns nil if absent.
    func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let h = handle else { return nil }
        guard let ptr = dlsym(h, name) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    /// dlclose. Call only after deinit + unload on the session thread.
    func unload() {
        if let h = handle {
            dlclose(h)
            handle = nil
            clearPointers()
        }
    }

    private func require<T>(_ name: String) throws -> T {
        guard let fn: T = symbol(name, as: T.self) else {
            throw RetroCoreError.missingSymbol(name)
        }
        return fn
    }

    private func clearPointers() {
        setEnvironment = nil
        setVideoRefresh = nil
        setAudioSample = nil
        setAudioBatch = nil
        setInputPoll = nil
        setInputState = nil
        retroInit = nil
        retroDeinit = nil
        retroApiVersion = nil
        retroGetSystemInfo = nil
        retroGetSystemAVInfo = nil
        retroSetControllerPortDevice = nil
        retroRun = nil
        retroLoadGame = nil
        retroUnloadGame = nil
        retroReset = nil
        retroLoadGameSpecial = nil
        retroGetRegion = nil
        retroGetMemoryData = nil
        retroGetMemorySize = nil
        retroSerializeSize = nil
        retroSerialize = nil
        retroUnserialize = nil
    }

    deinit {
        if handle != nil {
            unload()
        }
    }
}
