import DelosCore
import Foundation
import GameController
import Testing
@testable import DelosInput

/// Everything that reaches the PC, in order.
private final class EventSink: StreamInputSink, @unchecked Sendable {
    enum Sent: Equatable {
        case arrival(number: UInt8, mask: UInt16, type: ControllerType, capabilities: ControllerCapabilities)
        case state(number: UInt8, mask: UInt16, ControllerState)
        case motion(number: UInt8, MotionSensor)
        case battery(number: UInt8, BatteryState, UInt8)
        case touch(number: UInt8, TouchEventType, pointer: UInt32)
        case mouseMove(Int16, Int16)
        case mouseButton(MouseButton, Bool)
        case key(Int16, Bool, KeyModifiers)
        case scroll(Int8)
        case horizontalScroll(Int8)
        case highResolutionScroll(Int16)
        case highResolutionHorizontalScroll(Int16)
    }

    private let lock = NSLock()
    private var log: [Sent] = []
    var refusesTouch = false

    var sent: [Sent] { lock.withLock { log } }
    func clear() { lock.withLock { log.removeAll() } }
    private func add(_ event: Sent) { lock.withLock { log.append(event) } }

    var states: [ControllerState] {
        sent.compactMap { if case let .state(_, _, state) = $0 { state } else { nil } }
    }
    var keys: [(code: Int16, pressed: Bool, modifiers: KeyModifiers)] {
        sent.compactMap { if case let .key(code, pressed, modifiers) = $0 { (code, pressed, modifiers) } else { nil } }
    }

    func sendControllerArrival(
        number: UInt8, activeGamepadMask: UInt16, type: ControllerType, supportedButtons: ControllerButtons,
        capabilities: ControllerCapabilities
    ) throws(InputError) {
        add(.arrival(number: number, mask: activeGamepadMask, type: type, capabilities: capabilities))
    }
    func sendController(number: UInt8, activeGamepadMask: UInt16, state: ControllerState) throws(InputError) {
        add(.state(number: number, mask: activeGamepadMask, state))
    }
    func sendControllerMotion(number: UInt8, sensor: MotionSensor, x: Float, y: Float, z: Float) throws(InputError) {
        add(.motion(number: number, sensor))
    }
    func sendControllerBattery(number: UInt8, state: BatteryState, percentage: UInt8) throws(InputError) {
        add(.battery(number: number, state, percentage))
    }
    func sendControllerTouch(
        number: UInt8, _ type: TouchEventType, pointerID: UInt32, x: Float, y: Float, pressure: Float
    ) throws(InputError) {
        if refusesTouch { throw .unsupportedByHost }
        add(.touch(number: number, type, pointer: pointerID))
    }
    func sendMouseMove(deltaX: Int16, deltaY: Int16) throws(InputError) { add(.mouseMove(deltaX, deltaY)) }
    func sendMouseButton(_ button: MouseButton, pressed: Bool) throws(InputError) { add(.mouseButton(button, pressed)) }
    func sendKey(code: Int16, pressed: Bool, modifiers: KeyModifiers, nonNormalized: Bool) throws(InputError) {
        add(.key(code, pressed, modifiers))
    }
    func sendText(_ text: String) throws(InputError) {}
    func sendServerCommand(_ id: UInt8) throws(InputError) {}
    func sendScroll(clicks: Int8) throws(InputError) { add(.scroll(clicks)) }
    func sendHorizontalScroll(clicks: Int8) throws(InputError) { add(.horizontalScroll(clicks)) }
    func sendHighResolutionScroll(amount: Int16) throws(InputError) { add(.highResolutionScroll(amount)) }
    func sendHighResolutionHorizontalScroll(amount: Int16) throws(InputError) { add(.highResolutionHorizontalScroll(amount)) }
}

private func vk(_ usage: Int) -> Int16 { KeyboardMapping.keyCode(KeyboardMapping.virtualKey(hidUsage: usage)!) }

/// The clock the input reads and the events it reported.
@MainActor
private final class Record {
    var now: Int64 = 0
    var events: [GameInput.Event] = []
}

@MainActor
@Suite struct GameInputKeyboardTests {
    @Test func focusLossReleasesEveryHeldKeyLastPressedFirst() {
        let sink = EventSink()
        let input = GameInput(sink: sink) {}
        for usage in [0xE0, 0x04, 0x05] { input.key(usage, pressed: true) }
        sink.clear()
        input.releaseKeys()
        #expect(sink.keys.map(\.code) == [vk(0x05), vk(0x04), vk(0xE0)])
        #expect(sink.keys.allSatisfy { !$0.pressed && $0.modifiers.isEmpty })
        // Their releases afterwards send nothing, and nothing held sends nothing
        sink.clear()
        input.key(0x04, pressed: false)
        input.releaseKeys()
        #expect(sink.sent.isEmpty)
    }

