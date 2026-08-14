import SwiftUI

/// Top-level navigation targets.
enum AppScreen {
    case home
    case settings
    case emulator
}

/// Root state container. Owns the library, settings, and (later) the
/// controller manager, launchers, and the active emulator session.
final class AppEnvironment: ObservableObject {
    // Navigation
    @Published var screen: AppScreen = .home
    @Published var quickBarVisible = false
    @Published var errorMessage: String?

    // Data
    let settings: SettingsStore
    let library: LibraryStore

    init() {
        let settings = SettingsStore()
        self.settings = settings
        self.library = LibraryStore(settings: settings)
        try? AppPaths.ensureDirectories()
        library.refresh()
    }

    func dismissError() {
        errorMessage = nil
    }
}
