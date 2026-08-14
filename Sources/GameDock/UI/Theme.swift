import SwiftUI

/// GameDock's design system — a CRT-operator console aesthetic:
/// warm-ivory text on a cool near-black, one amber phosphor accent,
/// mono chrome (the machine) over proportional titles (the content).
/// See docs/design-spec.md for the rationale behind every choice.
enum Theme {
    // MARK: - Palette (6 + a hairline)
    static let void         = Color(hex: 0x0B0C10)
    static let panel        = Color(hex: 0x141418)
    static let raised       = Color(hex: 0x1E1E25)
    static let ivory        = Color(hex: 0xE9E6DE)
    static let ash          = Color(hex: 0x6E6B63)
    static let amber        = Color(hex: 0xF2A93B)
    static let hairline     = Color(hex: 0x26262E)

    // Legacy aliases kept for callers not yet migrated.
    static let background   = void
    static let textPrimary  = ivory
    static let textSecondary = Color(hex: 0x9A978E)
    static let textFaint    = ash
    static let panelRaised  = raised
    static let accent       = amber
    static let accentWarm   = amber
    static let accentGreen  = amber

    // Platform accents (used in the rail + hero eyebrow). All lean amber-warm-ish
    // so the single-accent discipline holds, but each reads slightly different.
    static let homeAccent   = Color(hex: 0xF2A93B)
    static let steamAccent   = Color(hex: 0xD98A3C)
    static let pspAccent     = Color(hex: 0xF2A93B)
    static let dsAccent      = Color(hex: 0xE0793B)

    // MARK: - Typography
    //
    // Mono = the machine (chrome, labels, counts, hints). Tracked-out uppercase.
    // Proportional = the content (game titles).
    static let wordmark     = Font.system(.body, design: .monospaced).weight(.heavy)
    static let railLabel    = Font.system(size: 11, weight: .semibold, design: .monospaced)
    static let railCount    = Font.system(size: 11, weight: .regular,   design: .monospaced)
    static let eyebrow      = Font.system(size: 11, weight: .semibold,   design: .monospaced)
    static let caption      = Font.system(size: 12, weight: .regular,   design: .monospaced)
    static let hint         = Font.system(size: 12, weight: .semibold,  design: .monospaced)

    static let heroTitle    = Font.system(size: 46, weight: .heavy,     design: .default)
    static let cardTitle    = Font.system(size: 14, weight: .semibold,  design: .default)
    static let settingsTitle = Font.system(size: 40, weight: .heavy,     design: .default)
    static let sectionFont  = Font.system(size: 22, weight: .bold,      design: .default)

    // Legacy (removed by the redesign; kept as aliases so un-migrated views compile)
    static let captionFont  = caption
    static let fontTitle    = Font.system(size: 34, weight: .heavy, design: .default)
    static let titleFont    = fontTitle
    static let cardTitleFont = cardTitle
    static let hintFont     = hint

    // MARK: - Layout
    static let railWidth: CGFloat = 210
    static let cardWidth: CGFloat = 360        // wide 16:9 banner cards
    static let cardArtHeight: CGFloat = 200
    static let cardRadius: CGFloat = 10
    static let heroRadius: CGFloat = 14
    static let gridPadding: CGFloat = 30

    // Legacy
    static let cardHeight: CGFloat = cardArtHeight
    static let cardCornerRadius: CGFloat = cardRadius
    static let sectionSpacing: CGFloat = 26

    // MARK: - Motion
    static let panelSlide: Animation = .easeOut(duration: 0.34)
    static let railSpring: Animation = .spring(response: 0.42, dampingFraction: 0.86)
    static let reticleSpring: Animation = .spring(response: 0.30, dampingFraction: 0.78)
    static let crossfade: Animation = .easeOut(duration: 0.20)
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
        // Tint toward amber so placeholders feel like the brand, not random.
        let base = NSColor(hue: h, saturation: 0.10, brightness: 0.20, alpha: 1)
        let edge = NSColor(hue: h, saturation: 0.16, brightness: 0.10, alpha: 1)
        return LinearGradient(colors: [Color(base), Color(edge)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func initials(for title: String) -> String {
        let parts = title.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}