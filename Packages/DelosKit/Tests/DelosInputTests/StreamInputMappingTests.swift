import CoreGraphics
import DelosCore
import Foundation
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

/// The stream menu's own buttons (`ButtonShortcutTest` of DELOS for Android), fed the buttons held at each moment.
@Suite struct MenuShortcutTests {
    /// The buttons kept from the host and whether the menu opened, for each moment in turn.
    private func run(_ buttons: Set<ShortcutButton>, _ states: [Set<ShortcutButton>]) -> (kept: [Set<ShortcutButton>], open: Int) {
        var shortcut = MenuShortcut(buttons: buttons)
        let results = states.map { shortcut.update($0) }
        return (results.map(\.swallowed), results.filter(\.open).count)
    }

    @Test func l3AndR3OpenTheMenuWhenReleasedInEitherOrder() {
        #expect(run([.l3, .r3], [[.l3], [.l3, .r3], [.r3], []]).open == 1)
        #expect(run([.l3, .r3], [[.r3], [.l3, .r3], [.r3], []]).open == 1)
        #expect(run([.l3, .r3], [[.l3], [.l3, .r3], [.l3], []]).open == 1)
    }

    @Test func opensOnTheLastReleaseNotBefore() {
        var shortcut = MenuShortcut(buttons: [.l3, .r3])
        let opened = [[.l3], [.l3, .r3], [.l3], []].map { shortcut.update($0).open }
        #expect(opened == [false, false, false, true])
    }

    @Test func oneButtonAloneNeverOpensAndAlwaysReachesTheGame() {
        let result = run([.l3, .r3], [[.l3], [], [.r3], [], [.l3], [], [.r3], []])
        #expect(result.open == 0)
        #expect(result.kept.allSatisfy { $0.isEmpty })
    }

    @Test func aButtonHeldAndReportedAgainDoesNotCountTwice() {
        #expect(run([.l3, .r3], [[.l3], [.l3], [.l3], []]).open == 0)
    }

    @Test func otherButtonsPressedAlongDoNotOpenOrDisturbIt() {
        let result = run([.l3, .r3], [[.a], [.a, .l3], [.a, .l3, .x], [.l3, .x], [.l3, .r3, .x], [.l3, .x], [.x], []])
        #expect(result.open == 1)
        #expect(result.kept.allSatisfy { !$0.contains(.a) && !$0.contains(.x) })
    }

    @Test func onlyTheCompletingButtonIsKeptFromTheGameSoEveryPressedButtonGetsItsRelease() {
        // The game saw L3 go down, so it must see it go up; R3 (and its release) never reaches it
        #expect(run([.l3, .r3], [[.l3], [.l3, .r3], [.l3], []]).kept == [[], [.r3], [], []])
        // The other release order: L3's release completes it and still reaches the game
        #expect(run([.l3, .r3], [[.l3], [.l3, .r3], [.r3], []]).kept == [[], [.r3], [.r3], []])
        // Both at once: both are kept
        #expect(run([.l3, .r3], [[.l3, .r3, .x], []]).kept == [[.l3, .r3], []])
    }

    @Test func theSameStateSeenTwiceChangesNothing() {
        #expect(run([.l3, .r3], [[.l3], [.l3], [.l3, .r3], [.l3, .r3], [.r3], [.r3], [], []]).open == 1)
    }

    @Test func otherCombinationsWork() {
        let combos: [Set<ShortcutButton>] = [[.start, .select], [.l1, .r1], [.home], [.l1, .r1, .start], [.l2, .paddle1]]
        for combo in combos {
            #expect(run(combo, [combo, []]).open == 1, "\(combo)")
        }
    }

    /// A tap of Home opens the menu, so no buttons are set by default (L3 + R3 was the default before).
    @Test func noButtonsAreSetByDefault() {
        var shortcut = MenuShortcut()
        #expect(shortcut.buttons.isEmpty)
        let results = [[.l3], [.l3, .r3], [.r3], []].map { shortcut.update($0) }
        #expect(results.allSatisfy { $0.swallowed.isEmpty && !$0.open })
    }

