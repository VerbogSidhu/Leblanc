import Foundation
import rcheevos

/// Wraps the local (Path A) ROM hashing flow: hash the ROM bytes locally with
/// `rc_hash_generate`, then load with `rc_client_begin_load_game`.
///
/// `rc_client_begin_identify_and_load_game` is compiled OUT of the current
/// CRcheevos build (`RC_CLIENT_SUPPORTS_HASH` is not defined), so identify is
/// not available. We hash locally instead.
enum RAHash {
    /// Generates the 32-character RetroAchievements canonical hash for the
    /// given ROM data, or nil on failure.
    static func generate(consoleID: UInt32, path: String?, data: Data) -> String? {
        var hash = [CChar](repeating: 0, count: 33)
        var iterator = rc_hash_iterator_t()

        // Keep the path's C string alive for the duration of the hashing calls.
        // An empty string is treated as no path (rcheevos would fail to open it).
        let pathCString = path.flatMap { $0.isEmpty ? nil : Array($0.utf8CString) }

        let success: Bool = pathCString.withOptionalUnsafeBuffer { pathPtr in
            // rc_hash.h: "path must be provided"; a NULL buffer / zero size makes
            // the iterator hash the file at path instead of the supplied bytes.
            guard !data.isEmpty || pathPtr != nil else { return false }

            if data.isEmpty {
                rc_hash_initialize_iterator(&iterator, pathPtr, nil, 0)
                let generated = rc_hash_generate(&hash, consoleID, &iterator)
                rc_hash_destroy_iterator(&iterator)
                return generated != 0
            }

            return data.withUnsafeBytes { (rb: UnsafeRawBufferPointer) -> Bool in
                guard let base = rb.baseAddress else { return false }
                let bufferPtr = base.bindMemory(to: UInt8.self, capacity: data.count)

                rc_hash_initialize_iterator(&iterator, pathPtr, bufferPtr, data.count)

                let generated = rc_hash_generate(&hash, consoleID, &iterator)
                rc_hash_destroy_iterator(&iterator)
                return generated != 0
            }
        }

        guard success else { return nil }
        return String(cString: hash)
    }
}

/// Helper: run a closure with an optional C-string buffer's base pointer,
/// mirroring `withUnsafeBufferPointer` but tolerant of nil source arrays.
private extension Optional where Wrapped == [CChar] {
    func withOptionalUnsafeBuffer<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case .none:
            return body(nil)
        case .some(let array):
            return array.withUnsafeBufferPointer { buf in body(buf.baseAddress) }
        }
    }
}
