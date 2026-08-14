import Foundation
import rcheevos
import CLibretro

// MARK: - @convention(c) callback globals (never capturing)
//
// Mirrors the CLibretro shim pattern: top-level free functions route through a
// dedicated static pointer (RCClientService.active) guarded by its own lock.
// This keeps RetroAchievements callback routing isolated from libretro's
// `EmulatorSession.active` and avoids widening the existing race there.

typealias RCServerCallback = @convention(c) (UnsafePointer<rc_api_server_response_t>?, UnsafeMutableRawPointer?) -> Void

private func ra_read_memory(_ address: UInt32, _ buffer: UnsafeMutablePointer<UInt8>?,
                            _ numBytes: UInt32, _ client: OpaquePointer?) -> UInt32 {
    guard let buffer else { return 0 }
    return RCClientService.active?.readMemory(address, buffer: buffer, numBytes: numBytes) ?? 0
}

private func ra_server_call(_ request: UnsafePointer<rc_api_request_t>?,
                            _ callback: RCServerCallback?,
                            _ callbackData: UnsafeMutableRawPointer?,
                            _ client: OpaquePointer?) {
    guard let request, let callback, let callbackData else { return }
    RCClientService.active?.serverCall(request, callback: callback, callbackData: callbackData)
}

private func ra_event(_ event: UnsafePointer<rc_client_event_t>?, _ client: OpaquePointer?) {
    guard let event else { return }
    RCClientService.active?.handleEvent(event)
}

private func ra_log(_ message: UnsafePointer<CChar>?, _ client: OpaquePointer?) {
    guard let message else { return }
    Log.debug("rcheevos: \(String(cString: message))")
}

private func ra_get_time_ms(_ client: OpaquePointer?) -> UInt64 {
    // Monotonic milliseconds. rc_client defaults to a seconds-based clock if
    // unset; supplying ms is mandatory for correct cooldown/timing behavior.
    UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
}

/// RA async callback (login / load-game / change-media). Non-capturing.
private func ra_async_callback(_ result: Int32, _ errorMessage: UnsafePointer<CChar>?,
                               _ client: OpaquePointer?, _ userdata: UnsafeMutableRawPointer?) {
    RCClientService.active?.handleAsyncCallback(result: result,
                                                errorMessage: errorMessage,
                                                userdata: userdata)
}

// MARK: - RCClientService

/// Thin Swift owner for a single `rc_client_t`. Binds RetroAchievements into
/// the libretro emulator path: memory reads map libretro regions, server calls
/// fan out through URLSession, and events surface as UI toasts.
final class RCClientService {
    /// A cached libretro memory region for runtime achievement reads.
    struct Region {
        let base: UnsafeMutableRawPointer
        let size: Int
    }

    /// The single service currently routing RA callbacks (process-wide).
    private static var _active: RCClientService?
    private static let activeLock = NSLock()

    static var active: RCClientService? {
        get {
            activeLock.lock()
            defer { activeLock.unlock() }
            return _active
        }
    }

    static func setActive(_ service: RCClientService?) {
        activeLock.lock()
        defer { activeLock.unlock() }
        _active = service
    }

    /// Owned rc_client_t (opaque C pointer).
    private(set) var client: OpaquePointer?

    /// Cached libretro memory regions, keyed by libretro memory id.
    private var regions: [UInt32: Region] = [:]

    /// Console memory map (address → libretro region + offset).
    private struct ConsoleRegion {
        let start: UInt32
        let end: UInt32
        let realAddress: UInt32
        let libretroID: UInt32
    }
    private var consoleRegions: [ConsoleRegion] = []

    /// Toast model handed in from the UI layer.
    let toasts: RAToastModel

    /// The console id for the current game (set at begin() time).
    private(set) var consoleID: UInt32 = 0

    /// Async login/load state machine.
    private enum State { case idle, loggingIn, loggedIn, loadingGame, loaded }
    private var state: State = .idle
    private var romPath: String?
    private var romData: Data?

