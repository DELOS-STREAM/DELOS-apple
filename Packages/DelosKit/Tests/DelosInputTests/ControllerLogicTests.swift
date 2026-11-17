import DelosCore
import Foundation
import GameController
import Testing
@testable import DelosInput

// MARK: - Gyro smoothing (`GyroSmootherTest` of DELOS for Android)

@Suite struct GyroSmootherTests {
    static let step: Int64 = 5_000_000  // 200 Hz
    static let sliders = [1, 10, 25, 50, 75, 100]

    private func run(_ smoother: inout GyroSmoother, _ t: Int64, _ x: Float) -> Float {
        smoother.filter(nanoseconds: t, x, x, x)!.0
    }

    /// A reproducible normal distribution (Box–Muller over a 64-bit LCG).
    private struct Gaussian {
        var state: UInt64 = 42
        mutating func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) + 0.5) / Double(1 << 53)
        }
        mutating func next() -> Double { (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform()) }
    }

    private func noiseRatio(_ slider: Int) -> Double {
        var smoother = GyroSmoother(strength: slider)
        var random = Gaussian()
        var input = 0.0, filtered = 0.0
        for i in 0..<20000 {
            let x = Float(random.next() * 0.5)
            let out = smoother.filter(nanoseconds: Int64(i) * Self.step, x, x, x)!.0
            if i >= 2000 {
                input += Double(x * x)
                filtered += Double(out * out)
            }
        }
        return filtered / input
    }

    private func flickEnd(_ slider: Int) -> Float {
        var smoother = GyroSmoother(strength: slider)
        var t: Int64 = 0
        for _ in 0..<400 { _ = run(&smoother, t, 0); t += Self.step }
        var last: Float = 0
        for i in 1...20 { last = run(&smoother, t, 300 * Float(i) / 20); t += Self.step }
        return last
    }

    @Test func offIsNoFilterAndTheSliderIsClamped() {
        var off = GyroSmoother(strength: 0)
        #expect(off.filter(nanoseconds: 0, 5, 6, 7) == nil)
        #expect(GyroSmoother.minCutoffHz(100) == GyroSmoother.minCutoffHz(250))
        #expect(GyroSmoother.minCutoffHz(0) == GyroSmoother.minCutoffHz(-3))
        #expect(GyroSmoother(strength: -5).strength == 0)
    }

    @Test func theMappingFallsMonotonicallyBetweenTheDocumentedEnds() {
        #expect(abs(GyroSmoother.minCutoffHz(0) - 8) < 1e-9)
        #expect(abs(GyroSmoother.minCutoffHz(100) - 0.2) < 1e-9)
        #expect(abs(GyroSmoother.beta(0) - 0.02) < 1e-12)
        #expect(abs(GyroSmoother.beta(100) - 0.005) < 1e-12)
        for slider in 1...100 {
            #expect(GyroSmoother.minCutoffHz(slider) < GyroSmoother.minCutoffHz(slider - 1))
            #expect(GyroSmoother.beta(slider) < GyroSmoother.beta(slider - 1))
        }
        #expect(abs(GyroSmoother.minCutoffHz(50) - 1.26) < 0.01)
    }

    @Test func theFirstSamplePassesAndEachAxisIsFilteredOnItsOwn() {
        var smoother = GyroSmoother(strength: 50)
        let first = smoother.filter(nanoseconds: 1_000_000_000, 10, -20, 30)!
        #expect(first == (10, -20, 30))
        let next = smoother.filter(nanoseconds: 1_000_000_000 + Self.step, 10, 40, 30)!
        #expect(abs(next.0 - 10) < 1e-5 && abs(next.2 - 30) < 1e-5)
        #expect(next.1 > -20 && next.1 < 40)
    }

    @Test func aConstantStaysConstantAndAStepConvergesWithoutOvershoot() {
        for slider in Self.sliders {
            var constant = GyroSmoother(strength: slider)
            for i in 0..<1000 { #expect(abs(run(&constant, Int64(i) * Self.step, 7.5) - 7.5) < 1e-4) }
            var smoother = GyroSmoother(strength: slider)
            for i in 0..<200 { _ = run(&smoother, Int64(i) * Self.step, 0) }
            var previous: Float = 0, last: Float = 0
            for i in 0..<1000 {
                last = run(&smoother, Int64(200 + i) * Self.step, 100)
                #expect(last <= 100.0001 && last >= previous - 1e-4, "slider \(slider)")
                previous = last
            }
            #expect(abs(last - 100) < 1, "slider \(slider)")
        }
    }

    @Test func noiseAtRestShrinksWithTheSlider() {
        // Android's ceilings, the last two a quarter higher: the noise here comes from another generator than Java's
        // `Random(42)`, and at the strong settings the few independent samples left make the ratio vary that much
        let ceilings = [0.12, 0.09, 0.06, 0.03, 0.015, 0.0075]
        var previous = 1.0
        for (slider, ceiling) in zip(Self.sliders, ceilings) {
            let ratio = noiseRatio(slider)
            #expect(ratio < ceiling, "slider \(slider) ratio \(ratio)")
            #expect(ratio < previous)
            previous = ratio
        }
    }

    @Test func aHundredMillisecondFlickReachesMostOfItsPeak() {
        #expect(flickEnd(25) >= 285)
        #expect(flickEnd(50) >= 280)
        #expect(flickEnd(75) >= 275)
        #expect(flickEnd(100) >= 270)
    }

    @Test func aLongGapRestartsButAShortOneDoesNot() {
        let last = 99 * Self.step
        var smoother = GyroSmoother(strength: 100)
        for i in 0..<100 { _ = run(&smoother, Int64(i) * Self.step, 0) }
        #expect(run(&smoother, last + GyroSmoother.maxGapNanoseconds, 50) < 50)
        var other = GyroSmoother(strength: 100)
        for i in 0..<100 { _ = run(&other, Int64(i) * Self.step, 0) }
        #expect(run(&other, last + GyroSmoother.maxGapNanoseconds + 1, 50) == 50)
        #expect(run(&other, last + GyroSmoother.maxGapNanoseconds + 1 + Self.step, 0) > 40)
    }

    @Test func aRepeatedTimestampRepeatsTheOutputAndABackwardsOneRestarts() {
        var smoother = GyroSmoother(strength: 50)
        _ = run(&smoother, 1_000_000_000, 0)
        let settled = run(&smoother, 1_000_000_000 + Self.step, 10)
        #expect(run(&smoother, 1_000_000_000 + Self.step, 99) == settled)
        #expect(run(&smoother, 500_000_000, 77) == 77)
        smoother.reset()
        #expect(run(&smoother, 600_000_000, 20) == 20)
    }

    @Test func theStrengthChangesLiveAndZeroIsAnExactBypass() {
        var smoother = GyroSmoother(strength: 0)
        #expect(smoother.strength == 0 && smoother.filter(nanoseconds: 0, 5, 6, 7) == nil)
        smoother.setStrength(50)
        #expect(smoother.filter(nanoseconds: 10 * Self.step, 5, 6, 7)!.0 == 5, "a fresh filter")
        let moved = smoother.filter(nanoseconds: 11 * Self.step, 105, 6, 7)!.0
        #expect(moved > 5 && moved < 105)
        smoother.setStrength(0)
        #expect(smoother.filter(nanoseconds: 12 * Self.step, 105, 6, 7) == nil)
        smoother.setStrength(50)
        #expect(smoother.filter(nanoseconds: 13 * Self.step, 40, 0, 0)!.0 == 40, "the state was forgotten")
    }

    @Test func retuningBetweenPositiveStrengthsKeepsTheState() {
        var steady = GyroSmoother(strength: 25), retuned = GyroSmoother(strength: 25)
        for i in 0..<100 {
            _ = run(&steady, Int64(i) * Self.step, 10)
            _ = run(&retuned, Int64(i) * Self.step, 10)
        }
        retuned.setStrength(75)
        #expect(abs(run(&retuned, 100 * Self.step, 10) - run(&steady, 100 * Self.step, 10)) < 1e-3)
        #expect(run(&retuned, 101 * Self.step, 60) < run(&steady, 101 * Self.step, 60))
    }
}

