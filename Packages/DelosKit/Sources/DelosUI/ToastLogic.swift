import Foundation

/// The kind of a toast (`ToastKind` of DELOS for Android): its color, its icon when it brings none, and the word above
/// its text.
enum ToastKind: Sendable, CaseIterable {
    case info, success, warning, error, action

    /// The word above the text (INFO, DONE, WARNING, ERROR, UNDO).
    var word: String {
        switch self {
        case .info: L("toast_kind_info")
        case .success: L("toast_kind_success")
        case .warning: L("toast_kind_warning")
        case .error: L("toast_kind_error")
        case .action: L("toast_kind_action")
        }
    }

    /// The icon of a toast that brings none of its own.
    var defaultIcon: String {
        switch self {
        case .info: Symbols.info
        case .success: Symbols.checkCircle
        case .warning: Symbols.warning
        case .error: Symbols.error
        case .action: Symbols.delete
        }
    }

    /// The kind of a toast (`toastKindFor`): the caller's [explicit] kind; otherwise one with an action is ``action``
    /// (Undo, the only action of DELOS for Android's toasts); otherwise it is read from the [icon] (a failure icon is an
    /// error, a check a success, the warning triangle a warning), and everything else is information. An explicit kind
    /// lets a notice whose action is not Undo (the Home button's settings) keep its own word.
    static func of(explicit: ToastKind?, icon: String?, hasAction: Bool) -> ToastKind {
        if let explicit { return explicit }
        if hasAction { return .action }
        switch icon {
        case Symbols.error, Symbols.wifiOff, Symbols.linkOff: return .error
        case Symbols.checkCircle, Symbols.check: return .success
        case Symbols.warning: return .warning
        default: return .info
        }
    }
}

/// A toast shows at most this many lines of text, then an ellipsis (no marquee: a toast is never focused); a notice
/// that tells more asks for more (``Toast/maxLines``).
let toastMaxLines = 2

/// The widest the text of a toast may be (stage pixels): 560 at the interface [scale], and never wider than the stage
/// minus 360, so a 4:3 screen still has room for the icon block and the margins.
func toastTextMaxWidth(stageWidth: Double, scale: Double = 1) -> Double { min(560 * scale, stageWidth - 360 * scale) }

/// Timings of the console toast that are not in ``Motion`` (`ToastTiming` of DELOS for Android; milliseconds, stage
/// pixels, fractions).
enum ToastTiming {
    /// A toast of the interface.
    static let shellMs = 4500.0
    /// A toast with an action: the profile deletion lets itself be undone for as long.
    static let actionMs = 10_000.0
    /// A short toast over the stream (`STREAM_SHORT_MS`, ToastLogic.kt:61 of DELOS for Android).
    static let streamShortMs = 4000.0
    /// A long toast over the stream (`STREAM_LONG_MS`, ToastLogic.kt:62 of DELOS for Android).
    static let streamLongMs = 6500.0

    /// Distance the card travels beyond its own width when it springs in from outside the right edge.
    static let slideExtra = 140.0
    /// Distance the card leaves to the right.
    static let exitSlide = 72.0

    /// Damping ratio and stiffness (mass 1) of the enter spring: it overshoots 8.4 % of the travel (peak at 327 ms),
    /// first reaches its place at 233 ms and is within 1 % after 627 ms.
    static let springDamping = 0.62
    static let springStiffness = 150.0
    static let fromScale = 0.94

    /// When the card first reaches its place: everything else is timed against it.
    static let landingMs = 230.0
    /// The icon block pops and the word, the text and the chip rise just before the card lands.
    static let iconDelay = landingMs - 100
    static let rowAt = landingMs - 90
    /// The kind-colored halo fades out from here over the rest of the time the toast is shown.
    static let glowAt = 200.0
    /// The light sweep crosses the card once, right after it lands.
    static let sweepAt = landingMs + 20
    static let sweepMs = 860.0
    /// The gold timer line draws in, then drains.
    static let lineAt = landingMs + 50
    static let lineDraw = 420.0

    /// Opacity of the glow at the card's edge at its peak, and how far it reaches (stage pixels).
    static let glowPeak = 0.42
    static let glowReach = 150.0
    /// The share of ``glowReach`` the halo has when the toast starts; it spreads to the full reach by the end.
    static let glowReachFrom = 0.45
    /// The drop shadow: its opacity at the edge, reach, drop and inset from the card (stage pixels).
    static let shadowPeak = 0.22
    static let shadowReach = 44.0
    static let shadowDrop = 14.0
    static let shadowInset = 10.0

