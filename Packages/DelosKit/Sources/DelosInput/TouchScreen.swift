import DelosCore
import Foundation

/// What a finger on the stream does (`mouse_mode_list` of DELOS for Android, `MouseModeController`).
public enum TouchMode: Int, CaseIterable, Sendable {
    /// The fingers are the PC's touch screen (passthrough); a host without touch support gets the Mouse mode.
    case multiTouch = 0
    /// The finger is the pointer where it touches (``AbsoluteTouchContext``).
    case mouse = 1
    /// The screen is a laptop's trackpad (``TrackpadContext``).
    case trackpadNatural = 2
    /// The finger moves the pointer by its motion, a long press drags (``RelativeTouchContext``).
    case trackpadGaming = 3
    /// Fingers send nothing.
    case disabled = 4
    /// The Mouse mode with the left and right buttons swapped.
    case mouseSwapped = 5

    /// The mode a saved `mouse_mode_list` value stands for (`savedMouseMode`): anything else is Multi touch.
    public init(saved: String) {
        self = Int(saved).flatMap(TouchMode.init(rawValue:)) ?? .multiTouch
    }

    /// The mode's name (`mouse_mode_names`).
    public var nameKey: String {
        switch self {
        case .multiTouch: "mouse_mode_multi_touch"
        case .mouse: "mouse_mode_absolute_touch"
        case .trackpadNatural: "mouse_mode_track_pad_natural"
        case .trackpadGaming: "mouse_mode_track_pad_gaming"
        case .disabled: "mouse_mode_disabled"
        case .mouseSwapped: "mouse_mode_absolute_touch_swapped"
        }
    }

    /// The modes an external display keeps: the picture is not under the fingers there.
    public var worksOnExternalDisplay: Bool { self == .trackpadNatural || self == .trackpadGaming || self == .disabled }
}

/// The profile's touch, mouse and pointer settings (Settings → Controls) under DELOS for Android's keys and defaults
/// (`PreferenceConfiguration`).
public struct TouchOptions: Sendable, Equatable {
    /// `mouse_mode_list`, Multi touch.
    public var mode = TouchMode.multiTouch
    /// A mode chosen in the stream menu is saved to the profile (`checkbox_remember_mouse_mode`, off).
    public var rememberMode = false
    /// The local pointer shows over the stream from the start (`checkbox_mouse_local_cursor`, off).
    public var localCursor = false
    /// The 3, 4 and 5-finger taps also work in the Multi touch mode (`checkbox_multi_touch_gestures`, off).
    public var multiTouchGestures = false
    /// The mouse and the Trackpad gaming mode move the PC's pointer to absolute positions (`checkbox_absolute_mouse_mode`).
    public var absoluteMouseMode = false
    /// The Trackpad gaming mode's speed in percent (`seekbar_touchpad_sensitivity_opacity`, `_y_opacity`, 10…300).
    public var touchpadSensitivityX = 100
    public var touchpadSensitivityY = 100
    /// A trackpad's scrolling speed in percent (`seekbar_trackpad_sensitivity_x`, `_y`, −200…200) and its axes swapped
    /// (`checkbox_trackpad_swap_axis`).
    public var trackpadSensitivityX = 100
    public var trackpadSensitivityY = 100
    public var trackpadSwapAxis = false
    /// The touch sensitivity of the Multi touch mode and the pen (`checkbox_enable_touch_sensitivity`, off; the stream menu
    /// toggles it): finger motion scaled by X and Y percent (`seekbar_touch_sensitivity_opacity_x`, `_y`, 10…300), on the
    /// right half of the screen or everywhere (`checkbox_enable_global_touch_sensitivity`), a finger that leaves the picture
    /// put back to its middle (`checkbox_enable_touch_sensitivity_rotation_auto`, on).
    public var touchSensitivity = false
    public var touchSensitivityX = 100
    public var touchSensitivityY = 100
    public var touchSensitivityGlobal = false
    public var touchSensitivityRotationAuto = true
    /// The zoom and pan stay for the next stream (`checkbox_remember_zoom_pan`, off).
    public var rememberZoomPan = false

