import DelosCore

/// What a game controller reports at one moment, as plain values: GameController's buttons and axes (sticks −1…1 with
/// y growing upwards, triggers 0…1). ``GameInput`` reads it from a `GCExtendedGamepad`; ``GamepadMapping`` turns it into
/// the state the host gets.
public struct GamepadSnapshot: Equatable, Sendable {
    public var a = false, b = false, x = false, y = false
    public var up = false, down = false, left = false, right = false
    public var leftShoulder = false, rightShoulder = false
    public var leftStickButton = false, rightStickButton = false
    /// Menu (Xbox: Menu, PlayStation: Options) is Start; Options (Xbox: View, PlayStation: Create/Share) is Select.
    public var menu = false, options = false, home = false
    public var paddle1 = false, paddle2 = false, paddle3 = false, paddle4 = false
    public var touchpadButton = false, share = false
    public var leftTrigger: Float = 0, rightTrigger: Float = 0
    /// The triggers past GameController's own press threshold (a trigger as a button of the stream menu's shortcut).
    public var leftTriggerPressed = false, rightTriggerPressed = false
    public var leftStickX: Float = 0, leftStickY: Float = 0
    public var rightStickX: Float = 0, rightStickY: Float = 0

    public init() {}
}

/// The mapping of a ``GamepadSnapshot`` to the core's controller state, as Moonlight for iOS maps a `GCExtendedGamepad`,
/// with DELOS for Android's stick dead zone, trigger dead zone and flipped face buttons (`ControllerHandler`).
public enum GamepadMapping {
    public static func buttons(_ pad: GamepadSnapshot) -> ControllerButtons {
        var buttons: ControllerButtons = []
        let flags: [(Bool, ControllerButtons)] = [
            (pad.a, .a), (pad.b, .b), (pad.x, .x), (pad.y, .y),
            (pad.up, .up), (pad.down, .down), (pad.left, .left), (pad.right, .right),
            (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
            (pad.leftStickButton, .leftStick), (pad.rightStickButton, .rightStick),
            (pad.menu, .play), (pad.options, .back), (pad.home, .special),
            (pad.paddle1, .paddle1), (pad.paddle2, .paddle2), (pad.paddle3, .paddle3), (pad.paddle4, .paddle4),
            (pad.touchpadButton, .touchpad), (pad.share, .misc),
        ]
        for (pressed, flag) in flags where pressed { buttons.insert(flag) }
        return buttons
    }

    /// A stick axis (−1…1) as the host's signed 16-bit value; both use y growing upwards.
    public static func stick(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16((min(max(value, -1), 1) * Float(Int16.max)).rounded())
    }

    /// A trigger (0…1) as the host's 0…255.
    public static func trigger(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((min(max(value, 0), 1) * 255).rounded())
    }

    /// A trigger's travel that still counts as released: 13 %, around XInput's default (`ControllerHandler`, the trigger
    /// dead zone of a controller that reports none of its own).
    public static let triggerDeadzone: Float = 0.13

    /// A stick's position through the dead zone of `radius` (the setting's percent / 100; `handleDeadZone` of DELOS for
    /// Android). A positive radius zeroes a stick that is closer to the centre than that, and leaves it untouched past it
    /// (the PC applies its own dead zone after this one). Zero or a negative radius keeps a 1 % dead zone for the centre
    /// and, below full travel, stretches the rest so a stick reaches the same value `−radius` earlier.
    public static func applyDeadzone(x: Float, y: Float, radius: Float) -> (x: Float, y: Float) {
        let magnitude = (x * x + y * y).squareRoot()
        if radius > 0 {
            return magnitude <= radius ? (0, 0) : (x, y)
        }
        if magnitude < 0.01 { return (0, 0) }
        let normalized = -radius + magnitude * (1 + radius)
        guard normalized < 1 else { return (x, y) }
        let scale = normalized / magnitude
        return (x * scale, y * scale)
    }

    /// A and B, X and Y swapped (`handleFlipFaceButtons`).
    public static func flipFaceButtons(_ pad: GamepadSnapshot) -> GamepadSnapshot {
        var flipped = pad
        (flipped.a, flipped.b) = (pad.b, pad.a)
        (flipped.x, flipped.y) = (pad.y, pad.x)
        return flipped
    }

    /// The state the host gets from `pad` with the stick dead zone and the face buttons of `options`.
    public static func state(_ pad: GamepadSnapshot, options: ControllerOptions = ControllerOptions()) -> ControllerState {
        let pad = options.flipFaceButtons ? flipFaceButtons(pad) : pad
        let radius = Float(options.deadzonePercent) / 100
        let left = applyDeadzone(x: pad.leftStickX, y: pad.leftStickY, radius: radius)
        let right = applyDeadzone(x: pad.rightStickX, y: pad.rightStickY, radius: radius)
        return ControllerState(
            buttons: buttons(pad),
            leftTrigger: trigger(pad.leftTrigger <= triggerDeadzone ? 0 : pad.leftTrigger),
            rightTrigger: trigger(pad.rightTrigger <= triggerDeadzone ? 0 : pad.rightTrigger),
            leftStickX: stick(left.x), leftStickY: stick(left.y), rightStickX: stick(right.x), rightStickY: stick(right.y))
    }

    /// The states of controllers that share a number (multiple controllers off: all are player 1) as one, as Android fuses
    /// them (`sendControllerInputPacket`): every button held on any of them, each axis the one furthest from rest.
    public static func fuse(_ states: [ControllerState]) -> ControllerState {
        func furthest(_ a: Int16, _ b: Int16) -> Int16 { abs(Int(a)) >= abs(Int(b)) ? a : b }
        return states.reduce(into: ControllerState()) { fused, state in
            fused.buttons.formUnion(state.buttons)
            fused.leftTrigger = max(fused.leftTrigger, state.leftTrigger)
            fused.rightTrigger = max(fused.rightTrigger, state.rightTrigger)
            fused.leftStickX = furthest(fused.leftStickX, state.leftStickX)
            fused.leftStickY = furthest(fused.leftStickY, state.leftStickY)
            fused.rightStickX = furthest(fused.rightStickX, state.rightStickX)
            fused.rightStickY = furthest(fused.rightStickY, state.rightStickY)
        }
    }
}

/// The controller numbers of a stream: each connected controller keeps the lowest number free when it arrived, up
/// to 16 (the width of the host's gamepad mask).
public struct ControllerSlots<Key: Hashable> {
    public static var capacity: Int { 16 }
    private var numbers: [Key: UInt8] = [:]

