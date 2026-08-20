import AppKit
import Foundation
import UniformTypeIdentifiers

/// Settings row actions for AppEnvironment: ROM folder management, core
/// overrides, standalone-app paths, RetroAchievements credentials, and toggles.
/// Rendered as the Settings category's item stack (SettingsNavModel rows).
extension AppEnvironment {
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
            // Destructive: confirm before removing (games stay on disk).
            let path = (settings.romFolders[source] ?? []).indices.contains(index)
                ? (settings.romFolders[source] ?? [])[index] : ""
            pendingConfirmation = PendingConfirmation(
                title: "Remove ROM folder",
                message: "Remove \(path)?\nGames on disk are not deleted — Leblanc just stops scanning this folder.",
                confirmLabel: "Remove",
                onConfirm: { [weak self] in
                    guard let self else { return }
                    self.settings.removeROMFolder(at: index, for: source)
                    self.library.refresh()
                }
            )
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
            // A manual library refresh also refreshes the preview caches
            // (Steam screenshots + localconfig playtime).
            SteamScreenshotStore.shared.invalidate()
            SteamLocalConfigReader.shared.invalidate()
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
            // Cancel keeps the current path — only an explicit pick changes it.
            guard response == .OK, let path = panel.url?.path else { return }
            self.settings.setStandaloneAppPath(path, for: key)
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
            // Cancel keeps the current override — only an explicit pick changes it.
            guard response == .OK, let path = panel.url?.path else { return }
            self.settings.setCoreOverride(path, for: source)
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
}