// MARK: - Motion

@Suite struct MotionTests {
    private func close(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> Bool {
        abs(a.0 - b.0) < 1e-3 && abs(a.1 - b.1) < 1e-3 && abs(a.2 - b.2) < 1e-3
    }

    @Test func aControllerAtRestFaceUpReadsGravityUpOnSDLsY() {
        // GameController: gravity −1 G along z (out of the face)
        #expect(close(MotionAxes.controller(.accelerometer, x: 0, y: 0, z: -1), (0, 9.80665, 0)))
        // Pointing its top edge up (y towards the sky) is SDL's −z (away from the player) up
        #expect(close(MotionAxes.controller(.accelerometer, x: 0, y: -1, z: 0), (0, 0, -9.80665)))
        // Turning about the face's normal is SDL's yaw (about y), in deg/s
        #expect(close(MotionAxes.controller(.gyroscope, x: 0, y: 0, z: 1), (0, 57.2957795, 0)))
        #expect(close(MotionAxes.controller(.gyroscope, x: 1, y: 0, z: 0), (57.2957795, 0, 0)))
    }

    @Test func theDeviceFollowsAndroidsRotationCorrection() {
        // Lying flat, screen up: gravity is the device's −z in every rotation, SDL's +y
        for rotation in MotionAxes.Rotation.allCases {
            #expect(close(MotionAxes.device(.accelerometer, x: 0, y: 0, z: -1, rotation: rotation), (0, 9.80665, 0)))
        }
        // Android's axis choice and factors per rotation, on (1, 2, 3)
        #expect(close(MotionAxes.remap((1, 2, 3), .none), (1, 3, -2)))
        #expect(close(MotionAxes.remap((1, 2, 3), .quarter), (-2, 3, -1)))
        #expect(close(MotionAxes.remap((1, 2, 3), .half), (-1, 3, 2)))
        #expect(close(MotionAxes.remap((1, 2, 3), .threeQuarters), (2, 3, 1)))
        // Core Motion's rad/s become deg/s
        #expect(close(MotionAxes.device(.gyroscope, x: 1, y: 0, z: 0, rotation: .none), (57.2957795, 0, 0)))
    }

    @Test func aStreamKeepsTheRateDropsDuplicatesAndSmoothsOnlyTheGyro() throws {
        #expect(MotionStream(sensor: .gyroscope, requestedHz: 0, smoothing: 0) == nil, "0 Hz stops the sensor")
        #expect(MotionStream(sensor: .gyroscope, requestedHz: 1000, smoothing: 0)?.rateHz == 200, "capped like Android")
        var stream = try #require(MotionStream(sensor: .accelerometer, requestedHz: 100, smoothing: 100))
        let first = stream.process((1, 2, 3), timestamp: 10, smoothing: 100)
        let tooSoon = stream.process((4, 5, 6), timestamp: 10.002, smoothing: 100)
        let again = stream.process((1, 2, 3), timestamp: 10.010, smoothing: 100)
        let next = stream.process((7, 8, 9), timestamp: 10.020, smoothing: 100)
        #expect(first! == (1, 2, 3), "the accelerometer is not smoothed")
        #expect(tooSoon == nil, "closer than the period")
        #expect(again == nil, "the same reading again")
        #expect(next! == (7, 8, 9))
        var gyro = try #require(MotionStream(sensor: .gyroscope, requestedHz: 100, smoothing: 50))
        _ = gyro.process((0, 0, 0), timestamp: 1, smoothing: 50)
        let smoothed = gyro.process((100, 100, 100), timestamp: 1.01, smoothing: 50)!
        #expect(smoothed.0 > 0 && smoothed.0 < 100)
        // The stream menu's 0 sends the reading untouched
        let untouched = gyro.process((50, 50, 50), timestamp: 1.02, smoothing: 0)
        #expect(untouched! == (50, 50, 50))
    }
}

/// `MotionSendRateTest` of DELOS for Android.
@Suite struct MotionSendRateTests {
    @Test func theLineHasTheDocumentedFormatAndRatesFollowTheWindow() {
        var rate = MotionSendRate()
        for _ in 0..<500 { rate.onSensorCallback(pad: 0, sensor: .gyroscope) }
        for _ in 0..<250 { rate.onHandedOver(pad: 0, sensor: .gyroscope, accepted: true) }
        for _ in 0..<100 { rate.onHandedOver(pad: 0, sensor: .accelerometer, accepted: true) }
        rate.onHandedOver(pad: 0, sensor: .accelerometer, accepted: false)
        #expect(rate.drainLines(window: 2, listening: [0]) == [
            "MotionSend gyro 125/s accel 50/s pad 0 (sensor callbacks gyro 250/s accel 0/s, refused gyro 0 accel 1)"
        ])
    }

    @Test func aDrainResetsAndAQuietListeningPadShowsZero() {
        var rate = MotionSendRate()
        rate.onHandedOver(pad: 3, sensor: .gyroscope, accepted: true)
        _ = rate.drainLines(window: 1, listening: [])
        #expect(rate.drainLines(window: 1, listening: []).isEmpty, "an idle pad shows nothing")
        #expect(rate.drainLines(window: 0, listening: [1]) == [
            "MotionSend gyro 0/s accel 0/s pad 1 (sensor callbacks gyro 0/s accel 0/s, refused gyro 0 accel 0)"
        ])
    }

    @Test func everyPadGetsItsOwnLine() {
        var rate = MotionSendRate()
        rate.onHandedOver(pad: 2, sensor: .gyroscope, accepted: true)
        rate.onHandedOver(pad: 0, sensor: .gyroscope, accepted: true)
        #expect(rate.drainLines(window: 1, listening: []).count == 2)
    }
}

