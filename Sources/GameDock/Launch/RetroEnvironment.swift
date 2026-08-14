import Foundation
import CLibretro

/// Handles the full retro_environment command table. Owned by the session;
/// the single gd_environment global dispatches here.
struct RetroEnvironment {
    // Accumulated state.
    var pixelFormat: RetroPixelFormat = .xrgb8888
    var canDupe = false
    var supportNoGame = false
    var audioVideoEnable: (video: Bool, audio: Bool) = (true, true)
    var fastForwarding = false
    var shutdownRequested = false

    // String buffers owned by the session (stable for the session lifetime).
    var systemDirectory: String?
    var saveDirectory: String?
    var libretroPath: String?

    var systemDirC: [CChar]?
    var saveDirC: [CChar]?
    var libretroPathC: [CChar]?

    /// Returns true when the command was handled; false = "not implemented / decline".
    mutating func handle(cmd: UInt32, data: UnsafeMutableRawPointer?) -> Bool {
        // Command values are canonical libretro enums (imported from CLibretro);
        // several carry the 0x10000 EXPERIMENTAL bit, so compare against the
        // enum's raw values rather than hardcoded numbers.
        switch cmd {
        // MARK: - Commands we implement (return true)
        case UInt32(RETRO_ENVIRONMENT_GET_CAN_DUPE.rawValue):
            // data is bool* (1 byte) — write a Swift Bool, NOT a 4-byte int
            // (writing UInt32 here would corrupt adjacent memory).
            guard let data else { return true }
            data.assumingMemoryBound(to: Bool.self).pointee = true
            canDupe = true
            return true

        case UInt32(RETRO_ENVIRONMENT_SET_MESSAGE.rawValue):
            if let data {
                let msg = data.assumingMemoryBound(to: retro_message.self).pointee
                if let text = msg.msg {
                    Log.info("core message: \(String(cString: text))")
                }
            }
            return true

        case UInt32(RETRO_ENVIRONMENT_SHUTDOWN.rawValue):
            shutdownRequested = true
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY.rawValue):
            ensureCStringBuffer(&systemDirC, backing: systemDirectory)
            return writeCStringPointer(data, buffer: &systemDirC)

        case UInt32(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT.rawValue):
            if let data {
                let raw = data.assumingMemoryBound(to: UInt32.self).pointee
                pixelFormat = RetroPixelFormat(rawValue: Int32(raw)) ?? .xrgb8888
            }
            return true

        case UInt32(RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME.rawValue):
            if let data {
                supportNoGame = data.assumingMemoryBound(to: Bool.self).pointee
            }
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_LIBRETRO_PATH.rawValue):
            ensureCStringBuffer(&libretroPathC, backing: libretroPath)
            return writeCStringPointer(data, buffer: &libretroPathC)

        case UInt32(RETRO_ENVIRONMENT_GET_LOG_INTERFACE.rawValue):
            // retro_log_printf_t imports as an opaque pointer; shim_get_log_printf()
            // (shim.c) returns the raw variadic C trampoline that forwards formatted
            // messages to the Swift log callback registered via shim_set_callbacks.
            guard let data else { return true }
            data.assumingMemoryBound(to: retro_log_callback.self).pointee.log = shim_get_log_printf()
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY.rawValue):
            ensureCStringBuffer(&saveDirC, backing: saveDirectory)
            return writeCStringPointer(data, buffer: &saveDirC)

        case UInt32(RETRO_ENVIRONMENT_SET_GEOMETRY.rawValue):
            // The core announces its real render target size (PPSSPP does this
            // after load; before load its av_info reports 0x0).
            if let data {
                let g = data.assumingMemoryBound(to: retro_game_geometry.self).pointee
                if g.base_width > 0, g.base_height > 0 {
                    geometryWidth = Int(g.base_width)
                    geometryHeight = Int(g.base_height)
                    Log.info("core set geometry: \(g.base_width)x\(g.base_height)")
                }
            }
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE.rawValue):
            guard let data else { return true }
            let arr = data.assumingMemoryBound(to: UInt32.self)
            arr[0] = audioVideoEnable.video ? 1 : 0
            arr[1] = audioVideoEnable.audio ? 1 : 0
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_FASTFORWARDING.rawValue):
            guard let data else { return true }
            data.assumingMemoryBound(to: Bool.self).pointee = fastForwarding
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_TARGET_REFRESH_RATE.rawValue):
            guard let data else { return true }
            data.assumingMemoryBound(to: Float.self).pointee = (targetRefreshRate == 0 ? 60.0 : targetRefreshRate)
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_INPUT_BITMASKS.rawValue):
            guard let data else { return true }
            data.assumingMemoryBound(to: Bool.self).pointee = false  // full-button analog not needed
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER.rawValue):
            // Tell cores (PPSSPP asks first) that we can host an OpenGL Core
            // context.
            guard let data else { return true }
            data.assumingMemoryBound(to: Int32.self).pointee = preferredHwContext
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION.rawValue):
            guard let data else { return true }
            data.assumingMemoryBound(to: UInt32.self).pointee = 1
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_INPUT_MAX_USERS.rawValue):
            guard let data else { return true }
            data.assumingMemoryBound(to: UInt32.self).pointee = 1
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_SAVESTATE_CONTEXT.rawValue):
            guard let data else { return true }
            data.assumingMemoryBound(to: UInt32.self).pointee = 0
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_JIT_CAPABLE.rawValue):
            guard let data else { return true }
            data.assumingMemoryBound(to: Bool.self).pointee = true
            return true

        // MARK: - Core options: gracefully decline (v1 has no options UI)
        case UInt32(RETRO_ENVIRONMENT_GET_VARIABLE.rawValue),
             UInt32(RETRO_ENVIRONMENT_SET_VARIABLES.rawValue),
             UInt32(RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE.rawValue),
             UInt32(RETRO_ENVIRONMENT_SET_VARIABLE.rawValue):
            return false

        // MARK: - HW render & related: SET_HW_RENDER is intercepted by the
        // session (GL bridge); these interfaces we don't provide.
        case UInt32(RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE.rawValue),
             UInt32(RETRO_ENVIRONMENT_GET_CURRENT_SOFTWARE_FRAMEBUFFER.rawValue),
             UInt32(RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE.rawValue):
            return false

        // MARK: - Everything we don't support (graceful decline)
        default:
            Log.debug("unhandled env cmd \(cmd)")
            return false
        }
    }

    /// FPS target written for GET_TARGET_REFRESH_RATE; session sets this from avInfo.
    var targetRefreshRate: Float = 60.0

    /// Context type reported by GET_PREFERRED_HW_RENDER (RETRO_HW_CONTEXT_OPENGL_CORE).
    var preferredHwContext: Int32 = 3

    /// Geometry announced via SET_GEOMETRY (0 until the core reports it).
    var geometryWidth = 0
    var geometryHeight = 0

    // Writes a C string pointer into `data` (const char**), using a stable
    // session-owned [CChar] buffer. Returns false if no backing path.
    private func ensureCStringBuffer(_ source: inout [CChar]?, backing: String?) {
        guard let backing else { return }
        if source == nil {
            source = Array(backing.utf8CString)
        }
    }

    private func writeCStringPointer(_ data: UnsafeMutableRawPointer?, buffer: inout [CChar]?) -> Bool {
        guard let data, let buf = buffer else { return false }
        data.assumingMemoryBound(to: UnsafePointer<CChar>.self).pointee =
            buf.withUnsafeBufferPointer { $0.baseAddress! }
        return true
    }
}
