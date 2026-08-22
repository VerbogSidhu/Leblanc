import Foundation
import CLibretro

/// Handles the full retro_environment command table. Owned by the session;
/// the single gd_environment global dispatches here.
struct RetroEnvironment {
    // Accumulated state.
    var pixelFormat: RetroPixelFormat = .xrgb8888
    var supportNoGame = false
    var audioVideoEnable: (video: Bool, audio: Bool) = (true, true)
    var fastForwarding = false
    var shutdownRequested = false

    // String buffers owned by the session (stable for the session lifetime).
    var systemDirectory: String?
    var saveDirectory: String?
    var libretroPath: String?

    var systemDirC: UnsafeMutablePointer<CChar>?
    var saveDirC: UnsafeMutablePointer<CChar>?
    var libretroPathC: UnsafeMutablePointer<CChar>?

    /// Core options (v1 retro_variable interface). The session sets this at
    /// load; handlers below run on the core thread during run and the model
    /// guards all value access.
    var coreOptionsModel: CoreOptionsModel?

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
            return writeCStringPointer(data, buffer: systemDirC)

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
            return writeCStringPointer(data, buffer: libretroPathC)

        case UInt32(RETRO_ENVIRONMENT_GET_LOG_INTERFACE.rawValue):
            // retro_log_printf_t imports as an opaque pointer; shim_get_log_printf()
            // (shim.c) returns the raw variadic C trampoline that forwards formatted
            // messages to the Swift log callback registered via shim_set_callbacks.
            guard let data else { return true }
            data.assumingMemoryBound(to: retro_log_callback.self).pointee.log = shim_get_log_printf()
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY.rawValue):
            ensureCStringBuffer(&saveDirC, backing: saveDirectory)
            return writeCStringPointer(data, buffer: saveDirC)

        case UInt32(RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO.rawValue):
            // PAL60/overclock etc: the core changed timing/geometry mid-run.
            // Forward to the session (updates stored av_info + run-loop pacing
            // thread-safely) instead of declining — declining would freeze
            // pacing at boot values.
            guard let data else { return false }
            systemAVInfoHandler?(data.assumingMemoryBound(to: retro_system_av_info.self).pointee)
            return true

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

        // MARK: - Core options (classic v1 retro_variable interface)
        case UInt32(RETRO_ENVIRONMENT_SET_VARIABLES.rawValue):
            // data = const struct retro_variable*, null-terminated (key == nil).
            // value format: "Human Title; opt1|opt2|opt3"
            guard let data, let model = coreOptionsModel else { return true }
            var defs: [String: CoreOptionDefinition] = [:]
            let ptr = data.assumingMemoryBound(to: retro_variable.self)
            var i = 0
            while let keyC = ptr[i].key, let valueC = ptr[i].value {
                let key = String(cString: keyC)
                if let parsed = CoreOptionParser.parse(String(cString: valueC)) {
                    defs[key] = CoreOptionDefinition(key: key, title: parsed.title, values: parsed.values)
                }
                i += 1
            }
            model.ingest(defs)
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_VARIABLE.rawValue):
            // data = struct retro_variable*: core sets .key; we fill .value with
            // the selected token (stable buffer owned by the model).
            guard let data, let model = coreOptionsModel else { return false }
            let variable = data.assumingMemoryBound(to: retro_variable.self)
            guard let keyC = variable.pointee.key else { return false }
            let key = String(cString: keyC)
            guard let valuePtr = model.readValue(forKey: key) else { return false }
            variable.pointee.value = valuePtr
            return true

        case UInt32(RETRO_ENVIRONMENT_SET_VARIABLE.rawValue):
            // Core-initiated change notification: key + new token.
            guard let data, let model = coreOptionsModel else { return true }
            let variable = data.assumingMemoryBound(to: retro_variable.self)
            if let keyC = variable.pointee.key, let valueC = variable.pointee.value {
                _ = model.setValue(String(cString: valueC), forKey: String(cString: keyC), persist: true)
            }
            return true

        case UInt32(RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE.rawValue):
            // bool*: true only after a frontend-initiated change; cleared.
            guard let data else { return true }
            data.assumingMemoryBound(to: Bool.self).pointee = coreOptionsModel?.takeChangedFlag() ?? false
            return true

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

    /// SET_SYSTEM_AV_INFO handler (session adopts the new timing/geometry).
    var systemAVInfoHandler: ((retro_system_av_info) -> Void)?

    /// Context type reported by GET_PREFERRED_HW_RENDER (RETRO_HW_CONTEXT_OPENGL_CORE).
    var preferredHwContext: Int32 = 3

    /// Geometry announced via SET_GEOMETRY (0 until the core reports it).
    var geometryWidth = 0
    var geometryHeight = 0

    // Stable session-owned C-string buffers (CoreOptionsModel pattern):
    // allocated once on first query, the pointer handed to cores stays valid
    // for the whole session — never freed mid-session. releaseBuffers() frees
    // them after teardown has joined the core thread.
    private func ensureCStringBuffer(_ buffer: inout UnsafeMutablePointer<CChar>?, backing: String?) {
        guard let backing, buffer == nil else { return }
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: backing.utf8.count + 1)
        backing.withCString { strcpy(p, $0); return () }
        buffer = p
    }

    private func writeCStringPointer(_ data: UnsafeMutableRawPointer?, buffer: UnsafeMutablePointer<CChar>?) -> Bool {
        guard let data, let buf = buffer else { return false }
        data.assumingMemoryBound(to: UnsafePointer<CChar>.self).pointee = UnsafePointer(buf)
        return true
    }

    /// Frees the stable C-string buffers. Teardown-only: call after the core
    /// thread has joined (cores read these pointers until retro_deinit).
    mutating func releaseBuffers() {
        systemDirC?.deallocate()
        systemDirC = nil
        saveDirC?.deallocate()
        saveDirC = nil
        libretroPathC?.deallocate()
        libretroPathC = nil
    }
}
