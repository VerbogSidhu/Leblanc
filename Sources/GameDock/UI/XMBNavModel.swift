import SwiftUI

/// An item in a category's vertical stack — a game, an action, or a
/// RetroAchievements hub entry (profile / unlock / completion / refresh).
struct XMBItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let entry: GameEntry?
    let action: XMBAction?

    var profile: RAProfile?
    var unlock: RARecentAchievement?
    var completion: RACompletionProgressEntry?
    var isRefresh = false

    enum Kind {
        case game, action, profile, unlock, completion, refresh
    }

    var kind: Kind {
        if entry != nil { return .game }
        if action != nil { return .action }
        if profile != nil { return .profile }
        if unlock != nil { return .unlock }
        if completion != nil { return .completion }
        if isRefresh { return .refresh }
        return .action
    }
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

    /// Last item position per category id, so leaving and returning to a
    /// category (or clicking its rail tab again) restores the cursor.
    private var lastItemIndexByCategory: [String: Int] = [:]

    var currentCategory: Category? {
        categories.indices.contains(categoryIndex) ? categories[categoryIndex] : nil
    }

    var selectedItem: XMBItem? {
        guard let cat = currentCategory, cat.items.indices.contains(itemIndex) else { return nil }
        return cat.items[itemIndex]
    }

    func rebuild(_ newCategories: [Category]) {
        // Preserve selection by identity across rebuilds (library refresh,
        // favorite toggle): the same game must stay under the cursor even
        // when its index shifts. Fall back to a plain clamp on miss.
        let selectedCategoryID = categories.indices.contains(categoryIndex)
            ? categories[categoryIndex].id : nil
        let selectedItemID = selectedItem?.id

        categories = newCategories

        if let selectedCategoryID,
           let idx = categories.firstIndex(where: { $0.id == selectedCategoryID }) {
            categoryIndex = idx
        } else {
            categoryIndex = min(categoryIndex, max(0, categories.count - 1))
        }

        if let selectedItemID,
           let cat = currentCategory,
           let idx = cat.items.firstIndex(where: { $0.id == selectedItemID }) {
            itemIndex = idx
        } else {
            clampItem()
        }
    }

    // MARK: - Movement

    func left() { previousCategory() }
    func right() { nextCategory() }

    /// L1: previous category.
    func previousPanel() { previousCategory() }
    /// R1: next category.
    func nextPanel() { nextCategory() }

    private func previousCategory() {
        guard categories.count > 1 else { return }
        leaveCategory()
        categoryIndex = (categoryIndex - 1 + categories.count) % categories.count
        enterCategory()
    }

    private func nextCategory() {
        guard categories.count > 1 else { return }
        leaveCategory()
        categoryIndex = (categoryIndex + 1) % categories.count
        enterCategory()
    }

    /// Jumps directly to a category (quick bar / tab clicks), not one step.
    /// Restores the category's last item position instead of resetting to 0.
    func jumpToCategory(at index: Int) {
        guard categories.indices.contains(index) else { return }
        leaveCategory()
        categoryIndex = index
        enterCategory()
    }

    /// Selects a specific item in the current category by id (mouse click on
    /// a card).
    func jumpToItem(id: String) {
        guard let cat = currentCategory, let idx = cat.items.firstIndex(where: { $0.id == id }) else { return }
        itemIndex = idx
    }

    private func leaveCategory() {
        guard let cat = currentCategory else { return }
        lastItemIndexByCategory[cat.id] = itemIndex
    }

    private func enterCategory() {
        guard let cat = currentCategory else { itemIndex = 0; return }
        let last = lastItemIndexByCategory[cat.id] ?? 0
        itemIndex = min(last, max(0, cat.items.count - 1))
    }

    func up() {
        guard let cat = currentCategory, !cat.items.isEmpty else { return }
        itemIndex = (itemIndex - 1 + cat.items.count) % cat.items.count
    }

    func down() {
        guard let cat = currentCategory, !cat.items.isEmpty else { return }
        itemIndex = (itemIndex + 1) % cat.items.count
    }

    /// Applies an action; returns the confirmed item (on .confirm), if any.
    /// D-pad up/down = items; left/right = categories (PSP/PS3 XMB muscle
    /// memory); L1/R1 = accelerated category switch.
    func handle(_ action: GamepadUIAction) -> XMBItem? {
        switch action {
        case .up: up()
        case .down: down()
        case .left: left()
        case .right: right()
        case .previousPanel: previousPanel()   // L1: previous category
        case .nextPanel: nextPanel()           // R1: next category
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
