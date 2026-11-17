import DelosCore

/// A controller button that can be part of the stream menu's own shortcut (`StreamMenuSettings.usable` of DELOS for
/// Android: any button that reaches the app as a key, but the D-pad; a touchpad's click does not). The order is the order
/// of their names in a label ("L3 + R3"); the raw value is what a profile stores.
public enum ShortcutButton: String, CaseIterable, Sendable, Hashable, Comparable {
    case a, b, x, y
    case l1, r1, l2, r2, l3, r3
    case start, select, home
    case paddle1, paddle2, paddle3, paddle4
    case share

    public static func < (lhs: ShortcutButton, rhs: ShortcutButton) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// The buttons a profile stored; names this version does not know are left out.
    public static func parse(_ stored: [String]) -> Set<ShortcutButton> {
        Set(stored.compactMap(ShortcutButton.init(rawValue:)))
    }

    /// The buttons as a profile stores them, in label order.
    public static func stored(_ buttons: Set<ShortcutButton>) -> [String] {
        buttons.sorted().map(\.rawValue)
    }

    /// The buttons held in [pad]. The triggers count as pressed past GameController's own threshold.
    public static func pressed(_ pad: GamepadSnapshot) -> Set<ShortcutButton> {
        let flags: [(Bool, ShortcutButton)] = [
            (pad.a, .a), (pad.b, .b), (pad.x, .x), (pad.y, .y),
            (pad.leftShoulder, .l1), (pad.rightShoulder, .r1), (pad.leftTriggerPressed, .l2), (pad.rightTriggerPressed, .r2),
            (pad.leftStickButton, .l3), (pad.rightStickButton, .r3),
            (pad.menu, .start), (pad.options, .select), (pad.home, .home),
            (pad.paddle1, .paddle1), (pad.paddle2, .paddle2), (pad.paddle3, .paddle3), (pad.paddle4, .paddle4),
            (pad.share, .share),
        ]
        return Set(flags.filter(\.0).map(\.1))
    }

    /// Takes [buttons] out of the state the PC gets: their flags, and a trigger's travel.
    public static func remove(_ buttons: Set<ShortcutButton>, from state: inout ControllerState) {
        for button in buttons {
            switch button {
            case .l2: state.leftTrigger = 0
            case .r2: state.rightTrigger = 0
            default: if let flag = button.flag { state.buttons.remove(flag) }
            }
        }
    }

    /// The button's flag in the PC's controller state (nil for the analog triggers).
    var flag: ControllerButtons? {
        switch self {
        case .a: .a
        case .b: .b
        case .x: .x
        case .y: .y
        case .l1: .leftShoulder
        case .r1: .rightShoulder
        case .l2, .r2: nil
        case .l3: .leftStick
        case .r3: .rightStick
        case .start: .play
        case .select: .back
        case .home: .special
        case .paddle1: .paddle1
        case .paddle2: .paddle2
        case .paddle3: .paddle3
        case .paddle4: .paddle4
        case .share: .misc
        }
    }
}

/// The stream menu's own button shortcut (`ButtonShortcut` of DELOS for Android): all of `buttons` held together, in any
/// order, open the menu when the last of them is let go. None are set by default: a tap of Home opens the menu
/// (``GuideTapHold``); the player records a combination in Settings → Controls.
///
/// Only the button that completes the shortcut is kept from the host, until it is released: the ones pressed before
/// it already reached the game, so their release must reach it too, or the host would keep them pressed.
public struct MenuShortcut: Sendable {
    public let buttons: Set<ShortcutButton>
    private var held: Set<ShortcutButton> = []
    private var swallowed: Set<ShortcutButton> = []
    private var pending = false

    public init(buttons: Set<ShortcutButton> = []) {
        self.buttons = buttons
    }

    /// Takes the buttons held now; returns the ones the host must not see and whether the menu opens.
    public mutating func update(_ pressed: Set<ShortcutButton>) -> (swallowed: Set<ShortcutButton>, open: Bool) {
        guard !buttons.isEmpty else { return ([], false) }
        let now = pressed.intersection(buttons)
        let newlyPressed = now.subtracting(held)
        held = now
        if !newlyPressed.isEmpty, now == buttons {
            pending = true
            swallowed.formUnion(newlyPressed)
        }
        swallowed.formIntersection(now)
        var open = false
        if pending, held.isEmpty {
            pending = false
            open = true
        }
        return (swallowed, open)
    }
}

/// Records the stream menu's buttons (`ButtonCaptureLayer` of DELOS for Android): the buttons held together (one or more)
/// are the combination once all of them are let go.
public struct MenuButtonRecorder: Sendable {
    /// How long the recording waits for a first button before it gives up, unchanged (Android's `IDLE_MS`).
    public static let idle = Duration.seconds(10)

    private var held: Set<ShortcutButton> = []
    /// The buttons pressed so far, in the order they went down.
    public private(set) var combination: [ShortcutButton] = []
    private var finished = false

    public init() {}

    /// Takes the buttons held now; returns the combination when the last of them was let go. Once it has, the recording is
    /// over and takes nothing more.
    public mutating func update(_ pressed: Set<ShortcutButton>) -> Set<ShortcutButton>? {
        guard !finished else { return nil }
        for button in ShortcutButton.allCases where pressed.contains(button) && !held.contains(button) {
            held.insert(button)
            if !combination.contains(button) { combination.append(button) }
        }
        held.formIntersection(pressed)
        guard held.isEmpty, !combination.isEmpty else { return nil }
        finished = true
        return Set(combination)
    }
}
