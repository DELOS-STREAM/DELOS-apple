import Observation
import SwiftUI

/// The touch swipe of the side menu: a drag in from the left edge opens it, a drag to the left on the open menu closes it.
/// The panel follows the finger as a progress, 0 = closed and 1 = fully open; on release the distance and the speed decide.
/// Pure arithmetic in points, so it is tested without a screen.
enum SideMenuSwipe {
    /// How far from the left edge an opening drag may start, points.
    static let edge = 40.0
    /// How far a finger moves before the drag is decided (a touch slop), points.
    static let slop = 10.0
    /// The share of the panel width a drag has to cover for the menu to open (or, from open, to close).
    static let threshold = 0.4
    /// A release at least this fast (points per second) goes the way it moves, whatever the distance.
    static let fling = 600.0
    /// How far past fully open the panel can be pulled, as a share of its width; the pull is damped towards it.
    static let rubber = 0.06

    static func startsAtEdge(_ x: Double) -> Bool { x >= 0 && x < edge }

    /// Whether a drag of ([dx], [dy]) from its start belongs to the menu: past the [slop], more sideways than up or down,
    /// and to the right for [opening] (to the left for closing). Nil while it is still undecided, false once it is clearly
    /// something else (a scroll, a drag the other way).
    static func claims(opening: Bool, dx: Double, dy: Double, slop: Double = slop) -> Bool? {
        let towards = opening ? dx : -dx
        if abs(dy) > slop && abs(dy) >= abs(dx) { return false }
        if towards > slop && towards > abs(dy) { return true }
        if -towards > slop { return false }
        return nil
    }

    /// The progress for a drag that moved [travel] points to the right since it began at [start] (0 opening, 1 closing) on a
    /// panel [width] wide: never below 0, and damped past 1 so it never passes 1 + ``rubber``.
    static func progress(start: Double, travel: Double, width: Double) -> Double {
        guard width > 0 else { return start }
        let raw = start + travel / width
        if raw <= 1 { return max(raw, 0) }
        let over = raw - 1
        return 1 + rubber * over / (over + rubber)
    }

    /// Whether the menu ends open after a release at [progress] with a horizontal [velocity] (points per second, to the right
    /// positive). A release as fast as [fling] follows its direction; otherwise an opening drag opens past ``threshold`` of
    /// the width and a closing drag closes past the same share.
    static func settlesOpen(opening: Bool, progress: Double, velocity: Double, fling: Double = fling) -> Bool {
        if velocity >= fling { return true }
        if velocity <= -fling { return false }
        return opening ? progress > threshold : 1 - progress <= threshold
    }

    /// Reduced motion: the panel does not follow; the drag only toggles the menu once it has covered ``threshold`` of the
    /// width.
    static func reducedToggles(opening: Bool, travel: Double, width: Double) -> Bool {
        (opening ? travel : -travel) >= width * threshold
    }
}

/// The side menu while a touch drag owns it (``SideMenuSwipe``): the panel, the scrim and the blur of the screen show
/// ``progress`` instead of their transitions.
@MainActor
@Observable
final class SideMenuDrag {
    /// From the moment a drag takes the menu until the menu has settled (and, after a close, has left the screen).
    var engaged = false
    /// 0 = closed, 1 = fully open; a little more while the open panel is pulled further.
    var progress = 0.0
    /// Where the current drag began, so a drag that catches a settling panel continues from where it is.
    @ObservationIgnored var start = 0.0
    /// Counts the settles: a settle that a new drag caught does not finish.
    @ObservationIgnored var settles = 0
    /// The release in progress, nil once the menu has settled.
    @ObservationIgnored var spring: SettleSpring?

    /// Where the panel is on the screen at [time]: on its way while a release settles, else ``progress``.
    func settlingProgress(at time: ContinuousClock.Instant) -> Double {
        guard let spring else { return progress }
        let elapsed = time - spring.began
        return spring.value(at: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }
}

/// The release of a drag: the geometry spring of the motion language (damping ratio 0.8, stiffness 190), from the progress
/// and the speed the finger left the panel with to open (1) or closed (0). ``value(at:)`` is where the animation is, so a
/// new drag can catch the panel mid-way.
struct SettleSpring: Equatable {
    static let stiffness = 190.0, dampingRatio = 0.8

    let from: Double
    let to: Double
    /// Progress per second.
    let velocity: Double
    let began: ContinuousClock.Instant

    private static var omega: Double { stiffness.squareRoot() }
    private static var damping: Double { 2 * dampingRatio * omega }

    /// The same spring as a SwiftUI animation; its initial velocity is a share of the distance per second.
    var animation: Animation {
        let distance = to - from
        return .interpolatingSpring(mass: 1, stiffness: Self.stiffness, damping: Self.damping,
                                    initialVelocity: abs(distance) < 1e-9 ? 0 : velocity / distance)
    }

    /// The progress [t] seconds after the release (an underdamped spring towards ``to``).
    func value(at t: Double) -> Double {
        let a = Self.dampingRatio * Self.omega
        let wd = Self.omega * (1 - Self.dampingRatio * Self.dampingRatio).squareRoot()
        let x0 = from - to
        let b = (velocity + a * x0) / wd
        return to + exp(-a * max(t, 0)) * (x0 * cos(wd * t) + b * sin(wd * t))
    }
}

#if os(iOS)
/// Watches a touch drag that belongs to the side menu and gives it to the [router] in points: the travel to the right since
/// the start and, at the end, the release speed (right positive). [opening]: a drag from the left edge; otherwise a drag
/// to the left on the open menu. A drag that turns out to be something else (a scroll, the other way) is left alone.
struct SideMenuSwipeGesture: ViewModifier {
    let opening: Bool
    let router: ShellRouter
    @Environment(\.stage) private var stage
    /// Undecided (nil), taken (true) or left alone (false), for the drag in progress.
    @State private var claimed: Bool?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { drag in
                    let dx = drag.translation.width, dy = drag.translation.height
                    if claimed == nil {
                        claimed = SideMenuSwipe.claims(opening: opening, dx: dx, dy: dy)
                        if claimed == true {
                            router.sideWidth = stage.px(SideMenuStyle.width)
                            router.beginSideDrag(opening: opening)
                        }
                    }
                    if claimed == true { router.moveSideDrag(travel: dx) }
                }
                .onEnded { drag in
                    defer { claimed = nil }
                    guard claimed == true else { return }
                    router.endSideDrag(opening: opening, travel: drag.translation.width, velocity: drag.velocity.width)
                })
    }
}

/// A thin strip along the left edge that takes a swipe in from the edge for the side menu (touch has no left menu button).
/// It covers only ``SideMenuSwipe/edge``, so taps and scrolls everywhere else reach the screen; it stays while its drag owns
/// the menu, which keeps the drag alive.
struct SideMenuEdgeStrip: View {
    let router: ShellRouter

    var body: some View {
        Color.clear
            .frame(width: SideMenuSwipe.edge)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .modifier(SideMenuSwipeGesture(opening: true, router: router))
            .frame(maxWidth: .infinity, alignment: .leading)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
#endif
