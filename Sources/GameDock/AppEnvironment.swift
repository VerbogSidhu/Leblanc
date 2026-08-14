import Combine
import ScreenCaptureKit
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
    let raHub: RAHubModel

    let volume = VolumeController()
    let status = StatusMonitor()
    let screenshots = ScreenshotController()
    private var lastLaunchedTitle = "Capture"

    @Published private(set) var emulator: EmulatorSession?

    private let controllers = ControllerManager()
    private var libraryCancellable: AnyCancellable?
    private var categoryCancellable: AnyCancellable?
    private var idleActivity: NSObjectProtocol?

    init() {
        let settings = SettingsStore()
        self.settings = settings
        self.library = LibraryStore(settings: settings)
        self.raHub = RAHubModel(settings: settings)
        try? AppPaths.ensureDirectories()

        controllers.uiReceiver = self
        controllers.onRightStickY = { [weak self] y in
            self?.discord.scrollByStick(y: y)
        }
        controllers.start()

        status.start()
        screenshots.emulatorFrameSlot = { [weak self] in self?.emulator?.frameSlot }

        libraryCancellable = library.$games
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildXMB() }

        // Refresh the hub (cache-first, TTL-gated) whenever the user lands on
        // the Achievements category.
        categoryCancellable = xmb.$categoryIndex
            .removeDuplicates()
            .sink { [weak self] idx in
                guard let self,
                      self.xmb.categories.indices.contains(idx),
                      self.xmb.categories[idx].id == "achievements" else { return }
                Task { await self.raHub.loadIfNeeded() }
            }

        library.refresh()
        rebuildXMB()

        Task { await raHub.loadIfNeeded() } // cache-first on launch
    }

    // MARK: - Input routing

    func gamepad(_ action: GamepadUIAction) {
        // When the Discord floating window is open, the controller drives it.
        if discord.isFloating {
            switch action {
            case .up: discord.moveSelection(delta: -1)
            case .down: discord.moveSelection(delta: 1)
            case .confirm: discord.activateSelection()
            case .back, .toggleDiscord: discord.hide()
            case .openQuickBar:
                quickBarVisible.toggle()
                if quickBarVisible { quickBarModel.reset() }
            default: break
            }
            return
        }

        // Quick bar open: d-pad left/right = volume, L2 = mute.
        if quickBarVisible {
            switch action {
            case .left:
                volume.adjust(by: -0.05)
                return
            case .right:
                volume.adjust(by: 0.05)
                return
            case .toggleMute:
                volume.toggleMute()
                return
            default:
                break
            }
        }

        // Touchpad click → screenshot (emulator frame or the screen).
        if action == .captureScreenshot {
            captureScreenshot()
            return
        }

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

        case .toggleMute, .captureScreenshot:
            break // handled earlier (quick-bar context / global screenshot)
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

        // RetroAchievements hub: read-only profile / recent unlocks / progress.
        cats.append(category("achievements", "Achievements", Theme.achievementsAccent, achievementsItems()))

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
            s += " · last played \(Self.lastPlayedFormatter.string(from: played))"
        }
        return s
    }

    // MARK: - RetroAchievements hub items

    private func achievementsItems() -> [XMBItem] {
        if !raHub.isConfigured {
            return [XMBItem(id: "ra-empty",
                            title: "Add your RetroAchievements username and API key in Settings to see your profile here.",
                            subtitle: nil, entry: nil, action: nil)]
        }

        var items: [XMBItem] = []

        if let p = raHub.profile {
            var subtitle = "\(p.totalPoints) pts · \(p.totalTruePoints) hardcore"
            if let since = p.memberSince { subtitle += " · member since \(since)" }
            items.append(XMBItem(id: "ra-profile", title: p.user, subtitle: subtitle,
                                 entry: nil, action: nil, profile: p))
        }

        if raHub.unlocks.isEmpty {
            items.append(XMBItem(id: "ra-no-unlocks", title: "No achievements unlocked recently.",
                                 subtitle: nil, entry: nil, action: nil))
        } else {
            for u in raHub.unlocks {
                items.append(XMBItem(id: "ra-unlock-\(u.id)", title: u.title,
                                     subtitle: "\(u.gameTitle) · \(u.points) pts · \(Self.relativeTime(u.date))",
                                     entry: nil, action: nil, unlock: u))
            }
        }

        for c in raHub.completions.prefix(12) {
            items.append(XMBItem(id: "ra-comp-\(c.id)", title: c.title,
                                 subtitle: "\(c.numAwarded)/\(c.maxPossible) · \(Int(c.percent * 100))% complete",
                                 entry: nil, action: nil, completion: c))
        }

        let refreshDetail = raHub.lastUpdated.map { "last updated \(Self.relativeTime($0))" }
        items.append(XMBItem(id: "ra-refresh", title: "Refresh data", subtitle: refreshDetail,
                             entry: nil, action: nil, isRefresh: true))
        return items
    }

    /// "3 hours ago" style, or a short date for old entries.
    private static func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr ago" }
        let days = hours / 24
        if days < 14 { return "\(days) d ago" }
        return Self.lastPlayedFormatter.string(from: date)
    }

    /// "3 hours ago" for RA timestamp strings ("2024-01-01 12:34:56").
    private static func relativeTime(_ iso: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = f.date(from: iso) else { return iso }
        return relativeTime(date)
    }

    private static let lastPlayedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

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
        } else if item.isRefresh {
            Task { await raHub.refresh(force: true) }
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
        lastLaunchedTitle = entry.title
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

    // MARK: - Screenshot

    private func captureScreenshot() {
        let title = emulator?.title ?? lastLaunchedTitle
        if screen == .emulator {
            screenshots.captureEmulator(title: title)
        } else {
            if !CGPreflightScreenCaptureAccess() {
                errorMessage = "Leblanc needs Screen Recording permission to capture Steam gameplay. Approve it in System Settings when prompted."
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    if self?.errorMessage == "Leblanc needs Screen Recording permission to capture Steam gameplay. Approve it in System Settings when prompted." {
                        self?.errorMessage = nil
                    }
                }
            }
            Task { await screenshots.captureScreen(title: title) }
        }
    }

    // MARK: - Emulation (libretro path for DS)

    func startEmulator(_ entry: GameEntry) {
        guard let corePath = CoreLocator.resolveCorePath(for: entry.source, settings: settings) else {
            errorMessage = "No \(entry.source.displayName) core found.\nDrop \(entry.source.defaultCoreFileName) into \(AppPaths.coresDir.path), or set one in Settings."
            return
        }
        let consoleID = RAConsole.id(for: entry.source)
        let session = EmulatorSession(corePath: corePath, romPath: entry.romPath, romData: nil, title: entry.title,
                                      inputSnapshot: controllers.snapshot,
                                      raConsoleID: consoleID, raSettings: settings)
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
        case .raUsername:
            promptForRAUsername()
        case .raHardcore:
            settings.setRAHardcore(!settings.raHardcore)
            rebuildXMB()
        case .raUnofficial:
            settings.setRAUnofficial(!settings.raUnofficial)
            rebuildXMB()
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

    private func promptForRAUsername() {
        let alert = NSAlert()
        alert.messageText = "RetroAchievements Sign in"
        alert.informativeText = "Enter your RetroAchievements username and API token (from retroachievements.org/controlpanel.php)."
        alert.addButton(withTitle: "Sign in")
        alert.addButton(withTitle: "Cancel")

        let usernameField = NSTextField(frame: NSRect(x: 0, y: 44, width: 300, height: 24))
        usernameField.placeholderString = "Username"
        usernameField.stringValue = settings.raUsername ?? ""

        let tokenField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tokenField.placeholderString = "API Token"
        tokenField.stringValue = settings.raAPIToken ?? ""

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 70))
        accessory.addSubview(usernameField)
        accessory.addSubview(tokenField)
        alert.accessoryView = accessory

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let u = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let t = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.setRACredentials(username: u.isEmpty ? nil : u, token: t.isEmpty ? nil : t)
            rebuildXMB()
        }
    }

    func dismissError() { errorMessage = nil }
}
