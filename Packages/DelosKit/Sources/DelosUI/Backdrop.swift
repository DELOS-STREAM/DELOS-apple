import SwiftUI

/// The animated background behind every screen. Only Contour exists so far (the default background of DELOS for
/// Android); it is drawn on a 960 × 540 canvas that keeps its proportions and grows along the axis with more room.
public struct Backdrop: View {
    @Environment(\.delosColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    /// The canvas size of the backgrounds, in canvas pixels.
    static let canvas = CGSize(width: 960, height: 540)

    public init() {}

    public var body: some View {
        // The prototype advances its clock by 0.016 per 60 Hz frame (0.96 per second); reduced motion slows it down
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            let t = context.date.timeIntervalSince(start) * 0.96 * (reduceMotion ? 0.15 : 1)
            GeometryReader { proxy in
                let unit = min(proxy.size.width / Self.canvas.width, proxy.size.height / Self.canvas.height)
                let res = CGSize(width: proxy.size.width / unit, height: proxy.size.height / unit)
                ZStack {
                    base
                    contour(unit: unit, res: res, t: t, size: proxy.size)
                }
            }
        }
        .ignoresSafeArea()
    }

    private var base: some View {
        LinearGradient(
            colors: colors.dark
                ? [hsl(colors.baseHue, 40, 8).color, hsl(colors.baseHue, 38, 5).color]
                : [hsl(colors.baseHue, 45, 96).color, hsl(colors.baseHue, 38, 90).color],
            startPoint: .top, endPoint: .bottom
        )
    }

    private func contour(unit: CGFloat, res: CGSize, t: Double, size: CGSize) -> some View {
        let dark = colors.dark
        let lightness = dark ? 68.0 : 40.0
        let c1 = hsl(colors.accentHue, 80, lightness)
        let c2 = hsl(colors.accent2Hue, 80, lightness)
        let blend: BlendMode = dark ? .plusLighter : .normal
        return ZStack {
            // The glow under the lines
            RadialGradient(
                colors: [hsl(colors.accentHue, 80, dark ? 50 : 70, dark ? 0.14 : 0.2).color, hsl(colors.accentHue, 80, 50, 0).color],
                center: UnitPoint(x: 0.66, y: 0.5), startRadius: 0, endRadius: size.width * 0.55
            )
            .blendMode(blend)
            Rectangle()
                .colorEffect(
                    ShaderLibrary.bundle(.module).delosContour(
                        .float(unit), .float2(res), .float(t),
                        .color(c1.color), .color(c2.color), .float(dark ? 1 : 0)
                    )
                )
                .blendMode(blend)
        }
    }
}
