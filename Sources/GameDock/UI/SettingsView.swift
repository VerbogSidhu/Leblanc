import AppKit
import SwiftUI

/// Controller-navigable settings page in the brand system: settings title,
/// mono section eyebrows, amber selection bar, hairline rows. A adds/removes,
/// B returns home, PS opens the quick bar.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("SETTINGS")
                        .font(Theme.settingsTitle)
                        .tracking(1.0)
                        .foregroundStyle(Theme.ivory)
                        .padding(.bottom, 6)

                    Text("A · Add / Remove / Set      B · Back      PS · Quick bar")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.ash)
                        .padding(.bottom, 24)

                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            settingsRow(row, index: index)
                                .id("setting-\(row.id)")
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
            .onChange(of: model.selection) { newSel in
                guard model.rows.indices.contains(newSel) else { return } // bounds-check (audit P1)
                withAnimation(reduceMotion ? .none : Theme.fade) {
                    proxy.scrollTo("setting-\(model.rows[newSel].id)", anchor: .center)
                }
            }
        }
        .background(Theme.void.ignoresSafeArea())
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
            // Amber selection bar (same language as the rail's active channel).
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.amber)
                .frame(width: 3, height: 26)
                .opacity(selected ? 1 : 0)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(Theme.railLabel)
                    .tracking(0.6)
                    .foregroundStyle(selected ? Theme.ivory : Theme.textSecondary)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ash)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if selected {
                Text(iconLabel(for: row.kind).uppercased())
                    .font(Theme.caption)
                    .foregroundStyle(Theme.amber)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            selected ? Theme.raised : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? .clear : Theme.hairline.opacity(0.6), lineWidth: 1)
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
