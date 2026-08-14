import SwiftUI

/// Settings rows (rendered as the Settings category's item stack in the XMB).
final class SettingsNavModel: ObservableObject {
    enum RowKind: Equatable {
        case addFolder(GameSource)
        case folder(GameSource, Int)       // remove a folder path
        case core(GameSource)              // set core override
        case standaloneApp(String)         // set standalone emulator app path
        case raUsername                    // edit RA username + API token
        case raHardcore                    // toggle hardcore
        case raUnofficial                  // toggle unofficial achievements
        case rescan
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String?
        let kind: RowKind
    }

    @Published private(set) var rows: [Row] = []
    @Published var selection = 0

    func rebuild(settings: SettingsStore, library: LibraryStore) {
        var newRows: [Row] = []

        for source in [GameSource.psp, GameSource.ds] {
            let folders = settings.romFolders[source] ?? []
            newRows.append(Row(
                id: "header-\(source.rawValue)",
                title: "\(source.displayName) ROM folders",
                detail: folders.isEmpty ? "none configured" : nil,
                kind: .addFolder(source)
            ))
            for (index, path) in folders.enumerated() {
                newRows.append(Row(
                    id: "folder-\(source.rawValue)-\(index)",
                    title: "  \(URL(fileURLWithPath: path).lastPathComponent)",
                    detail: path,
                    kind: .folder(source, index)
                ))
            }
        }

        for source in [GameSource.psp, GameSource.ds] {
            let corePath = CoreLocator.resolveCorePath(for: source, settings: settings)
            newRows.append(Row(
                id: "core-\(source.rawValue)",
                title: "\(source.displayName) core",
                detail: corePath.map { "\(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "not found — drop core in \(AppPaths.coresDir.path)",
                kind: .core(source)
            ))
        }

        let ppssppPath = settings.standaloneAppPath(for: "ppsspp")
            ?? StandaloneEmulatorLauncher.AppKind.ppsspp.defaultBundlePath
        newRows.append(Row(
            id: "app-ppsspp",
            title: "PPSSPP app",
            detail: "\(URL(fileURLWithPath: ppssppPath).lastPathComponent) — \(ppssppPath)",
            kind: .standaloneApp("ppsspp")
        ))

        newRows.append(Row(id: "rescan", title: "Rescan libraries", detail: "\(library.games.count) games currently", kind: .rescan))

        // RetroAchievements
        newRows.append(Row(
            id: "ra-username",
            title: "RA Sign in",
            detail: settings.raConfigured ? "signed in as \(settings.raUsername ?? "?")" : "not signed in",
            kind: .raUsername
        ))
        newRows.append(Row(
            id: "ra-hardcore",
            title: "RA Hardcore mode",
            detail: settings.raHardcore ? "on" : "off",
            kind: .raHardcore
        ))
        newRows.append(Row(
            id: "ra-unofficial",
            title: "RA Unofficial achievements",
            detail: settings.raUnofficial ? "on" : "off",
            kind: .raUnofficial
        ))

        let valid = newRows.indices.contains(selection)
        rows = newRows
        selection = valid ? selection : 0
    }
}
