import DelosInput
import Testing
@testable import DelosUI

/// `FullKeyboardKeysTest.kt` of DELOS for Android: the keys of the Delos full keyboard, how they are drawn and what they show.
@Suite struct FullKeyboardKeysTests {
    private let rows = FullKeyboardKeys.rows

    private func key(_ legend: String) -> KeyDef { rows.joined().first { $0.legend == legend }! }

    @Test func theKeyboardHasTheSameEightyKeysInSixRowsAsTheOldLayout() {
        #expect(rows.map(\.count) == [15, 14, 14, 13, 13, 11])
        #expect(rows.reduce(0) { $0 + $1.count } == 80)
        #expect(rows[0].map(\.legend) == ["ESC", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "Ins", "Del"])
        #expect(rows[1].map(\.legend) == ["~`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "_-", "+=", "Back"])
        #expect(rows[2].map(\.legend) == ["Tab", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "{[", "}]", "|\\"])
        #expect(rows[3].map(\.legend) == ["Caps", "A", "S", "D", "F", "G", "H", "J", "K", "L", ":;", "\"'", "Enter"])
        #expect(rows[4].map(\.legend) == ["Shift", "Z", "X", "C", "V", "B", "N", "M", "<,", ">.", "?/", "\u{2191}", "Hide"])
        #expect(rows[5].map(\.legend) == ["Ctrl", "Win", "Alt", "___", "Home", "End", "PgUp", "PgDn", "\u{2190}", "\u{2193}", "\u{2192}"])
    }

    /// Android names the Android key codes, which its key translation turns into these Windows virtual keys.
    @Test func everyKeyHasItsOwnVirtualKeyAndOnlyHideHasNone() {
        let codes = rows.joined().map(\.code)
        #expect(Set(codes).count == codes.count)
        #expect(codes.filter { $0 < 0 } == [KeyDef.hideCode])
        #expect(codes.allSatisfy { $0 == KeyDef.hideCode || UInt8(exactly: $0) != nil })
        #expect(key("Q").code == 0x51)
        #expect(key("F12").code == Int(VirtualKey.f12))
        #expect(key("Del").code == 0x2E)
        #expect(key("Back").code == Int(VirtualKey.backspace))
        #expect(key("Shift").code == Int(VirtualKey.leftShift))
        #expect(key("Win").code == Int(VirtualKey.leftWindows))
        #expect(key("\u{2191}").code == 0x26)
    }

    @Test func weightsAndMarginsAreTheOnesOfTheOldLayout() {
        #expect(key("ESC").weight == 150)
        #expect(key("ESC").marginEnd && !key("ESC").marginStart)
        #expect(key("Ins").marginStart && !key("Ins").marginEnd)
        #expect(key("___").weight == 310)
        #expect(key("___").marginStart && key("___").marginEnd)
        #expect(key("Hide").weight == 103)
        #expect(rows.joined().filter(\.small).map(\.legend) == ["Home", "End", "PgUp", "PgDn"])
    }

    @Test func keyKindsFollowTheOldModifierAndSpecialKeySets() {
        #expect(key("Ctrl").kind == .modifier)
        #expect(key("Shift").kind == .modifier)
        #expect(key("Tab").kind == .special)
        #expect(key("Enter").kind == .special)
        #expect(key("___").kind == .special)
        #expect(key("\u{2190}").kind == .special)
        #expect(key("F1").kind == .char)
        #expect(key("Q").kind == .char)
        #expect(key("Hide").kind == .hide)
        #expect(KeyCode.isModifier(Int(VirtualKey.rightAlt)))
    }

    @Test func glyphsAreStackedForPunctuationAndDrawnForArrowsAndSpace() {
        #expect(key("_-").glyph == .stacked)
        #expect(key("|\\").glyph == .stacked)
        #expect(key("F1").glyph == .text)
        #expect(key("1").glyph == .text)
        #expect(key("\u{2193}").glyph == .arrow)
        #expect(key("___").glyph == .space)
        #expect(key("Hide").glyph == .hide)
        #expect(KeyCode.arrow(KeyCode.left) == .left)
        #expect(KeyCode.arrow(key("Q").code) == nil)
    }

