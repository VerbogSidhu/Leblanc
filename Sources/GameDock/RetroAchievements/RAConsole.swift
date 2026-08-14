import Foundation

/// Maps GameDock's `GameSource` to RetroAchievements console identifiers.
/// Values come from `rc_consoles.h` (vendored rcheevos v12.4.0):
///   RC_CONSOLE_NINTENDO_DS = 18
///   RC_CONSOLE_PSP         = 41
enum RAConsole {
    static func id(for source: GameSource) -> UInt32? {
        switch source {
        case .ds:  return 18   // RC_CONSOLE_NINTENDO_DS
        case .psp: return 41   // RC_CONSOLE_PSP
        case .steam: return nil
        }
    }
}
