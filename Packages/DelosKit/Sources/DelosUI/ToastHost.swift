import Observation
import SwiftUI

/// The one thing a toast offers (Undo, `ToastAction` of DELOS for Android): [run] on Y of the controller or a tap,
/// while the toast is shown.
struct ToastAction {
    let label: String
    let run: @MainActor () -> Void
}

/// A message on the toast stage (`Toast`).
struct Toast: Identifiable {
    let id: Int
    let text: String
    let icon: String?
    let action: ToastAction?
    let durationMs: Double
    let kind: ToastKind
}

/// The toasts of the interface (the toast half of `ShellState`): the one that should show, and its action. A newer
/// toast replaces it; there is never a queue.
@MainActor
@Observable
final class Toasts {
    private(set) var current: Toast?
    /// Counts the presses of a toast's action (Y or a tap), so the toast squeezes its chip before it leaves.
    private(set) var actionPresses = 0
    @ObservationIgnored private var counter = 0

    /// Shows a toast. One with an [action] stays for the Undo time unless a duration is given. Its kind is [kind], else
    /// read from the [icon] (``ToastKind/of(explicit:icon:hasAction:)``).
    func show(_ text: String, icon: String? = nil, action: ToastAction? = nil, durationMs: Double? = nil, kind: ToastKind? = nil) {
        counter += 1
        current = Toast(
            id: counter, text: text, icon: icon, action: action,
            durationMs: durationMs ?? (action != nil ? ToastTiming.actionMs : ToastTiming.shellMs),
            kind: ToastKind.of(explicit: kind, icon: icon, hasAction: action != nil))
    }

    /// The toast [id]'s time is up.
    func hide(_ id: Int) {
        if current?.id == id { current = nil }
    }

    /// Runs the action of the toast that is shown and hides it; false when there is none.
    @discardableResult
    func runAction() -> Bool {
        guard let action = current?.action else { return false }
        current = nil
        actionPresses += 1
        action.run()
        return true
    }
}

/// What is on the toast stage and when it started (`ToastStage`): the leaving and the entering toast, whose motion is
/// a function of the clock.
@MainActor
@Observable
private final class ToastStage {
    @ObservationIgnored private let logic = ToastStageLogic<Toast>()
    @ObservationIgnored private var shownID: Int?
    @ObservationIgnored private var seenPresses: Int?
    private(set) var slots: [ToastSlot<Toast>] = []

    /// A new count of presses squeezes the newest toast's chip: true when [count] is a new one.
    func pressed(_ count: Int, now: Double) -> Bool {
        defer { seenPresses = count }
        guard let seen = seenPresses, seen != count else { return false }
        logic.press(now: now)
        slots = logic.slots
        return true
    }

    /// Brings the stage in line with [toast]: a new one replaces (or enters), none dismisses.
    func sync(_ toast: Toast?, now: Double) {
        guard toast?.id != shownID else { return }
        shownID = toast?.id
        if let toast { logic.show(toast, holdMs: toast.durationMs, now: now) } else { logic.dismiss(now: now) }
        slots = logic.slots
    }

    /// Tells [onExpired] about each toast whose time is up and drops the ones that have left; returns when the next
    /// thing happens (ms), nil when the stage is empty.
    func advance(now: Double, onExpired: (Toast) -> Void) -> Double? {
        if logic.advance(now: now, onExit: { onExpired($0.payload) }) { slots = logic.slots }
        let next = slots.flatMap { [$0.exitMs, $0.goneMs] }.filter { $0 > now }.min()
        return next
    }
}

/// Milliseconds of the toast clock.
private func toastNow() -> Double { Date.timeIntervalSinceReferenceDate * 1000 }

/// The console toast (`ToastHost` of DELOS for Android; docs/gui/MOTION_AND_COLORS.md, "Toasts"): one card at the top
/// right, 112 stage pixels from the top and 44 from the right edge. A newer toast replaces the one on the stage: the old
/// card leaves at once, the new one enters ``Motion/rowDelay`` later. A toast leaves its duration after it started to
/// enter (the gold line along the bottom edge shows what is left); one with an action runs it on a tap or Y. The card
/// never takes the focus.
struct ToastHost: View {
    let toasts: Toasts
    @State private var stage = ToastStage()
    @Environment(\.stage) private var stagePx

