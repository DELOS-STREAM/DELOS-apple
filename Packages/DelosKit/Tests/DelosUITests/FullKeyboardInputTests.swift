import DelosData
import DelosInput
import Testing
@testable import DelosUI

/// `FullKeyboardInputTest.kt` of DELOS for Android: the controller's focus, the modifiers, the controller's buttons and the
/// size of the keyboard. GameController reports a controller's state, not key events, so Android's D-pad key events and
/// their input sources have no counterpart here: the D-pad is the hat (``DpadTracker``), the buttons are the edges of two
/// snapshots (``PadAction/buttons(from:to:)``), and only controllers reach the keyboard (``GameInput/padCapture``).
@Suite struct FullKeyboardInputTests {
    private let grid = KeyGrid.standard

    private func pos(_ legend: String) -> KeyPos {
        for (r, row) in grid.rows.enumerated() {
            if let c = row.firstIndex(where: { $0.legend == legend }) { return KeyPos(row: r, col: c) }
        }
        fatalError("no key \(legend)")
    }

    private func legend(_ pos: KeyPos) -> String { grid.key(pos).legend }

    private func step(_ from: String, _ direction: KeyDirection, anchor: Double? = nil) -> NavMove? {
        grid.move(pos(from), anchorX: anchor ?? grid.span(pos(from)).center, direction)
    }

    private func pad(_ change: (inout GamepadSnapshot) -> Void) -> GamepadSnapshot {
        var snapshot = GamepadSnapshot()
        change(&snapshot)
        return snapshot
    }

    // MARK: Focus movement

    @Test func leftAndRightStayInTheRowAndStopAtItsEnds() {
        #expect(step("Q", .right).map { legend($0.pos) } == "W")
        #expect(step("W", .left).map { legend($0.pos) } == "Q")
        #expect(step("Tab", .left) == nil)
        #expect(step("|\\", .right) == nil)
        #expect(step("Del", .right) == nil)
        #expect(step("ESC", .left) == nil)
    }

    @Test func upAndDownStopAtTheTopAndBottomRows() {
        #expect(step("F5", .up) == nil)
        #expect(step("___", .down) == nil)
        #expect(step("\u{2192}", .down) == nil)
    }

    @Test func upAndDownFollowTheColumnUnderTheCurrentKeyEvenThoughTheRowsAreNotAligned() {
        #expect(step("Q", .down).map { legend($0.pos) } == "A")
        #expect(step("Q", .up).map { legend($0.pos) } == "1")
        #expect(step("ESC", .down).map { legend($0.pos) } == "~`")
        // The wide space bar reaches up to V, the middle of the bottom row's letters
        #expect(step("___", .up).map { legend($0.pos) } == "V")
        #expect(step("Hide", .down).map { legend($0.pos) } == "\u{2192}")
    }

    @Test func theColumnIsRememberedAcrossVerticalMovesAndRestartsWithAHorizontalOne() throws {
        // Del is at the far right: down goes to Back, then the next row's last key; the column stays that of Del all the way
        let first = try #require(step("Del", .down))
        #expect(legend(first.pos) == "Back")
        let second = try #require(grid.move(first.pos, anchorX: first.anchorX, .down))
        #expect(legend(second.pos) == "|\\")
        #expect(second.anchorX == first.anchorX)
        // A step left makes the key it lands on the new column: up from there aims for that key's center
        let left = try #require(grid.move(second.pos, anchorX: second.anchorX, .left))
        #expect(legend(left.pos) == "}]")
        #expect(left.anchorX == grid.span(left.pos).center)
    }

