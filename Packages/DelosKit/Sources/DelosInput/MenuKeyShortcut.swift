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
