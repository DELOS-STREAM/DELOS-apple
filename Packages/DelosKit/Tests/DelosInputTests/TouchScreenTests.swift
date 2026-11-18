import DelosCore
import Foundation
import Testing
@testable import DelosInput

/// What the touch screen sends to the PC, in order.
private final class PointerSink: StreamInputSink, @unchecked Sendable {
    enum Sent: Equatable {
        case move(Int16, Int16)
        case button(MouseButton, Bool)
        case position(Int16, Int16, Int16, Int16)
        case moveAsPosition(Int16, Int16, Int16, Int16)
        case scroll(Int16)
        case horizontalScroll(Int16)
        case touch(TouchEventType, UInt32, Float, Float)
        case pen(TouchEventType, PenTool, Float, Float, UInt8?)
    }

    private let lock = NSLock()
    private var log: [Sent] = []
    /// The host takes touch and pen events.
    var touchSupported = true
    var sent: [Sent] { lock.withLock { log } }
    func clear() { lock.withLock { log.removeAll() } }
    private func add(_ event: Sent) { lock.withLock { log.append(event) } }

    func sendControllerArrival(
        number: UInt8, activeGamepadMask: UInt16, type: ControllerType, supportedButtons: ControllerButtons,
        capabilities: ControllerCapabilities
    ) throws(InputError) {}
    func sendController(number: UInt8, activeGamepadMask: UInt16, state: ControllerState) throws(InputError) {}
    func sendControllerMotion(number: UInt8, sensor: MotionSensor, x: Float, y: Float, z: Float) throws(InputError) {}
    func sendControllerBattery(number: UInt8, state: BatteryState, percentage: UInt8) throws(InputError) {}
    func sendControllerTouch(
        number: UInt8, _ type: TouchEventType, pointerID: UInt32, x: Float, y: Float, pressure: Float) throws(InputError) {}
    func sendMouseMove(deltaX: Int16, deltaY: Int16) throws(InputError) { add(.move(deltaX, deltaY)) }
    func sendMouseButton(_ button: MouseButton, pressed: Bool) throws(InputError) { add(.button(button, pressed)) }
    func sendKey(code: Int16, pressed: Bool, modifiers: KeyModifiers, nonNormalized: Bool) throws(InputError) {}
    func sendText(_ text: String) throws(InputError) {}
    func sendServerCommand(_ id: UInt8) throws(InputError) {}
    func sendScroll(clicks: Int8) throws(InputError) {}
    func sendHorizontalScroll(clicks: Int8) throws(InputError) {}
    func sendHighResolutionScroll(amount: Int16) throws(InputError) { add(.scroll(amount)) }
    func sendHighResolutionHorizontalScroll(amount: Int16) throws(InputError) { add(.horizontalScroll(amount)) }
    func sendMousePosition(x: Int16, y: Int16, referenceWidth: Int16, referenceHeight: Int16) throws(InputError) {
        add(.position(x, y, referenceWidth, referenceHeight))
    }
    func sendMouseMoveAsMousePosition(deltaX: Int16, deltaY: Int16, referenceWidth: Int16, referenceHeight: Int16) throws(InputError) {
        add(.moveAsPosition(deltaX, deltaY, referenceWidth, referenceHeight))
    }
    func sendTouch(
        _ type: TouchEventType, pointerID: UInt32, x: Float, y: Float, pressureOrDistance: Float,
        contactAreaMajor: Float, contactAreaMinor: Float, rotation: UInt16?
    ) throws(InputError) {
        guard touchSupported else { throw .unsupportedByHost }
        add(.touch(type, pointerID, x, y))
    }
    func sendPen(
        _ type: TouchEventType, tool: PenTool, buttons: PenButtons, x: Float, y: Float, pressureOrDistance: Float,
        contactAreaMajor: Float, contactAreaMinor: Float, rotation: UInt16?, tilt: UInt8?
    ) throws(InputError) {
        guard touchSupported else { throw .unsupportedByHost }
        add(.pen(type, tool, x, y, tilt))
    }
}

