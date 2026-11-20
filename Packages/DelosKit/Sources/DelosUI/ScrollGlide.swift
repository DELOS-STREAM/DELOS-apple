import QuartzCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The spring of a scroll that follows the focus (`ListScrollDriver` and `ListScrollMotion` of DELOS for Android): the
/// distance still to go and the speed it closes at, stepped frame by frame. A new target changes the distance and keeps the
/// speed, so the steps of a held arrow join into one glide at a steady pace; SwiftUI's own animated scroll starts every
/// new target from rest after a frame without movement, which a held arrow turns into a hop per step (R2-15). Critically
/// damped: it never overshoots. Distances are points; the settle times are in stage pixels ([unit] points each).
struct GlideSpring: Equatable {
    enum Pace: Equatable {
        /// Settles within 2 % in [settle] seconds, whatever the distance (the library row).
        case fixed(settle: Double)
        /// The focus-driven lists: a step of a row settles in 600 ms, a jump of 700 px or more in 950 ms
        /// (``SettingsScrollMotion``).
        case list
    }

    let pace: Pace
    /// Points per stage pixel.
    var unit: Double
    /// The points still to go (positive: forward).
    private(set) var remaining = 0.0
    /// How fast [remaining] changes, points per second (negative while a forward distance closes).
    private(set) var velocity = 0.0

    /// `ωt` at which a critically damped spring `(1 + ωt)·e^(−ωt)` is within 2 % of its target.
    static let settleTurns = 5.83
    /// The fastest rate, 1/s, a retarget that arrives fast and close brakes at (`MAX_OMEGA`).
    static let maxOmega = 60.0
    /// Within this many points of the target and slower than [restSpeed] stage pixels a second the glide lands exactly.
    static let restPoints = 0.5
    static let restSpeed = 20.0
    /// A long frame (a hitch) advances the spring by at most this much, seconds.
    static let maxFrame = 0.05

    init(pace: Pace, unit: Double = 1) {
        self.pace = pace
        self.unit = unit
    }

    var active: Bool { remaining != 0 || velocity != 0 }

    /// The glide's target is now [distance] points away (positive: forward); the speed carries on.
    mutating func retarget(distance: Double) {
        remaining = distance
    }

    mutating func stop() {
        remaining = 0
        velocity = 0
    }

    /// The rate ω (1/s) for [distance] stage pixels still to go at [speed] stage pixels a second toward the target: the
    /// pace's, or for a retarget that arrives fast and close `speed / distance`, so the speed it has cannot overshoot.
    func omega(distance: Double, speed: Double) -> Double {
        let settle: Double
        switch pace {
        case .fixed(let seconds): settle = seconds
        case .list: settle = SettingsScrollMotion.settleMillis(distance: distance) / 1000
        }
        let base = Self.settleTurns / settle
        guard distance >= 0.5, speed > 0 else { return base }
        return max(base, min(speed / distance, Self.maxOmega))
    }

    /// Advances the glide by [seconds] and returns how far the scroll moves (points, positive: forward). At rest it lands
    /// exactly on the target and stops.
    mutating func step(_ seconds: Double) -> Double {
        let t = min(max(seconds, 0), Self.maxFrame)
        let x0 = remaining, v0 = velocity
        let toward = x0 > 0 ? -v0 : v0
        let w = omega(distance: abs(x0) / unit, speed: toward / unit)
        let a = v0 + w * x0
        let decay = exp(-w * t)
        let x1 = (x0 + a * t) * decay
        let v1 = (a - w * (x0 + a * t)) * decay
        if abs(x1) < Self.restPoints, abs(v1) < Self.restSpeed * unit {
            stop()
            return x0
        }
        remaining = x1
        velocity = v1
        return x0 - x1
    }
}

/// Where a scroll view is along its axis, in the units of `ScrollPosition.scrollTo(x:)` / `scrollTo(y:)` (points from the
/// start of the content), and how far it can go.
struct GlideGeometry: Equatable {
    var offset = 0.0
    var maxOffset = 0.0

    init(offset: Double = 0, maxOffset: Double = 0) {
        self.offset = offset
        self.maxOffset = maxOffset
    }

    init(_ geometry: ScrollGeometry, axis: Axis) {
        if axis == .horizontal {
            offset = geometry.contentOffset.x + geometry.contentInsets.leading
            maxOffset = max(geometry.contentSize.width + geometry.contentInsets.leading + geometry.contentInsets.trailing
                - geometry.containerSize.width, 0)
        } else {
            offset = geometry.contentOffset.y + geometry.contentInsets.top
            maxOffset = max(geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                - geometry.containerSize.height, 0)
        }
    }