    // Pending server responses, marshaled back to the core thread.
    private struct Pending {
        let callback: RCServerCallback
        let callbackData: UnsafeMutableRawPointer
        let body: [CChar]
        let status: Int32
    }
    private var pending: [Pending] = []
    private let pendingLock = NSLock()
    private var isDestroyed = false

    // Credentials (copied from settings at construction time).
    private let username: String
    private let token: String

    /// Creates the service with the given RA credentials. Does not touch the C
    /// library until `create()` is called.
    init(username: String, token: String, toasts: RAToastModel) {
        self.username = username
        self.token = token
        self.toasts = toasts
    }

    /// Returns a ready-to-use service only if RA credentials are configured.
    /// Otherwise returns nil (achievements silently off).
    static func make(settings: SettingsStore, consoleID: UInt32, toasts: RAToastModel) -> RCClientService? {
        guard let username = settings.raUsername, !username.isEmpty,
              let token = settings.raAPIToken, !token.isEmpty else {
            return nil
        }
        let service = RCClientService(username: username, token: token, toasts: toasts)
        service.consoleID = consoleID
        return service
    }

    // MARK: - Lifecycle

    /// Creates the rc_client_t, configures callbacks, and registers as active.
    func create() {
        guard client == nil else { return }

        let c = rc_client_create(ra_read_memory, ra_server_call)
        client = c

        rc_client_set_event_handler(c, ra_event)
        rc_client_set_get_time_millisecs_function(c, ra_get_time_ms)
        rc_client_set_allow_background_memory_reads(c, 0) // runtime reads only, inside do_frame
        rc_client_enable_logging(c, 2 /* RC_CLIENT_LOG_LEVEL_WARN */, ra_log)

        RCClientService.setActive(self)
    }

    /// Begins login (async). Once login succeeds, a pending game load (if any)
    /// is started automatically via handleAsyncCallback.
    func beginLogin() {
        guard let client else { return }
        state = .loggingIn
        _ = username.withCString { u in
            token.withCString { t in
                rc_client_begin_login_with_token(client, u, t, ra_async_callback, nil)
            }
        }
    }

    /// Sets the hardcore / unofficial flags from settings. Call after create().
    func applySettings(_ settings: SettingsStore) {
        guard let client else { return }
        rc_client_set_hardcore_enabled(client, settings.raHardcore ? 1 : 0)
        rc_client_set_unofficial_enabled(client, settings.raUnofficial ? 1 : 0)
    }

    /// Stores the ROM for hashing and queues a load. The actual
    /// rc_client_begin_load_game runs after login succeeds.
    func beginLoadGame(path: String?, data: Data) {
        romPath = path
        romData = data
        performLoadGameIfReady()
    }

    /// Loads game by an explicit (already-known) hash — used by the self-test.
    func beginLoadGame(hash: String) {
        guard let client else { return }
        state = .loadingGame
        let cHash = Array(hash.utf8CString)
        _ = cHash.withUnsafeBufferPointer { buf in
            rc_client_begin_load_game(client, buf.baseAddress, ra_async_callback, nil)
        }
    }

    /// Starts the game load once we have a client, are logged in, and have ROM
    /// data to hash.
    private func performLoadGameIfReady() {
        guard let client, state == .loggedIn, consoleID != 0 else { return }
        guard let hash = RAHash.generate(consoleID: consoleID, path: romPath, data: romData ?? Data()) else {
            Log.warn("RCClientService: failed to hash ROM")
            return
        }
        Log.debug("RCClientService: local hash \(hash)")
        state = .loadingGame
        let cHash = Array(hash.utf8CString)
        _ = cHash.withUnsafeBufferPointer { buf in
            rc_client_begin_load_game(client, buf.baseAddress, ra_async_callback, nil)
        }
    }

    var isReady: Bool { client != nil }

    var isGameLoaded: Bool {
        guard let client else { return false }
        return rc_client_is_game_loaded(client) != 0
    }

    var loadState: Int32 {
        guard let client else { return 0 }
        return rc_client_get_load_game_state(client)
    }

    // MARK: - Memory read (core thread, inside do_frame)