@Suite struct BatteryReportTests {
    @Test func gameControllersStatesAndLevelsMapLikeAndroid() {
        #expect(BatteryReport(state: .charging, level: 0.42) == BatteryReport(state: .charging, percentage: 42))
        #expect(BatteryReport(state: .discharging, level: 0.999) == BatteryReport(state: .discharging, percentage: 99))
        #expect(BatteryReport(state: .full, level: 1) == BatteryReport(state: .full, percentage: 100))
        #expect(BatteryReport(state: .unknown, level: .nan) == BatteryReport(state: .unknown, percentage: 0xFF))
        #expect(BatteryReport.interval == .seconds(120))
        #expect(BatteryState.unknownPercentage == 0xFF)
    }
}

// MARK: - Sticks, triggers, face buttons, players

@Suite struct ControllerMappingTests {
    @Test func aPositiveDeadzoneZeroesTheCentreAndLeavesTheRest() {
        #expect(GamepadMapping.applyDeadzone(x: 0.03, y: 0.03, radius: 0.05) == (0, 0))
        #expect(GamepadMapping.applyDeadzone(x: 0.3, y: -0.4, radius: 0.05) == (0.3, -0.4))
        var pad = GamepadSnapshot()
        pad.leftStickX = 0.04
        pad.rightStickY = 0.5
        let state = GamepadMapping.state(pad)
        #expect(state.leftStickX == 0, "the default 5 %")
        #expect(state.rightStickY == GamepadMapping.stick(0.5))
    }

