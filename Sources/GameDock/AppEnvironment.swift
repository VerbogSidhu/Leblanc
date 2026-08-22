import Combine
import Foundation
import SwiftUI

/// Top-level navigation targets.
enum AppScreen {
    case xmb        // the cross-media-bar shell
    case emulator   // fullscreen game surface
}

/// Root state container and input router. Owns libraries, settings,
/// controllers, the Discord float, Steam handoff, and the active emulator
/// session. All gamepad/keyboard UI actions funnel through `gamepad(_:)`.
///
/// Split by concern for navigability (zero behavior change):
///   • this file        — state, init, input routing, XMB/quick-bar, screenshots trigger
///   • +Launch.swift    — launch orchestration (Steam/PPSSPP/embedded core), keep-awake, screenshots
///   • +Settings.swift  — settings row actions + file/alert panels
/// A pending destructive action awaiting confirmation (modal overlay).
/// Identity is by title; the confirm closure is opaque.
struct PendingConfirmation {
    let title: String
    let message: String
    let confirmLabel: String
    let onConfirm: () -> Void
}

final class AppEnvironment: ObservableObject, GamepadUIReceiver {
    @Published var screen: AppScreen = .xmb
    @Published var quickBarVisible = false
    @Published private(set) var activeError: AppError?
    /// True while a game handoff is in progress (Steam/PPSSPP) and we're
    /// about to hide the window — drives the "Starting…" overlay.
    @Published var isLaunching = false
    /// True while the embedded emulator core is loading (moved off the main
    /// thread in 2.2) — drives the "Loading core…" boot overlay.
    @Published var isLaunchingGame = false
    /// True while a core load is in flight on emulatorLoadQueue (main-thread
    /// read to decide whether exitEmulation must own teardown).
    var isEmulatorLoadPending = false
    /// Serial queue for emulator core load/teardown — guarantees a load never
    /// overlaps a teardown (cores dlopen with RTLD_LOCAL; see RetroCore.swift).
    let emulatorLoadQueue = DispatchQueue(label: "com.leblanc.emulator.load")
    /// Modal confirmation for destructive actions (ROM folder removal).
    /// Confirm proceeds, Circle/PS dismisses — routed before anything else.
    @Published var pendingConfirmation: PendingConfirmation?

    let settings: SettingsStore
    let library: LibraryStore
    let discord = DiscordController()
    let steam = SteamLauncher()
    let standalone = StandaloneEmulatorLauncher()

    // XMB
    @Published private(set) var xmb = XMBNavModel()
    @Published private(set) var settingsNav = SettingsNavModel()
    @Published private(set) var quickBarModel = QuickBarModel()
    let raHub: RAHubModel
    /// Selection preview panel state (debounced screenshots/playtime for the
    /// XMB's selected item).
    let preview: SelectionPreviewModel

    let volume = VolumeController()
    let status = StatusMonitor()
    let screenshots = ScreenshotController()
    /// Transient "Capture saved" confirmation toasts (touchpad screenshot).
    let captureToasts = RAToastModel()
    /// Title used for screenshots when no emulator is active (the last game launched).
    var lastLaunchedTitle = "Capture"

    /// The active embedded-libretro emulator session (nil when not emulating).
    @Published var emulator: EmulatorSession?
    /// True while the core-options overlay is open (emulation is paused).
    @Published var coreOptionsVisible = false
    /// True while the in-game pause menu is open (Circle/back).
    @Published var pauseMenuVisible = false
    @Published var pauseMenu = PauseMenuModel()

