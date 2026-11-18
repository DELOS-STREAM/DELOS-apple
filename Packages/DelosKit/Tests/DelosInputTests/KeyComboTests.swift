import Testing
@testable import DelosInput

struct KeyComboTests {
    private func code(_ vk: UInt8) -> Int16 { KeyboardMapping.keyCode(vk) }

    @Test func theKeysGoDownInOrderWithTheModifiersHeldAndUpInReverse() {
        let events = KeyCombo([VirtualKey.leftControl, VirtualKey.leftShift, VirtualKey.escape]).events
        #expect(events.map(\.code) == [VirtualKey.leftControl, VirtualKey.leftShift, VirtualKey.escape, VirtualKey.escape, VirtualKey.leftShift, VirtualKey.leftControl].map(code))
        #expect(events.map(\.pressed) == [true, true, true, false, false, false])
        // Control is held for Shift, both for Escape; Escape goes up with both still held, then Shift with Control
        #expect(events.map(\.modifiers) == [[.control], [.control, .shift], [.control, .shift], [.control, .shift], [.control, .shift], [.control]])
    }

    @Test func aSingleKeyIsPressedAndReleased() {
        let events = KeyCombo([VirtualKey.escape]).events
        #expect(events.count == 2 && events[0].pressed && !events[1].pressed)
        #expect(events.allSatisfy { $0.modifiers.isEmpty })
    }

    @Test func theBuiltInCombinationsAreAndroidsFourteen() {
        #expect(SpecialKeys.all.count == 14)
        #expect(SpecialKeys.all.first?.label == "game_menu_send_keys_esc")
        #expect(SpecialKeys.all.last?.combo.keys == [VirtualKey.leftWindows, VirtualKey.leftAlt, VirtualKey.b])
        #expect(Set(SpecialKeys.all.map(\.label)).count == 14)
        #expect(SpecialKeys.taskManager.keys == [0xA2, 0xA0, 0x1B])
    }

    @Test func typedCharactersArePressedAsUSKeys() {
        #expect(TypedKeys.combo(for: "a")?.keys == [0x41])
        #expect(TypedKeys.combo(for: "A")?.keys == [VirtualKey.leftShift, 0x41])
        #expect(TypedKeys.combo(for: "7")?.keys == [0x37])
        #expect(TypedKeys.combo(for: "&")?.keys == [VirtualKey.leftShift, 0x37])
        #expect(TypedKeys.combo(for: " ")?.keys == [0x20])
        #expect(TypedKeys.combo(for: "?")?.keys == [VirtualKey.leftShift, 0xBF])
        #expect(TypedKeys.combo(for: "é") == nil)
        #expect(TypedKeys.combo(for: "😀") == nil)
    }
}