    @Test func aVerticalMoveGoesToTheKeyUnderTheColumnOrElseTheNearestOne() throws {
        func distance(_ x: Double, _ span: KeySpan) -> Double {
            x >= span.start && x <= span.end ? 0 : min(abs(x - span.start), abs(x - span.end))
        }
        for r in grid.rows.indices {
            for c in grid.rows[r].indices {
                let from = KeyPos(row: r, col: c)
                let anchor = grid.span(from).center
                for (direction, target) in [(KeyDirection.up, r - 1), (.down, r + 1)] {
                    let move = grid.move(from, anchorX: anchor, direction)
                    guard grid.rows.indices.contains(target) else {
                        #expect(move == nil)
                        continue
                    }
                    let chosen = try #require(move)
                    #expect(chosen.pos.row == target)
                    let best = distance(anchor, grid.span(chosen.pos))
                    for other in grid.rows[target].indices {
                        #expect(best <= distance(anchor, grid.span(KeyPos(row: target, col: other))), "\(from) \(direction): \(legend(chosen.pos)) is not the nearest")
                    }
                }
            }
        }
    }

    @Test func landingOnAKeyMakesItsCenterTheColumn() throws {
        let q = try #require(grid.find(KeyGrid.firstKey))
        #expect(legend(q) == "Q")
        let landed = grid.land(q)
        #expect(landed.pos == q)
        #expect(landed.anchorX == grid.span(q).center)
    }

    @Test func spansShareTheWidthByWeightAndMarginsTakeFromTheirOwnKeyOnly() {
        let row = FullKeyboardKeys.rows[0]
        let spans = KeyGrid.layoutSpans(row, width: 1000, gap: 6, sep: 12)
        #expect(spans.count == row.count)
        #expect(spans.first?.start == 0)
        // Esc is 150 of 1550 weight units of what the 14 gaps leave, less its margin on the right
        let free = 1000.0 - 6 * 14
        #expect(abs(spans[0].end - (free * 150 / 1550 - 12)) < 0.001)
        // Ins starts 12 later than its cell: F12 and Ins are further apart than F11 and F12
        #expect(abs(spans[13].start - spans[12].end - 18) < 0.001)
        #expect(abs(spans[12].start - spans[11].end - 6) < 0.001)
        #expect(abs(spans[spans.count - 1].end - 1000) < 0.001)
    }

    // MARK: Modifiers

    @Test func touchingAModifierPressesItAndHoldingLatchesIt() {
        var latch = ModifierLatch()
        let ctrl = KeyCode.leftControl
        #expect(latch.touchDown(ctrl, sticky: true) == .down)
        // Released before the hold time: an ordinary tap
        #expect(latch.touchUp(ctrl, sticky: true) == .up)
        #expect(!latch.isLatched(ctrl))

        #expect(latch.touchDown(ctrl, sticky: true) == .down)
        latch.latchHeld(ctrl)
        #expect(latch.isLatched(ctrl))
        // The release of a latched modifier is not sent: it stays down at the PC
        #expect(latch.touchUp(ctrl, sticky: true) == .none)
        #expect(latch.codes == [ctrl])
    }

    @Test func touchingALatchedModifierReleasesItWithTheNextUp() {
        var latch = ModifierLatch()
        let shift = KeyCode.leftShift
        _ = latch.touchDown(shift, sticky: true)
        latch.latchHeld(shift)
        #expect(latch.touchDown(shift, sticky: true) == .none)
        #expect(!latch.isLatched(shift))
        #expect(latch.touchUp(shift, sticky: true) == .up)
    }

    @Test func withoutStickyModifiersEveryKeyIsAnOrdinaryKey() {
        var latch = ModifierLatch()
        #expect(latch.touchDown(KeyCode.leftAlt, sticky: false) == .down)
        #expect(latch.touchUp(KeyCode.leftAlt, sticky: false) == .up)
        // An ordinary key is never latched, even if asked
        let q = KeyCode.character("Q")
        #expect(latch.touchDown(q, sticky: true) == .down)
        #expect(latch.touchUp(q, sticky: true) == .up)
    }

