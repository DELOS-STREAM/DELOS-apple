import DelosCore
import Foundation
import GameController
import Testing
@testable import DelosInput
@testable import DelosUI

/// A clock that only moves when the test says so; due timers fire in order.
@MainActor
private final class ManualClock: KeyboardClock {
    var now: Int64 = 1000
    private var timers: [KeyboardTimer: (at: Int64, action: @MainActor () -> Void)] = [:]

    func schedule(_ timer: KeyboardTimer, after milliseconds: Int64, _ action: @escaping @MainActor () -> Void) {
        timers[timer] = (now + max(milliseconds, 0), action)
    }

    func cancel(_ timer: KeyboardTimer) { timers[timer] = nil }

    func advance(_ milliseconds: Int64) {
        let end = now + milliseconds
        while let (timer, due) = timers.filter({ $0.value.at <= end }).min(by: { $0.value.at < $1.value.at }) {
            timers[timer] = nil
            now = due.at
            due.action()
        }
        now = end
    }
}

@MainActor
private final class RecordingHost: FullKeyboardHost {
    var stickyModifiers = true
    var keys: [(code: Int, down: Bool)] = []
    var haptics: [KeyHaptic] = []
    var closes = 0
    weak var state: FullKeyboardState?

    func sendKey(_ code: Int, down: Bool) { keys.append((code, down)) }
    func haptic(_ haptic: KeyHaptic) { haptics.append(haptic) }
    func closeFullKeyboard() {
        closes += 1
        state?.hide()
    }
}

@MainActor
private func keyboard(controller: Bool = false) -> (FullKeyboardState, RecordingHost, ManualClock) {
    let clock = ManualClock()
    let state = FullKeyboardState(clock: clock, hasController: { controller })
    let host = RecordingHost()
    host.state = state
    state.host = host
    state.show()
    return (state, host, clock)
}

private func pad(_ change: (inout GamepadSnapshot) -> Void = { _ in }) -> GamepadSnapshot {
    var snapshot = GamepadSnapshot()
    change(&snapshot)
    return snapshot
}

private let q = KeyCode.character("Q")

/// `FullKeyboardState` of DELOS for Android: what touches and a controller do to the keyboard and what reaches the PC.
@MainActor
@Suite struct FullKeyboardStateTests {
    @Test func theKeyboardOpensInTheModeOfTheInputThatIsConnectedAndLeavesAfterItsExit() {
        let (touch, _, clock) = keyboard()
        #expect(touch.open && touch.present && touch.input == .touch && touch.focus == nil)
        let (pad, _, _) = keyboard(controller: true)
        #expect(pad.input == .controller)
        // The ring comes once the keys are in, on Q
        pad.settled()
        #expect(pad.focusVisible && pad.focus == KeyGrid.standard.find(q))
        touch.hide()
        #expect(!touch.open && touch.present)
        clock.advance(Int64(Motion.exit) + FullKeyboardState.leaveMarginMs)
        #expect(!touch.present)
    }

    @Test func aTouchPressesTheKeyShowsItsPopupAndTheReleaseLetsGo() {
        let (state, host, clock) = keyboard()
        #expect(state.touchDown(q))
        #expect(host.keys.map(\.code) == [q] && host.keys[0].down)
        #expect(state.pressed == [q] && state.popup == KeyPopup(code: q, text: "q") && state.popupOn)
        state.touchUp(q)
        #expect(host.keys.count == 2 && !host.keys[1].down)
        #expect(host.haptics == [.press, .release])
        // The press shows a moment longer, the popup 75 ms
        #expect(state.pressed == [q])
        clock.advance(Int64(Motion.pressHold))
        #expect(state.pressed.isEmpty && !state.popupOn)
    }

    @Test func severalFingersHoldSeveralKeys() {
        let (state, host, _) = keyboard()
        state.touchDown(KeyCode.character("A"))
        state.touchDown(KeyCode.character("D"))
        #expect(state.pressed.count == 2 && host.keys.allSatisfy(\.down))
        state.touchUp(KeyCode.character("A"))
        #expect(host.keys.last.map { $0.code == KeyCode.character("A") && !$0.down } == true)
    }

    @Test func aHeldModifierLatchesAndShiftsTheLegendsUntilItIsTouchedAgain() {
        let (state, host, clock) = keyboard()
        state.touchDown(KeyCode.leftShift)
        #expect(state.shifted)
        clock.advance(FullKeyboardState.latchHoldMs)
        #expect(state.latched == [KeyCode.leftShift] && host.haptics.last == .latch)
        state.touchUp(KeyCode.leftShift)
        // Latched: still down at the PC, the keys show their shifted characters
        #expect(host.keys.map(\.down) == [true] && state.shifted)
        state.touchDown(q)
        #expect(state.popup?.text == "Q")
        state.touchUp(q)
        // A touch of the latched Shift lets it go with its release
        state.touchDown(KeyCode.leftShift)
        #expect(state.latched.isEmpty)
        state.touchUp(KeyCode.leftShift)
        #expect(host.keys.last.map { $0.code == KeyCode.leftShift && !$0.down } == true)
        #expect(!state.shifted)
    }

