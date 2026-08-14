import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Top-level navigation targets.
enum AppScreen {
    case home
    case settings
    case emulator
}

/// Root state container and input router. Owns libraries, settings,
/// controllers, the Discord float, Steam handoff, and the active emulator
/// session. All gamepad/keyboard UI actions funnel through `gamepad(_:)`.
final class AppEnvironment: ObservableObject, GamepadUIReceiver {
    // Navigation
    @Published var screen: AppScreen = .home
    @Published var quickBarVisible = false
    @Published var errorMessage: String?

    // Data & services
    let settings: SettingsStore
    let library: LibraryStore
    let discord = DiscordController()
    let steam = SteamLauncher()

    // Sub-models (observed by the views)
    @Published private(set) var homeNav = HomeNavModel()
    @Published private(set) var settingsNav = SettingsNavModel()
    @Published private(set) var quickBarModel = QuickBarModel()

    // Active emulation
    @Published private(set) var emulator: EmulatorSession?

    private let controllers = ControllerManager()
    private var libraryCancellable: AnyCancellable?
    private var idleActivity: NSObjectProtocol?

    init() {
        let settings = SettingsStore()
        self.settings = settings
        self.library = LibraryStore(settings: settings)
        try? AppPaths.ensureDirectories()

        controllers.uiReceiver = self
        controllers.start()

        // Rebuild the home grid whenever the library finishes a scan.
        libraryCancellable = library.$games
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildHomeSections() }

        library.refresh()
        rebuildHomeSections()
    }

    // MARK: - Input routing (GamepadUIReceiver)

    func gamepad(_ action: GamepadUIAction) {
        switch action {
        case .openQuickBar:
            quickBarVisible.toggle()
            if quickBarVisible { quickBarModel.reset() }

        case .toggleDiscord:
            discord.toggle()

        case .back:
            if quickBarVisible {
                quickBarVisible = false
            } else {
                switch screen {
                case .settings: screen = .home
                case .emulator: exitEmulation()
                case .home: break
                }
            }

        case .confirm, .up, .down, .left, .right:
            if quickBarVisible {
                handleQuickBar(action)
            } else {
                switch screen {
                case .home:
                    if let game = homeNav.handle(action) { launch(game) }
                case .settings:
                    if let kind = settingsNav.handle(action) { settingsAction(kind) }
                case .emulator:
                    break // no discrete nav inside the game itself
                }
            }
        }
    }

    private func handleQuickBar(_ action: GamepadUIAction) {
        if let item = quickBarModel.handle(action) {
            quickBarVisible = false
            quickBarSelect(item)
        }
    }

    // MARK: - Quick bar

    func quickBarSelect(_ item: QuickBarItem) {
        quickBarVisible = false
        switch item {
        case .home:
            screen = .home
        case .recentlyPlayed:
            screen = .home
            if let idx = homeNav.sections.firstIndex(where: { $0.id == "recents" }) {
                homeNav.selection.row = idx
            }
        case .discord:
            discord.toggle()
        case .settings:
            settingsNav.rebuild(settings: settings, library: library)
            screen = .settings
        }
    }

    // MARK: - Launch

    func launch(_ entry: GameEntry) {
        library.recordLaunch(entry)
        switch entry.source {
        case .steam:
            guard let appID = entry.appID else { return }
            steam.launch(appID: appID) { [weak self] in
                self?.restoreAfterSteam()
            }
        case .psp, .ds:
            startEmulator(entry)
        }
    }

    private func restoreAfterSteam() {
        AppDelegate.shared?.restoreFrontend()
        rebuildHomeSections()
    }

    // MARK: - Emulation

    func startEmulator(_ entry: GameEntry) {
        guard let corePath = CoreLocator.resolveCorePath(for: entry.source, settings: settings) else {
            errorMessage = "No \(entry.source.displayName) core found.\nDrop \(entry.source.defaultCoreFileName) into \(AppPaths.coresDir.path), or set one in Settings."
            return
        }

        let session = EmulatorSession(corePath: corePath, romPath: entry.romPath, romData: nil, title: entry.title)
        do {
            try session.load()
        } catch {
            errorMessage = "Failed to start \(entry.title): \(error.localizedDescription)"
            Log.error("startEmulator failed: \(error)")
            return
        }

        emulator = session
        session.start()
        screen = .emulator
        beginKeepAwake()
    }

    func exitEmulation() {
        emulator?.requestStop()
        emulator?.teardown()
        emulator = nil
        endKeepAwake()
        screen = .home
        rebuildHomeSections()
    }

    private func beginKeepAwake() {
        idleActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled],
            reason: "Emulation running"
        )
    }

    private func endKeepAwake() {
        if let idleActivity {
            ProcessInfo.processInfo.endActivity(idleActivity)
        }
        idleActivity = nil
    }

    // MARK: - Settings actions

    func settingsAction(_ kind: SettingsNavModel.RowKind) {
        switch kind {
        case .addFolder(let source):
            promptForFolder { [weak self] path in
                guard let self, let path else { return }
                self.settings.addROMFolder(path, for: source)
                self.library.refresh()
            }
        case .folder(let source, let index):
            settings.removeROMFolder(at: index, for: source)
            library.refresh()
        case .core(let source):
            promptForCoreFile(source)
        case .rescan:
            library.refresh()
        }
        settingsNav.rebuild(settings: settings, library: library)
    }

    private func promptForFolder(completion: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add folder"
        panel.begin { response in
            completion(response == .OK ? panel.url?.path : nil)
        }
    }

    private func promptForCoreFile(_ source: GameSource) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dylib") ?? .item]
        panel.prompt = "Select core"
        panel.begin { [weak self] response in
            guard let self else { return }
            if response == .OK, let path = panel.url?.path {
                self.settings.setCoreOverride(path, for: source)
            } else {
                self.settings.setCoreOverride(nil, for: source)
            }
            self.settingsNav.rebuild(settings: self.settings, library: self.library)
        }
    }

    // MARK: - Home sections

    /// Builds the home grid: Recently Played (first) then source sections.
    func rebuildHomeSections() {
        var sections: [HomeNavModel.Section] = []

        let recents = library.recentGames
        if !recents.isEmpty {
            sections.append(HomeNavModel.Section(id: "recents", title: "Recently Played", games: recents))
        }
        sections.append(HomeNavModel.Section(id: "steam", title: "Steam", games: library.steamGames))
        sections.append(HomeNavModel.Section(id: "psp", title: "PSP", games: library.pspGames))
        sections.append(HomeNavModel.Section(id: "ds", title: "Nintendo DS", games: library.dsGames))

        homeNav.rebuild(sections)
    }

    func dismissError() {
        errorMessage = nil
    }
}