    /// Caches libretro memory regions once per session (after retro_load_game),
    /// and loads the console's address map from rcheevos so reads translate
    /// native console addresses into the right region+offset.
    func cacheRegions(from core: RetroCore) {
        regions.removeAll()
        guard let dataFn = core.retroGetMemoryData, let sizeFn = core.retroGetMemorySize else { return }
        for id in [0, 1, 2, 3] as [UInt32] {
            let base = dataFn(id)
            let size = sizeFn(id)
            if let base, size > 0 {
                regions[id] = Region(base: base, size: size)
            }
        }
        loadConsoleMemoryMap()
    }

    private func loadConsoleMemoryMap() {
        consoleRegions.removeAll()
        guard let map = rc_console_memory_regions(consoleID), let rp = map.pointee.region else { return }
        let count = Int(map.pointee.num_regions)
        for i in 0..<count {
            let r = rp[i]
            // Map rcheevos memory types to libretro memory ids.
            let libretroID: UInt32
            switch r.type {
            case 0: libretroID = 2 // RC_MEMORY_TYPE_SYSTEM_RAM → RETRO_MEMORY_SYSTEM_RAM
            case 1: libretroID = 0 // RC_MEMORY_TYPE_SAVE_RAM  → RETRO_MEMORY_SAVE_RAM
            case 2: libretroID = 3 // RC_MEMORY_TYPE_VIDEO_RAM  → RETRO_MEMORY_VIDEO_RAM
            default: continue     // READONLY/other — not exposed by most cores
            }
            consoleRegions.append(ConsoleRegion(
                start: r.start_address, end: r.end_address,
                realAddress: r.real_address, libretroID: libretroID))
        }
        Log.debug("RCClientService: mapped \(consoleRegions.count) console memory regions")
    }

    /// Serves runtime achievement reads by translating console addresses into
    /// libretro region offsets (rcheevos hands us native console addresses).
    fileprivate func readMemory(_ address: UInt32, buffer: UnsafeMutablePointer<UInt8>, numBytes: UInt32) -> UInt32 {
        guard numBytes > 0 else { return 0 }
        var total: UInt32 = 0
        while total < numBytes {
            let addr = address + total
            guard let cr = consoleRegions.first(where: { addr >= $0.start && addr <= $0.end }),
                  let region = regions[cr.libretroID] else { break }
            let offset = cr.realAddress + (addr - cr.start)
            let regionSize = UInt32(region.size)
            guard offset < regionSize else { break }
            let available = regionSize - offset
            let count = min(numBytes - total, available)
            if count > 0 {
                let src = region.base.advanced(by: Int(offset))
                memcpy(buffer + Int(total), src, Int(count))
                total += count
            } else {
                break
            }
        }
        return total
    }

    // MARK: - Frame processing (core thread)

    /// Called once per frame after retro_run. Pumps the RA client and drains
    /// any pending server responses back onto the core thread.
    func doFrame() {
        guard let client else { return }
        let processing = rc_client_is_processing_required(client) != 0
        drainPending()
        if processing {
            rc_client_do_frame(client)
        } else {
            rc_client_idle(client)
        }
        drainPending()
    }

    func unloadGame() {
        guard let client else { return }
        rc_client_unload_game(client)
    }

    func destroy() {
        guard let client else { return }
        RCClientService.setActive(nil)
        isDestroyed = true
        rc_client_destroy(client)
        self.client = nil
        regions.removeAll()
        pendingLock.lock()
        pending.removeAll()
        pendingLock.unlock()
    }

    // MARK: - Server transport

    /// Non-capturing server-call trampoline. Snapshots the request, issues the
    /// HTTP request on a background queue, and queues the response for delivery
    /// on the core thread (via `doFrame`/`drainPending`).
    fileprivate func serverCall(_ request: UnsafePointer<rc_api_request_t>,
                                callback: RCServerCallback,
                                callbackData: UnsafeMutableRawPointer) {
        let url = String(cString: request.pointee.url)
        let postData = request.pointee.post_data.map { String(cString: $0) }
        let contentType = request.pointee.content_type.map { String(cString: $0) }

        let recordedURL = url

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.performHTTP(url: url, postData: postData, contentType: contentType) { body, status in
                self?.enqueue(body: body, status: status, callback: callback, callbackData: callbackData)
            }
        }