/// Delayed work that runs when the test moves the clock (Android's `Handler` in Robolectric's paused looper).
@MainActor
private final class ManualScheduler: TouchScheduler {
    final class Item: TouchScheduled {
        let due: Int
        let work: @MainActor () -> Void
        var cancelled = false
        init(due: Int, work: @escaping @MainActor () -> Void) {
            self.due = due
            self.work = work
        }
        func cancel() { cancelled = true }
    }

    private(set) var now = 0
    private var items: [Item] = []

    func schedule(after milliseconds: Int, _ work: @escaping @MainActor () -> Void) -> any TouchScheduled {
        let item = Item(due: now + milliseconds, work: work)
        items.append(item)
        return item
    }

    /// Runs what is due up to [time], in order.
    func advance(to time: Int) {
        while let next = items.filter({ !$0.cancelled && $0.due <= time }).min(by: { $0.due < $1.due }) {
            items.removeAll { $0 === next }
            now = next.due
            next.work()
        }
        now = time
    }
}

@MainActor
private final class Taps: TouchScreenHost {
    var opened: [String] = []
    func toggleKeyboard() { opened.append("keyboard") }
    func toggleFullKeyboard() { opened.append("full keyboard") }
    func showMenu() { opened.append("menu") }
}

/// A 1920 × 1080 surface showing a 1920 × 1080 picture.
private let fullHD = TouchSurface(width: 1920, height: 1080, videoWidth: 1920, videoHeight: 1080, fit: .fit)

@MainActor
private func touchScreen(
    _ mode: TouchMode, configure: (inout TouchOptions) -> Void = { _ in }, external: Bool = false
) -> (TouchScreen, PointerSink, ManualScheduler, Taps) {
    let sink = PointerSink()
    let scheduler = ManualScheduler()
    var options = TouchOptions()
    options.mode = mode
    configure(&options)
    let screen = TouchScreen(sink: sink, options: options, externalDisplay: external, scheduler: scheduler)
    let taps = Taps()
    screen.host = taps
    screen.setSurface(fullHD)
    return (screen, sink, scheduler, taps)
}

private func finger(_ id: Int, _ x: Double, _ y: Double) -> TouchSample { TouchSample(id: id, x: x, y: y) }

@MainActor
@Suite struct TouchScreenTests {
    @Test func aSavedModeIsReadLikeAndroidsAndAnythingElseIsMultiTouch() {
        #expect(TouchMode(saved: "3") == .trackpadGaming)
        #expect(TouchMode(saved: "5") == .mouseSwapped)
        #expect(TouchMode(saved: "6") == .multiTouch)
        #expect(TouchMode(saved: "mouse") == .multiTouch)
        #expect(TouchMode.allCases.map(\.nameKey).first == "mouse_mode_multi_touch")
    }