    @Test func theRightAltIsTheWindowsKeyWhenOn() {
        let sink = EventSink()
        var options = ControllerOptions()
        options.rightAltAsMeta = true
        let input = GameInput(sink: sink, options: options) {}
        input.key(0xE6, pressed: true)
        #expect(sink.keys.first! == (KeyboardMapping.keyCode(0x5B), true, KeyModifiers.meta))
        input.key(0xE6, pressed: false)
        #expect(sink.keys.last!.code == KeyboardMapping.keyCode(0x5B) && !sink.keys.last!.pressed)
    }

    @Test func ctrlAltShiftZReleasesTheInputAndQAsksToQuit() async throws {
        let sink = EventSink()
        let record = Record()
        let input = GameInput(sink: sink) {}
        input.onEvent = { record.events.append($0) }
        for usage in [0xE0, 0xE2, 0xE1, 0x1D] { input.key(usage, pressed: true) }
        for usage in [0x1D, 0xE0, 0xE2, 0xE1] { input.key(usage, pressed: false) }
        #expect(!sink.keys.contains { $0.code == vk(0x1D) }, "the Z never reached the PC")
        #expect(input.inputGrabbed, "the grab goes off a moment later")
        try await Task.sleep(for: .milliseconds(400))
        #expect(!input.inputGrabbed && record.events == [.keyCombo(.toggleInputGrab)])
        // Released, keys stay with the system
        sink.clear()
        input.key(0x04, pressed: true)
        input.key(0x04, pressed: false)
        #expect(sink.sent.isEmpty)
        // Q still works, and C grabs the input again
        for usage in [0xE0, 0xE2, 0xE1, 0x14] { input.key(usage, pressed: true) }
        for usage in [0x14, 0xE0, 0xE2, 0xE1] { input.key(usage, pressed: false) }
        for usage in [0xE0, 0xE2, 0xE1, 0x06] { input.key(usage, pressed: true) }
        for usage in [0x06, 0xE0, 0xE2, 0xE1] { input.key(usage, pressed: false) }
        #expect(record.events.suffix(2) == [.keyCombo(.quit), .keyCombo(.toggleLocalCursor)])
        #expect(input.inputGrabbed)
    }

    @Test func aKeyHeldWhenTheGrabGoesOffIsStillReleasedAtThePC() async throws {
        let sink = EventSink()
        let input = GameInput(sink: sink) {}
        input.key(0x04, pressed: true)
        for usage in [0xE0, 0xE2, 0xE1, 0x1D] { input.key(usage, pressed: true) }
        for usage in [0x1D, 0xE0, 0xE2, 0xE1] { input.key(usage, pressed: false) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(!input.inputGrabbed)
        input.key(0x04, pressed: false)
        #expect(sink.keys.last! == (vk(0x04), false, []))
    }

    @Test func recordedKeysOpenTheMenuOnTheLastReleaseAndKeepTheCompletingKey() {
        let sink = EventSink()
        var opened = 0
        let input = GameInput(sink: sink, menuButtons: [.key(0xE4), .key(0x3A)]) { opened += 1 }
        input.key(0xE4, pressed: true)
        input.key(0x3A, pressed: true)
        #expect(sink.keys.map(\.code) == [vk(0xE4)], "F1 completed it and stays off the PC")
        input.key(0x3A, pressed: false)
        #expect(opened == 0)
        input.key(0xE4, pressed: false)
        #expect(opened == 1)
        #expect(sink.keys.map(\.pressed) == [true, false], "right Control got its release")
    }
}

// MARK: - Controllers

@MainActor
@Suite struct GameInputControllerTests {
    private func snapshot(_ change: (inout GamepadSnapshot) -> Void) -> GamepadSnapshot {
        var pad = GamepadSnapshot()
        change(&pad)
        return pad
    }

    @Test func withMultipleControllersOffEveryControllerIsPlayerOneFused() {
        let sink = EventSink()
        var options = ControllerOptions()
        options.multiController = false
        let input = GameInput(sink: sink, options: options) {}
        let first = GCController.withExtendedGamepad(), second = GCController.withExtendedGamepad()
        input.attach(first)
        input.attach(second)
        let arrivals = sink.sent.compactMap { if case let .arrival(number, mask, _, _) = $0 { (number, mask) } else { nil } }
        #expect(arrivals.count == 2 && arrivals.allSatisfy { $0 == (0, 1) })
        sink.clear()
        input.send(snapshot { $0.a = true }, from: ObjectIdentifier(first))
        input.send(snapshot { $0.b = true }, from: ObjectIdentifier(second))
        #expect(sink.sent.last == .state(number: 0, mask: 1, ControllerState(buttons: [.a, .b])))
    }

