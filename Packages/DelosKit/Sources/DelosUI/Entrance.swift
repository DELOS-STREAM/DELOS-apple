import SwiftUI

extension Motion {
    /// An element that appears this long after its screen did (a row that shows up when data arrives, a PC found by the
    /// discovery) is not part of the entrance: it is just there (`Motion.STAGGER_WINDOW`).
    static let staggerWindow = 700.0

    /// When the element at place [index] starts its entrance, milliseconds after it appeared (`Motion.staggerDelay`).
    static func staggerDelay(_ index: Int, base: Double = rowDelay, step: Double = staggerRow) -> Double {
        base + Double(max(index, 0)) * step
    }
}

/// Counts the elements of one screen as they appear, so each knows its place in the staggered entrance (`EntranceStagger`
/// of DELOS for Android): the first takes place 0, the next 1, and so on up to [cap], which everything after it shares.
/// An element that appears more than [lateAfterMs] after the counter was made is not part of the entrance.
@MainActor
final class EntranceStagger {
    private let cap: Int
    private let lateAfterMs: Double
    private let clock: () -> Double
    private let created: Double
    private var next = 0

    /// [clock]: the time in milliseconds.
    init(cap: Int = Motion.staggerCap, lateAfterMs: Double = Motion.staggerWindow, clock: @escaping () -> Double = EntranceStagger.uptime) {
        self.cap = cap
        self.lateAfterMs = lateAfterMs
        self.clock = clock
        created = clock()
    }

    nonisolated static func uptime() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

    /// Whether an element that appears now still takes part in the entrance.
    var isEarly: Bool { clock() - created <= lateAfterMs }

    /// The next place in the entrance, or nil when this element does not take part in it.
    func take() -> Int? {
        guard isEarly else { return nil }
        defer { next += 1 }
        return min(next, cap)
    }
}

/// What an element of a staggered entrance looks like at [progress] (0…1, already eased): it fades in and rises
/// [distance] stage pixels; with reduced motion it only fades.
struct EntranceLook: Equatable {
    let opacity: Double
    let offset: Double

    init(progress: Double, distance: Double, reduced: Bool) {
        opacity = min(max(progress, 0), 1)
        offset = reduced ? 0 : distance * (1 - progress)
    }
}

extension EnvironmentValues {
    /// The counter of the screen whose elements enter one after the other; nil: nothing animates.
    @Entry var entranceStagger: EntranceStagger?
}

private struct EntranceScope: ViewModifier {
    let cap: Int
    let lateAfterMs: Double
    @State private var stagger: EntranceStagger

    init(cap: Int, lateAfterMs: Double) {
        self.cap = cap
        self.lateAfterMs = lateAfterMs
        _stagger = State(initialValue: EntranceStagger(cap: cap, lateAfterMs: lateAfterMs))
    }

    func body(content: Content) -> some View {
        content.environment(\.entranceStagger, stagger)
    }
}

private enum EntranceState {
    /// Not appeared yet: hidden while the screen's entrance is still going on.
    case undecided
    /// Appeared and hidden until its turn.
    case waiting
    case shown
}

private struct StaggerEntrance: ViewModifier {
    let explicit: Int?
    let base: Double
    let step: Double
    @Environment(\.entranceStagger) private var stagger
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.stage) private var stage
    @State private var state = EntranceState.undecided

    func body(content: Content) -> some View {
        // Hidden from the first frame while it will take part: no flash of the finished element before its turn. An
        // element appearing late (`isEarly` is false) is shown at once
        let hidden = state == .waiting || (state == .undecided && (explicit != nil || stagger?.isEarly == true))
        content
            .modifier(EntranceEffect(progress: hidden ? 0 : 1, distance: stage.px(Motion.rise), reduced: reduced))
            .onAppear {
                guard state == .undecided else { return }
                // The place is taken here, not while the body is evaluated: a measuring pass (a row that fits or scrolls)
                // evaluates bodies of elements that never show
                guard let index = explicit ?? stagger?.take() else {
                    state = .shown
                    return
                }
                state = .waiting
                let delay = Motion.staggerDelay(index, base: base, step: step) / 1000
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: Motion.rowIn / 1000).delay(delay)) { state = .shown }
            }
    }
}

private struct EntranceEffect: ViewModifier, Animatable {
    var progress: Double
    let distance: Double
    let reduced: Bool

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let look = EntranceLook(progress: progress, distance: distance, reduced: reduced)
        content
            .opacity(look.opacity)
            .offset(y: look.offset)
    }
}

extension View {
    /// Makes this the root of a screen, a page or a menu whose elements enter one after the other: everything inside
    /// that takes ``staggerEntrance(index:base:step:)`` without an index gets the next place, up to [cap]; elements
    /// that appear later than [lateAfterMs] after this was made just appear.
    func entranceScope(cap: Int = Motion.staggerCap, lateAfterMs: Double = Motion.staggerWindow) -> some View {
        modifier(EntranceScope(cap: cap, lateAfterMs: lateAfterMs))
    }

    /// The entrance of one element of a staggered list: it rises ``Motion/rise`` stage pixels and fades in over
    /// ``Motion/rowIn`` ms, starting [base] ms after it appears plus [step] ms for every place before it. The place is
    /// [index], else the next one the surrounding ``entranceScope(cap:lateAfterMs:)`` hands out; without either the
    /// element is left alone. The element is usable all the time, the entrance is only what it looks like.
    func staggerEntrance(index: Int? = nil, base: Double = Motion.rowDelay, step: Double = Motion.staggerRow) -> some View {
        modifier(StaggerEntrance(explicit: index, base: base, step: step))
    }
}
