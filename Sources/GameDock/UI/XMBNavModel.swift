import SwiftUI

/// An item in a category's vertical stack — either a game (launchable) or an
/// action (Discord, a settings row).
struct XMBItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let entry: GameEntry?
    let action: XMBAction?
}

enum XMBAction: Equatable {
    case discord
    case settings(SettingsNavModel.RowKind)
}

/// Navigation state for the XMB: a horizontal rail of categories, each with a
/// vertical stack of items. Left/right = categories, up/down = items — the UI
/// grammar matches the DualSense grammar exactly.
final class XMBNavModel: ObservableObject {
    struct Category: Identifiable, Equatable {
        let id: String
        let title: String
        let accent: Color
        let items: [XMBItem]
    }

    @Published private(set) var categories: [Category] = []
    @Published var categoryIndex = 0
    @Published var itemIndex = 0

    var currentCategory: Category? {
        categories.indices.contains(categoryIndex) ? categories[categoryIndex] : nil
    }

    var selectedItem: XMBItem? {
        guard let cat = currentCategory, cat.items.indices.contains(itemIndex) else { return nil }
        return cat.items[itemIndex]
    }

    func rebuild(_ newCategories: [Category]) {
        categories = newCategories
        categoryIndex = min(categoryIndex, max(0, categories.count - 1))
        clampItem()
    }

    // MARK: - Movement

    func left() {
        guard categoryIndex > 0 else { return }
        categoryIndex -= 1
        itemIndex = 0
    }

    func right() {
        guard categoryIndex < categories.count - 1 else { return }
        categoryIndex += 1
        itemIndex = 0
    }

    func up() {
        itemIndex = max(0, itemIndex - 1)
    }

    func down() {
        guard let cat = currentCategory else { return }
        itemIndex = min(cat.items.count - 1, itemIndex + 1)
    }

    /// Applies an action; returns the confirmed item (on .confirm), if any.
    func handle(_ action: GamepadUIAction) -> XMBItem? {
        switch action {
        case .left: left()
        case .right: right()
        case .up: up()
        case .down: down()
        case .previousPanel:  // L1: jump up through a long stack
            for _ in 0..<5 { up() }
        case .nextPanel:      // R1: jump down through a long stack
            for _ in 0..<5 { down() }
        case .confirm: return selectedItem
        default: break
        }
        return nil
    }

    private func clampItem() {
        guard let cat = currentCategory else { itemIndex = 0; return }
        itemIndex = min(itemIndex, max(0, cat.items.count - 1))
    }
}
