import DelosCore
import Testing
@testable import DelosInput

// MARK: - The stream menu's recorded keys

@Suite struct ShortcutKeyTests {
    @Test func keysAreStoredWithTheirUsageAfterTheButtonsAndArrowsAreRefused() {
        let buttons: Set<ShortcutButton> = [.key(0xE0), .l3, .key(0x10)]
        #expect(ShortcutButton.stored(buttons) == ["l3", "key:16", "key:224"])
        #expect(ShortcutButton.parse(["key:224", "key:16", "l3", "key:79", "key:x"]) == buttons)
        #expect(ShortcutButton.usableKey(0x52) == nil, "the up arrow is Android's D-pad")
        #expect(ShortcutButton.pressed(keys: [0x50, 0x29]) == [.key(0x29)])
    }

    @Test func keysAreNamedLikeAndroidsKeyCodes() {
        #expect(ShortcutButton.keyName(0x04) == "A")
        #expect(ShortcutButton.keyName(0x27) == "0")
        #expect(ShortcutButton.keyName(0x3E) == "F5")
        #expect(ShortcutButton.keyName(0xE0) == "Ctrl left")
        #expect(ShortcutButton.keyName(0x29) == "Escape")
        #expect(ShortcutButton.keyName(0x5A) == "Numpad 2")
    }

    @Test func theRecorderTakesKeysAndButtonsTogether() {
        var recorder = MenuButtonRecorder()
        #expect(recorder.update([.key(0xE0)]) == nil)
        #expect(recorder.update([.key(0xE0), .l1]) == nil)
        #expect(recorder.update([.l1]) == nil)
        #expect(recorder.update([]) == [.key(0xE0), .l1])
        #expect(recorder.combination == [.key(0xE0), .l1])
    }

    @MainActor
    @Test func theCaptureRecordsAKeyboardKey() {
        var saved: Set<ShortcutButton>?? = nil
        let capture = MenuButtonCapture { saved = .some($0) }
        capture.key(0xE4, pressed: true)
        capture.key(0x3A, pressed: true)
        capture.key(0xE4, pressed: false)
        #expect(saved == nil)
        capture.key(0x3A, pressed: false)
        #expect(saved == .some([.key(0xE4), .key(0x3A)]))
    }
}

