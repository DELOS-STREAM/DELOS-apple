import DelosCore

/// A key combination the stream menu sends to the PC once (`sendKeys` of DELOS for Android's key handler): every key goes
/// down in the order given, the modifiers among them held for the keys after them, then every key goes up in reverse.
public struct KeyCombo: Equatable, Sendable {
    /// One event of the combination.
    public struct Event: Equatable, Sendable {
        public let code: Int16
        public let pressed: Bool
        public let modifiers: KeyModifiers
    }

    /// Windows virtual-key codes.
    public let keys: [UInt8]

    public init(_ keys: [UInt8]) {
        self.keys = keys
    }

    /// The modifier a virtual key is, or none.
    static func modifier(of key: UInt8) -> KeyModifiers {
        switch key {
        case VirtualKey.leftShift, VirtualKey.rightShift: .shift
        case VirtualKey.leftControl, VirtualKey.rightControl: .control
        case VirtualKey.leftAlt, VirtualKey.rightAlt: .alt
        case VirtualKey.leftWindows, VirtualKey.rightWindows: .meta
        default: []
        }
    }

    /// The key events in the order they are sent.
    public var events: [Event] {
        var held: KeyModifiers = []
        var events: [Event] = []
        for key in keys {
            held.formUnion(Self.modifier(of: key))
            events.append(Event(code: KeyboardMapping.keyCode(key), pressed: true, modifiers: held))
        }
        for key in keys.reversed() {
            events.append(Event(code: KeyboardMapping.keyCode(key), pressed: false, modifiers: held))
            held.subtract(Self.modifier(of: key))
        }
        return events
    }
}

/// The Windows virtual-key codes the menu's combinations use.
public enum VirtualKey {
    public static let tab: UInt8 = 0x09
    public static let enter: UInt8 = 0x0D
    public static let backspace: UInt8 = 0x08
    public static let escape: UInt8 = 0x1B
    public static let left: UInt8 = 0x25
    public static let leftShift: UInt8 = 0xA0
    public static let rightShift: UInt8 = 0xA1
    public static let leftControl: UInt8 = 0xA2
    public static let rightControl: UInt8 = 0xA3
    public static let leftAlt: UInt8 = 0xA4
    public static let rightAlt: UInt8 = 0xA5
    public static let leftWindows: UInt8 = 0x5B
    public static let rightWindows: UInt8 = 0x5C
    public static let f1: UInt8 = 0x70
    public static let f4: UInt8 = 0x73
    public static let f11: UInt8 = 0x7A
    public static let f12: UInt8 = 0x7B
    public static let b: UInt8 = 0x42
    public static let d: UInt8 = 0x44
    public static let g: UInt8 = 0x47
    public static let v: UInt8 = 0x56
}

/// The built-in key combinations of the stream menu's Send keys page, in the order of DELOS for Android's `GameMenu`. The
/// names are the Android string names of their labels; the combinations are the same keys.
public enum SpecialKeys {
    public struct Option: Equatable, Sendable {
        public let label: String
        public let combo: KeyCombo
    }

    public static let all: [Option] = [
        Option(label: "game_menu_send_keys_esc", combo: KeyCombo([VirtualKey.escape])),
        Option(label: "game_menu_send_keys_f11", combo: KeyCombo([VirtualKey.f11])),
        Option(label: "game_menu_send_keys_alt_f4", combo: KeyCombo([VirtualKey.leftAlt, VirtualKey.f4])),
        Option(label: "game_menu_send_keys_alt_enter", combo: KeyCombo([VirtualKey.leftAlt, VirtualKey.enter])),
        Option(label: "game_menu_send_keys_ctrl_v", combo: KeyCombo([VirtualKey.leftControl, VirtualKey.v])),
        Option(label: "game_menu_send_keys_win", combo: KeyCombo([VirtualKey.leftWindows])),
        Option(label: "game_menu_send_keys_win_d", combo: KeyCombo([VirtualKey.leftWindows, VirtualKey.d])),
        Option(label: "game_menu_send_keys_win_g", combo: KeyCombo([VirtualKey.leftWindows, VirtualKey.g])),
        Option(label: "game_menu_send_keys_ctrl_alt_tab", combo: KeyCombo([VirtualKey.leftControl, VirtualKey.leftAlt, VirtualKey.tab])),
        Option(label: "game_menu_send_keys_shift_tab", combo: KeyCombo([VirtualKey.leftShift, VirtualKey.tab])),
        Option(label: "game_menu_send_keys_win_shift_left", combo: KeyCombo([VirtualKey.leftWindows, VirtualKey.leftShift, VirtualKey.left])),
        Option(label: "game_menu_send_keys_ctrl_alt_shift_f1", combo: KeyCombo([VirtualKey.leftControl, VirtualKey.leftAlt, VirtualKey.leftShift, VirtualKey.f1])),
        Option(label: "game_menu_send_keys_ctrl_alt_shift_f12", combo: KeyCombo([VirtualKey.leftControl, VirtualKey.leftAlt, VirtualKey.leftShift, VirtualKey.f12])),
        Option(label: "game_menu_send_keys_alt_b", combo: KeyCombo([VirtualKey.leftWindows, VirtualKey.leftAlt, VirtualKey.b])),
    ]

    /// Task manager: Ctrl + Shift + Esc.
    public static let taskManager = KeyCombo([VirtualKey.leftControl, VirtualKey.leftShift, VirtualKey.escape])
}
