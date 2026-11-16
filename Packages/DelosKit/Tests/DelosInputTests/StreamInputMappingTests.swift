import CoreGraphics
import DelosCore
import Testing
@testable import DelosInput

@Suite struct GamepadMappingTests {
    @Test func eachButtonSetsItsFlag() {
        let cases: [(WritableKeyPath<GamepadSnapshot, Bool>, ControllerButtons)] = [
            (\.a, .a), (\.b, .b), (\.x, .x), (\.y, .y), (\.up, .up), (\.down, .down), (\.left, .left), (\.right, .right),
            (\.leftShoulder, .leftShoulder), (\.rightShoulder, .rightShoulder),
            (\.leftStickButton, .leftStick), (\.rightStickButton, .rightStick),
            (\.menu, .play), (\.options, .back), (\.home, .special),
            (\.paddle1, .paddle1), (\.paddle2, .paddle2), (\.paddle3, .paddle3), (\.paddle4, .paddle4),
            (\.touchpadButton, .touchpad), (\.share, .misc),
        ]
        for (button, flag) in cases {
            var pad = GamepadSnapshot()
            pad[keyPath: button] = true
            #expect(GamepadMapping.buttons(pad) == flag, "\(flag)")
        }
        // The flags are the protocol's values (Limelight.h)
        #expect(ControllerButtons.a.rawValue == 0x1000)
        #expect(ControllerButtons.play.rawValue == 0x0010)
        #expect(ControllerButtons.back.rawValue == 0x0020)
        #expect(ControllerButtons.special.rawValue == 0x0400)
    }

    @Test func sticksScaleToSigned16BitWithUpPositive() {
        #expect(GamepadMapping.stick(1) == 32767)
        #expect(GamepadMapping.stick(-1) == -32767)
        #expect(GamepadMapping.stick(0) == 0)
        #expect(GamepadMapping.stick(0.5) == 16384)
        // Out of range and invalid values never overflow
        #expect(GamepadMapping.stick(1.7) == 32767)
        #expect(GamepadMapping.stick(-3) == -32767)
        #expect(GamepadMapping.stick(.nan) == 0)
        var pad = GamepadSnapshot()
        pad.leftStickY = 1
        pad.rightStickX = -1
        let state = GamepadMapping.state(pad)
        #expect(state.leftStickY == 32767 && state.rightStickX == -32767 && state.leftStickX == 0)
    }

    @Test func triggersScaleTo0Through255() {
        #expect(GamepadMapping.trigger(0) == 0)
        #expect(GamepadMapping.trigger(1) == 255)
        #expect(GamepadMapping.trigger(0.5) == 128)
        #expect(GamepadMapping.trigger(-0.2) == 0)
        #expect(GamepadMapping.trigger(2) == 255)
    }

    @Test func controllersGetTheLowestFreeNumber() {
        var slots = ControllerSlots<String>()
        #expect(slots.number(for: "a") == 0)
        #expect(slots.number(for: "b") == 1)
        #expect(slots.number(for: "a") == 0)
        #expect(slots.mask == 0b11)
        #expect(slots.remove("a") == 0)
        #expect(slots.mask == 0b10)
        #expect(slots.number(for: "c") == 0)
        for i in 0..<14 { _ = slots.number(for: "x\(i)") }
        #expect(slots.mask == 0xFFFF)
        #expect(slots.number(for: "seventeenth") == nil)
    }
}

@Suite struct MenuShortcutTests {
    /// The buttons forwarded and whether the menu opened, for each controller state in turn.
    private func run(_ states: [ControllerButtons]) -> (forward: [ControllerButtons], open: [Bool]) {
        var shortcut = MenuShortcut()
        let results = states.map { shortcut.update($0) }
        return (results.map(\.forward), results.map(\.open))
    }

    @Test func l3AndR3OpenTheMenuWhenBothAreLetGo() {
        let result = run([[.leftStick], [.leftStick, .rightStick], [.rightStick], [], []])
        // The button that completes the shortcut is kept from the host; the menu opens once, when both are let go
        #expect(result.forward == [[.leftStick], [.leftStick], [], [], []])
        #expect(result.open == [false, false, false, true, false])
    }

    @Test func otherButtonsPassAndOneButtonAloneDoesNotOpen() {
        let result = run([[.a, .rightStick], [.a], []])
        #expect(result.forward == [[.a, .rightStick], [.a], []])
        #expect(result.open == [false, false, false])
    }

    @Test func bothAtOnceAreBothKeptFromTheHost() {
        let result = run([[.leftStick, .rightStick, .x], []])
        #expect(result.forward == [[.x], []])
        #expect(result.open == [false, true])
    }
}

@Suite struct KeyboardMappingTests {
    @Test func lettersDigitsAndFunctionKeys() {
        #expect(KeyboardMapping.virtualKey(hidUsage: 0x04) == 0x41)  // A
        #expect(KeyboardMapping.virtualKey(hidUsage: 0x1D) == 0x5A)  // Z
        #expect(KeyboardMapping.virtualKey(hidUsage: 0x1E) == 0x31)  // 1
        #expect(KeyboardMapping.virtualKey(hidUsage: 0x27) == 0x30)  // 0
        #expect(KeyboardMapping.virtualKey(hidUsage: 0x62) == 0x60)  // keypad 0
        #expect(KeyboardMapping.virtualKey(hidUsage: 0x61) == 0x69)  // keypad 9
        #expect(KeyboardMapping.virtualKey(hidUsage: 0x3A) == 0x70)  // F1
        #expect(KeyboardMapping.virtualKey(hidUsage: 0x45) == 0x7B)  // F12
        #expect(KeyboardMapping.virtualKey(hidUsage: 0x68) == 0x7C)  // F13
        #expect(KeyboardMapping.virtualKey(hidUsage: 0x73) == 0x87)  // F24
    }