    @Test func aControllerPressTogglesTheLatchWhateverTheSettingSays() {
        var latch = ModifierLatch()
        #expect(latch.padPress(KeyCode.leftShift) == .down)
        #expect(latch.isLatched(KeyCode.leftShift))
        #expect(latch.padPress(KeyCode.leftShift) == .up)
        #expect(!latch.isLatched(KeyCode.leftShift))
    }

    @Test func hidingReleasesEveryLatchedModifierAndClearsTheLatch() {
        var latch = ModifierLatch()
        let shift = KeyCode.leftShift, ctrl = KeyCode.leftControl, alt = KeyCode.leftAlt
        // One latched by touch (held), one by the controller, one only pressed and not latched
        _ = latch.touchDown(ctrl, sticky: true)
        latch.latchHeld(ctrl)
        _ = latch.padPress(shift)
        _ = latch.touchDown(alt, sticky: true)

        #expect(latch.releaseAll() == [ctrl, shift])
        #expect(latch.codes.isEmpty)
        #expect(!latch.isLatched(ctrl))
        // Nothing is left to release, and the next touch starts a fresh press
        #expect(latch.releaseAll().isEmpty)
        #expect(latch.touchDown(ctrl, sticky: true) == .down)
        #expect(latch.padPress(shift) == .down)
    }

    // MARK: Controller buttons

    @Test func theDpadIsNoButtonActionItGoesThroughTheHat() {
        #expect(PadAction.buttons(from: GamepadSnapshot(), to: pad { $0.left = true }).isEmpty)
        var dpad = DpadTracker()
        #expect(dpad.onHat(x: -1, y: 0, now: 0) == .left)
    }

    @Test func aHatPressMovesAtOnceThenRepeatsAfterTheInitialDelayUntilItReturnsToCenter() {
        var dpad = DpadTracker(initialDelay: 300, repeatInterval: 100)
        #expect(dpad.onHat(x: 1, y: 0, now: 1000) == .right)
        #expect(dpad.repeatAt == 1300)
        // Re-sent hat readings change nothing
        #expect(dpad.onHat(x: 1, y: 0, now: 1100) == nil)
        #expect(dpad.repeat(now: 1299) == nil)
        #expect(dpad.repeat(now: 1300) == .right)
        #expect(dpad.repeatAt == 1400)
        #expect(dpad.repeat(now: 1399) == nil)
        #expect(dpad.repeat(now: 1410) == .right)
        #expect(dpad.repeatAt == 1510)
        // Back to the center: no move, no more repeats
        #expect(dpad.onHat(x: 0, y: 0, now: 1500) == nil)
        #expect(dpad.repeatAt == nil)
        #expect(dpad.repeat(now: 2000) == nil)
    }

    @Test func everyHatDirectionMapsToItsOwnMove() {
        var dpad = DpadTracker()
        #expect(dpad.onHat(x: -1, y: 0, now: 0) == .left)
        _ = dpad.onHat(x: 0, y: 0, now: 10)
        #expect(dpad.onHat(x: 0, y: -1, now: 20) == .up)
        _ = dpad.onHat(x: 0, y: 0, now: 30)
        #expect(dpad.onHat(x: 0, y: 1, now: 40) == .down)
        // Straight from one direction to another counts as a new press
        #expect(dpad.onHat(x: -1, y: 0, now: 50) == .left)
    }