    @Test func aQuickTapOfAModifierIsAnOrdinaryKeyAndWithoutStickyModifiersSoIsAHold() {
        let (state, host, clock) = keyboard()
        state.touchDown(KeyCode.leftControl)
        clock.advance(FullKeyboardState.latchHoldMs - 1)
        state.touchUp(KeyCode.leftControl)
        clock.advance(1000)
        #expect(state.latched.isEmpty && host.keys.map(\.down) == [true, false])
        host.stickyModifiers = false
        state.touchDown(KeyCode.leftAlt)
        clock.advance(1000)
        #expect(state.latched.isEmpty)
        state.touchUp(KeyCode.leftAlt)
        #expect(host.keys.last.map { $0.code == KeyCode.leftAlt && !$0.down } == true)
    }

    @Test func capsLockTogglesTheLegendsAndIsKeptWhenTheKeyboardHides() {
        let (state, _, _) = keyboard()
        state.touchDown(KeyCode.capsLock)
        state.touchUp(KeyCode.capsLock)
        #expect(state.capsOn)
        state.hide()
        state.show()
        #expect(state.capsOn)
    }

    @Test func hidingLetsGoOfEveryKeyHeldAndEveryModifierLatched() {
        let (state, host, clock) = keyboard()
        state.touchDown(KeyCode.leftControl)
        clock.advance(FullKeyboardState.latchHoldMs)
        state.touchUp(KeyCode.leftControl)
        state.touchDown(q)
        host.keys.removeAll()
        state.hide()
        #expect(Set(host.keys.map(\.code)) == [q, KeyCode.leftControl] && host.keys.allSatisfy { !$0.down })
        #expect(state.latched.isEmpty && state.pressed.isEmpty && host.haptics.last == .hide)
        // A finger lifted afterwards sends nothing more
        host.keys.removeAll()
        #expect(!state.touchDown(q))
    }

    @Test func theHideKeyClosesTheKeyboardOnItsRelease() {
        let (state, host, _) = keyboard()
        state.touchDown(KeyDef.hideCode)
        #expect(host.closes == 0 && host.keys.isEmpty)
        state.touchUp(KeyDef.hideCode)
        #expect(host.closes == 1 && !state.open)
    }

    @Test func theControllerMovesTheFocusPressesWithAAndNudgesAtTheEdge() {
        let (state, host, _) = keyboard(controller: true)
        state.settled()
        state.controller(pad(), pad { $0.right = true })
        #expect(state.focus.map { KeyGrid.standard.key($0).legend } == "W")
        state.controller(pad { $0.right = true }, pad())
        state.controller(pad(), pad { $0.a = true })
        #expect(host.keys.map(\.code) == [KeyCode.character("W")] && state.popup?.text == "w")
        state.controller(pad { $0.a = true }, pad())
        #expect(host.keys.count == 2 && !host.keys[1].down)
        // Up twice: the top row, then the edge
        state.controller(pad(), pad { $0.up = true })
        state.controller(pad { $0.up = true }, pad())
        state.controller(pad(), pad { $0.up = true })
        state.controller(pad { $0.up = true }, pad())
        #expect(state.focus?.row == 0)
        state.controller(pad(), pad { $0.up = true })
        #expect(state.nudgeCount == 1 && state.nudgeDirection == .up)
    }

    @Test func theFirstControllerInputBringsTheFocusAndTheModeBack() {
        let (state, _, _) = keyboard()
        state.settled()
        state.touchDown(q)
        state.touchUp(q)
        #expect(!state.focusVisible)
        state.controller(pad(), pad { $0.down = true })
        #expect(state.input == .controller && state.focusVisible)
    }

    @Test func aHeldDpadRepeatsAndSoDoesAHeldStick() {
        let (state, _, clock) = keyboard(controller: true)
        state.settled()
        state.controller(pad(), pad { $0.right = true })
        clock.advance(PadRepeat.delay)
        clock.advance(PadRepeat.interval)
        #expect(state.focus.map { KeyGrid.standard.key($0).legend } == "R")
        state.controller(pad { $0.right = true }, pad())
        clock.advance(1000)
        #expect(state.focus.map { KeyGrid.standard.key($0).legend } == "R")
        // The stick, y up as GameController reports it: down moves down
        state.controller(pad(), pad { $0.leftStickY = -0.9 })
        #expect(state.focus?.row == 3)
        clock.advance(PadRepeat.delay)
        #expect(state.focus?.row == 4)
        state.controller(pad { $0.leftStickY = -0.9 }, pad())
        clock.advance(1000)
        #expect(state.focus?.row == 4)
    }