    @Test func theButtonsAreReadFromTheControllerAndTakenOutOfTheStateThePCGets() {
        var pad = GamepadSnapshot()
        pad.leftStickButton = true
        pad.rightTriggerPressed = true
        pad.rightTrigger = 0.9
        pad.home = true
        pad.share = true
        pad.up = true
        // The D-pad is never part of a shortcut
        #expect(ShortcutButton.pressed(pad) == [.l3, .r2, .home, .share])
        var state = GamepadMapping.state(pad)
        ShortcutButton.remove([.l3, .r2, .share], from: &state)
        #expect(state.buttons == [.special, .up])
        #expect(state.rightTrigger == 0)
    }

    @Test func storedNamesRoundTripInLabelOrderAndUnknownNamesAreDropped() {
        #expect(ShortcutButton.stored([.r3, .l3, .start]) == ["l3", "r3", "start"])
        #expect(ShortcutButton.parse(["r3", "l3", "touchpad", "dpadUp"]) == [.l3, .r3])
    }
}

/// Recording the stream menu's buttons (`ButtonCaptureLayer` of DELOS for Android).
@Suite struct MenuButtonRecorderTests {
    /// What the recorder returns for each moment in turn.
    private func record(_ states: [Set<ShortcutButton>]) -> (results: [Set<ShortcutButton>?], combination: [ShortcutButton]) {
        var recorder = MenuButtonRecorder()
        let results = states.map { recorder.update($0) }
        return (results, recorder.combination)
    }

    @Test func theButtonsHeldTogetherAreSavedOnceAllAreLetGo() {
        let run = record([[.l1], [.l1, .r1], [.r1], [], [.a], []])
        // Saved when the last is let go; once saved, nothing more
        #expect(run.results == [nil, nil, nil, [.l1, .r1], nil, nil])
        #expect(run.combination == [.l1, .r1])
    }

    @Test func oneButtonWorksAndNothingIsSavedBeforeAPress() {
        #expect(record([[], [.paddle1], []]).results == [nil, nil, [.paddle1]])
    }

    @Test func aButtonLetGoAndPressedAgainWhileAnotherIsHeldCountsOnce() {
        let run = record([[.start], [.start, .select], [.select], [.start, .select], []])
        #expect(run.combination == [.start, .select])
        #expect(run.results.last == [.start, .select])
    }

    @Test func itGivesUpAfterTenSeconds() {
        #expect(MenuButtonRecorder.idle == .seconds(10))
    }
}

/// The capture of every controller's buttons: a combination from two controllers, an idle timeout and a cancel.
@MainActor
@Suite struct MenuButtonCaptureTests {
    @Test func buttonsOfTwoControllersFormOneCombination() {
        var saved: Set<ShortcutButton>??
        let capture = MenuButtonCapture { saved = .some($0) }
        let pads = (NSObject(), NSObject())
        let one = ObjectIdentifier(pads.0), two = ObjectIdentifier(pads.1)
        capture.update([.l3], from: one)
        capture.update([.r3], from: two)
        #expect(capture.combination == [.l3, .r3])
        capture.update([], from: one)
        #expect(saved == nil)
        capture.update([], from: two)
        #expect(saved == .some([.l3, .r3]))
    }

    @Test func withoutAPressItEndsUnchanged() async throws {
        var saved: Set<ShortcutButton>?? = nil
        let capture = MenuButtonCapture(idle: .milliseconds(30)) { saved = .some($0) }
        capture.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(saved == .some(nil))
    }

    @Test func aCancelEndsItUnchangedOnce() {
        var calls = 0
        let capture = MenuButtonCapture { result in
            calls += 1
            #expect(result == nil)
        }
        capture.cancel()
        capture.cancel()
        capture.update([.a], from: ObjectIdentifier(NSObject()))
        capture.update([], from: ObjectIdentifier(NSObject()))
        #expect(calls == 1)
    }
}