    @Test func aDiagonalIsTheSideThatWasPressedLastAndLettingGoOfItStopsTheRepeat() {
        var dpad = DpadTracker(initialDelay: 300, repeatInterval: 100)
        #expect(dpad.onHat(x: 1, y: 0, now: 0) == .right)
        // Thumb rolls up: Up is new and moves, and repeats from now on
        #expect(dpad.onHat(x: 1, y: -1, now: 50) == .up)
        #expect(dpad.repeatAt == 350)
        #expect(dpad.repeat(now: 350) == .up)
        // Letting go of Right (the older side) changes nothing
        #expect(dpad.onHat(x: 0, y: -1, now: 400) == nil)
        #expect(dpad.repeat(now: 450) == .up)
        // Back to Up-right: Right is new and moves
        #expect(dpad.onHat(x: 1, y: -1, now: 500) == .right)
        // Letting go of Right (the one repeating) leaves Up, which was not pressed anew: the repeat stops
        #expect(dpad.onHat(x: 0, y: -1, now: 520) == nil)
        #expect(dpad.repeatAt == nil)
        #expect(dpad.repeat(now: 2000) == nil)
        // The next press works as ever
        _ = dpad.onHat(x: 0, y: 0, now: 2100)
        #expect(dpad.onHat(x: 0, y: 1, now: 2200) == .down)
    }

    @Test func aDiagonalPressedInOneReadingMovesHorizontally() {
        var dpad = DpadTracker()
        #expect(dpad.onHat(x: -1, y: 1, now: 0) == .left)
        #expect(dpad.onHat(x: -1, y: 1, now: 5) == nil)
    }

    @Test func smallHatValuesAreTheCenter() {
        var dpad = DpadTracker()
        #expect(dpad.onHat(x: 0.3, y: -0.2, now: 0) == nil)
        #expect(dpad.repeatAt == nil)
    }

    @Test func resetForgetsAHeldHat() {
        var dpad = DpadTracker()
        _ = dpad.onHat(x: 1, y: 0, now: 0)
        dpad.reset()
        #expect(dpad.repeatAt == nil)
        #expect(dpad.onHat(x: 1, y: 0, now: 10) == .right)
    }

    @Test func aHoldsTheFocusedKeyDownAndLetsGoOnRelease() {
        let a = pad { $0.a = true }
        #expect(PadAction.buttons(from: GamepadSnapshot(), to: a) == [.pressDown])
        // A reading that changes something else is no new press
        #expect(PadAction.buttons(from: a, to: pad { $0.a = true; $0.leftStickX = 0.2 }).isEmpty)
        #expect(PadAction.buttons(from: a, to: GamepadSnapshot()) == [.pressUp])
    }

    @Test func bClosesOnRelease() {
        let b = pad { $0.b = true }
        #expect(PadAction.buttons(from: GamepadSnapshot(), to: b).isEmpty)
        #expect(PadAction.buttons(from: b, to: GamepadSnapshot()) == [.close])
    }

    @Test func l3TogglesShiftOnPressOnlyAndMovesNoFocus() {
        let l3 = pad { $0.leftStickButton = true }
        #expect(PadAction.buttons(from: GamepadSnapshot(), to: l3) == [.toggleShift])
        #expect(PadAction.buttons(from: l3, to: l3).isEmpty)
        #expect(PadAction.buttons(from: l3, to: GamepadSnapshot()).isEmpty)
    }

    @Test func l3LatchesShiftAndTheNextPressReleasesIt() {
        var latch = ModifierLatch()
        #expect(latch.padPress(KeyCode.leftShift) == .down)
        #expect(latch.isLatched(KeyCode.leftShift))
        #expect(latch.padPress(KeyCode.leftShift) == .up)
        #expect(!latch.isLatched(KeyCode.leftShift))
    }

    @Test func xIsBackspaceAndYIsSpaceDownOnPressUpOnRelease() {
        let x = pad { $0.x = true }, y = pad { $0.y = true }
        #expect(PadAction.buttons(from: GamepadSnapshot(), to: x) == [.boundDown(KeyCode.backspace)])
        #expect(PadAction.buttons(from: x, to: GamepadSnapshot()) == [.boundUp(KeyCode.backspace)])
        #expect(PadAction.buttons(from: GamepadSnapshot(), to: y) == [.boundDown(KeyCode.space)])
        #expect(PadAction.buttons(from: y, to: GamepadSnapshot()) == [.boundUp(KeyCode.space)])
        #expect(PadAction.xKey == KeyCode.backspace && PadAction.yKey == KeyCode.space)
    }

