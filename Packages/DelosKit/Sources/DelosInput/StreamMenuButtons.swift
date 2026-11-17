import DelosCore

/// A button that can be part of the stream menu's own shortcut (`StreamMenuSettings.usable` of DELOS for Android: any
/// key that reaches the app, a controller's buttons and a keyboard's keys alike, but the D-pad and the arrow keys; a
/// touchpad's click does not). The order is the order of their names in a label ("L3 + R3"): the controller's buttons,
/// then the keys by their HID usage; ``rawValue`` is what a profile stores (`key:` and the usage for a key). It is no
/// `RawRepresentable`: equality and hashing stay the cases' own, not the stored name's.
public enum ShortcutButton: Sendable, Hashable, Comparable {
    case a, b, x, y
    case l1, r1, l2, r2, l3, r3
    case start, select, home
    case paddle1, paddle2, paddle3, paddle4
    case share
    /// A keyboard key by its USB HID usage (`GCKeyCode`).
    case key(Int)

    /// The controller's buttons, in label order.
    public static let padButtons: [ShortcutButton] = [
        .a, .b, .x, .y, .l1, .r1, .l2, .r2, .l3, .r3, .start, .select, .home, .paddle1, .paddle2, .paddle3, .paddle4, .share,
    ]
    private static let padNames = [
        "a", "b", "x", "y", "l1", "r1", "l2", "r2", "l3", "r3", "start", "select", "home",
        "paddle1", "paddle2", "paddle3", "paddle4", "share",
    ]
    private static let keyPrefix = "key:"

    /// The keys that cannot be part of it: the arrow keys (Android's D-pad key codes, which a keyboard's arrows are too).
    public static let unusableKeys: Set<Int> = [0x4F, 0x50, 0x51, 0x52]

    /// A key that can be part of the shortcut, nil for an arrow key.
    public static func usableKey(_ usage: Int) -> ShortcutButton? {
        unusableKeys.contains(usage) ? nil : .key(usage)
    }

    public init?(rawValue: String) {
        if rawValue.hasPrefix(Self.keyPrefix) {
            guard let usage = Int(rawValue.dropFirst(Self.keyPrefix.count)), (0...0xFFFF).contains(usage),
                let key = Self.usableKey(usage)
            else { return nil }
            self = key
        } else {
            guard let index = Self.padNames.firstIndex(of: rawValue) else { return nil }
            self = Self.padButtons[index]
        }
    }

    public var rawValue: String {
        if case .key(let usage) = self { return Self.keyPrefix + String(usage) }
        return Self.padNames[Self.padButtons.firstIndex(of: self)!]
    }

    public static func < (lhs: ShortcutButton, rhs: ShortcutButton) -> Bool {
        switch (lhs, rhs) {
        case let (.key(l), .key(r)): l < r
        case (.key, _): false
        case (_, .key): true
        default: padButtons.firstIndex(of: lhs)! < padButtons.firstIndex(of: rhs)!
        }
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

    /// The keys held (HID usages) that can be part of the shortcut.
    public static func pressed(keys: Set<Int>) -> Set<ShortcutButton> {
        Set(keys.compactMap(usableKey))
    }

    /// The name of a key: Android's readout of its key code (`KeyEvent.keyCodeToString` without `KEYCODE_`, in sentence
    /// case: "Ctrl left", "Escape", "F5", "A"), since a key has no legend Android would show.
    public static func keyName(_ usage: Int) -> String {
        switch usage {
        case 0x04...0x1D: String(UnicodeScalar(UInt8(usage - 0x04 + 65)))
        case 0x1E...0x26: String(usage - 0x1E + 1)
        case 0x27: "0"
        case 0x3A...0x45: "F\(usage - 0x3A + 1)"
        case 0x68...0x73: "F\(usage - 0x68 + 13)"
        case 0x59...0x61: "Numpad \(usage - 0x59 + 1)"
        case 0x62: "Numpad 0"
        default: keyNames[usage] ?? "Unknown"
        }
    }

    private static let keyNames: [Int: String] = [
        0x28: "Enter", 0x29: "Escape", 0x2A: "Del", 0x2B: "Tab", 0x2C: "Space", 0x2D: "Minus", 0x2E: "Equals",
        0x2F: "Left bracket", 0x30: "Right bracket", 0x31: "Backslash", 0x32: "Backslash", 0x33: "Semicolon",
        0x34: "Apostrophe", 0x35: "Grave", 0x36: "Comma", 0x37: "Period", 0x38: "Slash", 0x39: "Caps lock",
        0x46: "Sysrq", 0x47: "Scroll lock", 0x48: "Break", 0x49: "Insert", 0x4A: "Move home", 0x4B: "Page up",
        0x4C: "Forward del", 0x4D: "Move end", 0x4E: "Page down", 0x53: "Num lock", 0x54: "Numpad divide",
        0x55: "Numpad multiply", 0x56: "Numpad subtract", 0x57: "Numpad add", 0x58: "Numpad enter", 0x63: "Numpad dot",
        0x64: "Backslash", 0x65: "Menu", 0x67: "Numpad equals", 0xE0: "Ctrl left", 0xE1: "Shift left", 0xE2: "Alt left",
        0xE3: "Meta left", 0xE4: "Ctrl right", 0xE5: "Shift right", 0xE6: "Alt right", 0xE7: "Meta right",
    ]

    /// Takes [buttons] out of the state the PC gets: their flags, and a trigger's travel. With `flippedFaceButtons` the
    /// PC's state has A and B, X and Y swapped (``ControllerOptions/flipFaceButtons``), while the shortcut is the
    /// controller's own buttons, as on Android (the menu takes the key before the flip).
    public static func remove(_ buttons: Set<ShortcutButton>, from state: inout ControllerState, flippedFaceButtons: Bool = false) {
        for button in buttons {
            switch button {
            case .l2: state.leftTrigger = 0
            case .r2: state.rightTrigger = 0
            default: if let flag = button.flag(flippedFaceButtons: flippedFaceButtons) { state.buttons.remove(flag) }
            }
        }
    }

    /// The button's flag in the PC's controller state (nil for the analog triggers and the keys).
    func flag(flippedFaceButtons: Bool = false) -> ControllerButtons? {
        switch self {
        case .a: flippedFaceButtons ? .b : .a
        case .b: flippedFaceButtons ? .a : .b
        case .x: flippedFaceButtons ? .y : .x
        case .y: flippedFaceButtons ? .x : .y
        case .l1: .leftShoulder
        case .r1: .rightShoulder
        case .l2, .r2, .key: nil
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
        for button in pressed.sorted() where !held.contains(button) {
            held.insert(button)
            if !combination.contains(button) { combination.append(button) }
        }
        held.formIntersection(pressed)
        guard held.isEmpty, !combination.isEmpty else { return nil }
        finished = true
        return Set(combination)
    }
}
