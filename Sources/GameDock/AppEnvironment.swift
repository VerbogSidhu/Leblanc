import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Top-level navigation targets.
enum AppScreen {
    case xmb        // the cross-media-bar shell
    case emulator   // fullscreen game surface
}

/// Root state container and input router. Owns libraries, settings,
/// controllers, the Discord float, Steam handoff, and the active emulator
/// session. All gamepad/keyboard UI actions funnel through `gamepad(_:)`.
final class AppEnvironment: ObservableObject, GamepadUIReceiver {
    @Published var screen: AppScreen = .xmb
    @Published var quickBarVisible = false
    @Published var errorMessage: String?

    let settings: SettingsStore
    let library: LibraryStore
    let discord = DiscordController()
    let steam = SteamLauncher()
    let standalone = StandaloneEmulatorLauncher()

    // XMB
    @Published private(set) var xmb = XMBNavModel()
    @Published private(set) var settingsNav = SettingsNavModel()
    @Published private(set) var quickBarModel = QuickBarModel()
    let waveField = WaveFieldModel()

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

        libraryCancellable = library.$games
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildXMB() }

        library.refresh()
        rebuildXMB()
    }

    // MARK: - Input routing

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
            } else if screen == .emulator {
                exitEmulation()
            }

        case .confirm, .up, .down, .left, .right:
            if quickBarVisible {
                handleQuickBar(action)
            } else if screen == .xmb {
                if let item = xmb.handle(action) {
                    xmbConfirm(item)
                } else {
                    selectionMoved()
                }
            }

        case .previousPanel, .nextPanel:
            // L1/R1 accelerate through a long item stack.
            if !quickBarVisible, screen == .xmb {
                _ = xmb.handle(action)
                selectionMoved()
            }
        }
    }

    private func handleQuickBar(_ action: GamepadUIAction) {
        if let item = quickBarModel.handle(action) {
            quickBarVisible = false
            quickBarSelect(item)
        }
    }

    // MARK: - XMB

    func rebuildXMB() {
        var cats: [XMBNavModel.Category] = []
        cats.append(category("home", "Home", Theme.homeAccent, gameItems(library.recentGames)))
        cats.append(category("steam", "Steam", Theme.steamAccent, gameItems(library.steamGames)))
        cats.append(category("psp", "PSP", Theme.pspAccent, gameItems(library.pspGames)))
        cats.append(category("ds", "DS", Theme.dsAccent, gameItems(library.dsGames)))

        // Discord: a single action item (Share button still floats it too).
        cats.append(category("discord", "Discord", Theme.discordAccent, [
            XMBItem(id: "discord", title: "Discord",
                    subtitle: "Open the floating window",
                    entry: nil, action: .discord)
        ]))

        // Settings rows become the Settings category's item stack.
        settingsNav.rebuild(settings: settings, library: library)
        cats.append(category("settings", "Settings", Theme.settingsAccent,
            settingsNav.rows.map { row in
                XMBItem(id: "setting-\(row.id)", title: row.title,
                        subtitle: row.detail, entry: nil,
                        action: .settings(row.kind))
            }))

        xmb.rebuild(cats)
    }

    private func category(_ id: String, _ title: String, _ accent: Color, _ items: [XMBItem]) -> XMBNavModel.Category {
        XMBNavModel.Category(id: id, title: title, accent: accent, items: items)
    }

    private func gameItems(_ games: [GameEntry]) -> [XMBItem] {
        games.map { game in
            XMBItem(id: game.id, title: game.title, subtitle: metaLine(for: game),
                    entry: game, action: nil)
        }
    }

    private func metaLine(for game: GameEntry) -> String {
        var s = game.source.displayName
        if let played = game.lastPlayed {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .none
            s += " · last played \(f.string(from: played))"
        }
        return s
    }

    /// Haptic tick + wave ripple on every selection change (the reactive
    /// part of the signature wave field).
    func selectionMoved() {
        Haptics.tick()
        waveField.emit(x: 0.5, y: 0.58, color: xmb.currentCategory?.accent ?? Theme.signal)
    }

    func selectCategory(_ id: String) {
        if let idx = xmb.categories.firstIndex(where: { $0.id == id }) {
            xmb.jumpToCategory(at: idx)
            selectionMoved()
        }
    }

    private func xmbConfirm(_ item: XMBItem) {
        if let entry = item.entry {
            launch(entry)
        } else if let action = item.action {
            switch action {
            case .discord:
                discord.toggle()
            case .settings(let kind):
                settingsAction(kind)
                rebuildXMB()
            }
        }
    }

    // MARK: - Quick bar

    func quickBarSelect(_ item: QuickBarItem) {
        quickBarVisible = false
        switch item {
        case .home: selectCategory("home")
        case .recentlyPlayed: selectCategory("home")
        case .discord: discord.toggle()
        case .settings: selectCategory("settings")
        }
    }

    // MARK: - Launch

    func launch(_ entry: GameEntry) {
        library.recordLaunch(entry)
        switch entry.source {
        case .steam:
            guard let appID = entry.appID else { return }
            steam.launch(appID: appID) { [weak self] in self?.restoreAfterSteam() }
        case .psp:
            launchPPSSPP(entry)
        case .ds:
            startEmulator(entry)
        }
    }

    private func launchPPSSPP(_ entry: GameEntry) {
        guard let romPath = entry.romPath else { return }
        let bundlePath = standalone.resolveBundlePath(for: .ppsspp, settings: settings)
        do {
            try standalone.launch(kind: .ppsspp, romPath: romPath, bundlePath: bundlePath) { [weak self] in
                self?.restoreAfterSteam()
            }
        } catch {
            errorMessage = "Couldn't launch PPSSPP: \(error.localizedDescription)\n\nPoint it at your PPSSPPSDL.app in Settings."
            Log.error("launchPPSSPP failed: \(error)")
        }
    }

    private func restoreAfterSteam() {
        AppDelegate.shared?.restoreFrontend()
        rebuildXMB()
    }

    // MARK: - Emulation (libretro path for DS)

    func startEmulator(_ entry: GameEntry) {
        guard let corePath = CoreLocator.resolveCorePath(for: entry.source, settings: settings) else {
            errorMessage = "No \(entry.source.displayName) core found.\nDrop \(entry.source.defaultCoreFileName) into \(AppPaths.coresDir.path), or set one in Settings."
            return
        }
        let session = EmulatorSession(corePath: corePath, romPath: entry.romPath, romData: nil, title: entry.title,
                                      inputSnapshot: controllers.snapshot)
        do {
            try session.load()
        } catch {
            errorMessage = "Failed to start \(entry.title): \(error.localizedDescription)"
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
        screen = .xmb
        rebuildXMB()
    }

    private func beginKeepAwake() {
        idleActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Emulation running")
    }

    private func endKeepAwake() {
        if let idleActivity { ProcessInfo.processInfo.endActivity(idleActivity) }
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
        case .standaloneApp(let key):
            promptForAppBundle(key)
        case .rescan:
            library.refresh()
        }
    }

    private func promptForFolder(completion: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add folder"
        panel.begin { response in completion(response == .OK ? panel.url?.path : nil) }
    }

    private func promptForAppBundle(_ key: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.prompt = "Select app"
        panel.begin { [weak self] response in
            guard let self else { return }
            self.settings.setStandaloneAppPath(response == .OK ? panel.url?.path : nil, for: key)
            self.rebuildXMB()
        }
    }

    private func promptForCoreFile(_ source: GameSource) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "dylib") ?? .item]
        panel.prompt = "Select core"
        panel.begin { [weak self] response in
            guard let self else { return }
            self.settings.setCoreOverride(response == .OK ? panel.url?.path : nil, for: source)
            self.rebuildXMB()
        }
    }

    func dismissError() { errorMessage = nil }
}