    public init() {}
}

/// One touch on the surface, in its pixels.
public struct TouchSample: Sendable, Equatable {
    public enum Tool: Sendable, Equatable { case finger, pencil }

    /// Identifies the touch while it lasts.
    public var id: Int
    public var x: Double
    public var y: Double
    public var tool: Tool
    /// 0…1: the force of the touch (a hovering pencil: its distance), 1 where the device measures none.
    public var pressure: Double
    /// The diameter of the touched area in pixels.
    public var diameter: Double
    /// A pencil's direction in the plane of the screen (radians, 0 along +x, clockwise) and its altitude above the screen
    /// (radians, π/2 upright).
    public var azimuth: Double?
    public var altitude: Double?

    public init(
        id: Int, x: Double, y: Double, tool: Tool = .finger, pressure: Double = 1, diameter: Double = 0, azimuth: Double? = nil,
        altitude: Double? = nil
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.tool = tool
        self.pressure = pressure
        self.diameter = diameter
        self.azimuth = azimuth
        self.altitude = altitude
    }
}

/// What the multi-finger taps open (`StreamPointerHandler.Host`).
@MainActor public protocol TouchScreenHost: AnyObject {
    /// Three fingers: the system's keyboard.
    func toggleKeyboard()
    /// Four fingers: the full keyboard.
    func toggleFullKeyboard()
    /// Five fingers: the stream menu.
    func showMenu()
}

/// The touch screen, the Apple Pencil and the local pointer during a stream (the finger and stylus part of
/// `StreamPointerHandler` and `MouseModeController` of DELOS for Android). The fingers follow the touch mode: passed
/// through to the PC's touch screen, or turned into its mouse by the contexts of the first two fingers; taps of 3, 4 and 5
/// fingers open the keyboard, the full keyboard and the menu (in the trackpad and mouse modes, and in Multi touch with
/// ``TouchOptions/multiTouchGestures``). In the pan and zoom mode the fingers pan and zoom the picture instead. The pencil
/// is the PC's pen, or its mouse where the host takes no pen.
@MainActor public final class TouchScreen {
    public enum Phase: Sendable { case began, moved, ended, cancelled }

    static let referenceWidth = 1280
    static let referenceHeight = 720
    static let threeFingerTapTime: Int64 = 300
    static let fourFingerTapTime: Int64 = 300
    static let fiveFingerTapTime: Int64 = 300
    static let stylusDownDeadZoneTime: Int64 = 100
    static let stylusDownDeadZoneRadius = 20.0
    static let stylusUpDeadZoneTime: Int64 = 150
    static let stylusUpDeadZoneRadius = 50.0

    /// What the taps open; kept strongly, so it must not keep this touch screen.
    public var host: (any TouchScreenHost)?
    /// The pen and the local pointer reach the PC only while the input is grabbed (`isCapturingActive`).
    public var capturing: @MainActor () -> Bool = { true }
    /// Called with a mode the stream menu chose when ``TouchOptions/rememberMode`` keeps it.
    public var onModeSaved: (@MainActor (TouchMode) -> Void)?
    /// Called after the zoom changed (the picture is drawn with ``zoom``).
    public var onZoomChanged: (@MainActor () -> Void)?
    /// The finger motion that starts a pan, in pixels (8 points).
    public var touchSlop = 16.0

    public let options: TouchOptions
    private let sink: any StreamInputSink
    private let scheduler: any TouchScheduler
    private let externalDisplay: Bool

    public private(set) var mode = TouchMode.multiTouch
    private var multiTouchScreen = false
    private var touchscreenTrackpad = false
    /// The contexts of the first two fingers; empty while touch is disabled.
    private var contexts: [any TouchContext] = []

