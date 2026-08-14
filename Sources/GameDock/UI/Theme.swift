import SwiftUI

/// GameDock design tokens. Minimal, modular: palette, type, spacing, shape.
/// The UI is a scrolling grid — it adapts to any resolution by construction.
enum Theme {
    // MARK: - Palette
    static let void       = Color(hex: 0x0C0D11)
    static let panel      = Color(hex: 0x15161B)
    static let raised     = Color(hex: 0x1D1E24)
    static let ivory      = Color(hex: 0xEDEBE6)
    static let ash        = Color(hex: 0x7A7A80)
    static let amber      = Color(hex: 0xF0A832)
    static let hairline   = Color(hex: 0x26272E)

    // MARK: - Type
    static let wordmark   = Font.system(size: 20, weight: .heavy)
    static let tabLabel   = Font.system(size: 13, weight: .bold)
    static let cardTitle  = Font.system(size: 14, weight: .semibold)
    static let caption    = Font.system(size: 11, weight: .medium)
    static let emptyTitle = Font.system(size: 26, weight: .heavy)

    // Secondary-view aliases (settings rows, emulator hints)
    static let railLabel    = Font.system(size: 12, weight: .semibold)
    static let settingsTitle = Font.system(size: 30, weight: .bold)
    static let hintFont     = caption
    static let cardTitleFont = cardTitle

    // MARK: - Spacing / shape
    static let screenPadding: CGFloat = 28   // window margin
    static let gridGap: CGFloat = 16        // column gap
    static let gridRowGap: CGFloat = 24     // row gap
    static let cardRadius: CGFloat = 10
    static let bannerAspect: CGFloat = 460.0 / 215.0  // Steam header aspect

    // MARK: - Text colors
    static let textPrimary   = ivory
    static let textSecondary = Color(hex: 0xA6A5AC)
    static let textFaint     = ash

    // MARK: - Motion (quiet)
    static let fade: Animation = .easeOut(duration: 0.18)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >>  8) & 0xFF) / 255.0,
            blue:  Double( hex        & 0xFF) / 255.0
        )
    }
}

/// Placeholder for games without artwork: a calm gradient + initials.
enum ArtworkPlaceholder {
    static func gradient(for title: String) -> LinearGradient {
        let h = Double(abs(title.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % 360) / 360.0
        let base = NSColor(hue: h, saturation: 0.10, brightness: 0.26, alpha: 1)
        let edge = NSColor(hue: h, saturation: 0.14, brightness: 0.14, alpha: 1)
        return LinearGradient(colors: [Color(base), Color(edge)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func initials(for title: String) -> String {
        title.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
