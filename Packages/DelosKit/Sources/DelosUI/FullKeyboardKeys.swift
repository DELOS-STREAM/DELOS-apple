import DelosInput

/// The keys of the Delos full keyboard (`FullKeyboardKeys.kt` of DELOS for Android): the 80 keys of its six rows, how each
/// is drawn and what it shows while Shift or Caps Lock is on.

/// What a key is: it decides its look (character keys are the brightest) and whether it has a popup or can be latched.
enum KeyKind: Sendable {
    case char, special, modifier, hide
}

/// How a key is drawn.
enum KeyGlyph: Sendable {
    case text, stacked, arrow, space, hide
}

/// One key of the full keyboard. [code] is the Windows virtual-key code that goes to the PC (Android names the Android key
/// code, which its key translation turns into the same virtual key; ``KeyDef/hideCode`` for the Hide key, which sends
/// nothing), [weight] its share of the row, [marginStart] / [marginEnd] the extra gap next to Esc, Ins and around Space.
struct KeyDef: Equatable, Sendable {
    let code: Int
    let legend: String
    let weight: Double
    let kind: KeyKind
    let glyph: KeyGlyph
    var marginStart = false
    var marginEnd = false
    /// Home, End, PgUp and PgDn: a smaller legend.
    var small = false

    /// The Hide key has no key code; it closes the keyboard.
    static let hideCode = -1

    /// Function and modifier keys sit one step quieter than the characters.
    var quiet: Bool { kind == .special || kind == .modifier }

    /// Only the character keys get a popup above them while pressed.
    var hasPopup: Bool { kind == .char }
}

/// The arrow keys, drawn as strokes.
enum KeyArrow: Sendable {
    case up, down, left, right
}

/// The Windows virtual-key codes of the keyboard's keys (Android's `KeyEvent.KEYCODE_*` after `KeyboardTranslator`).
enum KeyCode {
    static let escape = 0x1B, insert = 0x2D, forwardDelete = 0x2E, backspace = 0x08, tab = 0x09, capsLock = 0x14
    static let enter = 0x0D, space = 0x20, home = 0x24, end = 0x23, pageUp = 0x21, pageDown = 0x22
    static let left = 0x25, up = 0x26, right = 0x27, down = 0x28
    static let grave = 0xC0, minus = 0xBD, equals = 0xBB, leftBracket = 0xDB, rightBracket = 0xDD, backslash = 0xDC
    static let semicolon = 0xBA, apostrophe = 0xDE, comma = 0xBC, period = 0xBE, slash = 0xBF
    static let leftShift = Int(VirtualKey.leftShift), rightShift = Int(VirtualKey.rightShift)
    static let leftControl = Int(VirtualKey.leftControl), rightControl = Int(VirtualKey.rightControl)
    static let leftAlt = Int(VirtualKey.leftAlt), rightAlt = Int(VirtualKey.rightAlt)
    static let leftWindows = Int(VirtualKey.leftWindows), rightWindows = Int(VirtualKey.rightWindows)
    static let f1 = Int(VirtualKey.f1)

    /// A letter or a digit: its virtual key is its upper-case ASCII code.
    static func character(_ c: Character) -> Int { Int(c.asciiValue ?? 0) }

    /// The keys a sticky modifier setting latches: both sides, although the keyboard only has the left ones.
    static let modifiers: Set<Int> = [leftAlt, rightAlt, leftControl, rightControl, leftShift, rightShift, leftWindows, rightWindows]

    /// The keys that get no popup above them when pressed (besides the modifiers).
    static let specials: Set<Int> = [
        tab, enter, space, backspace, forwardDelete, escape, capsLock, insert, up, down, left, right, pageUp, pageDown, home, end,
    ]

    static func isModifier(_ code: Int) -> Bool { modifiers.contains(code) }

    static func isShift(_ code: Int) -> Bool { code == leftShift || code == rightShift }

    static func arrow(_ code: Int) -> KeyArrow? {
        switch code {
        case up: .up
        case down: .down
        case left: .left
        case right: .right
        default: nil
        }
    }
}

/// What a key shows now: the [primary] label is what the key types, the [secondary] one (nil for most keys) the other
/// character of a punctuation key, drawn small above it. A letter shows lower case, upper case while Shift is down or
/// Caps Lock is on (both: lower again); a digit shows its symbol while Shift is down; a punctuation key swaps its two
/// characters while Shift is down. Labels are the US layout. Keys with a fixed legend show it as written.
struct KeyLabel: Equatable, Sendable {
    let primary: String
    var secondary: String?
}

enum FullKeyboardKeys {
    /// The symbols the number row types with Shift (US layout), by digit.
    private static let digitShifted = Array(")!@#$%^&*(")