    public private(set) var zoomMode = false
    public private(set) var zoom = PanZoom()
    private var savedZoom: (scale: Double, x: Double, y: Double)?
    private var gesture = PanZoomGesture()
    public private(set) var surface: TouchSurface?
    public private(set) var touchSensitivityOn: Bool

    private struct Finger {
        let id: Int
        /// Android's pointer id: the lowest free one; the fingers are in its order.
        let pointerID: Int
        var sample: TouchSample
    }

    private enum Action { case down, pointerDown, move, pointerUp, up, cancel }

    private struct Event {
        let action: Action
        let actionIndex: Int
        let pointers: [Finger]
        let time: Int64
        /// A pointer up the system cancelled (`FLAG_CANCELED`).
        var canceled = false
    }

    private var fingers: [Finger] = []
    private var threeFingerDownTime: Int64 = 0
    private var fourFingerDownTime: Int64 = 0
    private var fiveFingerDownTime: Int64 = 0

    private struct Sensitivity {
        var lastAbsoluteX = -1.0, lastAbsoluteY = -1.0
        var lastRelativeX = -1.0, lastRelativeY = -1.0
    }

    private var sensitivity: [Int: Sensitivity] = [:]
    private static let penSensitivityKey = -1

    private var penDown = false
    private var lastPenDown = (time: Int64(0), x: 0.0, y: 0.0)
    private var lastPenUp = (time: Int64(0), x: 0.0, y: 0.0)

    /// `externalDisplay`: the stream is shown on another screen, so only the trackpad and disabled modes work
    /// (`initMouseMode`).
    public init(
        sink: any StreamInputSink, options: TouchOptions, externalDisplay: Bool = false,
        scheduler: any TouchScheduler = TaskTouchScheduler()
    ) {
        self.sink = sink
        self.options = options
        self.scheduler = scheduler
        self.externalDisplay = externalDisplay
        touchSensitivityOn = options.touchSensitivity
        apply(externalDisplay && !options.mode.worksOnExternalDisplay ? .trackpadNatural : options.mode)
    }

    // MARK: Mode

    /// The stream menu's choice (`setStreamMouseMode`): applied at once, and saved when the profile keeps it.
    public func setMode(_ mode: TouchMode) {
        guard !externalDisplay || mode.worksOnExternalDisplay else { return }
        apply(mode)
        if options.rememberMode { onModeSaved?(mode) }
    }

    private func apply(_ mode: TouchMode) {
        self.mode = mode
        switch mode {
        case .multiTouch:
            multiTouchScreen = true
            touchscreenTrackpad = false
        case .mouse, .mouseSwapped:
            multiTouchScreen = false
            touchscreenTrackpad = false
        case .trackpadNatural, .trackpadGaming:
            multiTouchScreen = false
            touchscreenTrackpad = true
        case .disabled:
            break
        }
        contexts.forEach { $0.cancelTouch() }
        let view: @MainActor () -> TouchViewSize = { [weak self] in self?.surface?.pictureSize ?? TouchViewSize(width: 1, height: 1) }
        contexts = (0..<2).compactMap { index -> (any TouchContext)? in
            switch mode {
            case .disabled: nil
            case _ where !touchscreenTrackpad:
                AbsoluteTouchContext(sink: sink, actionIndex: index, view: view, swapped: mode == .mouseSwapped, scheduler: scheduler)
            case .trackpadGaming:
                RelativeTouchContext(
                    sink: sink, actionIndex: index, referenceWidth: Self.referenceWidth, referenceHeight: Self.referenceHeight,
                    view: view, absoluteMouseMode: options.absoluteMouseMode, sensitivityX: options.touchpadSensitivityX,
                    sensitivityY: options.touchpadSensitivityY, scheduler: scheduler)
            default:
                TrackpadContext(sink: sink, actionIndex: index, scheduler: scheduler)
            }
        }
        // A new mode always leaves the pan and zoom mode
        zoomMode = false
    }

