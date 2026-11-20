import Observation
import SwiftUI

/// Session memory, not a profile preference or a value restored after relaunch.
@MainActor
@Observable
final class SettingsSession {
    static let shared = SettingsSession()
    var tab = SettingsTab.stream

    func opening(_ explicit: SettingsTab? = nil) -> SettingsTab {
        let requested = explicit ?? tab
        return SettingsTab.availableCases.contains(requested) ? requested : .stream
    }
}

enum SettingsPlateGeometry {
    static let duration = 0.520

    static func target(_ row: CGRect) -> CGRect {
        guard row.width > 0, row.height > 0 else { return .zero }
        return row.insetBy(dx: -row.width * 0.01, dy: -row.height * 0.01)
    }
}

struct SettingsRowAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Lives in the scrolling content's coordinate system: scrolling carries the plate with its target row.
struct SettingsFocusPlate: View {
    let target: CGRect?
    @State private var previous: CGRect?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced

    var body: some View {
        Group {
            if let frame = target ?? previous {
                RoundedRectangle(cornerRadius: stage.px(24))
                    .fill(colors.surface2.color)
                    .overlay(RoundedRectangle(cornerRadius: stage.px(24)).strokeBorder(colors.accent.color, lineWidth: stage.px(3)))
                    .background { PlateGlow(size: frame.size) }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    // RowGlide.kt and Motion.kt: ROW_FOCUS / Glide, not the per-item focus spring.
                    .animation(reduced ? nil : .timingCurve(0.3, 1.22, 0.42, 1, duration: SettingsPlateGeometry.duration), value: target)
                    .opacity(target == nil ? 0 : 1)
                    // RowGlide.focus: the ring fades in over 120 ms; blur waits 70 ms for the next row, then fades over Motion.FADE (CSS ease)
                    .animation(
                        target == nil
                            ? .timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000).delay(0.07)
                            : .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.12),
                        value: target != nil)
            }
        }
        .onChange(of: target, initial: true) { _, frame in if let frame { previous = frame } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The glow of a focused settings row (`FocusGlow(offsetY = 20, blur = 50, spread = -24)` of DELOS for Android): the plate
/// shrunk by the spread, blurred (CSS blur 50 = a Gaussian of 25), moved 20 down, and drawn only outside the plate, so its
/// translucent fill is not darkened.
struct PlateGlow: View {
    let size: CGSize
    var corner = 24.0
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        let spread = stage.px(24), radius = stage.px(corner)
        RoundedRectangle(cornerRadius: max(radius - spread, 0))
            .fill(colors.glow.color)
            .frame(width: max(size.width - 2 * spread, 0), height: max(size.height - 2 * spread, 0))
            .blur(radius: stage.px(25))
            .offset(y: stage.px(20))
            .frame(width: size.width, height: size.height)
            .mask {
                ZStack {
                    Rectangle().fill(.black).frame(width: size.width + stage.px(400), height: size.height + stage.px(400))
                    RoundedRectangle(cornerRadius: radius).fill(.black).frame(width: size.width, height: size.height).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

enum ScreenMotion {
    static let enter = 0.560
    static let fade = 0.280
    static let exit = 0.240
    static let scale = 1.035

    static func transition(reduced: Bool) -> AnyTransition {
        // MotionKit.kt:553–558: separate opacity/scale clocks, including the outward exit scale.
        let fadeIn = AnyTransition.opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: fade))
        let fadeOut = AnyTransition.opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: exit))
        if reduced { return .asymmetric(insertion: fadeIn, removal: fadeOut) }
        return .asymmetric(
            insertion: fadeIn.combined(with: .scale(scale: scale).animation(.timingCurve(0.16, 1, 0.3, 1, duration: enter))),
            removal: fadeOut.combined(with: .scale(scale: scale).animation(.timingCurve(0.5, 0, 0.75, 0, duration: exit))))
    }
}

extension Stage {
    /// Stage pixels of a non-text element, scaled by ``compactScale`` (`cpx` of DELOS for Android: the same as `px` on every
    /// shape but the compact one).
    func cpx(_ value: Double) -> CGFloat { px(value * compactScale) }

    /// Like ``cpx(_:)`` but never under 64 stage px: for a row or a button that is touched or focused (`targetPx`).
    func targetPx(_ value: Double) -> CGFloat { px(max(value * compactScale, min(value, 64))) }
}

/// What a scrolling settings list reports of itself.
struct SettingsScrollMetrics: Equatable {
    var offset = 0.0
    var viewport = 0.0
    var content = 0.0
    var maxOffset: Double { max(content - viewport, 0) }
}

