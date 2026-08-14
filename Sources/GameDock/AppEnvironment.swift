import SwiftUI

/// Top-level navigation targets.
enum AppScreen {
    case home
    case settings
    case emulator
}

/// Root state container. This placeholder is fleshed out in the integration
/// phase (libraries, controllers, launchers); it exists now so the shell
/// compiles and can be smoke-tested early.
final class AppEnvironment: ObservableObject {
    @Published var screen: AppScreen = .home
    @Published var quickBarVisible = false
    @Published var errorMessage: String?
}