        // Lightweight debug: log only the r= query arg if present.
        if let query = URLComponents(string: recordedURL)?.query,
           let rIndex = query.range(of: "r=") {
            let start = query.index(rIndex.lowerBound, offsetBy: 2)
            let rest = String(query[start...])
            let endpoint = rest.split(separator: "&").first.map(String.init) ?? "?"
            Log.debug("RCClientService: requesting r=\(endpoint)")
        }
    }

    private func performHTTP(url: String, postData: String?, contentType: String?, completion: @escaping (String, Int) -> Void) {
        guard let u = URL(string: url) else {
            completion("", -1)
            return
        }
        var request = URLRequest(url: u)
        request.timeoutInterval = 30
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let postData {
            request.httpMethod = "POST"
            request.httpBody = postData.data(using: .utf8)
        } else {
            request.httpMethod = "GET"
        }
        let ua = "Leblanc/1.0 "
        request.setValue(ua, forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            completion(body, status)
        }
        task.resume()
    }

    private func enqueue(body: String, status: Int, callback: RCServerCallback, callbackData: UnsafeMutableRawPointer) {
        guard !isDestroyed else { return } // in-flight response raced teardown
        let cBody = Array(body.utf8CString)
        let p = Pending(callback: callback, callbackData: callbackData, body: cBody, status: Int32(status))
        pendingLock.lock()
        pending.append(p)
        pendingLock.unlock()
    }

    /// Delivers queued server responses onto the current (core) thread.
    private func drainPending() {
        pendingLock.lock()
        let items = pending
        pending.removeAll()
        pendingLock.unlock()

        for item in items {
            var response = rc_api_server_response_t()
            item.body.withUnsafeBufferPointer { buf in
                response.body = buf.baseAddress
                response.body_length = buf.count > 0 ? buf.count - 1 : 0 // exclude NUL
                response.http_status_code = item.status
            }
            item.callback(&response, item.callbackData)
        }
    }

    // MARK: - Async + event handling (core thread)

    fileprivate func handleAsyncCallback(result: Int32, errorMessage: UnsafePointer<CChar>?, userdata: UnsafeMutableRawPointer?) {
        if result == 0 { // RC_OK
            switch state {
            case .loggingIn:
                state = .loggedIn
                performLoadGameIfReady()
            case .loadingGame:
                state = .loaded
                Log.info("RCClientService: game loaded")
            default:
                break
            }
        } else {
            let msg = errorMessage.map { String(cString: $0) } ?? "unknown"
            Log.warn("RCClientService: async callback result=\(result) \(msg)")
            state = .idle
        }
    }

    fileprivate func handleEvent(_ event: UnsafePointer<rc_client_event_t>) {
        let type = event.pointee.type
        switch type {
        case 1: // RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED
            if let achievement = event.pointee.achievement,
               let title = achievement.pointee.title {
                let copy = String(cString: title)
                let toast = RAToast(title: copy, kind: .achievement)
                DispatchQueue.main.async { [weak self] in
                    self?.toasts.push(toast)
                }
            }
        case 15: // RC_CLIENT_EVENT_GAME_COMPLETED
            let toast = RAToast(title: "Game Completed!", kind: .gameCompleted)
            DispatchQueue.main.async { [weak self] in
                self?.toasts.push(toast)
            }
        case 14: // RC_CLIENT_EVENT_RESET
            let toast = RAToast(title: "Hardcore mode — resetting", kind: .status)
            DispatchQueue.main.async { [weak self] in
                self?.toasts.push(toast)
            }
        case 16: // RC_CLIENT_EVENT_SERVER_ERROR
            let msg = event.pointee.server_error?.pointee.error_message.map { String(cString: $0) } ?? "Server error"
            let toast = RAToast(title: msg, kind: .status)
            DispatchQueue.main.async { [weak self] in
                self?.toasts.push(toast)
            }
        default:
            break
        }
    }
}


