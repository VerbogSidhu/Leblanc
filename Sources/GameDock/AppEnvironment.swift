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
    /// Title used for screenshots when no emulator is active (the last game launched).
    var lastLaunchedTitle = "Capture"

    /// The active embedded-libretro emulator session (nil when not emulating).
    @Published var emulator: EmulatorSession?

    let controllers = ControllerManager()
    private var libraryCancellable: AnyCancellable?
    private var categoryCancellable: AnyCancellable?
    var idleActivity: NSObjectProtocol?

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

        // NOTE: global PS-button capture while another app is frontmost is NOT
        // enabled. Research (Apple DTS) confirmed IOHIDManager global input
        // monitoring is broken/unreliable on macOS 14/15, and GameController
        // only delivers to the frontmost app — so there is no reliable public
        // API for it today. The Cmd+Shift+Home hotkey (AppDelegate) is the
        // permanent cross-process restore mechanism. Revisit GlobalHIDMonitor
        // if/when Apple fixes the HID monitoring bug.

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

    func dismissError() { errorMessage = nil }
}