    private struct Key: Equatable {
        let id: Int?
        let presses: Int
    }

    var body: some View {
        // The clock runs only while something is on the stage
        TimelineView(.animation(paused: stage.slots.isEmpty)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate * 1000
            ZStack(alignment: .topTrailing) {
                ForEach(stage.slots, id: \.payload.id) { slot in
                    ToastCard(slot: slot, now: now, isLatest: slot === stage.slots.last) {
                        if slot.payload.id == toasts.current?.id, now >= slot.startMs { toasts.runAction() }
                    }
                }
            }
        }
        .padding(.top, stagePx.px(112 + stagePx.safe.top))
        .padding(.trailing, stagePx.px((stagePx.compact ? 48 : 44) + stagePx.safe.trailing))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .task(id: Key(id: toasts.current?.id, presses: toasts.actionPresses)) {
            if stage.pressed(toasts.actionPresses, now: toastNow()) { try? await Task.sleep(for: .milliseconds(Int(Motion.pressHold))) }
            stage.sync(toasts.current, now: toastNow())
            // Wakes up when a toast's time is up or it has left
            while let next = stage.advance(now: toastNow(), onExpired: { toasts.hide($0.id) }) {
                do { try await Task.sleep(for: .milliseconds(max(1, Int(next - toastNow()) + 1))) } catch { return }
            }
        }
    }
}

/// The card's fixed colors: an opaque navy so it reads over any background and over a stream.
private let cardTop = RGBA(red: 0x17 / 255, green: 0x22 / 255, blue: 0x3C / 255)
private let cardBottom = RGBA(red: 0x0E / 255, green: 0x16 / 255, blue: 0x28 / 255)
private let cardText = RGBA(red: 0xEE / 255, green: 0xF3 / 255, blue: 0xFB / 255)
private let cardRing = RGBA(red: 0xA0 / 255, green: 0xB9 / 255, blue: 0xE6 / 255, alpha: 0x2E / 255)

/// A kind's block color and the glyph on it: success, warning and error are fixed semantic colors; information and Undo
/// follow the palette (its secondary and third colors).
private func kindColors(_ kind: ToastKind, _ colors: DelosColors) -> (fill: RGBA, on: RGBA) {
    switch kind {
    case .info: (colors.accent2, hsl(colors.accent2Hue, 85, 9))
    case .success: (RGBA(red: 0x5E / 255, green: 0xE0 / 255, blue: 0xA0 / 255), RGBA(red: 0x04 / 255, green: 0x26 / 255, blue: 0x1A / 255))
    case .warning: (RGBA(red: 1, green: 0x9D / 255, blue: 0x48 / 255), RGBA(red: 0x2E / 255, green: 0x15 / 255, blue: 0))
    case .error: (RGBA(red: 1, green: 0x65 / 255, blue: 0x77 / 255), RGBA(red: 0x33 / 255, green: 0x06 / 255, blue: 0x0D / 255))
    case .action: (hsl(colors.accent3Hue, 100, 80), hsl(colors.accent3Hue, 60, 15))
    }
}

private func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
    RGBA(red: Motion.lerp(a.red, b.red, t), green: Motion.lerp(a.green, b.green, t), blue: Motion.lerp(a.blue, b.blue, t),
         alpha: Motion.lerp(a.alpha, b.alpha, t))
}

/// One card at the clock [now]: a solid icon block in the kind's color, the kind's word, the text (two lines at most)
/// and, for an action, the Y chip; it springs in from the right, glows in the kind's color, a light sweeps across it
/// once and the gold timer line drains along its bottom edge.
private struct ToastCard: View {
    let slot: ToastSlot<Toast>
    let now: Double
    let isLatest: Bool
    let onTap: @MainActor () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced

    private static let radius = 20.0

