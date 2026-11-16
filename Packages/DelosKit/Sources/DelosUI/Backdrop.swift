import DelosData
import SwiftUI

/// The animated background behind every screen, as `AnimatedBackground` in DELOS for Android (`shell/ui/Backdrop.kt`):
/// the theme color, and over it the base gradient with the background of `kind` drawn on a 960 × 540 canvas that keeps
/// its proportions and grows along the axis with more room. In the dark theme that layer is blended with "screen", so it
/// lights the theme color (and later the game background) up instead of covering it. Game colors are not used yet.
public struct Backdrop: View {
    @Environment(\.delosColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now
    private let kind: BackgroundKind

    public init(kind: BackgroundKind = .contour) {
        self.kind = kind
    }

    public var body: some View {
        // The prototype advances its clock by 0.016 per 60 Hz frame (0.96 per second); reduced motion slows it down
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: kind == .still)) { context in
            let t = context.date.timeIntervalSince(start) * 0.96 * (reduceMotion ? 0.15 : 1)
            GeometryReader { proxy in
                let (unit, canvas) = BackgroundParams.canvas(for: proxy.size)
                let p = BackgroundParams(colors: colors, canvas: canvas, t: t)
                ZStack {
                    colors.bg.color
                    layer(p, unit: unit, size: proxy.size)
                        .compositingGroup()
                        .blendMode(colors.dark ? .screen : .normal)
                }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func layer(_ p: BackgroundParams, unit: Double, size: CGSize) -> some View {
        switch BackgroundStyle(kind) {
        case .still:
            base(p)
        case .canvas:
            Canvas { context, _ in
                context.scaleBy(x: unit, y: unit)
                context.fill(Path(CGRect(x: 0, y: 0, width: p.w, height: p.h)), with: .linearGradient(
                    Gradient(colors: baseColors(p)), startPoint: .zero, endPoint: CGPoint(x: 0, y: p.h)
                ))
                CanvasBackgrounds.draw(kind, in: &context, p)
            }
        case .contour:
            ZStack {
                base(p)
                contour(p, unit: unit, size: size)
            }
        case let .shader(name):
            let (c1, c2, c3) = p.lights
            ZStack {
                base(p)
                Rectangle()
                    .colorEffect(
                        ShaderLibrary.bundle(.module)[dynamicMember: name](
                            .float(unit), .float2(p.w, p.h), .float(p.t),
                            .color(c1.color), .color(c2.color), .color(c3.color), .float(p.glow)
                        )
                    )
                    .blendMode(p.dark ? .plusLighter : .normal)
            }
        }
    }

    private func baseColors(_ p: BackgroundParams) -> [Color] {
        p.dark
            ? [hsl(p.base, 40, 8).color, hsl(p.base, 38, 5).color]
            : [hsl(p.base, 45, 96).color, hsl(p.base, 38, 90).color]
    }

    private func base(_ p: BackgroundParams) -> some View {
        LinearGradient(colors: baseColors(p), startPoint: .top, endPoint: .bottom)
    }

    private func contour(_ p: BackgroundParams, unit: Double, size: CGSize) -> some View {
        let dark = p.dark
        let lightness = dark ? 68.0 : 40.0
        // The lowest level in the main color, the highest in the secondary one
        let c1 = hsl(p.acc, 80 * p.s(p.acc), lightness)
        let c2 = hsl(p.tint, 80 * p.s(p.tint), lightness)
        let blend: BlendMode = dark ? .plusLighter : .normal
        return ZStack {
            // The glow under the lines
            RadialGradient(
                colors: [hsl(p.acc, 80 * p.sat1, dark ? 50 : 70, dark ? 0.14 : 0.2).color, hsl(p.acc, 80, 50, 0).color],
                center: UnitPoint(x: 0.66, y: 0.5), startRadius: 0, endRadius: size.width * 0.55
            )
            .blendMode(blend)
            Rectangle()
                .colorEffect(
                    ShaderLibrary.bundle(.module).delosContour(
                        .float(unit), .float2(p.w, p.h), .float(p.t),
                        .color(c1.color), .color(c2.color), .float(dark ? 1 : 0)
                    )
                )
                .blendMode(blend)
        }
    }
}
