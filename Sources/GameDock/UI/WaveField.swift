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
        ripples.removeAll { now - $0.start > 0.8 }
    }
}

/// The signature element: a full-bleed, slowly drifting wave field rendered
/// behind everything. 4 overlapping sine layers at different amplitudes and
/// speeds, present but calm (~8-15% presence), tinted toward the platform
/// accent. Selection changes inject a radial ripple in the accent color.
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

    // MARK: - Idle waves

    private func drawWaves(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        // (baseY fraction, amplitude, wavelength fraction, speed, ink opacity, accent opacity)
        let layers: [(CGFloat, CGFloat, CGFloat, Double, Double, Double)] = [
            (0.38, 40, 0.85,  0.32,  0.13, 0.05),
            (0.50, 56, 1.30, -0.24,  0.11, 0.04),
            (0.62, 34, 0.60,  0.41,  0.09, 0.05),
            (0.74, 48, 1.00, -0.35,  0.07, 0.03),
            (0.28, 26, 1.60,  0.20,  0.08, 0.04),
        ]
        for layer in layers {
            var path = Path()
            let yBase = size.height * layer.0
            for x in stride(from: 0.0, through: Double(size.width), by: 5.0) {
                let wave = sin((layer.2 * CGFloat(x) / size.width) * 2 * .pi + layer.3 * t)
                let y = yBase + layer.1 * wave
                let p = CGPoint(x: x, y: y)
                x == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            // Fill the region below each wave toward the bottom for a "field" feel.
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()

            let base = Theme.ink.opacity(layer.4)
            ctx.fill(path, with: .color(base))
            ctx.stroke(path, with: .color(accent.opacity(layer.5)), style: StrokeStyle(lineWidth: 2))
        }
    }

    // MARK: - Ripples

    private func drawRipples(_ ctx: GraphicsContext, size: CGSize, t: TimeInterval) {
        for r in model.ripples {
            let age = t - r.start
            guard age >= 0, age < 0.7 else { continue }
            let progress = age / 0.7
            let center = CGPoint(x: r.x * size.width, y: r.y * size.height)
            let radius = 24 + progress * 200
            let rect = CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2)
            ctx.stroke(
                Path(ellipseIn: rect),
                with: .color(r.color.opacity((1 - progress) * 0.5)),
                style: StrokeStyle(lineWidth: 2.5)
            )
            ctx.fill(
                Path(ellipseIn: rect),
                with: .color(r.color.opacity((1 - progress) * 0.05))
            )
        }
    }
}