    var body: some View {
        let toast = slot.payload
        let look = kindColors(toast.kind, colors)
        let age = now - slot.startMs
        let leaving = Motion.progress(now - slot.exitMs, delay: 0, duration: Motion.exit, Motion.easeIn)
        let opacity = age < 0 ? 0 : Motion.progress(age, delay: 0, duration: Motion.fade, Motion.ease) * (1 - leaving)
        let step = ToastTiming.springStep(age)
        let glow = opacity * (1 - Motion.progress(age, delay: ToastTiming.glowAt, duration: max(1, slot.holdMs - ToastTiming.glowAt), Motion.ease))
        let spread = ToastTiming.glowReachFrom + (1 - ToastTiming.glowReachFrom) * Motion.progress(age, delay: 0, duration: max(1, slot.holdMs), Motion.easeOut)
        let shape = RoundedRectangle(cornerRadius: stage.px(Self.radius), style: .continuous)
        let word = toast.kind.word
        card(toast, look: look, age: age, shape: shape, word: word)
            .opacity(opacity)
            // The soft drop shadow and the kind-colored halo (no glass: an opaque card reads over any frame of a stream)
            .background {
                shape.fill(Color.black.opacity(ToastTiming.shadowPeak * opacity))
                    .blur(radius: stage.px(ToastTiming.shadowReach / 2))
                    .offset(y: stage.px(ToastTiming.shadowDrop))
            }
            .background {
                shape.strokeBorder(look.fill.opacity(ToastTiming.glowPeak * glow).color, lineWidth: stage.px(ToastTiming.glowReach * spread / 3))
                    .padding(-stage.px(ToastTiming.glowReach * spread / 6))
                    .blur(radius: stage.px(ToastTiming.glowReach * spread / 3))
            }
            .overlay { shape.inset(by: -stage.px(1)).stroke(look.fill.opacity(0.35 * glow).color, lineWidth: stage.px(1)) }
            .scaleEffect(reduced || age < 0 ? 1 : Motion.lerp(ToastTiming.fromScale, 1, step), anchor: .trailing)
            .visualEffect { [slide = reduced || age < 0 ? nil : (stage.px(ToastTiming.slideExtra), stage.px(ToastTiming.exitSlide) * leaving)] content, proxy in
                content.offset(x: slide.map { (proxy.size.width + $0.0) * (1 - step) + $0.1 } ?? 0)
            }
            .allowsHitTesting(toast.action != nil && age >= 0 && leaving == 0)
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(toast.action.map { L("toast_description_action", word, toast.text, $0.label) } ?? L("toast_description", word, toast.text))
            .accessibilityHidden(!isLatest)
    }

