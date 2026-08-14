import AppKit
import CoreText
import SwiftUI

/// Registers the bundled open-source fonts (Chakra Petch for display/labels,
/// JetBrains Mono for data) and exposes them as SwiftUI Fonts with system
/// fallbacks if registration ever fails.
enum GameDockFonts {
    static func registerAll() {
        guard let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil) else {
            Log.warn("GameDockFonts: font resources not found — using system fallbacks")
            return
        }
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                Log.warn("GameDockFonts: failed to register \(url.lastPathComponent)")
            }
        }
    }

    // MARK: - Display / labels (Chakra Petch)

    /// Note: do NOT chain `.weight()` on a custom font — that makes SwiftUI
    /// fall back to the system font. The weight is baked into the chosen file.
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy: name = "ChakraPetch-Bold"
        case .semibold: name = "ChakraPetch-SemiBold"
        case .medium: name = "ChakraPetch-Medium"
        default: name = "ChakraPetch-Regular"
        }
        return Font.custom(name, size: size)
    }

    // MARK: - Data / utility (JetBrains Mono)

    static func data(_ size: CGFloat) -> Font {
        Font.custom("JetBrainsMono-Regular", size: size)
    }
}