    @Test func zeroOrANegativeDeadzoneKeepsOnePercentAndStretchesTheTravel() {
        #expect(GamepadMapping.applyDeadzone(x: 0.005, y: 0, radius: 0) == (0, 0))
        #expect(GamepadMapping.applyDeadzone(x: 0.5, y: 0, radius: 0) == (0.5, 0))
        let stretched = GamepadMapping.applyDeadzone(x: 0.5, y: 0, radius: -0.2)
        #expect(abs(stretched.x - 0.6) < 1e-6, "−r + m(1 + r) = 0.2 + 0.5 × 0.8")
        #expect(GamepadMapping.applyDeadzone(x: 1, y: 0, radius: -0.2) == (1, 0), "at full travel: untouched")
    }

    @Test func triggersUnderThirteenPercentAreReleased() {
        var pad = GamepadSnapshot()
        pad.leftTrigger = 0.13
        pad.rightTrigger = 0.14
        let state = GamepadMapping.state(pad)
        #expect(state.leftTrigger == 0 && state.rightTrigger == GamepadMapping.trigger(0.14))
    }

    @Test func flippedFaceButtonsSwapAAndBXAndY() {
        var options = ControllerOptions()
        options.flipFaceButtons = true
        var pad = GamepadSnapshot()
        pad.a = true
        pad.x = true
        #expect(GamepadMapping.state(pad, options: options).buttons == [.b, .y])
        // The menu shortcut keeps the controller's own buttons: its A is the PC's B
        var state = GamepadMapping.state(pad, options: options)
        ShortcutButton.remove([.a], from: &state, flippedFaceButtons: true)
        #expect(state.buttons == [.y])
    }