    /// How strong the halo is at [t] (0 at the card's edge, 1 at its reach) as a fraction of its peak: a smoothstep, so
    /// it starts and ends without a visible edge.
    static func haloFalloff(_ t: Double) -> Double {
        let s = 1 - min(max(t, 0), 1)
        return s * s * (3 - 2 * s)
    }

    /// The enter spring's position [ms] after the card started to enter: 0 at the start, 1 at rest, above 1 while it
    /// overshoots.
    static func springStep(_ ms: Double) -> Double {
        if ms <= 0 { return 0 }
        let w0 = springStiffness.squareRoot()
        let wd = w0 * (1 - springDamping * springDamping).squareRoot()
        let t = ms / 1000
        return 1 - exp(-springDamping * w0 * t) * (cos(wd * t) + springDamping * w0 / wd * sin(wd * t))
    }

    /// How much of the timer line is there [age] ms after the toast started to enter: it draws in, then drains over
    /// [holdMs].
    static func timerFraction(age: Double, holdMs: Double) -> Double {
        let left = min(max(1 - age / holdMs, 0), 1)
        return min(Motion.progress(age, delay: lineAt, duration: lineDraw, Motion.easeOut), left)
    }

    /// The squeeze of the Undo chip [sinceMs] after it was pressed (negative: not pressed).
    static func pressScale(sinceMs: Double) -> Double {
        if sinceMs < 0 { return 1 }
        if sinceMs < Motion.pressHold {
            return Motion.lerp(1, Motion.pressScale, Motion.progress(sinceMs, delay: 0, duration: Motion.press, Motion.easeSpring))
        }
        return Motion.lerp(Motion.pressScale, 1, Motion.progress(sinceMs, delay: Motion.pressHold, duration: Motion.press, Motion.easeSpring))
    }
}

/// One toast on the stage (`ToastSlot` of DELOS for Android): it starts to enter at [startMs], leaves at ``exitMs`` and
/// is gone ``Motion/exit`` ms after that.
final class ToastSlot<Payload> {
    let payload: Payload
    let startMs: Double
    let holdMs: Double
    /// Set when a newer toast (or a dismissal) sends this one away before its time is up.
    fileprivate(set) var forcedExitMs = Double.infinity
    /// When its action was pressed (the chip squeezes); nil: not pressed.
    fileprivate(set) var pressMs: Double?
    fileprivate var notified = false

    init(payload: Payload, startMs: Double, holdMs: Double) {
        self.payload = payload
        self.startMs = startMs
        self.holdMs = holdMs
    }

    var exitMs: Double { min(forcedExitMs, startMs + holdMs) }
    var goneMs: Double { exitMs + Motion.exit }
}

/// The replace rule of the console toast (`ToastStageLogic` of DELOS for Android), as plain arithmetic on a clock in
/// milliseconds: there is never a queue. A new toast sends every live one away at once (they leave in ``Motion/exit``)
/// and, when there was one, starts to enter ``Motion/rowDelay`` later, so the two cross; a toast that arrives in that
/// gap replaces the waiting one (which never shows). Without a live toast it enters at once.
final class ToastStageLogic<Payload> {
    private(set) var slots: [ToastSlot<Payload>] = []

    var isEmpty: Bool { slots.isEmpty }

    @discardableResult
    func show(_ payload: Payload, holdMs: Double, now: Double) -> ToastSlot<Payload> {
        removeGone(now)
        var replaced = false
        for slot in slots where now < slot.exitMs {
            replaced = true
            slot.forcedExitMs = min(slot.forcedExitMs, now)
        }
        let slot = ToastSlot(payload: payload, startMs: replaced ? now + Motion.rowDelay : now, holdMs: holdMs)
        slots.append(slot)
        return slot
    }

    /// Sends every live toast away (the toast was dismissed or its action ran).
    func dismiss(now: Double) {
        for slot in slots where now < slot.exitMs { slot.forcedExitMs = min(slot.forcedExitMs, now) }
    }

    /// The newest toast that has not started to leave.
    func latestLive(now: Double) -> ToastSlot<Payload>? { slots.last { now < $0.exitMs } }

    /// The action chip of the newest live toast was pressed.
    func press(now: Double) {
        latestLive(now: now)?.pressMs = now
    }

    /// Calls [onExit] once for each toast whose time is up and drops the ones that have left; true when the list changed.
    @discardableResult
    func advance(now: Double, onExit: (ToastSlot<Payload>) -> Void) -> Bool {
        for slot in slots where now >= slot.exitMs && !slot.notified {
            slot.notified = true
            onExit(slot)
        }
        return removeGone(now)
    }

    @discardableResult
    private func removeGone(_ now: Double) -> Bool {
        let before = slots.count
        slots.removeAll { now >= $0.goneMs }
        return slots.count != before
    }
}