/// A tap of Home opens the stream menu, a hold of half a second is Guide (`GuideTapHoldTest` of DELOS for Android), driven
/// by a fake clock.
@Suite struct GuideTapHoldTests {
    /// The gesture with a fake clock: milliseconds since the test started.
    private final class Clock {
        var now: Int64 = 1_000
        var g = GuideTapHold()
        func advance(_ ms: Int64) { now += ms }
        func down() -> Bool { g.onDown(now) }
        func timeout() -> GuideTapHold.Action { g.onHoldTimeout(now) }
        func up() -> GuideTapHold.Action { g.onUp() }
        func reset() -> Bool { g.reset() }
    }

    private let c = Clock()
    private let hold = GuideTapHold.holdMilliseconds

    @Test func aTapOpensTheMenuOnReleaseAndSendsNoGuide() {
        #expect(c.down(), "the first down starts the hold timer")
        c.advance(120)
        #expect(c.up() == .tapMenu)
        #expect(!c.g.isGuideDown)
    }

    @Test func aHoldPressesGuideWhileHeldAndReleasesItOnUp() {
        _ = c.down()
        c.advance(hold)
        #expect(c.timeout() == .guideDown, "decided while held, not on release")
        #expect(c.g.isGuideDown)
        c.advance(2_000)
        #expect(c.up() == .guideUp, "no menu follows a hold")
        #expect(!c.g.isGuideDown)
    }

    @Test func aReleaseJustBeforeTheHoldTimeIsATap() {
        _ = c.down()
        c.advance(hold - 1)
        #expect(c.timeout() == GuideTapHold.Action.none)
        #expect(c.up() == .tapMenu)
    }

    @Test func repeatsOfAHeldButtonDoNotRestartTheHold() {
        #expect(c.down())
        c.advance(300)
        #expect(!c.down())
        c.advance(200)
        #expect(!c.down())
        #expect(c.timeout() == .guideDown)
        #expect(c.up() == .guideUp)
    }

    @Test func aLateTimerAfterReleaseAndAStrayUpDoNothing() {
        _ = c.down()
        _ = c.up()
        c.advance(hold)
        #expect(c.timeout() == GuideTapHold.Action.none)
        #expect(c.up() == GuideTapHold.Action.none)
    }

    @Test func aStaleTimerOfAnEarlierPressDoesNotCutTheNextPressShort() {
        _ = c.down()
        c.advance(100)
        _ = c.up()
        c.advance(100)
        _ = c.down()
        c.advance(hold - 200)
        #expect(c.timeout() == GuideTapHold.Action.none, "the first press's timer fires 300 ms into the second")
        c.advance(200)
        #expect(c.timeout() == .guideDown)
    }

    @Test func theTimerFiresOncePerPress() {
        _ = c.down()
        c.advance(hold)
        #expect(c.timeout() == .guideDown)
        #expect(c.timeout() == GuideTapHold.Action.none)
    }

    @Test func resetForgetsAPressAndSaysWhetherGuideWasDown() {
        _ = c.down()
        c.advance(hold)
        _ = c.timeout()
        #expect(c.reset())
        #expect(c.up() == GuideTapHold.Action.none)
        #expect(c.down(), "a new press works after a reset")
        #expect(!c.reset())
    }