    @Test func specialKeysFollowMoonlight() {
        let expected: [Int: UInt8] = [
            0x28: 0x0D, 0x29: 0x1B, 0x2A: 0x08, 0x2B: 0x09, 0x2C: 0x20, 0x4F: 0x27, 0x50: 0x25, 0x51: 0x28, 0x52: 0x26,
            0x4C: 0x2E, 0x58: 0x0D, 0xE0: 0xA2, 0xE1: 0xA0, 0xE2: 0xA4, 0xE3: 0x5B, 0xE7: 0x5C, 0x64: 0xE2,
        ]
        for (usage, vk) in expected { #expect(KeyboardMapping.virtualKey(hidUsage: usage) == vk, "\(usage)") }
        // Keys the host has no code for
        #expect(KeyboardMapping.virtualKey(hidUsage: 0x32) == nil)
        #expect(KeyboardMapping.virtualKey(hidUsage: 0) == nil)
        #expect(KeyboardMapping.mappedUsages.contains(0x04) && !KeyboardMapping.mappedUsages.contains(0x32))
    }

    @Test func codesCarryThePrefixAndModifiersFollowTheHeldKeys() {
        #expect(KeyboardMapping.keyCode(0x41) == Int16(bitPattern: 0x8041))
        #expect(KeyboardMapping.modifiers(held: []) == [])
        #expect(KeyboardMapping.modifiers(held: [0xE5, 0x04]) == .shift)
        #expect(KeyboardMapping.modifiers(held: [0xE0, 0xE6, 0xE3]) == [.control, .alt, .meta])
    }
}

@Suite struct TouchMouseTests {
    @Test func aShortTapClicksLeftAndTwoFingersClickRight() {
        var pad = TouchTrackpad()
        pad.began(1, at: CGPoint(x: 100, y: 100), time: 0)
        let small = pad.moved(1, to: CGPoint(x: 110, y: 104))
        let tap = pad.ended(1, time: 0.1)
        #expect(small == [])
        #expect(tap == [.click(.left)])

        pad.began(1, at: CGPoint(x: 100, y: 100), time: 1)
        pad.began(2, at: CGPoint(x: 300, y: 100), time: 1.02)
        let first = pad.ended(1, time: 1.1)
        let second = pad.ended(2, time: 1.12)
        #expect(first == [])
        #expect(second == [.click(.right)])
    }

    @Test func aLongTouchIsNoTap() {
        var pad = TouchTrackpad()
        pad.began(1, at: .zero, time: 0)
        let actions = pad.ended(1, time: 0.5)
        #expect(actions == [])
    }

    @Test func oneFingerMovesThePointerOnceItLeftTheTapRadius() {
        var pad = TouchTrackpad()
        pad.began(1, at: CGPoint(x: 0, y: 0), time: 0)
        let points = [CGPoint(x: 20, y: 0), CGPoint(x: 40, y: -5), CGPoint(x: 40.5, y: -5), CGPoint(x: 41, y: -5)]
        let moves = points.map { pad.moved(1, to: $0) }
        // Inside the tap radius nothing moves; then the motion, with fractions carried to the next report
        #expect(moves == [[], [.move(dx: 20, dy: -5)], [], [.move(dx: 1, dy: 0)]])
        let end = pad.ended(1, time: 0.1)
        #expect(end == [])
    }

    @Test func twoFingersScrollWithTheContent() {
        var pad = TouchTrackpad()
        pad.began(1, at: CGPoint(x: 0, y: 0), time: 0)
        pad.began(2, at: CGPoint(x: 100, y: 0), time: 0)
        _ = pad.moved(1, to: CGPoint(x: 0, y: 40))
        // Fingers down by 10 pixels each: the content follows, the wheel turns up (positive) by 3 per pixel
        let one = pad.moved(1, to: CGPoint(x: 0, y: 50))
        let two = pad.moved(2, to: CGPoint(x: 100, y: 10))
        let ends = pad.ended(1, time: 0.1) + pad.ended(2, time: 0.1)
        #expect(one == [.scroll(15)])
        #expect(two == [.scroll(15)])
        #expect(ends == [])
    }

    @Test func theLeftEdgeSwipeOwnsItsTouchAndOpensOnce() {
        var swipe = MenuSwipe()
        // Outside the left 4 %: not the swipe's
        let outside = swipe.began(1, x: 100, width: 2000)
        let inside = swipe.began(2, x: 30, width: 2000)
        #expect(!outside && inside)
        let moves = [100.0, 280, 400].map { swipe.moved(2, x: $0, width: 2000) }
        #expect(moves.map(\.owned) == [true, true, true])
        #expect(moves.map(\.open) == [false, true, false])
        let ended = (swipe.ended(2), swipe.ended(1))
        #expect(ended == (true, false))
    }
}
