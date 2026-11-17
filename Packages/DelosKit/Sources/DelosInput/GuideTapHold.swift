/// A controller's Home (Guide) button during a stream (`GuideTapHold` of DELOS for Android): a tap opens the stream menu
/// and sends nothing to the PC; a hold of ``holdMilliseconds`` sends Guide to the PC (Steam's overlay, the Game Bar),
/// pressed as soon as the hold time passes, while the button is still down, and released with the button.
///
/// Pure state with the caller's clock: ``GameInput`` feeds it the button's edges and its hold timer (one instance per
/// controller) and does what it returns.
public struct GuideTapHold: Sendable {
    /// How long the button must be held to become Guide.
    public static let holdMilliseconds: Int64 = 500

    /// What the caller does for an edge or the timer.
    public enum Action: Sendable, Equatable {
        /// Nothing now (the press is still undecided, or the edge belongs to no press).
        case none
        /// Open the stream menu: the button came up before the hold time. Nothing reaches the PC.
        case tapMenu
        /// Press Guide on the PC and keep it down: the hold time has passed with the button still down.
        case guideDown
        /// Release Guide on the PC: the button that became Guide came up.
        case guideUp
    }

    private var down = false
    private var guide = false
    private var downAt: Int64 = 0

    public init() {}

    /// Whether Guide is pressed on the PC now.
    public var isGuideDown: Bool { guide }

    /// The button went down at [now] (milliseconds; a repeat of a held button changes nothing). The caller starts the
    /// hold timer when this returns true.
    public mutating func onDown(_ now: Int64) -> Bool {
        guard !down else { return false }
        down = true
        guide = false
        downAt = now
        return true
    }

    /// The hold timer fired at [now]; a timer that runs early, late after a release or twice does nothing.
    public mutating func onHoldTimeout(_ now: Int64) -> Action {
        guard down, !guide, now - downAt >= Self.holdMilliseconds else { return .none }
        guide = true
        return .guideDown
    }

    /// The button came up. The caller cancels the hold timer.
    public mutating func onUp() -> Action {
        guard down else { return .none }
        down = false
        if guide {
            guide = false
            return .guideUp
        }
        return .tapMenu
    }

    /// Forgets a press in progress (the controller went away, the stream stopped, the menu took the input); returns
    /// whether Guide was down.
    @discardableResult
    public mutating func reset() -> Bool {
        let wasGuide = guide
        down = false
        guide = false
        return wasGuide
    }
}