    @Test func theHoldTimeIsHalfASecond() {
        #expect(GuideTapHold.holdMilliseconds == 500)
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

    // `StreamMenuSwipeTest` of DELOS for Android

    @Test func zoneBoundsFor1080() {
        expectZone(StreamMenuSwipe.zone(height: 1080, gestureInset: 0, minDeadEdge: 24), top: 885.6, bottom: 1056)
        expectZone(StreamMenuSwipe.zone(height: 1080, gestureInset: 48, minDeadEdge: 24), top: 885.6, bottom: 1032)
        expectZone(StreamMenuSwipe.zone(height: 1080, gestureInset: 150, minDeadEdge: 24), top: 885.6, bottom: 930)
    }

    private func expectZone(_ zone: SwipeZone, top: CGFloat, bottom: CGFloat) {
        #expect(abs(zone.top - top) < 1e-6 && zone.bottom == bottom, "\(zone)")
    }

    @Test func minimumWinsOverSmallInset() {
        #expect(StreamMenuSwipe.zone(height: 1080, gestureInset: 10, minDeadEdge: 24).bottom == 1056)
    }

    @Test func tinyHeightsStayValid() {
        let z = StreamMenuSwipe.zone(height: 20, gestureInset: 0, minDeadEdge: 24)
        #expect(z.bottom == 0)
        #expect(z.top <= z.bottom)
        #expect(!StreamMenuSwipe.starts(z, y: 5))
        #expect(!StreamMenuSwipe.starts(StreamMenuSwipe.zone(height: 0, gestureInset: 0, minDeadEdge: 24), y: 0))
    }

    @Test func startIsInclusiveAtTopExclusiveAtBottom() {
        let z = StreamMenuSwipe.zone(height: 1080, gestureInset: 0, minDeadEdge: 24)
        #expect(StreamMenuSwipe.starts(z, y: z.top))
        #expect(!StreamMenuSwipe.starts(z, y: z.top - 1))
        #expect(StreamMenuSwipe.starts(z, y: z.bottom - 1))
        #expect(!StreamMenuSwipe.starts(z, y: z.bottom))
    }

    @Test func theEdgeStripDoesNotStartAndTheBandAboveItDoes() {
        let z = StreamMenuSwipe.zone(height: 1080, gestureInset: 0, minDeadEdge: 24)
        #expect(StreamMenuSwipe.starts(z, y: 1080 * 0.94))
        #expect(!StreamMenuSwipe.starts(z, y: 1056))
        #expect(!StreamMenuSwipe.starts(z, y: 1079))
    }

    @Test func opensAtDistanceThreshold() {
        let start = CGPoint(x: 500, y: 1000)
        #expect(StreamMenuSwipe.opens(start: start, now: CGPoint(x: 500, y: 1000 - 130), height: 1080))
        #expect(!StreamMenuSwipe.opens(start: start, now: CGPoint(x: 500, y: 1000 - 129), height: 1080))
        #expect(!StreamMenuSwipe.opens(start: start, now: CGPoint(x: 500, y: 1010), height: 1080))
    }

    @Test func mostlyHorizontalDragIsRejected() {
        #expect(!StreamMenuSwipe.opens(start: CGPoint(x: 100, y: 1000), now: CGPoint(x: 400, y: 800), height: 1080))
        #expect(!StreamMenuSwipe.opens(start: CGPoint(x: 400, y: 1000), now: CGPoint(x: 100, y: 800), height: 1080))
        #expect(!StreamMenuSwipe.opens(start: CGPoint(x: 100, y: 1000), now: CGPoint(x: 300, y: 800), height: 1080))
        #expect(StreamMenuSwipe.opens(start: CGPoint(x: 100, y: 1000), now: CGPoint(x: 150, y: 800), height: 1080))
    }

    @Test func aTouchInTheBandIsTheSwipesForItsWholeLifeAndOpensOnce() {
        var swipe = MenuSwipe()
        let zone = StreamMenuSwipe.zone(height: 1080, gestureInset: 0, minDeadEdge: 24)
        // Above the band, and in the system's strip: not the swipe's
        let above = swipe.began(1, at: CGPoint(x: 500, y: 500), zone: zone)
        let strip = swipe.began(3, at: CGPoint(x: 500, y: 1070), zone: zone)
        let band = swipe.began(2, at: CGPoint(x: 500, y: 1000), zone: zone)
        #expect(!above && !strip && band)
        let moves = [950.0, 870, 700].map { swipe.moved(2, to: CGPoint(x: 500, y: $0), height: 1080) }
        #expect(moves.map(\.owned) == [true, true, true])
        #expect(moves.map(\.open) == [false, true, false])
        let stray = swipe.moved(1, to: CGPoint(x: 500, y: 100), height: 1080)
        #expect(!stray.owned && !stray.open)
        let ended = (swipe.ended(2), swipe.ended(1))
        #expect(ended == (true, false))
    }
}