    @Test func multiTouchPassesTheFingersThroughWithAndroidsPointerIDs() {
        let (screen, sink, _, _) = touchScreen(.multiTouch)
        screen.touches(.began, [finger(10, 960, 540)], time: 0)
        screen.touches(.began, [finger(11, 480, 270)], time: 5)
        screen.touches(.moved, [finger(11, 0, 0)], time: 10)
        screen.touches(.ended, [finger(10, 960, 540)], time: 20)
        // The lowest free id goes to the next finger
        screen.touches(.began, [finger(12, 1920, 1080)], time: 30)
        screen.touches(.cancelled, [finger(11, 0, 0), finger(12, 1920, 1080)], time: 40)
        #expect(sink.sent == [
            .touch(.down, 0, 0.5, 0.5), .touch(.down, 1, 0.25, 0.25),
            .touch(.move, 0, 0.5, 0.5), .touch(.move, 1, 0, 0),
            .touch(.up, 0, 0.5, 0.5), .touch(.down, 0, 1, 1), .touch(.cancelAll, 0, 0, 0),
        ])
    }

    @Test func aHostWithoutTouchGetsTheMouseInstead() {
        let (screen, sink, scheduler, _) = touchScreen(.multiTouch)
        sink.touchSupported = false
        screen.touches(.began, [finger(1, 100, 200)], time: 0)
        screen.touches(.ended, [finger(1, 100, 200)], time: 50)
        // A tap inside the dead zone time: down at the touch, up 100 ms later for games that poll
        #expect(sink.sent == [.position(100, 200, 1920, 1080), .button(.left, true)])
        scheduler.advance(to: 100)
        #expect(sink.sent.last == .button(.left, false))
    }

    @Test func theMouseModeClicksRightOnALongPressAndTheSwappedModeTheOtherWayRound() {
        let (screen, sink, scheduler, _) = touchScreen(.mouse)
        screen.touches(.began, [finger(1, 300, 300)], time: 0)
        scheduler.advance(to: 650)
        screen.touches(.ended, [finger(1, 300, 300)], time: 700)
        #expect(sink.sent == [
            .position(300, 300, 1920, 1080), .button(.left, true), .button(.left, false), .button(.right, true), .button(.right, false),
        ])

        let (swapped, swappedSink, swappedScheduler, _) = touchScreen(.mouseSwapped)
        swapped.touches(.began, [finger(1, 500, 500)], time: 0)
        swapped.touches(.ended, [finger(1, 500, 500)], time: 30)
        swappedScheduler.advance(to: 200)
        #expect(swappedSink.sent == [.position(500, 500, 1920, 1080), .button(.right, true), .button(.right, false)])
    }

    @Test func theSecondFingerScrollsInTheMouseMode() {
        let (screen, sink, _, _) = touchScreen(.mouse)
        screen.touches(.began, [finger(1, 300, 300)], time: 0)
        screen.touches(.began, [finger(2, 600, 300)], time: 10)
        sink.clear()
        screen.touches(.moved, [finger(2, 600, 320)], time: 20)
        #expect(sink.sent == [.scroll(60)])
    }

    @Test func theNaturalTrackpadTapsMovesWithAccelerationAndScrollsWithTwoFingers() {
        let (screen, sink, scheduler, _) = touchScreen(.trackpadNatural)
        screen.touches(.began, [finger(1, 500, 500)], time: 0)
        screen.touches(.ended, [finger(1, 500, 500)], time: 100)
        #expect(sink.sent == [.button(.left, true)])
        scheduler.advance(to: 330)
        #expect(sink.sent == [.button(.left, true), .button(.left, false)])

        sink.clear()
        screen.touches(.began, [finger(1, 500, 500)], time: 1000)
        screen.touches(.moved, [finger(1, 564, 500)], time: 1016)
        // 64 pixels: the cube root of 64 / 8 doubles them
        #expect(sink.sent == [.move(128, 0)])
        screen.touches(.ended, [finger(1, 564, 500)], time: 1200)

        sink.clear()
        screen.touches(.began, [finger(1, 500, 500)], time: 2000)
        screen.touches(.began, [finger(2, 700, 500)], time: 2005)
        screen.touches(.moved, [finger(1, 500, 540), finger(2, 700, 540)], time: 2020)
        screen.touches(.moved, [finger(1, 500, 548), finger(2, 700, 548)], time: 2040)
        // The second finger scrolls: 8 pixels down, 8 × (8/8)^(1/3) × 3 up the wheel
        #expect(sink.sent.contains(.scroll(24)))
    }

    @Test func theGamingTrackpadScalesToItsReferenceAndTheSensitivity() {
        let (screen, sink, _, _) = touchScreen(.trackpadGaming) { $0.touchpadSensitivityX = 200 }
        screen.touches(.began, [finger(1, 500, 500)], time: 0)
        screen.touches(.moved, [finger(1, 596, 554)], time: 10)
        // 96 × 1280/1920 = 64, × 200 % = 128; 54 × 720/1080 = 36
        #expect(sink.sent == [.move(128, 36)])

        let (absolute, absoluteSink, _, _) = touchScreen(.trackpadGaming) { $0.absoluteMouseMode = true }
        absolute.touches(.began, [finger(1, 500, 500)], time: 0)
        absolute.touches(.moved, [finger(1, 596, 554)], time: 10)
        #expect(absoluteSink.sent == [.moveAsPosition(64, 36, 1920, 1080)])
    }

    @Test func threeFourAndFiveFingerTapsOpenTheKeyboardsAndTheMenu() {
        let (screen, _, _, taps) = touchScreen(.trackpadNatural)
        func tap(_ count: Int, at time: Int64) {
            let fingers = (0..<count).map { finger($0, Double(100 + $0 * 100), 500) }
            fingers.enumerated().forEach { screen.touches(.began, [$1], time: time + Int64($0)) }
            fingers.reversed().enumerated().forEach { screen.touches(.ended, [$1], time: time + 100 + Int64($0)) }
        }
        tap(3, at: 0)
        tap(4, at: 1000)
        tap(5, at: 2000)
        #expect(taps.opened == ["keyboard", "full keyboard", "menu"])
    }

    @Test func multiTouchTakesTheFingerTapsOnlyWhenTheProfileAsks() {
        let (plain, _, _, plainTaps) = touchScreen(.multiTouch)
        let (gestures, _, _, gestureTaps) = touchScreen(.multiTouch) { $0.multiTouchGestures = true }
        for screen in [plain, gestures] {
            (0..<3).forEach { screen.touches(.began, [finger($0, 100, 100)], time: Int64($0)) }
            screen.touches(.ended, [finger(2, 100, 100)], time: 50)
        }
        #expect(plainTaps.opened.isEmpty)
        #expect(gestureTaps.opened == ["keyboard"])
    }

    @Test func disabledTouchSendsNothing() {
        let (screen, sink, scheduler, _) = touchScreen(.disabled)
        screen.touches(.began, [finger(1, 100, 100)], time: 0)
        screen.touches(.ended, [finger(1, 100, 100)], time: 10)
        scheduler.advance(to: 1000)
        #expect(sink.sent.isEmpty)
    }

    @Test func theZoomModeTakesTheFingersAndANewModeLeavesIt() {
        let (screen, sink, _, _) = touchScreen(.multiTouch)
        #expect(screen.toggleZoomMode())
        screen.touches(.began, [finger(1, 860, 540), finger(2, 1060, 540)], time: 0)
        screen.touches(.moved, [finger(1, 760, 540), finger(2, 1160, 540)], time: 10)
        #expect(sink.sent.isEmpty)
        #expect(screen.zoom.scale == 2)
        // About the fingers' middle, the middle of the picture
        #expect(screen.zoom.x == -960 && screen.zoom.y == -540)
        screen.touches(.ended, [finger(1, 760, 540), finger(2, 1160, 540)], time: 20)
        screen.setMode(.mouse)
        #expect(!screen.zoomMode && screen.zoom.scale == 2)
        // The mouse points into the zoomed picture
        screen.touches(.began, [finger(3, 0, 0)], time: 100)
        screen.touches(.ended, [finger(3, 0, 0)], time: 120)
        #expect(sink.sent.first == .position(480, 270, 1920, 1080))
    }

    @Test func thePictureStaysOnTheSurfaceAndARememberedZoomComesBack() {
        var zoom = PanZoom(surface: fullHD)
        zoom.zoom(by: 20, focusX: 0, focusY: 0, surface: fullHD)
        #expect(zoom.scale == PanZoom.maxScale)
        zoom.pan(dx: 500, dy: 500, surface: fullHD)
        #expect(zoom.x == 0 && zoom.y == 0)
        zoom.zoom(by: 0.01, focusX: 0, focusY: 0, surface: fullHD)
        #expect(zoom.scale == 1 && zoom.x == 0)
        // A letterboxed picture is centred where it is smaller than the surface
        let wide = TouchSurface(width: 2000, height: 1000, videoWidth: 1600, videoHeight: 1000, fit: .fit)
        #expect(wide.pictureX == 200 && wide.pictureWidth == 1600)
        let restored = PanZoom(scale: 2, x: -100, y: 0, surface: wide)
        #expect(restored.scale == 2 && restored.x == -100 && restored.y == 0)
        #expect(restored.transform(on: wide).tx == -100 - 400)
        // At the top of a top-aligned surface, also after a zoom back to 1
        let tall = TouchSurface(width: 2000, height: 1500, videoWidth: 1920, videoHeight: 1080, fit: .fit, topAligned: true)
        #expect(tall.pictureY == 0 && tall.pictureHeight == 1125)
        var top = PanZoom(surface: tall)
        top.zoom(by: 2, focusX: 1000, focusY: 500, surface: tall)
        top.zoom(by: 0.5, focusX: 1000, focusY: 500, surface: tall)
        #expect(top.scale == 1 && top.y == 0)

        let (screen, _, _, _) = touchScreen(.multiTouch)
        screen.restoreZoom(scale: 3, x: -1920, y: -1080)
        #expect(screen.zoom.scale == 3 && screen.zoom.x == -1920 && screen.zoom.y == -1080)
    }

    @Test func theTouchSensitivityScalesTheMotionOnTheSensitiveSide() {
        let (screen, sink, _, _) = touchScreen(.multiTouch) {
            $0.touchSensitivity = true
            $0.touchSensitivityX = 200
            $0.touchSensitivityY = 200
        }
        // The right half: 96 pixels of motion are 192
        screen.touches(.began, [finger(1, 1000, 100)], time: 0)
        screen.touches(.moved, [finger(1, 1000, 100)], time: 10)
        screen.touches(.moved, [finger(1, 1096, 100)], time: 20)
        #expect(sink.sent.last == .touch(.move, 0, Float(1192.0 / 1920), Float(100.0 / 1080)))
        // The stream menu turns it off
        screen.toggleTouchSensitivity()
        screen.touches(.moved, [finger(1, 1100, 100)], time: 30)
        #expect(sink.sent.last == .touch(.move, 0, Float(1100.0 / 1920), Float(100.0 / 1080)))
    }

    @Test func thePencilIsThePensWithItsTiltOrTheMouseWithTheTipAsLeftButton() {
        let (screen, sink, _, _) = touchScreen(.disabled)
        let pen = TouchSample(id: 9, x: 960, y: 540, tool: .pencil, pressure: 0.5, altitude: .pi / 3)
        screen.touches(.began, [pen], time: 0)
        screen.touches(.ended, [pen], time: 50)
        screen.penHover(TouchSample(id: 0, x: 0, y: 0, tool: .pencil, pressure: 0.2), time: 60)
        screen.penHover(nil, time: 70)
        #expect(sink.sent == [
            .pen(.down, .pen, 0.5, 0.5, 30), .pen(.up, .pen, 0.5, 0.5, 30), .pen(.hover, .pen, 0, 0, nil),
            .pen(.hoverLeave, .pen, 0, 0, nil),
        ])

        sink.clear()
        sink.touchSupported = false
        screen.touches(.began, [pen], time: 1000)
        screen.touches(.moved, [TouchSample(id: 9, x: 970, y: 540, tool: .pencil)], time: 1050)
        screen.touches(.moved, [TouchSample(id: 9, x: 1100, y: 540, tool: .pencil)], time: 1200)
        screen.touches(.ended, [TouchSample(id: 9, x: 1100, y: 540, tool: .pencil)], time: 1250)
        // The motion right after the down stays in its dead zone
        #expect(sink.sent == [
            .position(960, 540, 1920, 1080), .button(.left, true), .position(1100, 540, 1920, 1080),
            .position(1100, 540, 1920, 1080), .button(.left, false),
        ])
        // Nothing while the input is not grabbed
        sink.clear()
        screen.capturing = { false }
        screen.touches(.began, [pen], time: 2000)
        #expect(sink.sent.isEmpty)
    }

    @Test func anExternalDisplayKeepsOnlyTheTrackpadModesAndAChoiceIsRemembered() {
        let (screen, _, _, _) = touchScreen(.multiTouch, configure: { $0.rememberMode = true }, external: true)
        #expect(screen.mode == .trackpadNatural)
        var saved: [TouchMode] = []
        screen.onModeSaved = { saved.append($0) }
        screen.setMode(.mouse)
        screen.setMode(.trackpadGaming)
        #expect(screen.mode == .trackpadGaming && saved == [.trackpadGaming])
    }

    @Test func theLocalPointerPointsIntoThePicture() {
        let (screen, sink, _, _) = touchScreen(.multiTouch)
        screen.pointerMoved(x: 2000, y: -5)
        #expect(sink.sent == [.position(1920, 0, 1920, 1080)])
    }

    @Test func cancellingReleasesWhatTheFingersHold() {
        let (screen, sink, scheduler, _) = touchScreen(.trackpadGaming)
        screen.touches(.began, [finger(1, 500, 500)], time: 0)
        scheduler.advance(to: 650)
        #expect(sink.sent == [.button(.left, true)])
        screen.cancelAll(time: 700)
        #expect(sink.sent == [.button(.left, true), .button(.left, false)])
    }
}
