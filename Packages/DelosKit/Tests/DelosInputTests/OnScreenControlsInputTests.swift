import DelosCore
import Foundation
import Testing
@testable import DelosInput

/// Records the controller states that reach the PC.
private final class ControllerSink: StreamInputSink, @unchecked Sendable {
    struct Sent: Equatable {
        let number: UInt8
        let mask: UInt16
        let state: ControllerState
    }

    private let lock = NSLock()
    private var states: [Sent] = []

    var sent: [Sent] { lock.withLock { states } }

    func sendControllerArrival(
        number: UInt8, activeGamepadMask: UInt16, type: ControllerType, supportedButtons: ControllerButtons,
        capabilities: ControllerCapabilities
    ) throws(InputError) {}
    func sendController(number: UInt8, activeGamepadMask: UInt16, state: ControllerState) throws(InputError) {
        lock.withLock { states.append(Sent(number: number, mask: activeGamepadMask, state: state)) }
    }
    func sendMouseMove(deltaX: Int16, deltaY: Int16) throws(InputError) {}
    func sendControllerMotion(number: UInt8, sensor: MotionSensor, x: Float, y: Float, z: Float) throws(InputError) {}
    func sendControllerBattery(number: UInt8, state: BatteryState, percentage: UInt8) throws(InputError) {}
    func sendControllerTouch(
        number: UInt8, _ type: TouchEventType, pointerID: UInt32, x: Float, y: Float, pressure: Float) throws(InputError) {}
    func sendScroll(clicks: Int8) throws(InputError) {}
    func sendHorizontalScroll(clicks: Int8) throws(InputError) {}
    func sendMouseButton(_ button: MouseButton, pressed: Bool) throws(InputError) {}
    func sendKey(code: Int16, pressed: Bool, modifiers: KeyModifiers, nonNormalized: Bool) throws(InputError) {}
    func sendText(_ text: String) throws(InputError) {}
    func sendServerCommand(_ id: UInt8) throws(InputError) {}
    func sendHighResolutionScroll(amount: Int16) throws(InputError) {}
    func sendHighResolutionHorizontalScroll(amount: Int16) throws(InputError) {}
}

/// The on-screen controls as controller 0 (`defaultContext` of DELOS for Android's `ControllerHandler`).
@MainActor
@Suite struct OnScreenControlsInputTests {
    @Test func theControlsAloneAreTheirOwnStateAndJoinAControllerZero() {
        let osc = ControllerState(buttons: [.a, .leftShoulder], leftTrigger: 0xFF, leftStickX: 32766, leftStickY: -12000)
        // The fusion of a player's controllers (`GamepadMapping.fuse`) takes them in as one more source
        #expect(GamepadMapping.fuse([osc]) == osc)
        let fused = GamepadMapping.fuse([ControllerState(buttons: .b, leftStickX: 100), osc])
        #expect(fused.buttons == [.a, .b, .leftShoulder] && fused.leftStickX == 32766 && fused.leftTrigger == 0xFF)
    }

    @Test func theControlsAreControllerZeroWhileTheyAreOn() {
        let sink = ControllerSink()
        let input = GameInput(sink: sink) {}
        input.start()
        defer { input.stop() }
        // A physical controller of this Mac would take number 0 too; the test needs none
        guard sink.sent.isEmpty else { return }
        input.setOnScreenControls(ControllerState())
        input.setOnScreenControls(ControllerState(buttons: .a, rightTrigger: 0xFF))
        #expect(sink.sent.last == .init(number: 0, mask: 1, state: ControllerState(buttons: .a, rightTrigger: 0xFF)))
        // The menu opens: what the controls held is let go at the PC, and nothing is sent while it is open
        input.paused = true
        #expect(sink.sent.last == .init(number: 0, mask: 1, state: ControllerState()))
        let count = sink.sent.count
        input.setOnScreenControls(ControllerState(buttons: .b))
        #expect(sink.sent.count == count)
        input.paused = false
        // Off: controller 0 leaves the mask
        input.setOnScreenControls(nil)
        #expect(sink.sent.last == .init(number: 0, mask: 0, state: ControllerState()))
        let off = sink.sent.count
        input.setOnScreenControls(nil)
        #expect(sink.sent.count == off, "off twice sends nothing more")
    }
}