    let controllers = ControllerManager()
    private var libraryCancellable: AnyCancellable?
    private var categoryCancellable: AnyCancellable?
    var idleActivity: NSObjectProtocol?
    /// Playtime session tracking (launch → restore/exit).
    var sessionStart: Date?
    var sessionEntryID: String?
    /// Sleep/wake observers (pause emulation during sleep).
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init() {
        let settings = SettingsStore()
        self.settings = settings
        self.library = LibraryStore(settings: settings)
        self.preview = SelectionPreviewModel(recents: library.recents)
        self.raHub = RAHubModel(settings: settings)
        do {
            try AppPaths.ensureDirectories()
        } catch {
            Log.error("AppEnvironment: app-support setup failed — \(error.localizedDescription)")
        }

        controllers.uiReceiver = self
        controllers.onRightStickY = { [weak self] y in
            self?.discord.scrollByStick(y: y)
        }
        controllers.start()

        status.start()
        screenshots.emulatorFrameSlot = { [weak self] in self?.emulator?.frameSlot }
        screenshots.onSaved = { [weak self] title in
            self?.captureToasts.push(RAToast(title: "Capture saved — \(title)", kind: .status))
        }

        // Optional global PS-button capture while another app is frontmost.
        // OFF by default: it needs Input Monitoring, which macOS re-prompts for
        // (and may ask for an admin password) on every launch. When enabled,
        // Apple DTS confirmed IOHIDManager capture was broken/unreliable on
        // macOS 14/15 (fixed hope on 26+/27 beta). Cmd+Shift+Home is the
        // always-available, permission-free fallback restore path.
        if settings.globalCaptureEnabled {
            GlobalHIDMonitor.shared.startCapture { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
                        return // already frontmost; GameController handles the PS button
                    }
                    Log.info("AppEnvironment: HID system button — restoring frontend + quick bar")
                    AppDelegate.shared?.restoreFrontend()
                    self.quickBarVisible = true
                    self.quickBarModel.reset()
                }
            }
        }

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

        // Pre-warm artwork for recently-played games so the cache is hot
        // by the time the user scrolls to them.
        Task { @MainActor in
            let recent = library.recentGames.prefix(20)
            ArtworkLoader.shared.prewarm(entries: Array(recent))
        }

        Task { await raHub.loadIfNeeded() } // cache-first on launch

        // Pause/resume emulation around sleep so the core thread + audio
        // engine don't desync after a lid-close/wake cycle.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.emulator?.pause() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // If a modal (core options / pause menu) is open, emulation
            // stays paused.
            if !self.coreOptionsVisible, !self.pauseMenuVisible {
                self.emulator?.resume()
            }
        }
    }

    // MARK: - Quick bar visibility (contextual)

    /// The quick bar shows Save/Load/Reset/Options while an emulator is running,
    /// and Favorite when a game item is selected in the XMB.
    var visibleQuickBarItems: [QuickBarItem] {
        if screen == .emulator {
            return [.home, .coreOptions, .saveState, .loadState, .reset, .volume, .discord, .settings]
        }
        var items: [QuickBarItem] = [.home, .recentlyPlayed, .volume, .discord, .settings]
        if xmb.selectedItem?.entry != nil {
            items.insert(.favorite, at: 1)
        }
        return items
    }

    // MARK: - Input routing

    func gamepad(_ action: GamepadUIAction) {
        // Confirmation dialog is modal: Confirm proceeds, Circle/PS dismisses.
        if let pending = pendingConfirmation {
            switch action {
            case .confirm:
                pendingConfirmation = nil
                pending.onConfirm()
            case .back, .openQuickBar:
                pendingConfirmation = nil
            default: break
            }
            return
        }

        // Pause menu is modal (like core options): up/down select, confirm
        // runs the action, Circle/back resumes, PS resumes too.
        if pauseMenuVisible, emulator != nil {
            switch action {
            case .up: _ = pauseMenu.handle(.up)
            case .down: _ = pauseMenu.handle(.down)
            case .confirm:
                if let item = pauseMenu.handle(.confirm) { pauseMenuAction(item) }
            case .back, .openQuickBar:
                closePauseMenu()
            default: break
            }
            return
        }

        // Core-options overlay is modal: it drives the model; Circle/Confirm/PS
        // close it and return straight to gameplay (no quick bar re-summon).
        if coreOptionsVisible, let options = emulator?.coreOptions {
            switch action {
            case .up: options.moveCursor(-1)
            case .down: options.moveCursor(1)
            case .left: options.cycleValue(-1)
            case .right: options.cycleValue(1)
            case .confirm:
                // Confirm on the trailing reset row resets (stays open);
                // anywhere else it closes the overlay.
                if options.cursorIsOnResetRow {
                    options.activateResetRow()
                } else {
                    closeCoreOptions()
                }
            case .back, .openQuickBar:
                closeCoreOptions()
            default: break
            }
            return
        }

        // Quick bar open: left/right navigates the pill strip. When the
        // Volume pill is focused, left/right adjusts instead; L2 = mute.
        // Checked BEFORE the Discord float so the bar stays navigable while
        // both are up; unhandled actions fall through to the branches below.
        if quickBarVisible {
            switch action {
            case .left:
                if quickBarModel.selection == .volume {
                    volume.adjust(by: -0.05)
                } else {
                    _ = quickBarModel.handle(.left, items: visibleQuickBarItems)
                }
                return
            case .right:
                if quickBarModel.selection == .volume {
                    volume.adjust(by: 0.05)
                } else {
                    _ = quickBarModel.handle(.right, items: visibleQuickBarItems)
                }
                return
            case .toggleMute:
                volume.toggleMute()
                return
            default:
                break
            }
        }

        // When the Discord floating window is open, the controller drives it.
        // Skipped while the quick bar is open so up/down/confirm keep driving
        // the bar (they fall through to the quick-bar handling below).
        if discord.isFloating, !quickBarVisible {
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
                if isLaunchingGame {
                    exitEmulation() // cancel an in-flight boot
                } else {
                    openPauseMenu()
                }
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
        if let item = quickBarModel.handle(action, items: visibleQuickBarItems) {
            quickBarVisible = false
            quickBarSelect(item)
        }
    }

    // MARK: - XMB

    func rebuildXMB() {
        var cats: [XMBNavModel.Category] = []
        cats.append(category("home", "Home", Theme.homeAccent, homeItems()))
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

    /// Home category: favorites first, then recent launches (deduped).
    private func homeItems() -> [XMBItem] {
        var seen = Set<String>()
        var entries: [GameEntry] = []
        for game in library.favoriteGames {
            seen.insert(game.id)
            entries.append(game)
        }
        for game in library.recentGames where !seen.contains(game.id) {
            seen.insert(game.id)
            entries.append(game)
        }
        return gameItems(entries)
    }

    private func metaLine(for game: GameEntry) -> String {
        var s = game.source.displayName
        if library.favorites.isFavorite(game.id) {
            s = "★ " + s
        }
        if let played = game.lastPlayed {
            s += " · last played \(Self.lastPlayedFormatter.string(from: played))"
        }
        let playtime = library.totalPlaytime(for: game.id)
        if playtime >= 60 {
            s += " · \(PlaytimeFormatter.seconds(playtime)) played"
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

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// "3 hours ago" for RA timestamp strings ("2024-01-01 12:34:56").
    private static func relativeTime(_ iso: String) -> String {
        guard let date = Self.isoDateFormatter.date(from: iso) else { return iso }
        return relativeTime(date)
    }

    private static let lastPlayedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    /// Haptic tick on every selection change.
    func selectionMoved() {
        Haptics.tick()
    }

    func selectCategory(_ id: String) {
        if let idx = xmb.categories.firstIndex(where: { $0.id == id }) {
            xmb.jumpToCategory(at: idx)
            selectionMoved()
        }
    }

    private func xmbConfirm(_ item: XMBItem) {
        if let entry = item.entry {
            Haptics.play(.confirm)
            launch(entry)
        } else if item.isRefresh {
            Task { await raHub.refresh(force: true) }
        } else if let action = item.action {
            switch action {
            case .discord:
                Haptics.play(.confirm)
                discord.toggle()
            case .settings(let kind):
                Haptics.play(.confirm)
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
        case .favorite:
            if let entry = xmb.selectedItem?.entry {
                library.toggleFavorite(entry.id)
                rebuildXMB()
            }
        case .saveState:
            emulator?.requestSaveState()
        case .loadState:
            emulator?.requestLoadState()
        case .reset:
            emulator?.requestReset()
        case .coreOptions:
            openCoreOptions()
        case .volume:
            break // volume adjusts live via left/right while this pill is focused
        }
    }

    // MARK: - Core options overlay

    /// Opens the options overlay and pauses emulation (no gameplay behind the
    /// modal; cores apply changes live via GET_VARIABLE_UPDATE on resume).
    func openCoreOptions() {
        guard screen == .emulator, emulator != nil, !coreOptionsVisible else { return }
        coreOptionsVisible = true
        emulator?.pause()
    }

    func closeCoreOptions() {
        guard coreOptionsVisible else { return }
        coreOptionsVisible = false
        emulator?.resume()
    }

    // MARK: - Pause menu

    /// Opens the in-game pause menu and pauses emulation. Not available while
    /// the core is still booting (2.2).
    func openPauseMenu() {
        guard screen == .emulator, emulator != nil, !coreOptionsVisible, !isLaunchingGame else { return }
        pauseMenu.reset()
        pauseMenuVisible = true
        emulator?.pause()
    }

    func closePauseMenu() {
        guard pauseMenuVisible else { return }
        pauseMenuVisible = false
        emulator?.resume()
    }

    /// Runs the action for a confirmed pause-menu item.
    func pauseMenuAction(_ item: PauseMenuModel.Item) {
        switch item {
        case .resume:
            closePauseMenu()
        case .saveState:
            closePauseMenu()
            emulator?.requestSaveState()
        case .loadState:
            closePauseMenu()
            emulator?.requestLoadState()
        case .coreOptions:
            closePauseMenu()
            openCoreOptions()
        case .reset:
            closePauseMenu()
            emulator?.requestReset()
        case .quit:
            closePauseMenu()
            confirmQuit()
        }
    }

    /// Asks before quitting emulation (unsaved progress). Uses the shared
    /// confirmation overlay.
    private func confirmQuit() {
        let title = emulator?.title ?? "game"
        pendingConfirmation = PendingConfirmation(
            title: "Quit \(title)?",
            message: "Unsaved progress will be lost.",
            confirmLabel: "Quit",
            onConfirm: { [weak self] in self?.exitEmulation() }
        )
    }

    /// Sets the error/notice banner. `autoDismissAfter` (seconds) clears it
    /// without a touch — used for informational notices (permissions prompts).
    private var errorAutoDismissWorkItem: DispatchWorkItem?

    func showError(_ message: String, autoDismissAfter: TimeInterval? = nil,
                   kind: AppError.Kind = .error) {
        errorAutoDismissWorkItem?.cancel()
        activeError = AppError(message: message, kind: kind, autoDismissAfter: autoDismissAfter)
        if kind == .error { Haptics.play(.error) }
        guard let autoDismissAfter else { return }
        let work = DispatchWorkItem { [weak self] in self?.activeError = nil }
        errorAutoDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissAfter, execute: work)
    }

    func dismissError() {
        errorAutoDismissWorkItem?.cancel()
        errorAutoDismissWorkItem = nil
        activeError = nil
    }
}

/// A structured app notice. `kind` drives styling; `autoDismissAfter` (when
/// set) clears it without a touch. Carries an optional retry closure for
/// recoverable failures (artwork / preview / network).
struct AppError: Equatable {
    enum Kind: Equatable { case info, warn, error }
    let message: String
    let kind: Kind
    let autoDismissAfter: TimeInterval?
    var retry: (() -> Void)?

    // Ignore the closure in Equatable comparison.
    static func == (lhs: AppError, rhs: AppError) -> Bool {
        lhs.message == rhs.message && lhs.kind == rhs.kind
            && lhs.autoDismissAfter == rhs.autoDismissAfter
    }
}
