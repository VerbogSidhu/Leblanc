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
        switch cmd {
        // MARK: - Commands we implement (return true)
        case 3:  // RETRO_ENVIRONMENT_GET_CAN_DUPE
            // data is bool* (1 byte) — write a Swift Bool, NOT a 4-byte int
            // (writing UInt32 here would corrupt adjacent memory).
            guard let data else { return true }
            data.assumingMemoryBound(to: Bool.self).pointee = true
            canDupe = true
            return true

        case 6:  // RETRO_ENVIRONMENT_SET_MESSAGE
            if let data {
                let msg = data.assumingMemoryBound(to: retro_message.self).pointee
                if let text = msg.msg {
                    Log.info("core message: \(String(cString: text))")
                }
            }
            return true

        case 7:  // RETRO_ENVIRONMENT_SHUTDOWN
            shutdownRequested = true
            return true

        case 9:  // RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY
            ensureCStringBuffer(&systemDirC, backing: systemDirectory)
            return writeCStringPointer(data, buffer: &systemDirC)

        case 10: // RETRO_ENVIRONMENT_SET_PIXEL_FORMAT
            if let data {
                let raw = data.assumingMemoryBound(to: UInt32.self).pointee
                pixelFormat = RetroPixelFormat(rawValue: Int32(raw)) ?? .xrgb8888
            }
            return true

        case 18: // RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME
            if let data {
                supportNoGame = data.assumingMemoryBound(to: Bool.self).pointee
            }
            return true

        case 19: // RETRO_ENVIRONMENT_GET_LIBRETRO_PATH
            ensureCStringBuffer(&libretroPathC, backing: libretroPath)
            return writeCStringPointer(data, buffer: &libretroPathC)

        case 27: // RETRO_ENVIRONMENT_GET_LOG_INTERFACE
            // retro_log_printf_t imports as an opaque pointer; shim_get_log_printf()
            // (shim.c) returns the raw variadic C trampoline that forwards formatted
            // messages to the Swift log callback registered via shim_set_callbacks.
            guard let data else { return true }
            data.assumingMemoryBound(to: retro_log_callback.self).pointee.log = shim_get_log_printf()
            return true

        case 31: // RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY
            ensureCStringBuffer(&saveDirC, backing: saveDirectory)
            return writeCStringPointer(data, buffer: &saveDirC)

        case 48: // RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE
            guard let data else { return true }
            let arr = data.assumingMemoryBound(to: UInt32.self)
            arr[0] = audioVideoEnable.video ? 1 : 0
            arr[1] = audioVideoEnable.audio ? 1 : 0
            return true

        case 50: // RETRO_ENVIRONMENT_GET_FASTFORWARDING
            guard let data else { return true }
            data.assumingMemoryBound(to: Bool.self).pointee = fastForwarding
            return true

        case 51: // RETRO_ENVIRONMENT_GET_TARGET_REFRESH_RATE
            guard let data else { return true }
            data.assumingMemoryBound(to: Float.self).pointee = (targetRefreshRate == 0 ? 60.0 : targetRefreshRate)
            return true

        case 52: // RETRO_ENVIRONMENT_GET_INPUT_BITMASKS
            guard let data else { return true }
            data.assumingMemoryBound(to: Bool.self).pointee = false  // full-button analog not needed
            return true

        case 60: // RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION
            guard let data else { return true }
            data.assumingMemoryBound(to: UInt32.self).pointee = 1
            return true

        case 62: // RETRO_ENVIRONMENT_GET_INPUT_MAX_USERS
            guard let data else { return true }
            data.assumingMemoryBound(to: UInt32.self).pointee = 1
            return true

        case 73: // RETRO_ENVIRONMENT_GET_SAVESTATE_CONTEXT
            guard let data else { return true }
            data.assumingMemoryBound(to: UInt32.self).pointee = 0
            return true

        case 75: // RETRO_ENVIRONMENT_GET_JIT_CAPABLE
            guard let data else { return true }
            data.assumingMemoryBound(to: Bool.self).pointee = true
            return true

        // MARK: - Core options: gracefully decline (v1 has no options UI)
        case 15, 16, 17, 71:  // GET_VARIABLE / SET_VARIABLES / GET_VARIABLE_UPDATE / SET_VARIABLE
            return false

        // MARK: - HW render & related: MUST return false (software only)
        case 14, 41, 40, 43, 57:  // SET_HW_RENDER / GET_HW_RENDER_INTERFACE / GET_CURRENT_SOFTWARE_FRAMEBUFFER / NEGOTIATION / GET_PREFERRED_HW_RENDER
            return false

        // MARK: - Everything we don't support (graceful decline)
        default:
            Log.debug("unhandled env cmd \(cmd)")
            return false
        }
    }

    /// FPS target written for GET_TARGET_REFRESH_RATE; session sets this from avInfo.
    var targetRefreshRate: Float = 60.0

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