    static func label(_ key: KeyDef, shift: Bool, caps: Bool) -> KeyLabel {
        let legend = key.legend
        let first = legend.first
        if key.glyph == .stacked {
            let top = String(legend.prefix(1)), bottom = String(legend.dropFirst())
            return shift ? KeyLabel(primary: top, secondary: bottom) : KeyLabel(primary: bottom, secondary: top)
        }
        if key.kind == .char, key.glyph == .text, legend.count == 1, let first {
            if first.isLetter { return KeyLabel(primary: shift != caps ? legend.uppercased() : legend.lowercased()) }
            if let digit = first.wholeNumberValue { return KeyLabel(primary: shift ? String(digitShifted[digit]) : legend) }
        }
        return KeyLabel(primary: legend)
    }

    /// What a pressed key shows in the popup above it, nil for a key without one: what the key types.
    static func popupText(_ key: KeyDef, shift: Bool = false, caps: Bool = false) -> String? {
        key.hasPopup ? label(key, shift: shift, caps: caps).primary : nil
    }

    /// Punctuation keys write both characters in one string, the one Shift gives first ("_-", "{[", "?/").
    private static func isStacked(_ legend: String) -> Bool {
        legend.count == 2 && !(legend.first!.isLetter || legend.first!.isNumber)
    }

    private static func key(
        _ code: Int, _ legend: String, _ weight: Double, marginStart: Bool = false, marginEnd: Bool = false, small: Bool = false
    ) -> KeyDef {
        let kind: KeyKind =
            code == KeyDef.hideCode ? .hide : KeyCode.isModifier(code) ? .modifier : KeyCode.specials.contains(code) ? .special : .char
        let glyph: KeyGlyph =
            code == KeyDef.hideCode ? .hide : KeyCode.arrow(code) != nil ? .arrow : code == KeyCode.space ? .space
            : isStacked(legend) ? .stacked : .text
        return KeyDef(code: code, legend: legend, weight: weight, kind: kind, glyph: glyph, marginStart: marginStart, marginEnd: marginEnd, small: small)
    }

    private static func letters(_ text: String) -> [KeyDef] {
        text.map { key(KeyCode.character($0), String($0), 100) }
    }

    /// The 80 keys in their six rows: the keys, weights and margins of Android's `layout_axixi_keyboard.xml`. The legends of
    /// letters are upper case (``label(_:shift:caps:)`` says what is drawn); there are only the left modifiers.
    static let rows: [[KeyDef]] = [
        [key(KeyCode.escape, "ESC", 150, marginEnd: true)]
            + (1...12).map { key(KeyCode.f1 + $0 - 1, "F\($0)", 100) }
            + [key(KeyCode.insert, "Ins", 100, marginStart: true), key(KeyCode.forwardDelete, "Del", 100)],
        [key(KeyCode.grave, "~`", 90)] + letters("1234567890")
            + [key(KeyCode.minus, "_-", 100), key(KeyCode.equals, "+=", 100), key(KeyCode.backspace, "Back", 150)],
        [key(KeyCode.tab, "Tab", 140)] + letters("QWERTYUIOP")
            + [key(KeyCode.leftBracket, "{[", 100), key(KeyCode.rightBracket, "}]", 100), key(KeyCode.backslash, "|\\", 100)],
        [key(KeyCode.capsLock, "Caps", 160)] + letters("ASDFGHJKL")
            + [key(KeyCode.semicolon, ":;", 100), key(KeyCode.apostrophe, "\"'", 100), key(KeyCode.enter, "Enter", 160)],
        [key(KeyCode.leftShift, "Shift", 160)] + letters("ZXCVBNM")
            + [key(KeyCode.comma, "<,", 100), key(KeyCode.period, ">.", 100), key(KeyCode.slash, "?/", 100),
               key(KeyCode.up, "\u{2191}", 103), key(KeyDef.hideCode, "Hide", 103)],
        [key(KeyCode.leftControl, "Ctrl", 105), key(KeyCode.leftWindows, "Win", 105), key(KeyCode.leftAlt, "Alt", 105),
         key(KeyCode.space, "___", 310, marginStart: true, marginEnd: true),
         key(KeyCode.home, "Home", 98, small: true), key(KeyCode.end, "End", 98, small: true),
         key(KeyCode.pageUp, "PgUp", 98, small: true), key(KeyCode.pageDown, "PgDn", 98, small: true),
         key(KeyCode.left, "\u{2190}", 100), key(KeyCode.down, "\u{2193}", 100), key(KeyCode.right, "\u{2192}", 100)],
    ]
}