    // MARK: Zoom, pan and sensitivity

    /// The stream menu's Zoom (`toggleZoomMode`): on, the fingers pan and zoom the picture. Returns whether it is on now.
    @discardableResult
    public func toggleZoomMode() -> Bool {
        zoomMode.toggle()
        gesture = PanZoomGesture()
        return zoomMode
    }

    /// The stream menu's Touch sensitivity (`switchTouchSensitivity`).
    public func toggleTouchSensitivity() {
        touchSensitivityOn.toggle()
    }

    /// The zoom and pan the last stream left (`restoreZoomAndPan`); applied once the surface is known.
    public func restoreZoom(scale: Double, x: Double, y: Double) {
        savedZoom = (scale, x, y)
        if let surface { setSurface(surface) }
    }

    /// The surface the stream is shown on, laid out again: the zoom stays within it (`handleSurfaceChange`).
    public func setSurface(_ surface: TouchSurface) {
        let changed = surface != self.surface
        self.surface = surface
        if let saved = savedZoom {
            savedZoom = nil
            zoom = PanZoom(scale: saved.scale, x: saved.x, y: saved.y, surface: surface)
        } else if !zoom.isZoomed {
            zoom = PanZoom(surface: surface)
        } else if changed {
            zoom.constrain(to: surface)
        } else {
            return
        }
        onZoomChanged?()
    }

    // MARK: Fingers

    /// Touches of the fingers and the pencil on the surface; `time` in milliseconds.
    public func touches(_ phase: Phase, _ samples: [TouchSample], time: Int64) {
        let pens = samples.filter { $0.tool == .pencil }
        pens.forEach { pen(phase, $0, time: time) }
        let samples = samples.filter { $0.tool == .finger }
        guard !samples.isEmpty, surface != nil else { return }
        switch phase {
        case .began:
            for sample in samples where !fingers.contains(where: { $0.id == sample.id }) {
                let used = Set(fingers.map(\.pointerID))
                let finger = Finger(id: sample.id, pointerID: (0...).first { !used.contains($0) }!, sample: sample)
                let index = fingers.firstIndex { $0.pointerID > finger.pointerID } ?? fingers.count
                fingers.insert(finger, at: index)
                handleFinger(Event(action: fingers.count == 1 ? .down : .pointerDown, actionIndex: index, pointers: fingers, time: time))
            }
        case .moved:
            var moved = false
            for sample in samples {
                guard let index = fingers.firstIndex(where: { $0.id == sample.id }) else { continue }
                fingers[index].sample = sample
                moved = true
            }
            if moved { handleFinger(Event(action: .move, actionIndex: 0, pointers: fingers, time: time)) }
        case .ended:
            for sample in samples { lift(sample, time: time, canceled: false) }
        case .cancelled:
            let ids = Set(samples.map(\.id))
            if !fingers.isEmpty, fingers.allSatisfy({ ids.contains($0.id) }) {
                let pointers = fingers
                fingers.removeAll()
                handleFinger(Event(action: .cancel, actionIndex: 0, pointers: pointers, time: time))
            } else {
                for sample in samples { lift(sample, time: time, canceled: true) }
            }
        }
    }

    private func lift(_ sample: TouchSample, time: Int64, canceled: Bool) {
        guard let index = fingers.firstIndex(where: { $0.id == sample.id }) else { return }
        fingers[index].sample = sample
        let pointers = fingers
        fingers.remove(at: index)
        handleFinger(Event(action: pointers.count == 1 ? .up : .pointerUp, actionIndex: index, pointers: pointers, time: time, canceled: canceled))
    }

    /// Every finger and the pen are gone (the menu opened over them, the stream ends): what they held comes up.
    public func cancelAll(time: Int64) {
        if !fingers.isEmpty {
            let pointers = fingers
            fingers.removeAll()
            handleFinger(Event(action: .cancel, actionIndex: 0, pointers: pointers, time: time))
        }
        if penDown { pen(.cancelled, TouchSample(id: 0, x: 0, y: 0, tool: .pencil), time: time) }
    }