    @Test func withMultipleControllersOnEachGetsItsNumber() {
        let sink = EventSink()
        let input = GameInput(sink: sink) {}
        let first = GCController.withExtendedGamepad(), second = GCController.withExtendedGamepad()
        input.attach(first)
        input.attach(second)
        sink.clear()
        input.send(snapshot { $0.b = true }, from: ObjectIdentifier(second))
        #expect(sink.sent.last == .state(number: 1, mask: 0b11, ControllerState(buttons: [.b])))
    }

    @Test func aHeldStartTogglesTheMouseEmulationAndAClickReachesThePC() {
        let sink = EventSink()
        let record = Record()
        var options = ControllerOptions()
        options.motionSensors = false
        let input = GameInput(sink: sink, options: options) {}
        input.clock = { record.now }
        input.onEvent = { record.events.append($0) }
        let pad = GCController.withExtendedGamepad()
        input.attach(pad)
        let id = ObjectIdentifier(pad)
        input.send(snapshot { $0.menu = true }, from: id)
        record.now = 800
        input.send(GamepadSnapshot(), from: id)
        #expect(record.events == [.mouseEmulation(on: true)])
        sink.clear()
        input.send(snapshot { $0.a = true }, from: id)
        #expect(sink.sent == [.mouseButton(.left, true), .state(number: 0, mask: 1, ControllerState())])
        input.send(GamepadSnapshot(), from: id)
        // A second long Start, not quick after the first: back to the controller
        record.now = 2000
        input.send(snapshot { $0.menu = true }, from: id)
        record.now = 2800
        input.send(GamepadSnapshot(), from: id)
        #expect(record.events == [.mouseEmulation(on: true), .mouseEmulation(on: false)])
        sink.clear()
        input.send(snapshot { $0.a = true }, from: id)
        #expect(sink.sent == [.state(number: 0, mask: 1, ControllerState(buttons: [.a]))])
    }

    @Test func aControllerWithMotionThatIsNotPlayStationIsAnnouncedGenericWithItsSensors() {
        let sink = EventSink()
        let record = Record()
        let input = GameInput(sink: sink) {}
        input.onEvent = { record.events.append($0) }
        // GameController's virtual gamepad has a motion profile and no PlayStation type
        let pad = GCController.withExtendedGamepad()
        #expect(pad.motion != nil)
        input.attach(pad)
        guard case let .arrival(_, _, type, capabilities)? = sink.sent.first else { Issue.record("no arrival"); return }
        #expect(type == .unknown && capabilities.contains(.accelerometer))
        #expect(record.events == [.controllerTypeChanged])
        // Without the controller's sensors (Settings) it is announced as it is, without them
        let plainSink = EventSink()
        var options = ControllerOptions()
        options.motionSensors = false
        let plain = GameInput(sink: plainSink, options: options) {}
        plain.attach(GCController.withExtendedGamepad())
        guard case let .arrival(_, _, _, plainCapabilities)? = plainSink.sent.first else { Issue.record("no arrival"); return }
        #expect(!plainCapabilities.contains(.accelerometer) && !plainCapabilities.contains(.gyroscope))
    }

    @Test func theTouchpadIsTheControllersOrTheMouseWhenTheHostRefusesIt() {
        let sink = EventSink()
        let input = GameInput(sink: sink) {}
        let pad = GCController.withExtendedGamepad()
        input.attach(pad)
        let id = ObjectIdentifier(pad)
        sink.clear()
        input.touch(0, x: -1, y: 1, from: id)
        input.touch(0, x: 0.5, y: 0.5, from: id)
        input.touch(0, x: 0, y: 0, from: id)
        #expect(sink.sent == [.touch(number: 0, .down, pointer: 0), .touch(number: 0, .move, pointer: 0), .touch(number: 0, .up, pointer: 0)])
        sink.refusesTouch = true
        sink.clear()
        input.touch(0, x: 0.1, y: 0.1, from: id)
        input.touch(0, x: 0.2, y: 0.1, from: id)
        #expect(sink.sent.count == 1, "from the refusal on the touchpad moves the mouse")
        if case let .mouseMove(dx, dy) = sink.sent.first { #expect(dx > 0 && dy == 0) } else { Issue.record("no mouse move") }
    }
}
