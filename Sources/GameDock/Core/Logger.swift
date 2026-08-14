import Foundation
import os

/// Unified logger: os_log in GUI mode, plain stdout in CLI modes
/// (--selftest / --scan-steam / --diagnose-input) so scripts can capture output.
enum Log {
    static let subsystem = "com.gamedock.GameDock"
    static let category = OSLog(subsystem: subsystem, category: "gamedock")

    static var isCLIMode: Bool {
        CommandLine.arguments.contains("--selftest")
            || CommandLine.arguments.contains("--scan-steam")
            || CommandLine.arguments.contains("--diagnose-input")
            || CommandLine.arguments.contains("--probe-core")
    }

    static func debug(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        emit(.debug, message(), file: file, line: line)
    }

    static func info(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        emit(.info, message(), file: file, line: line)
    }

    static func warn(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        emit(.default, message(), file: file, line: line)
    }

    static func error(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        emit(.error, message(), file: file, line: line)
    }

    /// Prints to stdout unconditionally (CLI tools, self-test results).
    static func cliPrint(_ message: String) {
        print(message)
    }

    private static func emit(_ level: OSLogType, _ message: String, file: String, line: Int) {
        if isCLIMode {
            let prefix: String
            switch level {
            case .debug: prefix = "[debug]"
            case .error: prefix = "[error]"
            case .default: prefix = "[warn]"
            default: prefix = "[info]"
            }
            print("\(prefix) \(message)")
        } else {
            let source = "\(file):\(line)"
            os_log(level, log: category, "%{public}@ — %{public}@", message, source)
        }
    }
}