    private func handleFinger(_ event: Event) {
        // The gesture is over for all of its pointers
        if event.action == .cancel { sensitivity.removeAll() }
        if zoomMode {
            panZoom(event)
            return
        }
        guard !contexts.isEmpty else { return }
        if options.multiTouchGestures || !multiTouchScreen, event.pointers.count > 2,
            [.pointerDown, .pointerUp, .up].contains(event.action), multiTouchGesture(event)
        {
            return
        }
        if multiTouchScreen, !touchscreenTrackpad, sendTouch(event) { return }
        touchInput(event)
    }

    private func panZoom(_ event: Event) {
        guard let surface else { return }
        let points = { (fingers: [Finger]) in fingers.map { (x: $0.sample.x, y: $0.sample.y) } }
        switch event.action {
        case .down, .pointerDown:
            gesture.reset(points(event.pointers))
        case .move:
            let before = zoom
            gesture.moved(points(event.pointers), zoom: &zoom, surface: surface, slop: touchSlop)
            if zoom != before { onZoomChanged?() }
        case .pointerUp, .up:
            var rest = event.pointers
            rest.remove(at: event.actionIndex)
            gesture.reset(points(rest))
        case .cancel:
            gesture.reset([])
        }
    }

    /// 3, 4 and 5-finger taps (`handleMultiTouchGesture`): true when one fired.
    private func multiTouchGesture(_ event: Event) -> Bool {
        let pointerCount = event.pointers.count
        if event.action == .pointerDown {
            if pointerCount == 3 {
                threeFingerDownTime = event.time
            } else if pointerCount == 4 {
                threeFingerDownTime = 0
                fourFingerDownTime = event.time
            } else if pointerCount == 5 {
                threeFingerDownTime = 0
                fourFingerDownTime = 0
                fiveFingerDownTime = event.time
            }
            return false
        }
        let time = event.time
        if pointerCount >= 5, fiveFingerDownTime > 0, time - fiveFingerDownTime < Self.fiveFingerTapTime {
            fiveFingerDownTime = 0
            host?.showMenu()
        } else if pointerCount == 4, fourFingerDownTime > 0, time - fourFingerDownTime < Self.fourFingerTapTime {
            fourFingerDownTime = 0
            host?.toggleFullKeyboard()
        } else if pointerCount == 3, threeFingerDownTime > 0, time - threeFingerDownTime < Self.threeFingerTapTime {
            threeFingerDownTime = 0
            host?.toggleKeyboard()
        } else {
            threeFingerDownTime = 0
            fourFingerDownTime = 0
            fiveFingerDownTime = 0
            cancelStaleTouchState(event)
            return false
        }
        cancelStaleTouchState(event)
        return true
    }

    /// What the fingers started is cancelled: at the PC's touch screen and in the contexts.
    private func cancelStaleTouchState(_ event: Event) {
        handleFinger(Event(action: .cancel, actionIndex: 0, pointers: event.pointers, time: event.time))
        for context in contexts {
            context.cancelTouch()
            context.setPointerCount(0)
        }
    }

    // MARK: Passthrough