    @Test func controllersOfOnePlayerAreFused() {
        let a = ControllerState(buttons: [.a], leftTrigger: 10, leftStickX: 100, rightStickY: -5)
        let b = ControllerState(buttons: [.b], leftTrigger: 200, leftStickX: -300, rightStickY: 2)
        let fused = GamepadMapping.fuse([a, b])
        #expect(fused == ControllerState(buttons: [.a, .b], leftTrigger: 200, leftStickX: -300, rightStickY: -5))
    }
}

/// The combinations of a controller without Select or Home, and the touchpad click of one announced as generic.
@Suite struct ButtonCombosTests {
    @Test func startAndL1AreSelectWithoutASelectButton() {
        var combos = ButtonCombos(hasSelect: false, hasHome: true, touchpadEmulation: false)
        #expect(combos.apply([.play], now: 0) == [.play])
        #expect(combos.apply([.play, .leftShoulder], now: 10) == [.back])
        // The first button released lets go of Select; Start stays off until it is pressed again
        #expect(combos.apply([.play], now: 20) == [])
        #expect(combos.apply([], now: 30) == [])
        #expect(combos.apply([.play], now: 500) == [.play])
    }

    @Test func startShortlyAfterL1CameUpIsSelectToo() {
        var combos = ButtonCombos(hasSelect: false, hasHome: true, touchpadEmulation: false)
        _ = combos.apply([.leftShoulder], now: 0)
        _ = combos.apply([], now: 50)
        #expect(combos.apply([.play], now: 140) == [.back])
        _ = combos.apply([], now: 200)
        _ = combos.apply([.leftShoulder], now: 300)
        _ = combos.apply([], now: 310)
        #expect(combos.apply([.play], now: 500) == [.play], "too late")
    }

    @Test func startAndSelectAreGuideWithoutHome() {
        var combos = ButtonCombos(hasSelect: true, hasHome: false, touchpadEmulation: false)
        #expect(combos.apply([.play, .back], now: 0) == [.special])
        #expect(combos.apply([.back], now: 10) == [])
        var noSelect = ButtonCombos(hasSelect: false, hasHome: false, touchpadEmulation: false)
        #expect(noSelect.apply([.play, .rightShoulder], now: 0) == [.special])
    }