    @Test func heldKeysRepeatLikeTheDpad() {
        #expect(PadRepeat.delay == 350)
        #expect(PadRepeat.interval == 100)
        var dpad = DpadTracker()
        #expect(dpad.onHat(x: 1, y: 0, now: 1000) == .right)
        #expect(dpad.repeatAt == 1000 + PadRepeat.delay)
    }

    @Test func otherButtonsDoNothingForTheKeyboard() {
        let others: [(inout GamepadSnapshot) -> Void] = [
            { $0.leftShoulder = true }, { $0.rightTrigger = 1; $0.rightTriggerPressed = true }, { $0.menu = true }, { $0.rightStickButton = true },
        ]
        for press in others {
            #expect(PadAction.buttons(from: GamepadSnapshot(), to: pad(press)).isEmpty)
            #expect(PadAction.buttons(from: pad(press), to: GamepadSnapshot()).isEmpty)
        }
    }

    @Test func aStickMovesTheFocusInItsStrongerDirectionPastTheThreshold() {
        #expect(analogDirection(x: 0.3, y: -0.4) == nil)
        #expect(analogDirection(x: -0.9, y: 0.2) == .left)
        #expect(analogDirection(x: 0.8, y: -0.7) == .right)
        #expect(analogDirection(x: 0.2, y: -0.9) == .up)
        #expect(analogDirection(x: -0.5, y: 0.6) == .down)
        // Equal strength goes vertical, like the stream menu
        #expect(analogDirection(x: 0.7, y: 0.7) == .down)
    }

    @Test func aHeldStickMovesAtOnceThenRepeatsAndTheCenterStopsIt() {
        var stick = DirectionalRepeater(initialDelay: 350, repeatInterval: 100)
        #expect(stick.shouldMove(.right, now: 0) == true)
        #expect(stick.repeatAt == 350)
        #expect(stick.shouldMove(.right, now: 349) == false)
        #expect(stick.shouldMove(.right, now: 350) == true)
        #expect(stick.repeatAt == 450)
        // Another direction is a new press
        #expect(stick.shouldMove(.up, now: 360) == true)
        #expect(stick.shouldMove(nil, now: 400) == false)
        #expect(stick.repeatAt == nil)
    }

    // MARK: Size

    @Test func theAutomaticFitFillsTheWidthUpToTheCapAndSizesTheKeysFromIt() {
        let prefs = KeyboardPrefs()
        let sixteenNine = KeyboardMetrics.metrics(screenWidth: 1920, prefs: prefs, dpPerPx: 0.444)
        #expect(sixteenNine.bodyWidth == 1840)
        #expect(abs(sixteenNine.keyHeight - 1840 * 0.0365) < 0.001)
        // 21:9 keeps the width and the keys: it only centers
        let ultrawide = KeyboardMetrics.metrics(screenWidth: 2520, prefs: prefs, dpPerPx: 0.444)
        #expect(ultrawide.bodyWidth == 1840)
        #expect(ultrawide.keyHeight == sixteenNine.keyHeight)
        // 4:3 is narrower: smaller keys, not a taller keyboard
        let fourThree = KeyboardMetrics.metrics(screenWidth: 1440, prefs: prefs, dpPerPx: 0.444)
        #expect(fourThree.bodyWidth == 1440 - 48)
        #expect(fourThree.keyHeight < sixteenNine.keyHeight && fourThree.keyHeight >= KeyboardMetrics.minKey)
        #expect(KeyboardMetrics.metrics(screenWidth: 400, prefs: prefs, dpPerPx: 0.444).keyHeight == KeyboardMetrics.minKey)
    }

    @Test func theBarIsAboutHalfTheScreenAtSixteenByNine() {
        let bar = KeyboardMetrics.metrics(screenWidth: 1920, prefs: KeyboardPrefs(), dpPerPx: 0.444).barHeight
        #expect(abs(bar - 543) <= 1)
        #expect(KeyboardMetrics.gap >= FocusSpacing.gap(reach: 0))
    }