/// The bring-into-view scroll of the focus-driven lists (`MarginBringIntoView` and `ListScrollMotion` of DELOS for Android):
/// the focused row is kept [before] / [after] stage pixels inside the viewport's edges (clear of the faded edges) and the
/// list scrolls only when the row would leave that safe area, on a critically damped spring whose rate follows the distance
/// still to go: a step of one row settles in 600 ms, a jump of 700 px or more in 950 ms.
enum SettingsScrollMotion {
    static let nearMs = 600.0, farMs = 950.0, nearPx = 90.0, farPx = 700.0
    /// ωt at which a critically damped spring is within 2 % of its target.
    static let settleTurns = 5.83
    /// The margin above the focused row (the section heading above the first row stays in view) and under it.
    static let before = 72.0, after = 110.0, compactAfter = 90.0

    static func settleMillis(distance: Double) -> Double {
        let t = min(max((distance - nearPx) / (farPx - nearPx), 0), 1)
        return nearMs + (farMs - nearMs) * t
    }

    /// The scroll offset that brings a row spanning [rowTop]…[rowBottom] (content points) into the safe area, or nil when
    /// it is inside already. [current] is the offset the list is scrolling to (or rests at).
    static func target(rowTop: Double, rowBottom: Double, current: Double, viewport: Double, maxOffset: Double, before: Double, after: Double) -> Double? {
        var next = current
        if rowTop - before < current {
            next = rowTop - before
        } else if rowBottom + after > current + viewport {
            next = rowBottom + after - viewport
        }
        next = min(max(next, 0), maxOffset)
        return abs(next - current) < 0.5 ? nil : next
    }

    /// The spring for a scroll of [distance] stage pixels.
    static func animation(distance: Double) -> Animation {
        let omega = settleTurns / (settleMillis(distance: distance) / 1000)
        return .interpolatingSpring(mass: 1, stiffness: omega * omega, damping: 2 * omega)
    }
}

private struct SelectionPillKey: PreferenceKey {
    static var defaultValue: [AnyHashable: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [AnyHashable: Anchor<CGRect>], nextValue: () -> [AnyHashable: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    /// Marks a tab of a ``SelectionPillHost``: while it is selected, the pill glides to it. Put it before any scale or other
    /// transform on the tab (its bounds are those of the layout, not of the press squeeze).
    func selectionPillTarget(_ id: some Hashable) -> some View {
        anchorPreference(key: SelectionPillKey.self, value: .bounds) { [AnyHashable(id): $0] }
    }
}

/// A row of tabs with one accent pill behind the selected tab, which glides to the next selected one (`SelectionPillHost` of
/// DELOS for Android). The pill's two edges are two springs (stiffness 190 and damping ratio 0.8, the geometry spring of the
/// app; the edge in the direction of travel 1.5 times as stiff, the one behind it 0.75 times), so the pill stretches over the
/// gap between the old and the new tab and squashes into the new one: it follows the new tab's width as well as its place.
/// The first tab is placed without animation, and reduced motion jumps.
struct SelectionPillHost<Content: View>: View {
    let selected: AnyHashable
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .backgroundPreferenceValue(SelectionPillKey.self) { anchors in
                GeometryReader { proxy in
                    SelectionPillBody(target: anchors[selected].map { proxy[$0] })
                }
            }
    }
}

enum SelectionPillMotion {
    static let geometryStiffness = 190.0, geometryDamping = 0.8
    static let leadingStiffness = 1.5, trailingStiffness = 0.75

    /// Whether the pill moves to the right (its centre does); one that stays put counts as rightwards.
    static func travelsRight(fromLeft: Double, fromRight: Double, toLeft: Double, toRight: Double) -> Bool {
        toLeft + toRight >= fromLeft + fromRight
    }

    static func spring(leading: Bool) -> Animation {
        let stiffness = geometryStiffness * (leading ? leadingStiffness : trailingStiffness)
        return .interpolatingSpring(mass: 1, stiffness: stiffness, damping: 2 * geometryDamping * stiffness.squareRoot())
    }
}

private struct SelectionPillBody: View {
    let target: CGRect?
    @State private var left = 0.0
    @State private var right = 0.0
    @State private var top = 0.0
    @State private var height = 0.0
    @State private var visible = false
    @Environment(\.delosColors) private var colors
    @Environment(\.reducedMotion) private var reduced

