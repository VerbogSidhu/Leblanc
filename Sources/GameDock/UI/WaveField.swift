import SwiftUI

/// Drives the ambient wave field: holds the ripples triggered by selection.
final class WaveFieldModel: ObservableObject {
    struct Ripple: Identifiable {
        let id = UUID()
        let x: CGFloat   // normalized 0...1
        let y: CGFloat   // normalized 0...1
        let color: Color
        let start: TimeInterval
    }

    @Published private(set) var ripples: [Ripple] = []

    func emit(x: CGFloat, y: CGFloat, color: Color) {
        let now = CACurrentMediaTime()
        ripples.append(Ripple(x: x, y: y, color: color, start: now))
        // Drop ripples older than their ~700ms life.
        ripples.removeAll { now - $0.start > 0.8 }
    }
}

/// The signature element: a slow, subtle procedurally-drawn wave/ripple field
/// rendered behind everything. Idles as faint moving waves in ink/void tones,
/// ripples outward from the selection with the platform's accent, and tints
/// subtly toward the active platform. Static under reduced motion.
struct WaveField: View {
    @ObservedObject var model: WaveFieldModel
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                drawWaves(ctx, size: size, t: t)
                drawRipples(ctx, size: size, t: context.date.timeIntervalSinceReferenceDate)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Idle waves (very faint, ink/void, ~4% presence)

    private func drawWaves(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let bands: [(base: CGFloat, amp: CGFloat, freq: CGFloat, speed: Double)] = [
            (0.42, 22, 0.006, 0.35),
            (0.55, 30, 0.004, -0.28),
            (0.68, 18, 0.007, 0.22),
            (0.33, 14, 0.005, -0.40),
        ]
        for band in bands {
            var path = Path()
            let y0 = size.height * band.base
            for x in stride(from: 0.0, through: Double(size.width), by: 6.0) {
                let y = y0 + band.amp * sin(band.freq * CGFloat(x) + band.speed * t)
                let p = CGPoint(x: x, y: y)
                x == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            // Ink wave with a whisper of the platform accent.
            let inkTone = Theme.ink
            var stroke = inkTone.opacity(0.5)
            ctx.stroke(path, with: .color(stroke), style: StrokeStyle(lineWidth: 1.2))
            _ = stroke // keep accent tint subtle below
            let accentStroke = accent.opacity(0.05)
            ctx.stroke(path, with: .color(accentStroke), style: StrokeStyle(lineWidth: 3.5))
        }
    }

    // MARK: - Ripples (selection pulse, ~600ms life)

    private func drawRipples(_ ctx: GraphicsContext, size: CGSize, t: TimeInterval) {
        for r in model.ripples {
            let age = t - r.start
            guard age >= 0, age < 0.7 else { continue }
            let progress = age / 0.7
            let center = CGPoint(x: r.x * size.width, y: r.y * size.height)
            let radius = 20 + progress * 160
            let rect = CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2)
            let opacity = (1 - progress) * 0.45
            ctx.stroke(
                Path(ellipseIn: rect),
                with: .color(r.color.opacity(opacity)),
                style: StrokeStyle(lineWidth: 2)
            )
        }
    }
}
