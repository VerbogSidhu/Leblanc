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
/// event handler (core thread) dispatches to main and pushes here; SwiftUI
/// observes on main. A burst of toasts queues up and shows one at a time
/// instead of clobbering each other.
final class RAToastModel: ObservableObject {
    @Published private(set) var current: RAToast?

    private let lock = NSLock()
    private var queue: [RAToast] = []
    private var dismissWorkItem: DispatchWorkItem?
    private static let displayDuration: TimeInterval = 4.0

    /// Pushes a toast; shows it now if none is displayed, else queues it.
    func push(_ toast: RAToast) {
        lock.lock()
        queue.append(toast)
        lock.unlock()
        if current == nil { advance() }
    }

    /// Shows the next queued toast (or nothing) and schedules its dismissal.
    private func advance() {
        lock.lock()
        guard current == nil, !queue.isEmpty else {
            lock.unlock()
            return
        }
        current = queue.removeFirst()
        lock.unlock()

        dismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.dismissCurrent() }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayDuration, execute: item)
    }

    private func dismissCurrent() {
        lock.lock()
        current = nil
        lock.unlock()
        advance()
    }

    func clear() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        lock.lock()
        current = nil
        queue.removeAll()
        lock.unlock()
    }
}
