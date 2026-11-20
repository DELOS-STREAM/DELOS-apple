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

/// The time one screen's entrance takes elements in (`lateAfterMs` of `EntranceStagger` of DELOS for Android): an element
/// that appears more than [lateAfterMs] after the screen did is not part of the entrance. The places are the elements' own,
/// handed out top-down by the screen: the order SwiftUI makes views appear in is not the order they stand in.
@MainActor
final class EntranceWindow {
    private let lateAfterMs: Double
    private let clock: () -> Double
    private let created: Double

    /// [clock]: the time in milliseconds.
    init(lateAfterMs: Double = Motion.staggerWindow, clock: @escaping () -> Double = EntranceWindow.uptime) {
        self.lateAfterMs = lateAfterMs
        self.clock = clock
        created = clock()
    }

    nonisolated static func uptime() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

    /// Whether an element that appears now still takes part in the entrance.
    var isOpen: Bool { clock() - created <= lateAfterMs }
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
    /// The entrance window of the screen around; nil: every element with a place enters, whenever it appears (a menu, a dialog).
    @Entry var entranceWindow: EntranceWindow?
}

private struct EntranceScope: ViewModifier {
    @State private var window: EntranceWindow

    init(lateAfterMs: Double) {
        _window = State(initialValue: EntranceWindow(lateAfterMs: lateAfterMs))
    }

    func body(content: Content) -> some View {
        content.environment(\.entranceWindow, window)
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
    let index: Int?
    let base: Double
    let step: Double
    let rises: Bool
    @Environment(\.entranceWindow) private var window
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.stage) private var stage
    @State private var state = EntranceState.undecided

    /// Whether an element appearing now takes part in the entrance.
    private var enters: Bool { index != nil && window?.isOpen != false }

    func body(content: Content) -> some View {
        // Hidden from the first frame while it will take part: no flash of the finished element before its turn. An
        // element appearing late is shown at once
        let hidden = state == .waiting || (state == .undecided && enters)
        content
            .modifier(EntranceEffect(look: EntranceLook(progress: hidden ? 0 : 1, distance: rises ? stage.px(Motion.rise) : 0, reduced: reduced)))
            .onAppear {
                guard state == .undecided else { return }
                guard let index, enters else {
                    state = .shown
                    return
                }
                state = .waiting
                let delay = Motion.staggerDelay(index, base: base, step: step) / 1000
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: Motion.rowIn / 1000).delay(delay)) { state = .shown }
            }
    }
}

/// The look of an entering element as a render effect (`graphicsLayer { alpha; translationY }` of DELOS for Android): the
/// animation interpolates the opacity and the offset where the view is drawn, so no body is evaluated again and nothing is
/// laid out again while it rises.
private struct EntranceEffect: ViewModifier {
    let look: EntranceLook

    func body(content: Content) -> some View {
        content.visualEffect { [look] effect, _ in
            effect
                .opacity(look.opacity)
                .offset(y: look.offset)
        }
    }
}

extension View {
    /// Makes this the root of a screen or a page whose elements enter one after the other: an element inside that appears
    /// later than [lateAfterMs] after this was made (a PC found by the discovery, a row revealed by a switch) just appears.
    func entranceScope(lateAfterMs: Double = Motion.staggerWindow) -> some View {
        modifier(EntranceScope(lateAfterMs: lateAfterMs))
    }

    /// The entrance of one element of a staggered list: it rises ``Motion/rise`` stage pixels and fades in over
    /// ``Motion/rowIn`` ms, starting [base] ms after it appears plus [step] ms for every place before [index]. The places
    /// run top-down as on DELOS for Android (`staggerEntrance(index)`); nil leaves the element alone. The element is usable
    /// all the time, the entrance is only what it looks like. With [rises] false it only fades (a focus ring that shows
    /// together with its row, in the row's place).
    func staggerEntrance(index: Int?, base: Double = Motion.rowDelay, step: Double = Motion.staggerRow, rises: Bool = true) -> some View {
        modifier(StaggerEntrance(index: index, base: base, step: step, rises: rises))
    }
}