    /// The fingers as the PC's touch screen (`trySendTouchEvent`); false when the host takes no touches.
    private func sendTouch(_ event: Event) -> Bool {
        func send(_ type: TouchEventType, _ finger: Finger, _ action: Action) -> Bool {
            let (x, y) = normalized(finger.sample, key: finger.pointerID, action: action)
            let area = contactArea(finger.sample)
            do {
                try sink.sendTouch(
                    type, pointerID: UInt32(finger.pointerID), x: x, y: y, pressureOrDistance: Float(min(max(finger.sample.pressure, 0), 1)),
                    contactAreaMajor: area.major, contactAreaMinor: area.minor, rotation: nil)
            } catch .unsupportedByHost {
                return false
            } catch {}
            return true
        }
        switch event.action {
        case .move:
            return event.pointers.allSatisfy { send(.move, $0, .move) }
        case .cancel:
            do {
                try sink.sendTouch(.cancelAll, pointerID: 0, x: 0, y: 0, pressureOrDistance: 0, contactAreaMajor: 0, contactAreaMinor: 0, rotation: nil)
            } catch .unsupportedByHost {
                return false
            } catch {}
            return true
        case .down, .pointerDown:
            return send(.down, event.pointers[event.actionIndex], event.action)
        case .up, .pointerUp:
            return send(event.canceled ? .cancel : .up, event.pointers[event.actionIndex], event.action)
        }
    }

    /// A touch's position as 0…1 of the picture (`getStreamViewRelativeNormalizedXY`): through the touch sensitivity, then
    /// the zoom.
    private func normalized(_ sample: TouchSample, key: Int, action: Action) -> (Float, Float) {
        guard let surface else { return (0, 0) }
        var x = sample.x, y = sample.y
        if touchSensitivityOn, options.touchSensitivityX != 100 || options.touchSensitivityY != 100 {
            (x, y) = sensitive(
                x: x, y: y, key: key, action: action,
                sensitiveSide: options.touchSensitivityGlobal || sample.x >= surface.width / 2, surface: surface)
        }
        let point = zoom.picturePoint(x: x, y: y)
        let width = max(surface.pictureWidth, 1), height = max(surface.pictureHeight, 1)
        return (Float(min(max(point.x, 0), width) / width), Float(min(max(point.y, 0), height) / height))
    }

    /// The touch sensitivity (`getStreamViewRelativeSensitivityXY`): a finger's motion scaled by X and Y percent from where
    /// it went down, on the sensitive side only.
    private func sensitive(x: Double, y: Double, key: Int, action: Action, sensitiveSide: Bool, surface: TouchSurface) -> (Double, Double) {
        // A pointer that just went down starts afresh
        if action == .down || action == .pointerDown { sensitivity[key] = nil }
        // Off the sensitive side the pointer is unchanged, and its offset forgotten
        guard sensitiveSide else {
            sensitivity[key] = nil
            return (x, y)
        }
        var x2 = x, y2 = y
        if action == .move {
            var state = sensitivity[key] ?? Sensitivity()
            if state.lastAbsoluteX != -1 {
                x2 = state.lastRelativeX + (x - state.lastAbsoluteX) * 0.01 * Double(options.touchSensitivityX)
                y2 = state.lastRelativeY + (y - state.lastAbsoluteY) * 0.01 * Double(options.touchSensitivityY)
            }
            if options.touchSensitivityRotationAuto {
                if x2 >= surface.pictureWidth { x2 = surface.pictureWidth / 2 }
                if y2 >= surface.pictureHeight { y2 = surface.pictureHeight / 2 }
            }
            state.lastAbsoluteX = x
            state.lastAbsoluteY = y
            state.lastRelativeX = x2
            state.lastRelativeY = y2
            sensitivity[key] = state
        }
        if action == .up || action == .pointerUp { sensitivity[key] = nil }
        return (x2, y2)
    }

    /// The touched area as parts of the picture (`getStreamViewNormalizedContactArea`): its axes at the touch's direction,
    /// 45° when unknown.
    private func contactArea(_ sample: TouchSample) -> (major: Float, minor: Float) {
        guard let surface else { return (0, 0) }
        let orientation = sample.azimuth.map { $0 + .pi / 2 } ?? .pi / 4
        let width = max(surface.pictureWidth, 1), height = max(surface.pictureHeight, 1)
        func normalized(_ r: Double, _ theta: Double) -> Float {
            let x = min(abs(r * cos(theta)), width) / width, y = min(abs(r * sin(theta)), height) / height
            return Float((x * x + y * y).squareRoot())
        }
        let diameter = sample.diameter / zoom.scale
        return (normalized(diameter, orientation), normalized(diameter, orientation + .pi / 2))
    }