    private func card(_ toast: Toast, look: (fill: RGBA, on: RGBA), age: Double, shape: RoundedRectangle, word: String) -> some View {
        let gold = colors.accent
        let pop = Motion.progress(age, delay: ToastTiming.iconDelay, duration: Motion.pillPop, Motion.easeSpring)
        return HStack(spacing: 0) {
            // The solid icon block
            SymbolView(symbol: toast.icon ?? toast.kind.defaultIcon, size: 44, color: look.on, filled: true)
                .scaleEffect(reduced ? 1 : Motion.lerp(Motion.popFromPill, 1, pop))
                .rotationEffect(.degrees(reduced ? 0 : (1 - pop) * -50))
                .opacity(Motion.progress(age, delay: ToastTiming.iconDelay, duration: Motion.fade, Motion.ease))
                .frame(width: stage.px(92))
                .frame(maxHeight: .infinity)
                .background(look.fill.color)
            HStack(spacing: stage.px(22)) {
                VStack(alignment: .leading, spacing: stage.px(3)) {
                    Text(word)
                        .font(DelosFonts.figtree(stage.tpx(16), .heavy))
                        .tracking(stage.tpx(16) * 0.18)
                        .foregroundStyle(look.fill.color)
                        .rising(age: age, delay: ToastTiming.rowAt, reduced: reduced, unit: stage.px(1))
                    CappedWidth(max: stage.px(toastTextMaxWidth(stageWidth: stage.width))) {
                        Text(toast.text)
                            .font(DelosFonts.figtree(stage.tpx(25), .semibold))
                            .lineSpacing(stage.px(25 * 0.28))
                            .foregroundStyle(cardText.color)
                            .lineLimit(toastMaxLines)
                            .truncationMode(.tail)
                    }
                    .rising(age: age, delay: ToastTiming.rowAt + Motion.staggerRow, reduced: reduced, unit: stage.px(1))
                }
                if let action = toast.action {
                    HStack(spacing: stage.px(10)) {
                        Text("Y")
                            .font(DelosFonts.figtree(stage.tpx(21), .heavy))
                            .foregroundStyle(cardBottom.color)
                            .frame(width: stage.px(38), height: stage.px(38))
                            .background(Circle().fill(cardText.color))
                        Text(action.label)
                            .font(DelosFonts.figtree(stage.tpx(24), .heavy))
                            .foregroundStyle(mix(gold, RGBA(red: 1, green: 1, blue: 1), 0.45).color)
                            .lineLimit(1)
                    }
                    .padding(.leading, stage.px(8))
                    .padding(.vertical, stage.px(7))
                    .padding(.trailing, stage.px(22))
                    .background(Capsule().fill(gold.opacity(0.16).color))
                    .overlay(Capsule().strokeBorder(gold.opacity(0.6).color, lineWidth: stage.px(1.5)))
                    .scaleEffect(ToastTiming.pressScale(sinceMs: slot.pressMs.map { now - $0 } ?? -1))
                    .rising(age: age, delay: ToastTiming.rowAt + 2 * Motion.staggerRow, reduced: reduced, unit: stage.px(1))
                }
            }
            .padding(.leading, stage.px(24))
            .padding(.top, stage.px(16))
            .padding(.trailing, stage.px(toast.action != nil ? 18 : 26))
            .padding(.bottom, stage.px(20))
        }
        .fixedSize()
        .background(LinearGradient(colors: [cardTop.color, cardBottom.color], startPoint: .top, endPoint: .bottom))
        .overlay { if !reduced { sweep(age: age) } }
        .overlay(alignment: .bottomLeading) { timerLine(age: age, gold: gold) }
        .clipShape(shape)
        .overlay { shape.strokeBorder(cardRing.color, lineWidth: 1) }
    }

    /// The light sweep: a soft band of white, tilted 12°, that crosses the card once right after it lands.
    private func sweep(age: Double) -> some View {
        let progress = Motion.progress(age, delay: ToastTiming.sweepAt, duration: ToastTiming.sweepMs, Motion.easeOut)
        let strength = sin(Double.pi * progress)
        return GeometryReader { proxy in
            let band = stage.px(190)
            LinearGradient(stops: (0...10).map { i in
                let t = Double(i) / 10
                return .init(color: .white.opacity(0.30 * 0.5 * (1 - cos(2 * Double.pi * t))), location: t)
            }, startPoint: .leading, endPoint: .trailing)
            .frame(width: band, height: proxy.size.height * 1.4)
            .rotationEffect(.degrees(12))
            .offset(x: proxy.size.width * Motion.lerp(-0.4, 1.4, progress) - band / 2, y: -proxy.size.height * 0.2)
            .opacity(strength)
        }
        .allowsHitTesting(false)
    }

    /// The timer: one thin gold line along the bottom edge that draws in from the left, then drains toward it.
    private func timerLine(age: Double, gold: RGBA) -> some View {
        GeometryReader { proxy in
            LinearGradient(colors: [mix(gold, RGBA(red: 0xB8 / 255, green: 0x78 / 255, blue: 0), 0.6).color, gold.color],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: proxy.size.width * ToastTiming.timerFraction(age: age, holdMs: slot.holdMs), height: stage.px(4))
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }
}

private extension View {
    /// An element of the card that fades in and rises ``Motion/rise`` stage pixels from [delay] ms after the card
    /// started to enter.
    func rising(age: Double, delay: Double, reduced: Bool, unit: CGFloat) -> some View {
        let appear = Motion.progress(age, delay: delay, duration: Motion.rowIn, Motion.easeOut)
        return opacity(appear).offset(y: reduced ? 0 : Motion.rise * unit * (1 - appear))
    }
}

/// Proposes at most [max] points of width to its content and takes the width the content needs: the toast is as wide as
/// its widest line.
private struct CappedWidth: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? max, max), height: nil)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
