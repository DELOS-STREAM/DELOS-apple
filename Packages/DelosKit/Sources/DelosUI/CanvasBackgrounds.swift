import DelosData
import SwiftUI

/// The backgrounds drawn as shapes on the canvas (Aurora, Tide, Silk): ports of `drawAurora`, `drawTide` and `drawSilk`
/// in DELOS for Android (`shell/ui/Backdrop.kt`), in canvas pixels; keep both in step. The context is already scaled
/// to canvas pixels and holds the base gradient.
enum CanvasBackgrounds {
    static func draw(_ kind: BackgroundKind, in context: inout GraphicsContext, _ p: BackgroundParams) {
        switch kind {
        case .aurora: aurora(&context, p)
        case .tide: tide(&context, p)
        case .silk: silk(&context, p)
        default: break
        }
    }

    /// Plus in the dark theme (the lights add up), over in the light one.
    private static func blend(_ p: BackgroundParams) -> GraphicsContext.BlendMode { p.dark ? .plusLighter : .normal }

    private static func aurora(_ context: inout GraphicsContext, _ p: BackgroundParams) {
        // The main color twice, the secondary and the accent once, the accent fainter: about 50 / 35 / 15
        let hues = [p.acc, p.tint, p.acc, p.acc3]
        let t = p.t
        let rect = Path(CGRect(x: 0, y: 0, width: p.w, height: p.h))
        context.blendMode = blend(p)
        for (i, h) in hues.enumerated() {
            let fi = Double(i)
            let x = p.w * (0.5 + 0.38 * sin(t * 0.11 + fi * 1.9))
            let y = p.h * (0.45 + 0.32 * cos(t * 0.09 + fi * 1.3))
            let r = p.w * (0.42 + 0.08 * sin(t * 0.2 + fi))
            let sat = p.s(h)
            let w = i == 3 ? 0.6 : 1
            let inner = p.dark ? hsl(h, 85 * sat, 52, 0.32 * w) : hsl(h, 80 * sat, 70, 0.45 * w)
            context.fill(rect, with: .radialGradient(
                Gradient(colors: [inner.color, hsl(h, 80, 50, 0).color]),
                center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r
            ))
        }
        context.blendMode = .normal
    }

    private static func tide(_ context: inout GraphicsContext, _ p: BackgroundParams) {
        let t = p.t
        for i in 0..<6 {
            let fi = Double(i)
            // From a third of the height down: the waves fill the lower two thirds
            let y0 = p.h * (0.34 + fi * 0.11)
            let amp = 14 + fi * 4
            let k = 0.006 + fi * 0.0015
            let sp = 0.35 + fi * 0.12
            var path = Path()
            path.move(to: CGPoint(x: 0, y: p.h))
            var x = 0.0
            while x <= p.w {
                path.addLine(to: CGPoint(x: x, y: y0 + sin(x * k + t * sp + fi) * amp + sin(x * k * 2.3 - t * sp * 0.7) * amp * 0.35))
                x += 12
            }
            path.addLine(to: CGPoint(x: p.w, y: p.h))
            path.closeSubpath()
            // Three of the six waves in the main color, two in the secondary one, one in the accent
            let h = switch i {
            case 1, 3: p.tint
            case 4: p.acc3
            default: p.acc
            }
            let sat = 70 * p.s(h)
            let color = p.dark ? hsl(h, sat, 30 + fi * 5, 0.2 + fi * 0.04) : hsl(h, sat, 70 - fi * 4, 0.22 + fi * 0.05)
            context.fill(path, with: .color(color.color))
        }
    }

    /// Silk samples every 16 px from -80 to w + 80.
    static func silkPoints(_ w: Double) -> Int { Int((w + 160) / 16) + 1 }

    private static func silk(_ context: inout GraphicsContext, _ p: BackgroundParams) {
        // Flowing satin ribbons; a band twists where its width crosses zero
        let ribbons = [p.acc, p.tint, p.acc, p.acc3]
        let t = p.t
        var c = context
        c.blendMode = blend(p)
        c.translateBy(x: p.w / 2, y: p.h / 2)
        c.rotate(by: .radians(-0.21))
        c.translateBy(x: -p.w / 2, y: -p.h / 2)
        let count = silkPoints(p.w)
        for (i, h) in ribbons.enumerated() {
            let fi = Double(i)
            let sat = p.s(h)
            let y0 = p.h * (0.22 + fi * 0.18)
            let ph = fi * 1.7
            let sp = 0.18 + fi * 0.05
            var top: [CGPoint] = []
            var bottom: [CGPoint] = []
            top.reserveCapacity(count)
            bottom.reserveCapacity(count)
            for j in 0..<count {
                let x = -80 + Double(j) * 16
                let y = y0 + sin(x * 0.006 + t * sp + ph) * 46 + sin(x * 0.013 - t * sp * 1.3 + ph * 2) * 18
                let w = 64 * sin(x * 0.0042 + t * 0.22 + ph) + 10 * sin(x * 0.02 + t)
                top.append(CGPoint(x: x, y: y - w / 2))
                bottom.append(CGPoint(x: x, y: y + w / 2))
            }
            var sheen = Path()
            sheen.addLines(top)
            var fill = sheen
            for point in bottom.reversed() { fill.addLine(to: point) }
            fill.closeSubpath()
            let a = (p.dark ? 0.26 : 0.3) * (i == 3 ? 0.6 : 1)
            let l = p.dark ? 60.0 : 62.0
            let gradient = Gradient(stops: [
                .init(color: hsl(h, 85 * sat, l, 0).color, location: 0),
                .init(color: hsl(h, 85 * sat, l, a).color, location: 0.3),
                .init(color: hsl(h + 30, 85 * sat, l + 8, a).color, location: 0.7),
                .init(color: hsl(h, 85 * sat, l, 0).color, location: 1),
            ])
            c.fill(
                fill,
                with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: p.w, y: 0)),
                style: FillStyle(eoFill: true)
            )
            // Sheen along one edge of the ribbon
            c.stroke(
                sheen,
                with: .color(hsl(h + 30, 90 * sat, p.dark ? 80 : 45, p.dark ? 0.18 : 0.22).color),
                style: StrokeStyle(lineWidth: 1.2)
            )
        }
    }
}
