import DelosCore

/// How a hardware keyboard opens the stream menu (the Mac, where a keyboard and a mouse are the usual input, and any
/// other device with a keyboard). Two ways, both without a controller:
///
/// - the chord Control + Option + Shift + M, which opens the menu the moment M goes down and keeps that M from the PC;
/// - holding Escape for ``holdDuration``, which also lets go of the Escape at the PC.
///
/// A quick press of Escape still reaches the PC, since games use it.
public enum MenuKeyShortcut {
    /// HID usage of M, the key that completes the chord.
    public static let chordKey = 0x10
    /// HID usage of Escape.
    public static let escape = 0x29
    /// How long Escape is held to open the menu.
    public static let holdDuration = Duration.seconds(1)

    /// Whether the key that just went down completes the chord: `usage` is M and Control, Option and Shift (the left or
    /// the right one of each) are all in `held`.
    public static func completesChord(usage: Int, held: Set<Int>) -> Bool {
        guard usage == chordKey else { return false }
        let control = held.contains(0xE0) || held.contains(0xE4)
        let option = held.contains(0xE2) || held.contains(0xE6)
        let shift = held.contains(0xE1) || held.contains(0xE5)
        return control && option && shift
    }
}

/// The keyboard's own combinations (`handleSpecialKeys` of DELOS for Android): Control + Alt + Shift with Z toggles the
/// input grab, with Q ends the stream, with C shows or hides the local pointer. On Apple's keyboards Command may stand
/// for Control (Command + Option + Shift), since Control + Option is VoiceOver's modifier while it runs; macOS itself
/// takes Command + Option + Shift + Q (log out), so Q works there with Control only.
///
/// The letter never reaches the PC; while the modifiers are still down every other key press is kept from the PC too
/// (releases pass), and the action runs once the last modifier is up.
public struct ClientKeyCombos: Sendable {
    public enum Action: Equatable, Sendable {
        case toggleInputGrab, quit, toggleLocalCursor
    }

    /// HID usages of Z, Q and C.
    public static let toggleInputGrabKey = 0x1D, quitKey = 0x14, toggleLocalCursorKey = 0x06

    private var modifiers: KeyModifiers = []
    private var special: Int?

    public init() {}

    /// A key went down or up (HID usage). Returns whether the PC must not get the event and the action that is due.
    public mutating func key(_ usage: Int, pressed: Bool, rightAltAsMeta: Bool) -> (consumed: Bool, action: Action?) {
        var mask: KeyModifiers = []
        switch usage {
        case 0xE0, 0xE4: mask = .control
        case 0xE1, 0xE5: mask = .shift
        case KeyboardMapping.rightAlt where rightAltAsMeta:
            // The right Option key as the Windows key goes to the PC at once, outside the combinations
            if pressed { modifiers.insert(.meta) } else { modifiers.remove(.meta) }
            return (false, nil)
        case 0xE2, 0xE6: mask = .alt
        case 0xE3, 0xE7: mask = .meta
        default: break
        }
        if pressed { modifiers.formUnion(mask) } else { modifiers.subtract(mask) }

        if let special {
            // The letter's own release (and repeats): the PC never saw it go down
            if special == usage { return (true, nil) }
            // Still waiting for the modifiers to come up: presses are kept, releases pass
            if !modifiers.isEmpty { return (pressed, nil) }
            self.special = nil
            return (false, Self.action(special))
        }
        let chord = modifiers.contains([.alt, .shift]) && !modifiers.isDisjoint(with: [.control, .meta])
        if chord, pressed, mask.isEmpty, Self.action(usage) != nil {
            special = usage
            return (true, nil)
        }
        return (false, nil)
    }

    /// Forgets the modifiers held and a combination in progress (the keys were released at the PC).
    public mutating func reset() {
        modifiers = []
        special = nil
    }

    private static func action(_ usage: Int) -> Action? {
        switch usage {
        case toggleInputGrabKey: .toggleInputGrab
        case quitKey: .quit
        case toggleLocalCursorKey: .toggleLocalCursor
        default: nil
        }
    }
}