    @Test func theSizeSettingsApplyOnlyWithTheAutomaticFitOff() {
        let ignored = KeyboardMetrics.metrics(
            screenWidth: 1920, prefs: KeyboardPrefs(autoFitDisabled: false, heightDp: 400, widthDp: 300), dpPerPx: 0.444)
        #expect(ignored == KeyboardMetrics.metrics(screenWidth: 1920, prefs: KeyboardPrefs(), dpPerPx: 0.444))

        let custom = KeyboardMetrics.metrics(
            screenWidth: 1920, prefs: KeyboardPrefs(autoFitDisabled: true, heightDp: 200, widthDp: 500), dpPerPx: 0.444)
        #expect(abs(custom.bodyWidth - 500 / 0.444) < 0.01)
        // The whole bar is as high as the setting says: 200 points = 450 stage pixels
        #expect(abs(custom.barHeight - 200 / 0.444) < 0.5)

        let tall = KeyboardMetrics.metrics(
            screenWidth: 1920, prefs: KeyboardPrefs(autoFitDisabled: true, heightDp: 300, widthDp: 500), dpPerPx: 0.444)
        #expect(tall.keyHeight > custom.keyHeight)
        let full = KeyboardMetrics.metrics(
            screenWidth: 1920, prefs: KeyboardPrefs(autoFitDisabled: true, heightDp: 200, widthDp: 1000), dpPerPx: 0.444)
        #expect(full.bodyWidth == 1840)
        // A width wider than the screen never overflows it
        #expect(KeyboardMetrics.metrics(screenWidth: 1920, prefs: KeyboardPrefs(autoFitDisabled: true, widthDp: 990), dpPerPx: 0.444).bodyWidth == 1840)
    }

    @Test func theAlignModeSettingIsParsedAndUnknownValuesCenter() {
        #expect(KeyboardAlign.parse("left") == .left)
        #expect(KeyboardAlign.parse("right") == .right)
        #expect(KeyboardAlign.parse("center") == .center)
        #expect(KeyboardAlign.parse(nil) == .center)
        #expect(KeyboardAlign.parse("middle") == .center)
    }

    @Test func theProfilesSettingsAreTheKeyboardsSizeAndOpacity() {
        var settings = StreamSettings()
        settings.set(.onscreenKeyboardAutofit, .bool(true))
        settings.set(.onscreenKeyboardHeight, .int(300))
        settings.set(.onscreenKeyboardWidth, .int(600))
        settings.set(.onscreenKeyboardAlignMode, .text("right"))
        settings.set(.keyboardOpacity, .int(70))
        #expect(KeyboardPrefs(settings) == KeyboardPrefs(autoFitDisabled: true, heightDp: 300, widthDp: 600, align: .right, opacityPercent: 70))
        #expect(KeyboardPrefs(StreamSettings()) == KeyboardPrefs())
    }

    @Test func theShadeDarkensFromHalfTheScreenToTheBottom() {
        // A keyboard reaching well above half the screen: from nothing at its top through nothing at half to .38 at the bottom
        let tall = KeyboardShade.stops(height: 700, barTop: 70, screenHeight: 1080)
        #expect(tall.count == 4)
        #expect(tall[0].location == 0 && tall[0].alpha == 0)
        #expect(tall[1].alpha == 0 && tall[2].location == 160.0 / 700 && tall[2].alpha == 0)
        #expect(tall[3].location == 1 && tall[3].alpha == KeyboardShade.maxAlpha)
        // A short one starts where the screen is already darker
        let short = KeyboardShade.stops(height: 300, barTop: 50, screenHeight: 1080)
        #expect(short.count == 3)
        #expect(abs(short[1].alpha - KeyboardShade.maxAlpha * (830.0 - 540) / 540) < 1e-9)
    }
}