    var body: some View {
        Capsule()
            .fill(colors.accent.color)
            .frame(width: max(right - left, 0), height: height)
            .offset(x: left, y: top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .onChange(of: target, initial: true) { _, new in move(to: new) }
    }

    private func move(to bounds: CGRect?) {
        var still = Transaction(animation: nil)
        still.disablesAnimations = true
        guard let bounds else {
            withTransaction(still) { visible = false }
            return
        }
        // Row geometry never glides: only the two edges do
        withTransaction(still) {
            top = bounds.minY
            height = bounds.height
        }
        guard visible, !reduced else {
            withTransaction(still) {
                left = bounds.minX
                right = bounds.maxX
                visible = true
            }
            return
        }
        let rightwards = SelectionPillMotion.travelsRight(fromLeft: left, fromRight: right, toLeft: bounds.minX, toRight: bounds.maxX)
        withAnimation(SelectionPillMotion.spring(leading: !rightwards)) { left = bounds.minX }
        withAnimation(SelectionPillMotion.spring(leading: rightwards)) { right = bounds.maxX }
    }
}

/// Where a row of tabs (its L1 / R1 badges included) sits (`TabRowLayout` of DELOS for Android): exactly centred on the stage,
/// or with its outer edge exactly flush with the content's edge; nothing in between. A row wider than the room between the
/// content's edges neither tightens nor overhangs: it becomes one row that scrolls inside that room. Stage pixels throughout.
enum TabRowLayout {
    /// How far a centred row may overhang the content's edges before it scrolls instead.
    static let overhang = 12.0
    /// Half a pixel of the row's own rounding does not push a centred row out of the content.
    private static let rounding = 0.5
    /// A tab focused on tvOS (where the tabs are items of the focus) grows by ``tabScale`` with its ``tabRing`` px ring as far
    /// out, inside its scale; tabs are up to ``tabMaxWidth`` wide in any language (a label of about 18 characters, or a label
    /// and its count of custom settings). ``tvTabGap`` between two tabs is twice that reach and the clearance
    /// (``FocusSpacing``). The other platforms never focus a tab and keep ``tabGap``, scaled with the compact stage there.
    static let tabScale = 1.06, tabRing = 3.0, tabMaxWidth = 340.0
    static let tvTabGap = 42.0, tabGap = 10.0, compactTabGap = 6.0

    /// Where a row goes: its [x], the [width] it is given (the room between the edges when it [scrolls]).
    struct Placement: Equatable {
        var x: Double
        var width: Double
        var scrolls: Bool
    }

    /// The placement of a row [rowWidth] wide whose first and last visible edges sit [outset] inside it, between the content's [left]
    /// and [right] edges. A centred row stays centred on the stage while its visible ends stay inside the edges (or overhang them by
    /// ``overhang`` in all); otherwise its visible right edge is at [right]. With [spill] (not compact) the row only scrolls when it
    /// does not fit the stage.
    static func place(stageWidth: Double, rowWidth: Double, outset: Double, left: Double, right: Double, centred: Bool = true, spill: Bool = false) -> Placement {
        if spill {
            let x = centred ? (stageWidth - rowWidth) / 2 : flushRight(rowWidth, outset: outset, right: right)
            if x >= 0, x + rowWidth <= stageWidth { return Placement(x: x, width: rowWidth, scrolls: false) }
        }
        let allowed = centred ? overhang : 0
        if rowWidth - 2 * outset > right - left + allowed + rounding {
            return Placement(x: left - outset, width: max(right - left + 2 * outset, 0), scrolls: true)
        }
        let placed = centred ? x(stageWidth: stageWidth, rowWidth: rowWidth, outset: outset, left: left, right: right, slack: allowed / 2) : flushRight(rowWidth, outset: outset, right: right)
        return Placement(x: placed, width: rowWidth, scrolls: false)
    }

    /// The x of a row centred on the stage when the visible row then stays inside [left]…[right] (less [slack] at each end), else
    /// its visible right edge is at [right].
    static func x(stageWidth: Double, rowWidth: Double, outset: Double, left: Double, right: Double, slack: Double = 0) -> Double {
        let centred = (stageWidth - rowWidth) / 2
        return centred + outset >= left - slack - rounding && centred + rowWidth - outset <= right + slack + rounding
            ? centred : flushRight(rowWidth, outset: outset, right: right)
    }

    /// The x of a row whose visible right edge is exactly at [right].
    static func flushRight(_ rowWidth: Double, outset: Double, right: Double) -> Double { right - rowWidth + outset }
}
