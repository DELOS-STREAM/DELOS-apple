import DelosCore
import DelosData
import DelosInput
import Foundation
import Testing
@testable import DelosUI

/// Counts what the touch screen sends to the PC.
private final class TouchSink: StreamInputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var touchEvents = 0
    var touches: Int { lock.withLock { touchEvents } }

    func sendControllerArrival(
        number: UInt8, activeGamepadMask: UInt16, type: ControllerType, supportedButtons: ControllerButtons,
        capabilities: ControllerCapabilities
    ) throws(InputError) {}
    func sendController(number: UInt8, activeGamepadMask: UInt16, state: ControllerState) throws(InputError) {}
    func sendControllerMotion(number: UInt8, sensor: MotionSensor, x: Float, y: Float, z: Float) throws(InputError) {}
    func sendControllerBattery(number: UInt8, state: BatteryState, percentage: UInt8) throws(InputError) {}
    func sendControllerTouch(
        number: UInt8, _ type: TouchEventType, pointerID: UInt32, x: Float, y: Float, pressure: Float) throws(InputError) {}
    func sendMouseMove(deltaX: Int16, deltaY: Int16) throws(InputError) {}
    func sendMouseButton(_ button: MouseButton, pressed: Bool) throws(InputError) {}
    func sendKey(code: Int16, pressed: Bool, modifiers: KeyModifiers, nonNormalized: Bool) throws(InputError) {}
    func sendText(_ text: String) throws(InputError) {}
    func sendServerCommand(_ id: UInt8) throws(InputError) {}
    func sendScroll(clicks: Int8) throws(InputError) {}
    func sendHorizontalScroll(clicks: Int8) throws(InputError) {}
    func sendHighResolutionScroll(amount: Int16) throws(InputError) {}
    func sendHighResolutionHorizontalScroll(amount: Int16) throws(InputError) {}
    func sendMousePosition(x: Int16, y: Int16, referenceWidth: Int16, referenceHeight: Int16) throws(InputError) {}
    func sendMouseMoveAsMousePosition(deltaX: Int16, deltaY: Int16, referenceWidth: Int16, referenceHeight: Int16) throws(InputError) {}
    func sendTouch(
        _ type: TouchEventType, pointerID: UInt32, x: Float, y: Float, pressureOrDistance: Float,
        contactAreaMajor: Float, contactAreaMinor: Float, rotation: UInt16?
    ) throws(InputError) { lock.withLock { touchEvents += 1 } }
    func sendPen(
        _ type: TouchEventType, tool: PenTool, buttons: PenButtons, x: Float, y: Float, pressureOrDistance: Float,
        contactAreaMajor: Float, contactAreaMinor: Float, rotation: UInt16?, tilt: UInt8?) throws(InputError) {}
}

/// A stream that is up at once.
@MainActor
private final class TouchSteps: StreamSteps {
    let pcName = "Gaming-PC"
    let appName = "Desktop"
    let events: AsyncStream<StreamEvent>
    private let continuation: AsyncStream<StreamEvent>.Continuation
    let sink = TouchSink()
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
private final class Kept {
    var modes: [TouchMode] = []
    var notices: [Bool] = []
    var fullKeyboard = 0
}

private let area = StreamController.TouchArea(width: 1920, height: 1080)

@MainActor
private func streaming(_ configure: (inout TouchOptions) -> Void = { _ in }, zoomStore: ZoomPanStore? = nil) async
    -> (StreamController, TouchSteps, Kept)
{
    let steps = TouchSteps()
    let kept = Kept()
    let controller = StreamController { steps }
    var options = TouchOptions()
    configure(&options)
    controller.touchOptions = options
    controller.zoomStore = zoomStore
    controller.touchPicture = TouchPicture(width: 1920, height: 1080, fit: .fit)
    controller.touchModeChosen = { kept.modes.append($0) }
    controller.zoomNotice = { kept.notices.append($0) }
    controller.fullKeyboardToggle = { kept.fullKeyboard += 1 }
    controller.start(display: DisplayInfo(pixelWidth: 1920, pixelHeight: 1080, maxFramesPerSecond: 60))
    for _ in 0..<500 where controller.phase != .streaming { try? await Task.sleep(for: .milliseconds(2)) }
    controller.loaderEnded()
    controller.surfaceLaidOut(area)
    return (controller, steps, kept)
}

@MainActor
@Suite struct StreamTouchTests {
    @Test func theMousePageChoosesTheModeAndARememberedOneIsKept() async {
        let (controller, _, kept) = await streaming { $0.rememberMode = true }
        #expect(controller.allowsTouchModeChange && controller.rememberMouseMode)
        #expect(controller.touchModeOptionValues.map(\.value) == [0, 1, 2, 3, 4, 5])
        #expect(controller.touchModeOptionValues[2].labelKey == "mouse_mode_track_pad_natural")
        #expect(controller.touchModeOptionValues[2].helpKey == "help_mouse_mode_list_2")
        #expect(controller.selectedTouchMode == 0)
        controller.setTouchMode(3)
        #expect(controller.selectedTouchMode == 3 && kept.modes == [.trackpadGaming])
    }

    @Test func zoomSensitivityAndTheLocalPointerToggle() async {
        let (controller, _, kept) = await streaming()
        controller.toggleZoom()
        #expect(controller.zoomOn && kept.notices == [true])
        // A new mode leaves the zoom mode
        controller.setTouchMode(2)
        #expect(!controller.zoomOn)
        controller.toggleTouchSensitivity()
        #expect(controller.touchSensitivityOn)
        controller.toggleLocalCursor()
        #expect(controller.localCursorVisible && controller.input?.localCursor == true && controller.inputGrabbed)
        controller.toggleLocalCursor()
        #expect(!controller.localCursorVisible && controller.input?.localCursor == false)
    }

    @Test func fingersReachThePCAndFourAndFiveFingerTapsOpenTheFullKeyboardAndTheMenu() async {
        let (controller, steps, kept) = await streaming { $0.multiTouchGestures = true }
        controller.touch(1, .began, at: CGPoint(x: 500, y: 300), area: area, time: 10)
        controller.touch(1, .ended, at: CGPoint(x: 500, y: 300), area: area, time: 10.05)
        #expect(steps.sink.touches == 2)

        func tap(_ count: Int, at time: TimeInterval) {
            let samples = (0..<count).map { TouchSample(id: 10 + $0, x: Double(200 + $0 * 200), y: 300) }
            controller.touches(.began, samples, area: area, time: time)
            controller.touches(.ended, samples, area: area, time: time + 0.1)
        }
        tap(4, at: 20)
        #expect(kept.fullKeyboard == 1 && !controller.menuOpen)
        tap(5, at: 30)
        #expect(controller.menuOpen)
    }

    @Test func aRememberedZoomComesBackAndIsKeptWhenTheStreamEnds() async {
        let suite = "stream-touch-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = ZoomPanStore(suiteName: suite)
        store.save(ZoomPanStore.Saved(scale: 2, x: -500, y: -200))
        let (controller, _, _) = await streaming({ $0.rememberZoomPan = true }, zoomStore: store)
        #expect(controller.videoZoom == VideoZoom(scale: 2, tx: -500, ty: -200))
        await controller.leave(quit: false)
        #expect(store.load() == ZoomPanStore.Saved(scale: 2, x: -500, y: -200))
    }
}
