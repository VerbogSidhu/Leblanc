import SwiftUI

/// Central visual language — dark console dashboard.
enum Theme {
    // Surfaces
    static let background = Color(red: 0.055, green: 0.060, blue: 0.085)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.16)
    static let panelRaised = Color(red: 0.16, green: 0.17, blue: 0.23)

    // Accents
    static let accent = Color(red: 0.25, green: 0.62, blue: 1.00)   // PS-ish blue
    static let accentWarm = Color(red: 1.00, green: 0.55, blue: 0.20)
    static let accentGreen = Color(red: 0.30, green: 0.85, blue: 0.50)

    // Platform accents (home panels)
    static let homeAccent = accent
    static let steamAccent = Color(red: 0.30, green: 0.62, blue: 0.95)
    static let pspAccent = Color(red: 0.10, green: 0.55, blue: 0.95)
    static let dsAccent = Color(red: 0.95, green: 0.42, blue: 0.32)

    // Text
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let textFaint = Color.white.opacity(0.32)

    // Typography
    static let titleFont = Font.system(size: 34, weight: .heavy, design: .rounded)
    static let sectionFont = Font.system(size: 22, weight: .bold, design: .rounded)
    static let cardTitleFont = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let captionFont = Font.system(size: 12, weight: .medium, design: .rounded)
    static let hintFont = Font.system(size: 13, weight: .regular, design: .rounded)

    // Layout
    static let cardWidth: CGFloat = 264
    static let cardHeight: CGFloat = 148
    static let cardCornerRadius: CGFloat = 12
    static let gridPadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 26
}

/// Fallback gradient placeholder for games without artwork.
enum ArtworkPlaceholder {
    static func gradient(for title: String) -> LinearGradient {
        let hue = Double(abs(title.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % 360) / 360.0
        let base = NSColor(hue: hue, saturation: 0.35, brightness: 0.45, alpha: 1)
        let darker = NSColor(hue: hue, saturation: 0.45, brightness: 0.25, alpha: 1)
        return LinearGradient(
            colors: [Color(base), Color(darker)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func initials(for title: String) -> String {
        let parts = title.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