    @Test func selectAndL1AreTheTouchpadOfAGenericControllerWithMotion() {
        var combos = ButtonCombos(hasSelect: true, hasHome: true, touchpadEmulation: true)
        #expect(combos.apply([.back, .leftShoulder], now: 0) == [.touchpad])
        #expect(combos.apply([.back], now: 50) == [])
        var plain = ButtonCombos(hasSelect: true, hasHome: true, touchpadEmulation: false)
        #expect(!plain.isActive)
        #expect(plain.apply([.back, .leftShoulder], now: 0) == [.back, .leftShoulder])
    }
}

// MARK: - Start held, mouse emulation

@Suite struct StartButtonHoldTests {
    @Test func aLongPressTogglesTheMouseEmulationAndAShortOneDoesNothing() {
        var start = StartButtonHold()
        start.onDown(0)
        #expect(start.onUp(700, mouseEmulation: true) == .none)
        start.onDown(1000)
        #expect(start.onUp(1751, mouseEmulation: true) == .toggleMouseEmulation)
        start.onDown(3000)
        #expect(start.onUp(3800, mouseEmulation: false) == .none, "the emulation is off in Settings")
    }

    @Test func aQuickDoubleStartHeldTheSecondTimeOpensTheMenu() {
        var start = StartButtonHold()
        start.onDown(0)
        _ = start.onUp(100, mouseEmulation: true)
        start.onDown(250)
        #expect(start.onUp(1100, mouseEmulation: true) == .openMenu)
        // Not quick enough: the hold is the mouse emulation
        start.onDown(1400)
        #expect(start.onUp(2200, mouseEmulation: true) == .toggleMouseEmulation)
        // Quick but not held: nothing
        start.onDown(2300)
        #expect(start.onUp(2400, mouseEmulation: true) == .none)
    }
}

@Suite struct MouseEmulationTests {
    @Test func buttonsClickScrollAndSetTheStep() {
        var emulation = MouseEmulation()
        #expect(emulation.buttons([.a]) == [.button(.left, pressed: true)])
        #expect(emulation.buttons([.a, .b]) == [.button(.right, pressed: true)])
        #expect(emulation.buttons([]) == [.button(.left, pressed: false), .button(.right, pressed: false)])
        #expect(emulation.buttons([.up]) == [.scroll(1)])
        #expect(emulation.buttons([.up]).isEmpty, "a held D-pad scrolls once")
        #expect(emulation.buttons([.down]) == [.scroll(-1)])
        #expect(emulation.buttons([.right]) == [.horizontalScroll(1)])
        #expect(emulation.buttons([.left]) == [.horizontalScroll(-1)])
        _ = emulation.buttons([.x])
        #expect(emulation.fixedStep)
        for _ in 0..<8 {
            _ = emulation.buttons([.x, .y])
            _ = emulation.buttons([.x])
        }
        #expect(emulation.multiplier == 1, "doubled past 255 back to 1")
        _ = emulation.buttons([.x, .y])
        #expect(emulation.multiplier == 2)
    }

    @Test func theSticksMoveAndScrollByTheChosenStick() {
        let full = ControllerState(leftStickX: 32766, rightStickY: 32766)
        let emulation = MouseEmulation()
        // Full travel: 4 × 4² = 64 pixels a period
        #expect(emulation.tick(full, scrollStick: .right) == [.move(dx: 64, dy: 0), .highResolutionScroll(64), .highResolutionHorizontalScroll(0)])
        #expect(emulation.tick(full, scrollStick: .left) == [.move(dx: 0, dy: -64), .highResolutionScroll(0), .highResolutionHorizontalScroll(64)])
        #expect(emulation.tick(full, scrollStick: .none) == [.move(dx: 64, dy: 0), .move(dx: 0, dy: -64)])
        // Under a pixel nothing moves
        #expect(emulation.tick(ControllerState(leftStickX: 5000), scrollStick: .right).isEmpty)
    }

