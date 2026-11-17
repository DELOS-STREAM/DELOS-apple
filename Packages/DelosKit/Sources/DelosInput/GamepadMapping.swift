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

/// The mapping of a ``GamepadSnapshot`` to the core's controller state, as Moonlight for iOS maps a `GCExtendedGamepad`.
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

    public static func state(_ pad: GamepadSnapshot) -> ControllerState {
        ControllerState(
            buttons: buttons(pad), leftTrigger: trigger(pad.leftTrigger), rightTrigger: trigger(pad.rightTrigger),
            leftStickX: stick(pad.leftStickX), leftStickY: stick(pad.leftStickY),
            rightStickX: stick(pad.rightStickX), rightStickY: stick(pad.rightStickY))
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
