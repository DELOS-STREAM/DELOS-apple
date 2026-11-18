import DelosCore
import DelosData
import DelosInput
import Foundation
import Testing
@testable import DelosUI

/// Takes the input and records nothing: the tests read the controller's state.
private final class SilentSink: StreamInputSink, @unchecked Sendable {
    func sendControllerArrival(
        number: UInt8, activeGamepadMask: UInt16, type: ControllerType, supportedButtons: ControllerButtons,
        capabilities: ControllerCapabilities
    ) throws(InputError) {}
    func sendController(number: UInt8, activeGamepadMask: UInt16, state: ControllerState) throws(InputError) {}
    func sendMouseMove(deltaX: Int16, deltaY: Int16) throws(InputError) {}
    func sendMouseButton(_ button: MouseButton, pressed: Bool) throws(InputError) {}
    func sendKey(code: Int16, pressed: Bool, modifiers: KeyModifiers, nonNormalized: Bool) throws(InputError) {}
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

/// A stream that is up at once; counts its stops.
@MainActor
private final class Steps: StreamSteps {
    let pcName = "Gaming-PC"
    let appName = "Desktop"
    let events: AsyncStream<StreamEvent>
    private let continuation: AsyncStream<StreamEvent>.Continuation
    let sink = SilentSink()
    var input: (any StreamInputSink)? { sink }
    /// `connect` waits for ``finishConnect()``.
    var holdsConnect = false
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var stops = 0

    init() {
        (events, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
    }

    func launch(display: DisplayInfo) async throws(LaunchFailure) {}

    func connect() async throws(StreamError) {
        if holdsConnect { await withCheckedContinuation { gate = $0 } }
        continuation.yield(.connectionStarted)
    }

    func finishConnect() {
        gate?.resume()
        gate = nil
    }

    var isConnecting: Bool { gate != nil }

    /// The core reports the connection lost.
    func terminate() {
        continuation.yield(.terminated(.noVideoTraffic))
    }

    func stop() async {
        stops += 1
        finishConnect()
        continuation.finish()
    }

    func quitApp() async -> Bool { true }
}

@MainActor
private final class Brightness: ScreenBrightness {
    var percent = 62
    private var original: Int?

    func set(_ percent: Int) {
        if original == nil { original = self.percent }
        self.percent = percent
    }

    func restore() {
        if let original { percent = original }
        original = nil
    }
}

@MainActor
private final class Made {
    var steps: [Steps] = []
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private let screen = DisplayInfo(pixelWidth: 2048, pixelHeight: 2732, maxFramesPerSecond: 120)

/// A running stream with Picture in Picture turned on, past its launch scene.
@MainActor
private func streaming(
    enabled: Bool = true, grace: Duration = .seconds(30), brightness: Brightness? = nil, holdsFirstConnect: Bool = false
) async -> (StreamController, Made) {
    let made = Made()
    let controller = StreamController(brightness: brightness) {
        let steps = Steps()
        steps.holdsConnect = holdsFirstConnect && made.steps.isEmpty
        made.steps.append(steps)
        return steps
    }
    controller.pictureInPictureEnabled = enabled
    controller.pictureInPictureGrace = grace
    controller.start(display: screen)
    if !holdsFirstConnect {
        await eventually { controller.phase == .streaming }
        controller.loaderEnded()
    }
    return (controller, made)
}

/// Picture in Picture's observer mode (`checkbox_enable_pip`, Android's `StreamWindowController`).
@MainActor
@Suite struct StreamPictureInPictureTests {
    @Test func theWindowMayStartOnlyWhileTheStreamRunsWithTheSettingOn() async {
        let (connecting, made) = await streaming(holdsFirstConnect: true)
        await eventually { made.steps.first?.isConnecting == true }
        #expect(connecting.phase == .connecting)
        #expect(!connecting.pictureInPictureMayStart)
        made.steps[0].finishConnect()
        await eventually { connecting.phase == .streaming }
        #expect(connecting.pictureInPictureMayStart)

        let (off, _) = await streaming(enabled: false)
        #expect(off.phase == .streaming && !off.pictureInPictureMayStart)

        // A failed stream has nothing to show
        let (failed, failedMade) = await streaming()
        failedMade.steps[0].terminate()
        await eventually { failed.phase != .streaming }
        #expect(!failed.pictureInPictureMayStart)
    }

    @Test func theWindowKeepsTheStreamAndTheInputStops() async throws {
        let brightness = Brightness()
        let (controller, made) = await streaming(brightness: brightness)
        controller.setBrightness(30)
        controller.toggleFullKeyboard()
        controller.openMenu()
        let input = try #require(controller.input)
        #expect(controller.menuOpen && controller.fullKeyboard.open)

        controller.pictureInPicture(.starting)
        #expect(controller.pictureInPictureShown)
        // Observer mode: nothing reaches the PC, the menu and the keyboards are closed, the brightness is the system's
        #expect(input.paused)
        #expect(!controller.menuOpen && !controller.fullKeyboard.open && !controller.systemKeyboardShown)
        #expect(brightness.percent == 62)

        // The app leaves: the connection stays
        #expect(controller.enteredBackground() == nil)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(made.steps[0].stops == 0)
        #expect(controller.phase == .streaming && !controller.suspended)
    }

