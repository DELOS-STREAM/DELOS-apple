import DelosCore

/// Hardware keyboard keys (USB HID usages, which `GCKeyCode` and `UIKey.keyCode` carry) as Windows virtual-key codes,
/// the table of Moonlight for iOS's `KeyboardSupport`.
public enum KeyboardMapping {
    /// The core's prefix of a virtual-key code (`0x8000 | VK`, as Moonlight and DELOS for Android send it).
    static let keyPrefix: UInt16 = 0x8000

    /// The virtual-key code of a HID usage; nil for a key the host has no code for.
    public static func virtualKey(hidUsage usage: Int) -> UInt8? {
        switch usage {
        case 0x04...0x1D: return UInt8(usage - 0x04 + 0x41)  // A…Z
        case 0x1E...0x26: return UInt8(usage - 0x1E + 0x31)  // 1…9
        case 0x27: return 0x30  // 0
        case 0x59...0x61: return UInt8(usage - 0x59 + 0x61)  // keypad 1…9
        case 0x62: return 0x60  // keypad 0
        case 0x3A...0x45: return UInt8(usage - 0x3A + 0x70)  // F1…F12
        case 0x68...0x73: return UInt8(usage - 0x68 + 0x7C)  // F13…F24
        default: return others[usage]
        }
    }

    private static let others: [Int: UInt8] = [
        0x28: 0x0D,  // Return
        0x29: 0x1B,  // Escape
        0x2A: 0x08,  // Backspace
        0x2B: 0x09,  // Tab
        0x2C: 0x20,  // Space
        0x2D: 0xBD,  // -
        0x2E: 0xBB,  // =
        0x2F: 0xDB,  // [
        0x30: 0xDD,  // ]
        0x31: 0xDC,  // \
        0x33: 0xBA,  // ;
        0x34: 0xDE,  // '
        0x35: 0xC0,  // `
        0x36: 0xBC,  // ,
        0x37: 0xBE,  // .
        0x38: 0xBF,  // /
        0x39: 0x14,  // Caps Lock
        0x46: 0x2A,  // Print Screen
        0x47: 0x91,  // Scroll Lock
        0x48: 0x13,  // Pause
        0x49: 0x2D,  // Insert
        0x4A: 0x24,  // Home
        0x4B: 0x21,  // Page Up
        0x4C: 0x2E,  // Delete
        0x4D: 0x23,  // End
        0x4E: 0x22,  // Page Down
        0x4F: 0x27,  // Right
        0x50: 0x25,  // Left
        0x51: 0x28,  // Down
        0x52: 0x26,  // Up
        0x53: 0x90,  // Num Lock
        0x54: 0x6F,  // keypad /
        0x55: 0x6A,  // keypad *
        0x56: 0x6D,  // keypad -
        0x57: 0x6B,  // keypad +
        0x58: 0x0D,  // keypad Enter
        0x63: 0x6E,  // keypad .
        0x64: 0xE2,  // the key between left Shift and Z on ISO keyboards
        0x85: 0x6C,  // keypad ,
        0x9B: 0x03,  // Cancel
        0x9C: 0x0C,  // Clear
        0xA3: 0xF7,  // CrSel
        0xA4: 0xF8,  // ExSel
        0xE0: 0xA2,  // left Control
        0xE1: 0xA0,  // left Shift
        0xE2: 0xA4,  // left Alt (Option)
        0xE3: 0x5B,  // left Windows (Command)
        0xE4: 0xA3,  // right Control
        0xE5: 0xA1,  // right Shift
        0xE6: 0xA5,  // right Alt (Option)
        0xE7: 0x5C,  // right Windows (Command)
    ]

    /// Every HID usage that has a virtual-key code.
    public static let mappedUsages: [Int] = (0...0xE7).filter { virtualKey(hidUsage: $0) != nil }

    /// The code `StreamSession.sendKey` takes for a virtual key.
    public static func keyCode(_ virtualKey: UInt8) -> Int16 {
        Int16(bitPattern: keyPrefix | UInt16(virtualKey))
    }

    /// The modifiers of the keys held (HID usages): Shift, Control, Alt (Option) and Meta (Command), left or right.
    public static func modifiers(held: Set<Int>) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if held.contains(0xE1) || held.contains(0xE5) { modifiers.insert(.shift) }
        if held.contains(0xE0) || held.contains(0xE4) { modifiers.insert(.control) }
        if held.contains(0xE2) || held.contains(0xE6) { modifiers.insert(.alt) }
        if held.contains(0xE3) || held.contains(0xE7) { modifiers.insert(.meta) }
        return modifiers
    }
}