    // MARK: Contexts

    /// A finger's position for the contexts: the trackpads measure motion on the unzoomed surface, the mouse modes point
    /// into the zoomed picture.
    private func contextPoint(_ finger: Finger) -> (Int, Int) {
        guard let surface else { return (0, 0) }
        if touchscreenTrackpad {
            return (Int((finger.sample.x - surface.pictureX).rounded(.towardZero)), Int((finger.sample.y - surface.pictureY).rounded(.towardZero)))
        }
        let point = zoom.picturePoint(x: finger.sample.x, y: finger.sample.y)
        return (Int(point.x.rounded(.towardZero)), Int(point.y.rounded(.towardZero)))
    }

    /// The fingers through the contexts (`handleTouchInput`).
    private func touchInput(_ event: Event) {
        guard event.actionIndex < contexts.count else { return }
        let context = contexts[event.actionIndex]
        let pointerCount = event.pointers.count
        switch event.action {
        case .move:
            for context in contexts where context.actionIndex < pointerCount {
                let (x, y) = contextPoint(event.pointers[context.actionIndex])
                context.touchMove(x: x, y: y, time: event.time)
            }
        case .down, .pointerDown:
            contexts.forEach { $0.setPointerCount(pointerCount) }
            let (x, y) = contextPoint(event.pointers[event.actionIndex])
            context.touchDown(x: x, y: y, time: event.time, isNewFinger: true)
        case .up, .pointerUp:
            if touchscreenTrackpad, pointerCount == 1, !event.canceled {
                // All fingers up: a 3, 4 or 5-finger tap
                if threeFingerDownTime > 0, event.time - threeFingerDownTime < Self.threeFingerTapTime {
                    host?.toggleKeyboard()
                    return
                } else if fourFingerDownTime > 0, event.time - fourFingerDownTime < Self.fourFingerTapTime {
                    host?.toggleFullKeyboard()
                    return
                } else if fiveFingerDownTime > 0, event.time - fiveFingerDownTime < Self.fiveFingerTapTime {
                    host?.showMenu()
                    return
                }
            }
            if event.canceled {
                context.cancelTouch()
            } else {
                let (x, y) = contextPoint(event.pointers[event.actionIndex])
                context.touchUp(x: x, y: y, time: event.time)
            }
            contexts.forEach { $0.setPointerCount(pointerCount - 1) }
            if event.actionIndex == 0, pointerCount > 1, !context.isCancelled {
                // The second finger is the first one now
                let (x, y) = contextPoint(event.pointers[1])
                context.touchDown(x: x, y: y, time: event.time, isNewFinger: false)
            }
        case .cancel:
            for context in contexts {
                context.cancelTouch()
                context.setPointerCount(0)
            }
        }
    }

    // MARK: Pencil

    /// A pencil touching or hovering (`trySendPenEvent`, else `updateMousePosition` and `handleStylusPress`): the PC's pen,
    /// or its mouse with the tip as the left button where the host takes no pen.
    private func pen(_ phase: Phase, _ sample: TouchSample, time: Int64) {
        switch phase {
        case .began: penDown = true
        case .ended, .cancelled: penDown = false
        case .moved: break
        }
        guard capturing() else { return }
        let type: TouchEventType = switch phase {
        case .began: .down
        case .moved: .move
        case .ended: .up
        case .cancelled: .cancelAll
        }
        if sendPen(type, sample) { return }
        penMouse(type, sample, time: time)
    }

    /// A pencil hovering over the screen (nil: it left; `ACTION_HOVER_*`); `distance` 0…1 in the sample's pressure.
    public func penHover(_ sample: TouchSample?, time: Int64) {
        guard capturing(), !penDown else { return }
        let hover = sample ?? TouchSample(id: 0, x: lastHover?.x ?? 0, y: lastHover?.y ?? 0, tool: .pencil, pressure: 0)
        lastHover = sample.map { ($0.x, $0.y) }
        let type: TouchEventType = sample == nil ? .hoverLeave : .hover
        if sendPen(type, hover) { return }
        penMouse(type, hover, time: time)
    }

