import SwiftUI

/// The geometry and timing of the portal (`#portal` of the prototype, `PortalOverlay` of DELOS for Android), in stage
/// pixels and seconds.
enum PortalLook {
    /// Four rings 0.35 s apart, every 2.2 s.
    static let ripplePeriod = 2.2
    static let rippleGap = 0.35
    static let rippleCount = 4
    /// A ring of 300 px grows from 0.35 to 3.4 of its size.
    static let ringRadius = 150.0
    static let ringFrom = 0.35
    static let ringGrowth = 3.05
    static let ringHalo = 36.0
    static let ringLine = 3.0
    static let orb = 220.0
    static let orbIcon = 100.0
    static let orbLine = 2.0
    static let orbGlow = 80.0
    static let gap = 30.0
    static let textGap = 16.0
    static let labelSize = 36.0
    static let subSize = 24.0
    /// The flash of the burst: a circle of 200 px, scale 0.5 → 16 while it fades out, over 0.9 s.
    static let flashRadius = 100.0
    static let flashFrom = 0.5
    static let flashGrowth = 15.5
    static let flashDuration = 0.9
    /// The orb at the burst: scale 1.6 over 0.8 s, fading out over 0.6 s.
    static let coreScale = 1.6
    static let coreScaleDuration = 0.8
    static let coreFadeDuration = 0.6
    /// The overlay fades in over 0.3 s (0.4 s when it arrives with a burst) and out over 0.3 s.
    static let fadeIn = 0.3
    static let fadeInArriving = 0.4
    static let fadeOut = 0.3
    /// How far the screen behind blurs, in stage pixels (the backdrop blur of the overlay).
    static let blur = 22.0

    /// A ring's alpha at the fraction [u] of its period (`@keyframes ripple`): 0 → 1 over the first quarter, then out.
    static func ringAlpha(_ u: Double) -> Double {
        u < 0.25 ? Motion.easeOut(u / 0.25) : 1 - Motion.easeOut((u - 0.25) / 0.75)
    }

    /// The ring [index]'s place in its period at [time] seconds, or nil before it starts.
    static func ringPhase(index: Int, time: Double) -> Double? {
        let local = time - Double(index) * rippleGap
        guard local >= 0 else { return nil }
        return local.truncatingRemainder(dividingBy: ripplePeriod) / ripplePeriod
    }

    /// The ring's radius in stage pixels at the fraction [u] of its period.
    static func ringRadius(_ u: Double) -> Double { ringRadius * (ringFrom + ringGrowth * Motion.easeOut(u)) }
}

/// The portal into a PC (`PortalOverlay`): the screen behind blurs (``DelosRoot`` does that), rings ripple out from an
/// orb with the PC's icon, its name and state below. When [burst] it flashes open and the orb flies at the viewer.
/// While it shows nothing underneath reacts: only B (cancel) passes through; a tap or a click cancels too, for the
/// ones without a B.
struct PortalOverlay: View {
    let portal: Portal
    let burst: Bool
    let focus: FocusModel
    /// Whether it holds the tvOS focus itself (the exit scene's stream screen does that already).
    var holdsFocus = true
    let onCancel: @MainActor () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced
    @State private var started = Date()
    @State private var burstStarted: Date?