    @Test func aOnAModifierAndL3TogglesTheirLatch() {
        let (state, host, _) = keyboard(controller: true)
        state.settled()
        state.controller(pad(), pad { $0.leftStickButton = true })
        #expect(state.latched == [KeyCode.leftShift] && host.keys.last.map { $0.code == KeyCode.leftShift && $0.down } == true)
        state.controller(pad { $0.leftStickButton = true }, pad())
        state.controller(pad(), pad { $0.leftStickButton = true })
        #expect(state.latched.isEmpty && host.keys.last.map { $0.code == KeyCode.leftShift && !$0.down } == true)
    }

    @Test func xAndYTypeBackspaceAndSpaceAndRepeatWhileHeld() {
        let (state, host, clock) = keyboard(controller: true)
        state.settled()
        state.controller(pad(), pad { $0.x = true })
        clock.advance(PadRepeat.delay + PadRepeat.interval)
        #expect(host.keys.map(\.code) == [KeyCode.backspace, KeyCode.backspace, KeyCode.backspace])
        state.controller(pad { $0.x = true }, pad())
        #expect(host.keys.last.map { $0.code == KeyCode.backspace && !$0.down } == true)
        state.controller(pad(), pad { $0.y = true })
        state.controller(pad { $0.y = true }, pad())
        #expect(host.keys.suffix(2).map(\.code) == [KeyCode.space, KeyCode.space])
    }

    @Test func bClosesTheKeyboardOnItsRelease() {
        let (state, host, _) = keyboard(controller: true)
        state.controller(pad(), pad { $0.b = true })
        #expect(state.open)
        state.controller(pad { $0.b = true }, pad())
        #expect(host.closes == 1 && !state.open)
    }

    @Test func theMenuOpeningLetsGoOfHeldKeysButKeepsTheLatches() {
        let (state, host, _) = keyboard(controller: true)
        state.settled()
        state.controller(pad(), pad { $0.leftStickButton = true })
        state.controller(pad(), pad { $0.a = true })
        host.keys.removeAll()
        state.releaseInput()
        #expect(host.keys.map(\.code) == [q] && !host.keys[0].down)
        #expect(state.latched == [KeyCode.leftShift] && state.open)
    }
}

// MARK: The keyboard in the stream

private final class KeySink: StreamInputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var keyLog: [(code: Int16, pressed: Bool, modifiers: KeyModifiers)] = []
    private var stateLog: [ControllerState] = []
    var keys: [(code: Int16, pressed: Bool, modifiers: KeyModifiers)] { lock.withLock { keyLog } }
    var states: [ControllerState] { lock.withLock { stateLog } }

    func sendControllerArrival(
        number: UInt8, activeGamepadMask: UInt16, type: ControllerType, supportedButtons: ControllerButtons,
        capabilities: ControllerCapabilities
    ) throws(InputError) {}
    func sendController(number: UInt8, activeGamepadMask: UInt16, state: ControllerState) throws(InputError) {
        lock.withLock { stateLog.append(state) }
    }
    func sendMouseMove(deltaX: Int16, deltaY: Int16) throws(InputError) {}
    func sendMouseButton(_ button: MouseButton, pressed: Bool) throws(InputError) {}
    func sendKey(code: Int16, pressed: Bool, modifiers: KeyModifiers, nonNormalized: Bool) throws(InputError) {
        lock.withLock { keyLog.append((code, pressed, modifiers)) }
    }
    func sendText(_ text: String) throws(InputError) {}
    func sendServerCommand(_ id: UInt8) throws(InputError) {}
    func sendHighResolutionScroll(amount: Int16) throws(InputError) {}
    func sendHighResolutionHorizontalScroll(amount: Int16) throws(InputError) {}
    func sendControllerMotion(number: UInt8, sensor: MotionSensor, x: Float, y: Float, z: Float) throws(InputError) {}
    func sendControllerBattery(number: UInt8, state: BatteryState, percentage: UInt8) throws(InputError) {}
    func sendControllerTouch(
        number: UInt8, _ type: TouchEventType, pointerID: UInt32, x: Float, y: Float, pressure: Float
    ) throws(InputError) {}
    func sendScroll(clicks: Int8) throws(InputError) {}
    func sendHorizontalScroll(clicks: Int8) throws(InputError) {}
    func sendMousePosition(x: Int16, y: Int16, referenceWidth: Int16, referenceHeight: Int16) throws(InputError) {}
    func sendMouseMoveAsMousePosition(deltaX: Int16, deltaY: Int16, referenceWidth: Int16, referenceHeight: Int16) throws(InputError) {}
    func sendTouch(
        _ type: TouchEventType, pointerID: UInt32, x: Float, y: Float, pressureOrDistance: Float,
        contactAreaMajor: Float, contactAreaMinor: Float, rotation: UInt16?) throws(InputError) {}
    func sendPen(
        _ type: TouchEventType, tool: PenTool, buttons: PenButtons, x: Float, y: Float, pressureOrDistance: Float,
        contactAreaMajor: Float, contactAreaMinor: Float, rotation: UInt16?, tilt: UInt8?) throws(InputError) {}
}