    @Test func popupsShowTheCharacterAKeyTypesAndNothingForTheRest() {
        #expect(FullKeyboardKeys.popupText(key("E")) == "e")
        #expect(FullKeyboardKeys.popupText(key("5")) == "5")
        #expect(FullKeyboardKeys.popupText(key("F1")) == "F1")
        #expect(FullKeyboardKeys.popupText(key("_-")) == "-")
        #expect(FullKeyboardKeys.popupText(key("|\\")) == "\\")
        #expect(FullKeyboardKeys.popupText(key("\"'")) == "'")
        #expect(FullKeyboardKeys.popupText(key("?/")) == "/")
        for legend in ["Shift", "Tab", "___", "Hide"] { #expect(FullKeyboardKeys.popupText(key(legend)) == nil) }
    }

    private func primary(_ legend: String, shift: Bool = false, caps: Bool = false) -> String {
        FullKeyboardKeys.label(key(legend), shift: shift, caps: caps).primary
    }

    @Test func lettersAreLowerCaseUntilShiftOrCapsLockMakesThemUpperAndBothMakeThemLowerAgain() {
        #expect(primary("Q") == "q")
        #expect(primary("Q", shift: true) == "Q")
        #expect(primary("Q", caps: true) == "Q")
        #expect(primary("Q", shift: true, caps: true) == "q")
        #expect(FullKeyboardKeys.label(key("Q"), shift: true, caps: false).secondary == nil)
    }

    @Test func theNumberRowShowsItsSymbolsWhileShiftIsDownAndCapsLockDoesNotChangeThem() {
        let plain = Array("1234567890").map(String.init), shifted = Array("!@#$%^&*()").map(String.init)
        for (digit, symbol) in zip(plain, shifted) {
            #expect(primary(digit) == digit)
            #expect(primary(digit, shift: true) == symbol)
            #expect(primary(digit, caps: true) == digit)
        }
    }

    @Test func punctuationKeysSwapTheirTwoCharactersWithShift() {
        for pair in ["_-", "+=", "{[", "}]", ":;", "\"'", "<,", ">.", "?/", "~`", "|\\"] {
            let first = String(pair.prefix(1)), second = String(pair.dropFirst())
            #expect(FullKeyboardKeys.label(key(pair), shift: false, caps: false) == KeyLabel(primary: second, secondary: first))
            #expect(FullKeyboardKeys.label(key(pair), shift: true, caps: false) == KeyLabel(primary: first, secondary: second))
            // Caps Lock changes letters only
            #expect(FullKeyboardKeys.label(key(pair), shift: false, caps: true) == FullKeyboardKeys.label(key(pair), shift: false, caps: false))
        }
    }

    @Test func otherKeysKeepTheirLegendWhateverShiftDoes() {
        for legend in ["Tab", "Enter", "Caps", "Shift", "F1", "Home", "Hide", "\u{2191}", "___"] {
            #expect(FullKeyboardKeys.label(key(legend), shift: true, caps: true) == KeyLabel(primary: legend))
            #expect(FullKeyboardKeys.label(key(legend), shift: false, caps: false) == KeyLabel(primary: legend))
        }
    }

    @Test func popupsShowTheShiftedCharacterToo() {
        #expect(FullKeyboardKeys.popupText(key("E"), shift: true) == "E")
        #expect(FullKeyboardKeys.popupText(key("5"), shift: true) == "%")
        #expect(FullKeyboardKeys.popupText(key("_-"), shift: true) == "_")
        #expect(FullKeyboardKeys.popupText(key("E"), shift: true, caps: true) == "e")
    }

    @Test func bothShiftKeysAreShift() {
        #expect(KeyCode.isShift(Int(VirtualKey.leftShift)))
        #expect(KeyCode.isShift(Int(VirtualKey.rightShift)))
        #expect(!KeyCode.isShift(KeyCode.capsLock))
    }
}
