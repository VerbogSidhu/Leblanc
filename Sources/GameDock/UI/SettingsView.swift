import AppKit
import SwiftUI

/// Controller-navigable settings screen: ROM folders per system, core path
/// status, and a rescan action. Rows are selected with up/down, activated
/// with A (opens a folder picker / removes a path), B returns home.
final class SettingsNavModel: ObservableObject {
    enum RowKind: Equatable {
        case addFolder(GameSource)
        case folder(GameSource, Int)       // remove a folder path
        case core(GameSource)              // set core override
        case standaloneApp(String)         // set standalone emulator app path (settings key)
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
                kind: .addFolder(source) // header row doubles as "add"
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

        // Standalone emulator path (PPSSPP uses the user's own install).
        let ppssppPath = settings.standaloneAppPath(for: "ppsspp")
            ?? StandaloneEmulatorLauncher.AppKind.ppsspp.defaultBundlePath
        newRows.append(Row(
            id: "app-ppsspp",
            title: "PPSSPP app",
            detail: "\(URL(fileURLWithPath: ppssppPath).lastPathComponent) — \(ppssppPath)",
            kind: .standaloneApp("ppsspp")
        ))

        newRows.append(Row(id: "rescan", title: "Rescan libraries", detail: "\(library.games.count) games currently", kind: .rescan))

        let selectionIsValid = newRows.indices.contains(selection)
        rows = newRows
        selection = selectionIsValid ? selection : 0
    }

    func handle(_ action: GamepadUIAction) -> RowKind? {
        switch action {
        case .up:
            if selection > 0 { selection -= 1 }
        case .down:
            if selection < rows.count - 1 { selection += 1 }
        case .confirm:
            guard rows.indices.contains(selection) else { return nil }
            return rows[selection].kind
        default:
            break
        }
        return nil
    }
}

struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var model: SettingsNavModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(Theme.titleFont)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.bottom, 12)

                    Text("A: add / remove / set · B: back · PS: quick bar")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textFaint)
                        .padding(.bottom, 8)

                    LazyVStack(spacing: 4) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            settingsRow(row, index: index)
                                .id("setting-\(row.id)")
                        }
                    }
                }
                .padding(Theme.gridPadding)
            }
            .onChange(of: model.selection) { _, newSel in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("setting-\(model.rows[newSel].id)", anchor: .center)
                }
            }
        }
        .onAppear {
            model.rebuild(settings: env.settings, library: env.library)
        }
        .onChange(of: env.settings.romFolders) { _, _ in
            model.rebuild(settings: env.settings, library: env.library)
        }
    }

    private func settingsRow(_ row: SettingsNavModel.Row, index: Int) -> some View {
        let selected = model.selection == index
        return HStack(spacing: 12) {
            Image(systemName: selected ? "chevron.right" : "circle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(selected ? Theme.accent : Theme.textFaint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(Theme.hintFont)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if selected {
                Text(iconLabel(for: row.kind))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            selected ? Theme.panelRaised : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if index != model.selection {
                model.selection = index
            } else if let kind = model.handle(.confirm) {
                env.settingsAction(kind)
            }
        }
    }

    private func iconLabel(for kind: SettingsNavModel.RowKind) -> String {
        switch kind {
        case .addFolder: return "add folder"
        case .folder: return "remove"
        case .core: return "set path"
        case .standaloneApp: return "set path"
        case .rescan: return "run"
        }
    }
}
