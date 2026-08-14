import SwiftUI

/// GameDock design tokens — deliberately basic: dark, clean, one accent.
/// The launcher is a grid of wide banner cards; nothing competes with the art.
/// See docs/design-spec.md for the original direction; this is the simplified
/// take after user feedback ("basic but good").
enum Theme {
    // MARK: - Palette
    static let void        = Color(hex: 0x0C0D11)
    static let panel       = Color(hex: 0x15161B)
    static let raised      = Color(hex: 0x1D1E24)
    static let ivory       = Color(hex: 0xEDEBE6)
    static let ash         = Color(hex: 0x7A7A80)
    static let amber       = Color(hex: 0xF0A832)   // the one accent
    static let hairline    = Color(hex: 0x26272E)

    // Aliases (legacy callers)
    static let background   = void
    static let textPrimary  = ivory
    static let textSecondary = Color(hex: 0xA6A5AC)
    static let textFaint    = ash
    static let panelRaised  = raised
    static let accent       = amber
    static let accentWarm   = amber
    static let accentGreen  = amber
    static let homeAccent   = amber
    static let steamAccent  = amber
    static let pspAccent    = amber
    static let dsAccent     = amber

    // MARK: - Typography (simple hierarchy, default design)
    static let wordmark       = Font.system(size: 20, weight: .heavy)
    static let titleFont      = Font.system(size: 28, weight: .bold)
    static let sectionFont    = Font.system(size: 18, weight: .bold)
    static let cardTitleFont  = Font.system(size: 14, weight: .semibold)
    static let captionFont    = Font.system(size: 11, weight: .medium)
    static let hintFont       = Font.system(size: 12, weight: .medium)
    static let railLabel      = Font.system(size: 12, weight: .semibold)
    static let railCount      = Font.system(size: 11, weight: .regular)
    static let eyebrow        = Font.system(size: 11, weight: .semibold)
    static let caption        = captionFont
    static let hint           = hintFont
    static let heroTitle      = Font.system(size: 30, weight: .bold)
    static let cardTitle      = cardTitleFont
    static let settingsTitle  = Font.system(size: 30, weight: .bold)
    static let fontTitle      = titleFont

    // MARK: - Layout (consistent clearances)
    static let gridPadding: CGFloat = 32   // window margin
    static let cardRadius: CGFloat = 10
    static let cardGap: CGFloat = 18
    static let rowGap: CGFloat = 22
    static let cardWidth: CGFloat = 320
    static let cardArtHeight: CGFloat = 180
    static let cardAspect: CGFloat = 460.0 / 215.0   // Steam header aspect
    static let heroRadius: CGFloat = 12
    static let railWidth: CGFloat = 200
    static let cardHeight = cardArtHeight
    static let cardCornerRadius = cardRadius
    static let sectionSpacing: CGFloat = 24

    // MARK: - Motion (quiet)
    static let panelSlide: Animation = .easeOut(duration: 0.22)
    static let railSpring: Animation = .easeOut(duration: 0.22)
    static let reticleSpring: Animation = .easeOut(duration: 0.18)
    static let crossfade: Animation = .easeOut(duration: 0.18)
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

/// Fallback gradient placeholder for games without artwork.
enum ArtworkPlaceholder {
    static func gradient(for title: String) -> LinearGradient {
        let h = Double(abs(title.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % 360) / 360.0
        let base = NSColor(hue: h, saturation: 0.12, brightness: 0.24, alpha: 1)
        let edge = NSColor(hue: h, saturation: 0.18, brightness: 0.12, alpha: 1)
        return LinearGradient(colors: [Color(base), Color(edge)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func initials(for title: String) -> String {
        let parts = title.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
