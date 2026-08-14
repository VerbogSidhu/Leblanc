import SwiftUI

/// GameDock design tokens — exact palette from the design brief, XMB-style
/// console UI. Colors are named and used exactly; no substitutions.
enum Theme {
    // MARK: - Core palette (exact hex values from the brief)
    static let void    = Color(hex: 0x0A0D16)   // base background
    static let ink     = Color(hex: 0x12172A)   // panels / surfaces
    static let signal  = Color(hex: 0x4FD3FF)   // primary accent: selection, focus
    static let ember   = Color(hex: 0xFF9F4A)   // "recently played" marker, sparingly
    static let mist    = Color(hex: 0x8B93A7)   // secondary text, unselected
    static let paper   = Color(hex: 0xEDEFF5)   // primary text

    // MARK: - Platform accents (small glow/underline only, never a wash)
    static let steamAccent    = signal
    static let pspAccent      = Color(hex: 0x9B8CFF)   // muted violet
    static let dsAccent       = Color(hex: 0xFF8C8C)   // soft coral
    static let homeAccent     = ember
    static let discordAccent  = Color(hex: 0x7A86C8)
    static let settingsAccent = mist

    // MARK: - Type scale
    /// Horizontal category rail labels. Fixed size.
    static func railLabel(selected: Bool) -> Font {
        GameDockFonts.display(selected ? 22 : 16, weight: selected ? .semibold : .medium)
    }
    /// Selected item title — notably larger than siblings (the primary
    /// "what's selected" signal).
    static let itemTitleSelected = GameDockFonts.display(44, weight: .bold)
    static let itemTitleUnselected = GameDockFonts.display(20, weight: .medium)
    /// Meta line (source, playtime, last played).
    static let meta = GameDockFonts.data(13)
    /// Body / settings text.
    static let body = Font.system(size: 14)
    static let caption = Font.system(size: 12)

    // MARK: - Layout
    static let railHeight: CGFloat = 120
    static let itemCoverWidth: CGFloat = 300
    static let itemCoverAspect: CGFloat = 0.70   // portrait-ish cover
    static let screenPadding: CGFloat = 40

    // MARK: - Motion
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    static let fade = Animation.easeOut(duration: 0.22)
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

/// Placeholder for games without artwork.
enum ArtworkPlaceholder {
    static func gradient(for title: String) -> LinearGradient {
        let h = Double(abs(title.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % 360) / 360.0
        let base = NSColor(hue: h, saturation: 0.10, brightness: 0.24, alpha: 1)
        let edge = NSColor(hue: h, saturation: 0.14, brightness: 0.12, alpha: 1)
        return LinearGradient(colors: [Color(base), Color(edge)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func initials(for title: String) -> String {
        title.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
