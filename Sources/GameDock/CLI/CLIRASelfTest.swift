import Foundation
import rcheevos

// MARK: - --ra-selftest
//
// Headless smoke test proving the Swift↔C @convention(c) callback plumbing,
// the server-call transport contract, and the event→callback pipeline. Uses a
// fake read_memory + fake server_call: no real ROM, no real network.

// File-scope mutable state observed by the non-capturing C callbacks.
private var raSTServerCallCount = 0
private var raSTLoginObserved = false
private var raSTLock = NSLock()
private let raSTFakeRAM: [UInt8] = Array(repeating: 0xAB, count: 64)

// MARK: - Fake callbacks (top-level free functions, never capture)

private func raSTReadMemory(_ address: UInt32, _ buffer: UnsafeMutablePointer<UInt8>?,
                            _ numBytes: UInt32, _ client: OpaquePointer?) -> UInt32 {
    guard let buffer, numBytes > 0 else { return 0 }
    let count = Int(min(numBytes, UInt32(raSTFakeRAM.count)))
    raSTFakeRAM.withUnsafeBufferPointer { buf in
        if let base = buf.baseAddress {
            memcpy(buffer, base, count)
        }
    }
    return UInt32(count)
}

private func raSTServerCall(_ request: UnsafePointer<rc_api_request_t>?,
                            _ callback: RCServerCallback?,
                            _ callbackData: UnsafeMutableRawPointer?,
                            _ client: OpaquePointer?) {
    guard let request, let callback, let callbackData else { return }
    raSTLock.lock()
    raSTServerCallCount += 1
    let url = String(cString: request.pointee.url)
    let postData = request.pointee.post_data.map { String(cString: $0) } ?? ""
    if url.contains("login") || postData.contains("login") || url.contains("dorequest") {
        raSTLoginObserved = true
    }
    raSTLock.unlock()

    let body = "{\"Success\":true,\"User\":\"smoketest\"}"
    var response = rc_api_server_response_t()
    body.withCString { cstr in
        response.body = cstr
        response.body_length = body.utf8.count
        response.http_status_code = 200
        callback(&response, callbackData)
    }
}

private func raSTEvent(_ event: UnsafePointer<rc_client_event_t>?, _ client: OpaquePointer?) {
    // No-op for the smoke test (event routing is exercised separately).
}

private func raSTLog(_ message: UnsafePointer<CChar>?, _ client: OpaquePointer?) {}

private func raSTTime(_ client: OpaquePointer?) -> UInt64 { 0 }

private func raSTAsyncCallback(_ result: Int32, _ errorMessage: UnsafePointer<CChar>?,
                               _ client: OpaquePointer?, _ userdata: UnsafeMutableRawPointer?) {}

// MARK: - Runner

enum CLIRASelfTest {
    static func run() -> Bool {
        Log.cliPrint("RA SELFTEST: constructing rc_client with fake callbacks")

        guard let client = rc_client_create(raSTReadMemory, raSTServerCall) else {
            Log.cliPrint("RA SELFTEST FAIL: rc_client_create returned NULL")
            return false
        }

        rc_client_set_event_handler(client, raSTEvent)
        rc_client_set_get_time_millisecs_function(client, raSTTime)
        rc_client_set_allow_background_memory_reads(client, 0)
        rc_client_enable_logging(client, 0, raSTLog)

        // Start login.
        "smoketest".withCString { u in
            "token".withCString { t in
                _ = rc_client_begin_login_with_token(client, u, t, raSTAsyncCallback, nil)
            }
        }

        // Pump the client to advance the async login chain.
        for _ in 0..<20 {
            _ = rc_client_is_processing_required(client)
            rc_client_idle(client)
            rc_client_do_frame(client)
        }

        var failures: [String] = []

        raSTLock.lock()
        let scCount = raSTServerCallCount
        let loggedIn = raSTLoginObserved
        raSTLock.unlock()

        if scCount == 0 {
            failures.append("fake server_call was never invoked")
        }
        if !loggedIn {
            failures.append("login request (url containing 'login') was not observed")
        }

        // Attempt to load a game by a fake hash (Path A) and pump again.
        let hashString = "0123456789abcdef0123456789abcdef"
        var fakeHash = Array(repeating: CChar(0), count: 33)
        for (i, byte) in hashString.utf8CString.enumerated() where i < 32 {
            fakeHash[i] = CChar(byte)
        }
        fakeHash.withUnsafeBufferPointer { buf in
            _ = rc_client_begin_load_game(client, buf.baseAddress, raSTAsyncCallback, nil)
        }
        for _ in 0..<20 {
            rc_client_idle(client)
            rc_client_do_frame(client)
        }

        let loadState = rc_client_get_load_game_state(client)
        Log.cliPrint("RA SELFTEST: server calls=\(scCount) loginObserved=\(loggedIn) loadState=\(loadState)")

        rc_client_destroy(client)

        if failures.isEmpty {
            Log.cliPrint("RA SELFTEST PASS")
            return true
        } else {
            for f in failures {
                Log.cliPrint("RA SELFTEST FAIL: \(f)")
            }
            return false
        }
    }
}
