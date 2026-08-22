import Foundation

/// Shared "14h 32m"-style playtime formatting. Used by the XMB meta line and
/// the selection preview panel; Steam (`localconfig.vdf`, minutes) and Leblanc
/// session tracking (seconds) both funnel through here so the two sources
/// render identically.
enum PlaytimeFormatter {
    /// Formats a whole-minute duration: "14h 32m", "2h", "5m", "0m".
    static func minutes(_ totalMinutes: Int) -> String {
        let m = max(0, totalMinutes)
        let h = m / 60
        let rem = m % 60
        if h > 0 { return rem > 0 ? "\(h)h \(rem)m" : "\(h)h" }
        return "\(m)m"
    }

    /// Formats a TimeInterval (seconds) with minute granularity.
    /// Non-finite (NaN/infinite) inputs count as 0; oversized values are
    /// clamped so the Int conversion can never trap.
    static func seconds(_ totalSeconds: TimeInterval) -> String {
        guard totalSeconds.isFinite else { return minutes(0) }
        let clamped = min(max(totalSeconds, 0), Double(Int.max) / 60)
        return minutes(Int(clamped) / 60)
    }
}