    /// The offset that centers an item spanning [itemStart]…[itemEnd] in a viewport spanning [viewStart]…[viewEnd] (the same
    /// coordinates, measured at this offset), kept within the content.
    func centering(itemStart: Double, itemEnd: Double, viewStart: Double, viewEnd: Double) -> Double {
        min(max(offset + (itemStart + itemEnd) / 2 - (viewStart + viewEnd) / 2, 0), maxOffset)
    }
}

/// Moves a scroll view along a ``GlideSpring``, one frame at a time on a display link that asks for up to 120 frames a
/// second (ProMotion): every target retargets the running glide, which keeps its speed. [apply] sets the scroll view's
/// offset without an animation; [geometry] is where the scroll view is (its `onScrollGeometryChange`). A touch that drags
/// the scroll view stops the glide (``stop()``), as does anything else that scrolls it.
@MainActor
final class ScrollGlide: NSObject {
    private var spring: GlideSpring
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    /// Where the glide has put the scroll view.
    private var offset = 0.0
    /// Sets the scroll view's offset (points, along its axis) without an animation.
    var apply: (Double) -> Void = { _ in }
    /// Where the scroll view is, as it last reported.
    var geometry = GlideGeometry()
    /// The scroll view's frame in the global space, for centering an item reported there.
    var viewport = CGRect.zero

    init(pace: GlideSpring.Pace) {
        spring = GlideSpring(pace: pace)
    }

    var isGliding: Bool { link != nil }

    /// Whether the player scrolls the scroll view in [phase]: a finger drags or flicks it, or the trackpad's two fingers or a
    /// wheel move it with their momentum. The player's scroll owns the scroll view: the glide stops for it.
    nonisolated static func isPlayers(_ phase: ScrollPhase) -> Bool {
        phase == .tracking || phase == .interacting || phase == .decelerating
    }

    /// Glides to [target] (clamped to the content), from where the scroll view is or, while gliding, from where the glide is.
    func glide(to target: Double, unit: Double) {
        let target = min(max(target, 0), geometry.maxOffset)
        spring.unit = unit
        if link == nil {
            offset = geometry.offset
            spring.stop()
        }
        spring.retarget(distance: target - offset)
        guard spring.active else { return }
        start()
    }

    /// Puts the scroll view at [target] at once.
    func jump(to target: Double) {
        stop()
        offset = target
        apply(target)
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastFrame = nil
        spring.stop()
    }

    private func start() {
        guard link == nil else { return }
        #if os(macOS)
        guard let link = NSScreen.main?.displayLink(target: self, selector: #selector(frame(_:))) else {
            jump(to: offset + spring.remaining)
            return
        }
        #else
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        #endif
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// One frame: the glide advances to the time the frame is shown, the first one by one frame's length.
    @objc private func frame(_ link: CADisplayLink) {
        let shown = link.targetTimestamp
        let seconds = lastFrame.map { shown - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastFrame = shown
        offset += spring.step(seconds)
        apply(offset)
        if !spring.active { stop() }
    }
}

extension View {
    /// Connects [glide] to the scroll view this is put on: it reads where the scroll view is and stops when a touch or
    /// anything but the glide scrolls it. [position] is the scroll view's `scrollPosition`, which the glide sets.
    func scrollGlide(_ glide: ScrollGlide, axis: Axis, position: Binding<ScrollPosition>) -> some View {
        modifier(ScrollGlideHost(glide: glide, axis: axis, position: position))
    }
}

private struct ScrollGlideHost: ViewModifier {
    let glide: ScrollGlide
    let axis: Axis
    @Binding var position: ScrollPosition

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: GlideGeometry.self) { GlideGeometry($0, axis: axis) } action: { _, now in glide.geometry = now }
            .onScrollPhaseChange { _, phase in if ScrollGlide.isPlayers(phase) { glide.stop() } }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { glide.viewport = $0 }
            .onAppear {
                let position = $position, horizontal = axis == .horizontal
                glide.apply = { offset in
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) {
                        if horizontal { position.wrappedValue.scrollTo(x: offset) } else { position.wrappedValue.scrollTo(y: offset) }
                    }
                }
            }
            .onDisappear { glide.stop() }
    }
}
