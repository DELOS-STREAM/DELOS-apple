import DelosCore

/// What a release of Start does (`handleButtonUp` of DELOS for Android, `KEYCODE_BUTTON_START`): a press held longer
/// than ``holdMilliseconds`` toggles the mouse emulation (when it is on in Settings), or opens the stream menu when it
/// followed another Start within ``doublePressMilliseconds`` (a quick double Start, held the second time).
public struct StartButtonHold: Sendable {
    /// `START_DOWN_TIME_MOUSE_MODE_MS`.
    public static let holdMilliseconds: Int64 = 750
    /// `QUICK_MENU_FIRST_STAGE_MS`: from the release of a Start to the next press.
    public static let doublePressMilliseconds: Int64 = 200

    public enum Action: Equatable, Sendable {
        case none, toggleMouseEmulation, openMenu
    }

    private var downTime: Int64?
    private var upTime: Int64 = .min / 2
    private var menuPending = false

    public init() {}

    /// Start went down at `now` (milliseconds).
    public mutating func onDown(_ now: Int64) {
        guard downTime == nil else { return }
        downTime = now
        menuPending = now - upTime <= Self.doublePressMilliseconds
    }

    /// Start went up at `now`; `mouseEmulation` is the setting.
    public mutating func onUp(_ now: Int64, mouseEmulation: Bool) -> Action {
        upTime = now
        guard let down = downTime else { return .none }
        downTime = nil
        guard now - down > Self.holdMilliseconds else { return .none }
        if menuPending {
            menuPending = false
            return .openMenu
        }
        return mouseEmulation ? .toggleMouseEmulation : .none
    }

    /// Forgets a press in progress (the menu opened, the input stopped).
    public mutating func reset() {
        downTime = nil
        menuPending = false
    }
}

/// The controller as the PC's mouse while the mouse emulation runs (`mouseEmulationActive` of DELOS for Android): the
/// PC's controller gets a neutral state; A and B are the left and right buttons; the D-pad scrolls a notch per press (up
/// and down, right and left); while X is held the pointer moves a fixed step of the multiplier, which each press of Y
/// doubles (back to 1 past 255). Every ``period`` the sticks move the pointer and scroll (``ControllerOptions/scrollStick``).
public struct MouseEmulation: Sendable {
    /// `mouseEmulationReportPeriod`.
    public static let period = Duration.milliseconds(50)

    public enum Action: Equatable, Sendable {
        case button(MouseButton, pressed: Bool)
        /// Wheel notches, positive up.
        case scroll(Int8)
        /// Horizontal wheel notches, positive right.
        case horizontalScroll(Int8)
        /// Relative motion, y growing downwards.
        case move(dx: Int16, dy: Int16)
        case highResolutionScroll(Int16)
        case highResolutionHorizontalScroll(Int16)
    }

    private var lastButtons: ControllerButtons = []
    public private(set) var fixedStep = false
    public private(set) var multiplier = 1

    public init() {}

    /// The buttons of the PC's controller state changed: the clicks and notches they make.
    public mutating func buttons(_ buttons: ControllerButtons) -> [Action] {
        let changed = buttons.symmetricDifference(lastButtons)
        lastButtons = buttons
        var actions: [Action] = []
        if changed.contains(.x) { fixedStep = buttons.contains(.x) }
        if changed.contains(.y), buttons.contains(.y) {
            multiplier *= 2
            if multiplier > 255 { multiplier = 1 }
        }
        if changed.contains(.a) { actions.append(.button(.left, pressed: buttons.contains(.a))) }
        if changed.contains(.b) { actions.append(.button(.right, pressed: buttons.contains(.b))) }
        if changed.contains(.up), buttons.contains(.up) { actions.append(.scroll(1)) }
        if changed.contains(.down), buttons.contains(.down) { actions.append(.scroll(-1)) }
        if changed.contains(.right), buttons.contains(.right) { actions.append(.horizontalScroll(1)) }
        if changed.contains(.left), buttons.contains(.left) { actions.append(.horizontalScroll(-1)) }
        return actions
    }

    /// One period's motion and scrolling from the sticks (the host's values, y growing upwards).
    public func tick(_ state: ControllerState, scrollStick: ControllerOptions.ScrollStick) -> [Action] {
        let left = (state.leftStickX, state.leftStickY), right = (state.rightStickX, state.rightStickY)
        switch scrollStick {
        case .right: return move(left) + Self.scroll(right)
        case .left: return move(right) + Self.scroll(left)
        case .none: return move(left) + move(right)
        }
    }

    /// `convertRawStickAxisToPixelMovement`: the stick (−32766…32766) times 4, faster the further out (× magnitude²).
    static func pixels(_ stick: (Int16, Int16)) -> (x: Double, y: Double, magnitude: Double) {
        var x = Double(stick.0) / 32766 * 4, y = Double(stick.1) / 32766 * 4
        var magnitude = (x * x + y * y).squareRoot()
        if magnitude > 0 {
            let factor = magnitude * magnitude
            x *= factor
            y *= factor
            magnitude *= factor
        }
        return (x, y, magnitude)
    }

    /// `sendEmulatedMouseMove`: nothing under a pixel; with X held a fixed step of the multiplier in the stick's
    /// direction (a component under a pixel gives none).
    private func move(_ stick: (Int16, Int16)) -> [Action] {
        let v = Self.pixels(stick)
        guard v.magnitude >= 1 else { return [] }
        if fixedStep {
            return [.move(
                dx: Int16(clamping: Int(v.x).signum() * multiplier), dy: Int16(clamping: Int(-v.y).signum() * multiplier))]
        }
        return [.move(dx: Int16(clamping: Int(v.x)), dy: Int16(clamping: Int(-v.y)))]
    }

    /// `sendEmulatedMouseScroll`: high-resolution scrolling, vertical then horizontal (both, once the stick is out).
    private static func scroll(_ stick: (Int16, Int16)) -> [Action] {
        let v = pixels(stick)
        guard v.magnitude >= 1 else { return [] }
        return [.highResolutionScroll(Int16(clamping: Int(v.y))), .highResolutionHorizontalScroll(Int16(clamping: Int(v.x)))]
    }
}