    @Test func backFromTheWindowTheStreamIsThePlayersAgain() async throws {
        let brightness = Brightness()
        let (controller, made) = await streaming(brightness: brightness)
        controller.setBrightness(30)
        controller.pictureInPicture(.starting)
        _ = controller.enteredBackground()

        // The restore button: the stream is shown in the app again, the same connection
        controller.pictureInPicture(.stopped(restored: true))
        controller.returnedToForeground()
        let input = try #require(controller.input)
        #expect(!controller.pictureInPictureShown)
        #expect(!input.paused)
        #expect(brightness.percent == 30)
        #expect(made.steps.count == 1 && made.steps[0].stops == 0)
        #expect(controller.phase == .streaming)
    }

    @Test func returningToTheAppWhileTheWindowIsUpResumesTheInput() async throws {
        let (controller, made) = await streaming()
        controller.pictureInPicture(.starting)
        _ = controller.enteredBackground()
        controller.returnedToForeground()
        #expect(controller.input?.paused == false)
        // The window closes afterwards (the app stops it): nothing more happens
        controller.pictureInPicture(.stopped(restored: false))
        #expect(made.steps.count == 1 && made.steps[0].stops == 0)
        #expect(controller.phase == .streaming)
    }

    @Test func theLaunchSceneKeepsTheInputAfterTheWindow() async throws {
        let made = Made()
        let controller = StreamController {
            let steps = Steps()
            made.steps.append(steps)
            return steps
        }
        controller.pictureInPictureEnabled = true
        controller.start(display: screen)
        await eventually { controller.phase == .streaming }
        controller.pictureInPicture(.starting)
        // The scene ends while the window is up: the input stays off
        controller.loaderEnded()
        #expect(controller.input?.paused == true)
        controller.returnedToForeground()
        #expect(controller.input?.paused == false)
    }

    @Test func closingTheWindowInTheBackgroundClosesTheStreamAndTheReturnConnectsAgain() async {
        let (controller, made) = await streaming()
        controller.pictureInPicture(.starting)
        _ = controller.enteredBackground()
        controller.pictureInPicture(.stopped(restored: false))
        await eventually { made.steps[0].stops == 1 }
        #expect(made.steps[0].stops == 1)
        #expect(controller.suspended && controller.phase == .connecting)
        #expect(!controller.pictureInPictureShown)

        controller.returnedToForeground()
        await eventually { made.steps.count == 2 && controller.phase == .streaming }
        #expect(controller.phase == .streaming)
    }

    @Test func withoutTheWindowTheBackgroundClosesTheStreamAfterTheGrace() async {
        let (controller, made) = await streaming(grace: .milliseconds(20))
        let wait = controller.enteredBackground()
        // The window may still come: the stream waits
        #expect(made.steps[0].stops == 0 && !controller.suspended)
        await wait?.value
        #expect(made.steps[0].stops == 1)
        #expect(controller.suspended && controller.phase == .connecting)
    }

    @Test func theWindowThatStartsInTheGraceKeepsTheStream() async {
        let (controller, made) = await streaming(grace: .milliseconds(50))
        let wait = controller.enteredBackground()
        controller.pictureInPicture(.starting)
        await wait?.value
        #expect(made.steps[0].stops == 0)
        #expect(controller.pictureInPictureShown && !controller.suspended)
    }

    @Test func aWindowThatFailsInTheBackgroundClosesTheStreamAtOnce() async {
        let (controller, made) = await streaming()
        _ = controller.enteredBackground()
        controller.pictureInPicture(.failed)
        await eventually { made.steps[0].stops == 1 }
        #expect(made.steps[0].stops == 1)
        #expect(controller.suspended)
    }

    @Test func aReturnInTheGraceKeepsTheStream() async {
        let (controller, made) = await streaming(grace: .milliseconds(20))
        let wait = controller.enteredBackground()
        controller.returnedToForeground()
        await wait?.value
        #expect(made.steps[0].stops == 0)
        #expect(controller.phase == .streaming && !controller.suspended)
    }

    @Test func withTheSettingOffTheBackgroundClosesTheStreamAtOnce() async {
        let (controller, made) = await streaming(enabled: false)
        await controller.enteredBackground()?.value
        #expect(made.steps[0].stops == 1)
        #expect(controller.suspended)
        controller.pictureInPicture(.starting)
        #expect(!controller.pictureInPictureShown)
    }
}