    private var lastHover: (x: Double, y: Double)?

    private func sendPen(_ type: TouchEventType, _ sample: TouchSample) -> Bool {
        let action: Action = type == .down ? .down : type == .up ? .up : .move
        let (x, y) = type == .cancelAll ? (0, 0) : normalized(sample, key: Self.penSensitivityKey, action: action)
        let area = type == .cancelAll ? (major: Float(0), minor: Float(0)) : contactArea(sample)
        let rotation = sample.azimuth.map { UInt16((Int(($0 * 180 / .pi).rounded()) + 90 + 360) % 360) }
        let tilt = sample.altitude.map { UInt8(clamping: Int((90 - $0 * 180 / .pi).rounded())) }
        do {
            try sink.sendPen(
                type, tool: type == .cancelAll ? .unknown : .pen, buttons: [], x: x, y: y,
                pressureOrDistance: Float(min(max(sample.pressure, 0), 1)), contactAreaMajor: area.major, contactAreaMinor: area.minor,
                rotation: type == .cancelAll ? nil : rotation, tilt: type == .cancelAll ? nil : tilt)
        } catch .unsupportedByHost {
            return false
        } catch {}
        return true
    }

    /// The pencil as the mouse (`updateMousePosition` with its dead zones, `handleStylusPress`).
    private func penMouse(_ type: TouchEventType, _ sample: TouchSample, time: Int64) {
        guard let surface else { return }
        let point = zoom.picturePoint(x: sample.x, y: sample.y)
        func near(_ last: (time: Int64, x: Double, y: Double), _ window: Int64, _ radius: Double) -> Bool {
            time - last.time <= window && ((point.x - last.x) * (point.x - last.x) + (point.y - last.y) * (point.y - last.y)).squareRoot() <= radius
        }
        // Small dead zones after an up and after a down make double clicks precise
        let still = switch type {
        case .down, .hover, .hoverLeave: near(lastPenUp, Self.stylusUpDeadZoneTime, Self.stylusUpDeadZoneRadius)
        case .move, .up: near(lastPenDown, Self.stylusDownDeadZoneTime, Self.stylusDownDeadZoneRadius)
        default: false
        }
        if !still, type != .cancelAll { sendPosition(point, surface: surface) }
        switch type {
        case .down:
            lastPenDown = (time, point.x, point.y)
            try? sink.sendMouseButton(.left, pressed: true)
        case .up, .cancelAll:
            lastPenUp = (time, point.x, point.y)
            try? sink.sendMouseButton(.left, pressed: false)
        default:
            break
        }
    }

    private func sendPosition(_ point: (x: Double, y: Double), surface: TouchSurface) {
        let size = surface.pictureSize
        let x = min(max(Int(point.x), 0), size.width), y = min(max(Int(point.y), 0), size.height)
        try? sink.sendMousePosition(
            x: Int16(clamping: x), y: Int16(clamping: y), referenceWidth: Int16(clamping: size.width), referenceHeight: Int16(clamping: size.height))
    }

    // MARK: Local pointer

    /// The system pointer moved to [x], [y] of the surface while the local cursor shows: the PC's pointer goes there
    /// (`updateMousePosition` of a mouse that is not captured).
    public func pointerMoved(x: Double, y: Double) {
        guard capturing(), let surface else { return }
        sendPosition(zoom.picturePoint(x: x, y: y), surface: surface)
    }

    /// Stops the contexts' pending work and releases what they hold (the stream ends).
    public func stop() {
        contexts.forEach { $0.cancelTouch() }
        contexts.removeAll()
        fingers.removeAll()
    }
}