@MainActor
private final class KeyboardSteps: StreamSteps {
    let pcName = "Gaming-PC"
    let appName = "Desktop"
    let events: AsyncStream<StreamEvent>
    private let continuation: AsyncStream<StreamEvent>.Continuation
    let sink = KeySink()
    var input: (any StreamInputSink)? { sink }

    init() {
        (events, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
    }

    func launch(display: DisplayInfo) async throws(LaunchFailure) {}
    func connect() async throws(StreamError) { continuation.yield(.connectionStarted) }
    func stop() async { continuation.finish() }
    func quitApp() async -> Bool { true }
}

@MainActor
@Suite struct FullKeyboardStreamTests {
    private func streaming() async -> (StreamController, KeyboardSteps, ManualClock) {
        let steps = KeyboardSteps()
        let clock = ManualClock()
        let controller = StreamController(fullKeyboard: FullKeyboardState(clock: clock, hasController: { true })) { steps }
        controller.start(display: DisplayInfo(pixelWidth: 1920, pixelHeight: 1080, maxFramesPerSecond: 60))
        for _ in 0..<500 where controller.phase != .streaming { try? await Task.sleep(for: .milliseconds(2)) }
        controller.loaderEnded()
        return (controller, steps, clock)
    }

    @Test func theKeysReachThePCWithTheModifiersThatAreDown() async {
        let (controller, steps, clock) = await streaming()
        controller.toggleFullKeyboard()
        let keyboard = controller.fullKeyboard
        keyboard.touchDown(KeyCode.leftControl)
        clock.advance(FullKeyboardState.latchHoldMs)
        keyboard.touchUp(KeyCode.leftControl)
        keyboard.touchDown(KeyCode.character("C"))
        keyboard.touchUp(KeyCode.character("C"))
        let c = KeyboardMapping.keyCode(UInt8(ascii: "C"))
        #expect(steps.sink.keys.map(\.code) == [KeyboardMapping.keyCode(VirtualKey.leftControl), c, c])
        #expect(steps.sink.keys.allSatisfy { $0.modifiers == .control })
        // Closing lets go of the latched Control at the PC
        controller.closeFullKeyboard()
        #expect(steps.sink.keys.last.map { $0.code == KeyboardMapping.keyCode(VirtualKey.leftControl) && !$0.pressed } == true)
    }

    @Test func whileTheKeyboardIsUpTheControllersDriveItAndThePCGetsANeutralController() async throws {
        let (controller, steps, _) = await streaming()
        let input = try #require(controller.input)
        let gamepad = GCController.withExtendedGamepad()
        input.attach(gamepad)
        let id = ObjectIdentifier(gamepad)
        input.send(pad { $0.x = true }, from: id)
        #expect(steps.sink.states.last == ControllerState(buttons: [.x]))
        controller.toggleFullKeyboard()
        // What was held came up at the PC
        #expect(steps.sink.states.last == ControllerState())
        controller.fullKeyboard.settled()
        let sent = steps.sink.states.count
        input.send(pad(), from: id)
        input.send(pad { $0.a = true }, from: id)
        input.send(pad(), from: id)
        #expect(steps.sink.states.count == sent, "nothing of the controller reached the game")
        let q = KeyboardMapping.keyCode(UInt8(ascii: "Q"))
        #expect(steps.sink.keys.map(\.code) == [q, q], "A typed the focused key")
        // B closes the keyboard: the controller is the game's again
        input.send(pad { $0.b = true }, from: id)
        input.send(pad(), from: id)
        #expect(!controller.fullKeyboard.open && input.padCapture == nil)
        input.send(pad { $0.y = true }, from: id)
        #expect(steps.sink.states.last == ControllerState(buttons: [.y]))
    }
}