    public init() {}

    /// The number of `key`, given one if it has none; nil when all 16 are taken.
    public mutating func number(for key: Key) -> UInt8? {
        if let number = numbers[key] { return number }
        let taken = Set(numbers.values)
        guard let free = (0..<UInt8(Self.capacity)).first(where: { !taken.contains($0) }) else { return nil }
        numbers[key] = free
        return free
    }

    /// Frees the number of `key` and returns it.
    @discardableResult
    public mutating func remove(_ key: Key) -> UInt8? {
        numbers.removeValue(forKey: key)
    }

    /// A bit for every controller connected (`activeGamepadMask`).
    public var mask: UInt16 {
        numbers.values.reduce(0) { $0 | 1 << UInt16($1) }
    }
}

/// The buttons a controller lacks, made from others (`handleButtonDown`/`handleButtonUp` of DELOS for Android), on the
/// buttons as the PC gets them:
/// - without Select (Options, View): Start + L1 is Select;
/// - without Home: Start + Select is Guide (Start + R1 when it has no Select either);
/// - the touchpad click emulation of a controller announced as a generic one so the PC emulates motion on it (its type
///   is not PlayStation, ``GameInput``): Select + L1 is the touchpad button.
///
/// A combination counts when its buttons are all that is held as one of them goes down, or when the second one goes down
/// within ``bumperUpDelayMilliseconds`` after the shoulder button came up. Its buttons stay off at the PC until each is
/// released again; the made button comes up with the first button released.
public struct ButtonCombos: Sendable {
    /// `MAXIMUM_BUMPER_UP_DELAY_MS`.
    public static let bumperUpDelayMilliseconds: Int64 = 100

    public let hasSelect: Bool
    public let hasHome: Bool
    public let touchpadEmulation: Bool

    private var physical: ControllerButtons = []
    /// Android's `inputMap`: the physical buttons, without the ones a combination took, with the ones it made.
    private var map: ControllerButtons = []
    private var emulating: ControllerButtons = []
    private var lastL1Up: Int64 = .min / 2
    private var lastR1Up: Int64 = .min / 2

    public init(hasSelect: Bool, hasHome: Bool, touchpadEmulation: Bool) {
        self.hasSelect = hasSelect
        self.hasHome = hasHome
        self.touchpadEmulation = touchpadEmulation
    }

    /// Whether this controller needs any of the combinations.
    public var isActive: Bool { !hasSelect || !hasHome || touchpadEmulation }

    /// The buttons for the PC, from the `buttons` held at `now` (milliseconds).
    public mutating func apply(_ buttons: ControllerButtons, now: Int64) -> ControllerButtons {
        guard isActive else { return buttons }
        let released = physical.subtracting(buttons), pressed = buttons.subtracting(physical)
        physical = buttons
        if !released.isEmpty {
            map.subtract(released)
            if released.contains(.leftShoulder) { lastL1Up = now }
            if released.contains(.rightShoulder) { lastR1Up = now }
            if emulating.contains(.back), !map.contains(.play) || !map.contains(.leftShoulder) {
                map.remove(.back)
                emulating.remove(.back)
            }
            if emulating.contains(.special), !map.contains(.play) || (!map.contains(.back) && !map.contains(.rightShoulder)) {
                map.remove(.special)
                emulating.remove(.special)
            }
            if emulating.contains(.touchpad), !map.contains(.back) || !map.contains(.leftShoulder) {
                map.remove(.touchpad)
                emulating.remove(.touchpad)
            }
        }
        if !pressed.isEmpty {
            map.formUnion(pressed)
            if !hasSelect {
                if map == [.play, .leftShoulder] || (map == .play && now - lastL1Up <= Self.bumperUpDelayMilliseconds) {
                    map.subtract([.play, .leftShoulder])
                    map.insert(.back)
                    emulating.insert(.back)
                }
            } else if touchpadEmulation {
                if map == [.back, .leftShoulder] || (map == .back && now - lastL1Up <= Self.bumperUpDelayMilliseconds) {
                    map.subtract([.back, .leftShoulder])
                    map.insert(.touchpad)
                    emulating.insert(.touchpad)
                }
            }
            if !hasHome {
                if hasSelect {
                    if map == [.play, .back] {
                        map.subtract([.play, .back])
                        map.insert(.special)
                        emulating.insert(.special)
                    }
                } else if map == [.play, .rightShoulder] || (map == .play && now - lastR1Up <= Self.bumperUpDelayMilliseconds) {
                    map.subtract([.play, .rightShoulder])
                    map.insert(.special)
                    emulating.insert(.special)
                }
            }
        }
        return map
    }

    /// Forgets everything held (the input paused or stopped).
    public mutating func reset() {
        physical = []
        map = []
        emulating = []
    }
}
