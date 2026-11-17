import SwiftUI

/// One focus ring for a group of elements that glides to whichever has the focus (`GlideRing` and `GlideRingHost` of DELOS
/// for Android) instead of every element fading its own in and out: 560 ms with the slight overshoot of the prototype's
/// `--ease-glide`. The elements mark themselves with ``View/glideTarget(focused:)``; the ring is drawn behind the host's
/// content, [focusScale] times as big as the element's layout bounds (the scale the element grows to when focused).
/// It fades in over 120 ms and out over 280 ms after a moment of grace (the focus passes through "nothing" for a frame
/// when it moves from one element to the next). While the ring is not showing, and with reduced motion, it jumps.
@MainActor
@Observable
final class GlideRing {
    /// The coordinate space the targets report their bounds in.
    static let space = "glide-ring"

    /// Where the ring is now (before growing by the focus scale); animated by the glide.
    private(set) var shown: CGRect?
    private(set) var alpha = 0.0
    @ObservationIgnored private var holder: AnyHashable?
    @ObservationIgnored private var grace: Task<Void, Never>?
    @ObservationIgnored var reduced = false

    /// The element [key] gained the focus; [frame] are its layout bounds in the host's space.
    func focus(_ key: AnyHashable, _ frame: CGRect) {
        grace?.cancel()
        holder = key
        guard frame != .zero else { return }
        if alpha > 0, shown != nil, !reduced {
            withAnimation(.timingCurve(0.3, 1.22, 0.42, 1, duration: Motion.ring / 1000)) { shown = frame }
        } else {
            shown = frame
        }
        withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.12)) { alpha = 1 }
    }

    func blur(_ key: AnyHashable) {
        guard holder == key else { return }
        holder = nil
        grace?.cancel()
        grace = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000)) { alpha = 0 }
        }
    }

    /// The focused element is somewhere else than it was (scrolled, laid out again): the ring is on it at once.
    func moved(_ key: AnyHashable, _ frame: CGRect) {
        guard holder == key, frame != .zero, frame != shown else { return }
        // The focus came before the first layout: the ring appears now
        if shown == nil || alpha == 0 {
            focus(key, frame)
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { shown = frame }
    }
}

extension EnvironmentValues {
    /// The ring of the surrounding ``glideRingHost(focusScale:ring:gap:)``; nil outside one (an element draws its own).
    @Entry var glideRing: GlideRing?
}

/// The numbers of the ring drawn around a circle (`drawFocusRing` of DELOS for Android).
enum RingGeometry {
    /// The diameter of the ring's outer edge around an element [layout] wide that has grown by [focusScale]: the ring and
    /// its gap are not scaled with it.
    static func outerDiameter(layout: Double, focusScale: Double, ring: Double, gap: Double) -> Double {
        layout * focusScale + 2 * (gap + ring)
    }
}

private struct GlideRingHost: ViewModifier {
    let focusScale: Double
    let ring: Double
    let gap: Double
    @State private var model = GlideRing()
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced

    func body(content: Content) -> some View {
        model.reduced = reduced
        return content
            .coordinateSpace(name: GlideRing.space)
            .environment(\.glideRing, model)
            .background(alignment: .topLeading) {
                if let rect = model.shown, model.alpha > 0 {
                    let g = stage.px(gap), r = stage.px(ring)
                    let width = rect.width * focusScale, height = rect.height * focusScale
                    ZStack {
                        // `box-shadow: 0 0 0 gap bg, 0 0 0 gap+width accent` around a round element
                        Circle().strokeBorder(colors.bg.color, lineWidth: g).frame(width: width + 2 * g, height: height + 2 * g)
                        Circle().strokeBorder(colors.accent.color, lineWidth: r).frame(width: RingGeometry.outerDiameter(layout: rect.width, focusScale: focusScale, ring: r, gap: g), height: RingGeometry.outerDiameter(layout: rect.height, focusScale: focusScale, ring: r, gap: g))
                    }
                    .frame(width: width, height: height)
                    .opacity(model.alpha)
                    .offset(x: rect.midX - width / 2, y: rect.midY - height / 2)
                    .allowsHitTesting(false)
                }
            }
    }
}

private struct GlideTarget: ViewModifier {
    let focused: Bool
    @Environment(\.glideRing) private var ring
    @State private var key = UUID()
    @State private var frame = CGRect.zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(GlideRing.space)) } action: { now in
                frame = now
                if focused { ring?.moved(key, now) }
            }
            .onChange(of: focused, initial: true) { _, now in
                if now { ring?.focus(key, frame) } else { ring?.blur(key) }
            }
            .onDisappear { ring?.blur(key) }
    }
}

extension View {
    /// One focus ring for the group of elements inside, which glides to the focused one (`GlideRingHost`): the elements
    /// mark themselves with ``glideTarget(focused:)``.
    func glideRingHost(focusScale: Double, ring: Double = 5, gap: Double = 5) -> some View {
        modifier(GlideRingHost(focusScale: focusScale, ring: ring, gap: gap))
    }

    /// Marks an element of a ``glideRingHost(focusScale:ring:gap:)``: while it is [focused] the ring is on it. Put it before
    /// the element's focus scale (its bounds are those of the layout). Does nothing outside a host.
    func glideTarget(focused: Bool) -> some View {
        modifier(GlideTarget(focused: focused))
    }
}