    var body: some View {
        ZStack {
            scrim
            if !reduced {
                TimelineView(.animation) { timeline in
                    ripples(at: timeline.date)
                }
            }
            core
            #if os(tvOS)
            // Menu reaches the app only through a focused view: this one holds the focus
            if holdsFocus {
                FocusItem(id: "portal", model: focus, action: {}) { _ in Color.clear.frame(width: 2, height: 2) }
                    .onAppear { focus.focus("portal") }
                    .accessibilityHidden(true)
            }
            #endif
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { if portal.cancellable { onCancel() } }
        .onChange(of: burst) { _, now in burstStarted = now ? Date() : nil }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(portal.label)
        .accessibilityValue(portal.sub)
    }

    /// radial-gradient(bg 25 % at the center → bg 70 % at 75 %)
    private var scrim: some View {
        GeometryReader { proxy in
            Rectangle().fill(RadialGradient(
                stops: [
                    .init(color: colors.bg.opacity(0.25).color, location: 0),
                    .init(color: colors.bg.opacity(0.7).color, location: 0.75),
                    .init(color: colors.bg.opacity(0.7).color, location: 1),
                ],
                center: .center, startRadius: 0, endRadius: max(max(proxy.size.width, proxy.size.height) / 2, 1)))
        }
    }

    private func ripples(at date: Date) -> some View {
        let time = date.timeIntervalSince(started)
        let flash = burstStarted.map { Motion.progress(date.timeIntervalSince($0) * 1000, delay: 0, duration: PortalLook.flashDuration * 1000, Motion.easeOut) }
        return Canvas { context, size in
            let k = stage.px(1)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for index in 0..<PortalLook.rippleCount {
                guard let u = PortalLook.ringPhase(index: index, time: time) else { continue }
                let alpha = PortalLook.ringAlpha(u)
                let radius = PortalLook.ringRadius(u) * k
                let halo = PortalLook.ringHalo * k
                let outer = radius + halo
                let glow = Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: max((radius - halo) / outer, 0)),
                    .init(color: colors.glow.color, location: radius / outer),
                    .init(color: .clear, location: 1),
                ])
                var layer = context
                layer.opacity = alpha
                layer.fill(
                    Path(ellipseIn: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2)),
                    with: .radialGradient(glow, center: center, startRadius: 0, endRadius: outer))
                let tint: RGBA = switch index { case 1: colors.accent2; case 3: colors.accent3; default: colors.accent }
                layer.stroke(
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(tint.color), lineWidth: PortalLook.ringLine * k)
            }
            // .flash: accent → accent-2 → transparent, scale .5 → 16 while fading out
            if let f = flash, f > 0, f < 1 {
                let r = PortalLook.flashRadius * k * (PortalLook.flashFrom + PortalLook.flashGrowth * f)
                var layer = context
                layer.opacity = 1 - f
                layer.fill(
                    Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: colors.accent.color, location: 0),
                            .init(color: colors.accent2.color, location: 0.45),
                            .init(color: .clear, location: 0.7),
                        ]), center: center, startRadius: 0, endRadius: r))
            }
        }
        .allowsHitTesting(false)
    }

    private var core: some View {
        VStack(spacing: stage.px(PortalLook.gap)) {
            orb
            VStack(spacing: stage.px(PortalLook.textGap)) {
                Text(portal.label)
                    .font(DelosFonts.unbounded(stage.tpx(PortalLook.labelSize)))
                    .foregroundStyle(colors.text.color)
                Text(portal.sub)
                    .font(DelosFonts.figtree(stage.tpx(PortalLook.subSize)))
                    .foregroundStyle(colors.text2.color)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, stage.px(96))
        }
        .scaleEffect(burst ? PortalLook.coreScale : 1)
        .opacity(burst ? 0 : 1)
        .animation(Motion.out(PortalLook.coreScaleDuration * 1000), value: burst)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: PortalLook.coreFadeDuration), value: burst)
    }

    private var orb: some View {
        let size = stage.px(PortalLook.orb)
        // box-shadow: 0 0 90px -10px glow
        let reach = size / 2 + stage.px(PortalLook.orbGlow)
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [colors.glow.color, .clear], center: .center, startRadius: 0, endRadius: reach))
                .frame(width: reach * 2, height: reach * 2)
            Circle()
                .fill(RadialGradient(
                    colors: [colors.surface3.color, colors.bg2.color], center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0,
                    endRadius: hypot(size * 0.6, size * 0.65)))
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(colors.line.color, lineWidth: stage.px(PortalLook.orbLine)))
            SymbolView(symbol: portal.icon, size: PortalLook.orbIcon, color: colors.accent, filled: true)
        }
        .frame(width: size, height: size)
    }
}

/// The screen behind the portal blurs (the overlay's backdrop blur of 22 stage pixels), easing in and out with it.
struct PortalBackdropBlur: ViewModifier {
    let active: Bool
    @Environment(\.stage) private var stage

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? stage.px(PortalLook.blur) : 0)
            .animation(.easeOut(duration: active ? PortalLook.fadeIn : PortalLook.fadeOut), value: active)
    }
}
