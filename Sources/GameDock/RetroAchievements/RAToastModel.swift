import Combine
import Foundation

/// A single achievement/status toast shown on the emulator surface.
struct RAToast: Identifiable, Equatable {
    enum Kind: Equatable {
        case achievement      // "Achievement Unlocked: <title>"
        case gameCompleted    // "Game Completed!"
        case status           // generic connection/status message
        case progress         // progress pill text
    }

    let id = UUID()
    let title: String
    let kind: Kind
    let timestamp = Date()
}

/// Thread-safe toast queue surfaced in `EmulatorScreen`. The RetroAchievements
/// event handler (core thread) pushes here; SwiftUI observes on main.
final class RAToastModel: ObservableObject {
    @Published private(set) var current: RAToast?

    private let lock = NSLock()
    private var dismissWorkItem: DispatchWorkItem?

    /// Pushes a new toast and schedules auto-dismiss.
    func push(_ toast: RAToast) {
        dismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.current = nil
        }
        dismissWorkItem = item

        lock.lock()
        current = toast
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: item)
    }

    func clear() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        lock.lock()
        current = nil
        lock.unlock()
    }
}