    @Test func xHeldMovesAFixedStepOfTheMultiplier() {
        var emulation = MouseEmulation()
        _ = emulation.buttons([.y])
        _ = emulation.buttons([.x])
        #expect(emulation.tick(ControllerState(leftStickX: -32766, leftStickY: 20000), scrollStick: .right) == [.move(dx: -2, dy: -2)])
    }
}

// MARK: - Keyboard (`StreamKeyHandlerTest` of DELOS for Android)

@Suite struct ClientKeyCombosTests {
    private func press(_ combos: inout ClientKeyCombos, _ usage: Int, _ pressed: Bool, rightAltAsMeta: Bool = false)
        -> (consumed: Bool, action: ClientKeyCombos.Action?)
    {
        combos.key(usage, pressed: pressed, rightAltAsMeta: rightAltAsMeta)
    }

    @Test func ctrlAltShiftZFiresOnceEveryModifierIsUp() {
        var combos = ClientKeyCombos()
        for usage in [0xE0, 0xE2, 0xE1] { #expect(press(&combos, usage, true) == (false, nil)) }
        #expect(press(&combos, 0x1D, true) == (true, nil), "the Z is kept from the PC")
        #expect(press(&combos, 0x04, true) == (true, nil), "other presses while waiting are kept")
        #expect(press(&combos, 0x04, false) == (false, nil), "releases pass")
        #expect(press(&combos, 0x1D, false) == (true, nil), "the Z's release never reaches the PC")
        #expect(press(&combos, 0xE0, false) == (false, nil))
        #expect(press(&combos, 0xE2, false) == (false, nil))
        #expect(press(&combos, 0xE1, false) == (false, .toggleInputGrab))
    }

    @Test func qQuitsAndCTogglesTheCursorWithControlOrCommand() {
        var combos = ClientKeyCombos()
        for usage in [0xE4, 0xE6, 0xE5] { _ = press(&combos, usage, true) }
        _ = press(&combos, 0x14, true)
        _ = press(&combos, 0x14, false)
        _ = press(&combos, 0xE4, false)
        _ = press(&combos, 0xE6, false)
        #expect(press(&combos, 0xE5, false).action == .quit)
        // Command + Option + Shift + C
        for usage in [0xE3, 0xE2, 0xE1] { _ = press(&combos, usage, true) }
        #expect(press(&combos, 0x06, true).consumed)
        _ = press(&combos, 0xE3, false)
        _ = press(&combos, 0xE2, false)
        _ = press(&combos, 0x06, false)
        #expect(press(&combos, 0xE1, false).action == .toggleLocalCursor)
    }

    @Test func otherKeysAndIncompleteCombinationsAreNotSpecial() {
        var combos = ClientKeyCombos()
        for usage in [0xE0, 0xE2] { _ = press(&combos, usage, true) }
        #expect(press(&combos, 0x1D, true) == (false, nil), "Shift is missing")
        _ = press(&combos, 0xE1, true)
        #expect(press(&combos, 0x05, true) == (false, nil), "B is no combination")
        // With the right Alt as Meta it is no Alt
        var meta = ClientKeyCombos()
        for usage in [0xE0, 0xE6, 0xE1] { _ = press(&meta, usage, true, rightAltAsMeta: true) }
        #expect(press(&meta, 0x1D, true, rightAltAsMeta: true) == (false, nil))
    }

    @Test func rightAltAsMetaSendsTheWindowsKeyWithTheMetaModifier() {
        #expect(KeyboardMapping.virtualKey(hidUsage: 0xE6, rightAltAsMeta: true) == 0x5B)
        #expect(KeyboardMapping.virtualKey(hidUsage: 0xE6, rightAltAsMeta: false) == 0xA5)
        #expect(KeyboardMapping.modifiers(held: [0xE6], rightAltAsMeta: true) == .meta)
        #expect(KeyboardMapping.modifiers(held: [0xE6, 0xE2], rightAltAsMeta: true) == [.meta, .alt])
        #expect(KeyboardMapping.modifiers(held: [0xE6]) == .alt)
    }
}

