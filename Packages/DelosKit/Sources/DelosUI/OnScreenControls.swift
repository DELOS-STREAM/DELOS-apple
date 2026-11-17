import DelosCore
import DelosData
import Foundation
import Observation

/// One vibration of a press (`VirtualController.sendControllerInputContext(duration, amplitude)` of DELOS for Android):
/// [milliseconds] long at [amplitude] of 255; nil is the device's default amplitude.
struct OscVibration: Equatable, Sendable {
    var milliseconds: Int
    var amplitude: Int?

    /// A button's press and release: 10 ms at the default amplitude.
    static let press = OscVibration(milliseconds: 10, amplitude: nil)
    /// The D-pad: 10 ms at 0x22.
    static let dpad = OscVibration(milliseconds: 10, amplitude: 0x22)
    /// A stick's movement: 10 ms at 0x11.
    static let stick = OscVibration(milliseconds: 10, amplitude: 0x11)
}

/// What the on-screen controls send, play and say, and where their layout is kept. The stream gives the PC (controller 0
/// through ``GameInput``) and the device's haptics; the preview gives nothing, so presses go nowhere.
@MainActor
struct OscOutput {
    var send: @MainActor (ControllerState) -> Void = { _ in }
    var vibrate: @MainActor (OscVibration) -> Void = { _ in }
    /// The editor's mode changed: the toast's text.
    var announce: @MainActor (String) -> Void = { _ in }
    /// The layout's stored changes (``OnScreenControlsStore`` of the current profile).
    var readLayout: @MainActor () -> [Int: OscPlacement] = { [:] }
    var writeLayout: @MainActor ([Int: OscPlacement]) -> Void = { _ in }
}

/// The settings the on-screen controls follow (DELOS for Android's `PreferenceConfiguration`, by its keys).
struct OscOptions: Equatable, Sendable {
    /// `checkbox_only_show_L3R3`
    var onlyL3R3 = false
    /// `checkbox_show_guide_button`
    var showGuide = true
    /// `checkbox_flip_face_buttons`: A and B, X and Y swap their places.
    var flipFaceButtons = false
    /// `checkbox_enable_analog_stick_new`: the sticks start where the finger lands.
    var freeSticks = false
    /// `seekbar_osc_opacity`, percent.
    var opacity = 90
    /// `seekbar_osc_free_analog_stick_opacity`, percent: the least a free stick shows while it is held.
    var freeStickOpacity = 20
    /// `checkbox_vibrate_keyboard`: a short vibration with every press (Android's `enableKeyboardVibrate`).
    var pressHaptics = false
    /// `checkbox_vibrate_osc`: the host's rumble of controller 0 plays on this device when no controller 0 is connected.
    var deviceRumble = true
}

/// The on-screen controls' editor (`VirtualController.ControllerMode`): the gear goes Active → turn controls on or off →
/// move → resize → Active, which saves the layout.
enum OscMode: Sendable {
    case active, disableEnable, move, resize

    var configuring: Bool { self != .active }
}

/// The directions of the D-pad (`DigitalPad.DIGITAL_PAD_DIRECTION_*`).
struct OscDirections: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let left = OscDirections(rawValue: 1)
    static let up = OscDirections(rawValue: 2)
    static let right = OscDirections(rawValue: 4)
    static let down = OscDirections(rawValue: 8)
}

/// What an on-screen control is (`DigitalButton`, `LeftTrigger` / `RightTrigger`, `DigitalPad`, `AnalogStick`,
/// `AnalogStickFree`). A button has a [layer]: a finger that slides off a button presses the buttons of its layer it
/// slides over.
enum OscElementKind: Equatable, Sendable {
    case button(label: String, layer: Int, flag: ControllerButtons)
    case trigger(label: String, layer: Int, right: Bool)
    case dpad
    case stick(right: Bool, free: Bool)

    var layer: Int? {
        switch self {
        case .button(_, let layer, _), .trigger(_, let layer, _): layer
        case .dpad, .stick: nil
        }
    }
}

/// The motion of a stick (`AnalogStick.STICK_STATE`, `CLICK_STATE` and the numbers they work on).
struct OscStick: Equatable, Sendable {
    enum Motion: Sendable { case none, inDeadZone, active }
    var motion = Motion.none
    var doubleClick = false
    var movementRadius = 0.0
    var movementAngle = 0.0
    /// Where the knob is drawn, in pixels of the element.
    var knobX: Float = 0
    var knobY: Float = 0
    /// The last press's time, in milliseconds.
    var lastClick = -Double.infinity
    /// A free stick: where the finger landed, in pixels of the element, while it is down.
    var startX: Float = 0
    var startY: Float = 0
    var fingerDown = false
}

/// One on-screen control: what it is, where it is and its state.
struct OscElement: Equatable, Sendable {
    let id: OscElementID
    let kind: OscElementKind
    var slot: OscSlot
    var enabled = true
    var pressed = false
    /// The button whose finger slid onto this one and holds it.
    var heldBy: OscElementID?
    var directions = OscDirections()
    var stick = OscStick()
    /// The editor's drag in progress on this element (move or resize), with where it began.
    var drag: OscDrag?

    /// The label it shows (a button's letters).
    var label: String? {
        switch kind {
        case .button(let label, _, _), .trigger(let label, _, _): label
        case .dpad, .stick: nil
        }
    }
}

/// A drag of the editor: the touch's place in the element when it began, and the element's size then.
struct OscDrag: Equatable, Sendable {
    var resize: Bool
    var pressedX: Int
    var pressedY: Int
    var startWidth: Int
    var startHeight: Int
}

/// The on-screen controls of DELOS for Android (`VirtualController` and its elements) on iPhone and iPad: the D-pad, A/B/X/Y,
/// the bumpers and triggers, Back, Guide and Start, L3 and R3, the trackpad button and the two sticks (fixed, or free where the
/// finger lands), laid out by ``OscDefaultLayout`` on the panel they are drawn on with the player's stored changes
/// (``OscPlacement``), edited with the gear in the corner. Every touch is in pixels of the panel and has its own id, so any
/// number of fingers press any number of controls at once; a control takes the first finger that lands on it and ignores
/// the others. What the controls hold is one controller state (Android's `ControllerInputContext`), sent whole on every
/// change and again 25, 50 and 75 ms later (GFE drops a packet that follows another too closely).
@MainActor
@Observable
final class OnScreenControls {
    private(set) var elements: [OscElement] = []
    private(set) var panel = OscPanel(width: 0, height: 0)
    private(set) var mode = OscMode.active
    private(set) var options: OscOptions
    /// The player wants them up (Android's `shown`; the stream menu's toggle).
    private(set) var enabled: Bool
    /// They hide while a controller is the input in use (`checkbox_hide_osc_when_has_gamepad`); the stream menu's toggle ends it
    /// for the stream.
    private(set) var followsGamepad: Bool
    /// The input in use is a controller.
    private(set) var gamepadInUse = false
    /// The state the controls hold, as the PC gets it.
    private(set) var state = ControllerState()

    @ObservationIgnored var output: OscOutput
    /// Who owns each touch.
    @ObservationIgnored private var touches: [Int: Owner] = [:]
    /// The touches each element holds, the first one first.
    @ObservationIgnored private var held: [OscElementID: [Int]] = [:]
    @ObservationIgnored private var points: [Int: (x: Float, y: Float)] = [:]
    @ObservationIgnored private var longClicks: [OscElementID: Task<Void, Never>] = [:]
    @ObservationIgnored private var retransmit: Task<Void, Never>?
    /// The gear's pixel size factor of the panel height and its margin.
    static let gearShare: Float = 0.06
    static let gearMargin = 15
    /// How long a button is held before its long press is sent (`DigitalButton.timerLongClickTimeout`).
    static let longClickMilliseconds = 3000
    /// A second press of a stick within this is L3 / R3 (`AnalogStick.timeoutDoubleClick`).
    static let doubleClickMilliseconds = 350.0
    /// A fixed stick held this long leaves its dead zone (`AnalogStick.timeoutDeadzone`).
    static let deadZoneMilliseconds = 150.0
    /// The resends after each change (`delayedRetransmitRunnable`).
    static let retransmitMilliseconds = [25, 50, 75]

    private enum Owner { case element(OscElementID), gear }

    init(options: OscOptions, enabled: Bool, followsGamepad: Bool, output: OscOutput = OscOutput()) {
        self.options = options
        self.enabled = enabled
        self.followsGamepad = followsGamepad
        self.output = output
    }

    // MARK: Showing

    /// Whether they are on the screen now.
    var visible: Bool { enabled && !(followsGamepad && gamepadInUse) }

    /// The host's rumble of controller 0 plays on the device (`vibrateOsc` in Android's `ControllerHandler.handleRumble`): the
    /// controls are on and show more than L3 and R3.
    var rumblesDevice: Bool { enabled && !options.onlyL3R3 && options.deviceRumble }

    /// The input in use is a controller, or not any more.
    func setGamepadInUse(_ inUse: Bool) {
        guard inUse != gamepadInUse else { return }
        let was = visible
        gamepadInUse = inUse
        if was, !visible { releaseAll() }
    }

    /// The stream menu's toggle (`toggleVirtualController`): off, or on, also while a controller is in use, for the rest of the
    /// stream.
    func toggle() {
        if visible {
            enabled = false
            releaseAll()
        } else {
            enabled = true
            followsGamepad = false
        }
    }

    /// Lets go of every touch and every control (the stream menu opened, the controls went away).
    func releaseAll() {
        touches.removeAll()
        held.removeAll()
        points.removeAll()
        longClicks.values.forEach { $0.cancel() }
        longClicks.removeAll()
        for i in elements.indices {
            elements[i].pressed = false
            elements[i].heldBy = nil
            elements[i].directions = []
            elements[i].stick = OscStick()
            elements[i].drag = nil
        }
        if state != ControllerState() {
            state = ControllerState()
            send(nil)
        }
    }

    /// The opacity (the stream menu's slider): the controls show it at once, and every later layout of them too.
    func setOpacity(_ percent: Int) {
        options.opacity = min(max(percent, 0), 100)
    }

    /// An element's opacity, 0…1, as Android rounds it to a colour's alpha.
    var elementOpacity: Double { Double(options.opacity * 255 / 100) / 255 }

    /// A free stick's least opacity while it is held.
    var freeStickOpacity: Double { Double(min(max(options.freeStickOpacity, 0), 100) * 255 / 100) / 255 }

    // MARK: Layout

    /// Lays the controls out on a panel of [width] x [height] pixels: the default layout, with the stored changes over it
    /// unless [saved] is false. A panel of the same size keeps what is there, unless [force].
    func layOut(width: Int, height: Int, saved: Bool = true, force: Bool = false) {
        guard width > 0, height > 0, force || width != panel.width || height != panel.height || elements.isEmpty else { return }
        releaseAll()
        panel = OscPanel(width: width, height: height)
        elements = OscDefaultLayout.compute(panel, onlyL3R3: options.onlyL3R3, showGuide: options.showGuide).map {
            OscElement(id: $0.id, kind: Self.kind($0.id, options), slot: $0.slot)
        }
        guard saved else { return }
        let placements = output.readLayout()
        for i in elements.indices {
            guard let placement = placements[elements[i].id.rawValue] else { continue }
            elements[i].slot = placement.slot(on: panel)
            elements[i].enabled = placement.enabled
        }
    }

    /// Other settings (the profile changed them): the controls are laid out again with them.
    func update(_ options: OscOptions) {
        guard options != self.options else { return }
        self.options = options
        layOut(width: panel.width, height: panel.height, force: true)
    }

    /// What element [id] is with [options] (`VirtualControllerConfigurationLoader.createDefaultLayout`).
    static func kind(_ id: OscElementID, _ options: OscOptions) -> OscElementKind {
        let flip = options.flipFaceButtons
        switch id {
        case .dpad: return .dpad
        case .a: return .button(label: flip ? "B" : "A", layer: 1, flag: flip ? .b : .a)
        case .b: return .button(label: flip ? "A" : "B", layer: 1, flag: flip ? .a : .b)
        case .x: return .button(label: flip ? "Y" : "X", layer: 1, flag: flip ? .y : .x)
        case .y: return .button(label: flip ? "X" : "Y", layer: 1, flag: flip ? .x : .y)
        case .leftTrigger: return .trigger(label: "LT", layer: 1, right: false)
        case .rightTrigger: return .trigger(label: "RT", layer: 1, right: true)
        case .leftBumper: return .button(label: "LB", layer: 1, flag: .leftShoulder)
        case .rightBumper: return .button(label: "RB", layer: 1, flag: .rightShoulder)
        case .leftStick: return .stick(right: false, free: options.freeSticks)
        case .rightStick: return .stick(right: true, free: options.freeSticks)
        case .back: return .button(label: "BACK", layer: 2, flag: .back)
        case .start: return .button(label: "START", layer: 3, flag: .play)
        case .leftStickButton: return .button(label: "L3", layer: 1, flag: .leftStick)
        case .rightStickButton: return .button(label: "R3", layer: 1, flag: .rightStick)
        case .touchpad: return .button(label: "TRACKPAD", layer: 1, flag: .touchpad)
        case .guide: return .button(label: "GUIDE", layer: 1, flag: .special)
        }
    }

    /// The gear that runs the editor, at the top left (Android's `buttonConfigure`).
    var gearSlot: OscSlot {
        let size = Int(Float(panel.height) * Self.gearShare)
        return OscSlot(left: Self.gearMargin, top: Self.gearMargin, width: size, height: size)
    }

    /// The stroke of a stick's ring and of the editor's frames (`getDefaultStrokeWidth`: 0.4 % of the screen's height).
    var configStroke: Int { Int(Float(panel.height) * 0.004) }

    /// Whether element [element] is drawn now: every one while controls are turned on or off, else the ones that are on.
    func shows(_ element: OscElement) -> Bool { visible && (mode == .disableEnable || element.enabled) }

    /// The stored changes of the layout on screen (`saveProfile`): a control that is on and where the default puts it is not
    /// stored, it follows the default; controls not on screen now keep what was stored for them.
    func placements() -> [Int: OscPlacement] {
        var placements = output.readLayout()
        for e in elements {
            if e.enabled, OscDefaultLayout.isDefault(e.id, e.slot, on: panel) {
                placements.removeValue(forKey: e.id.rawValue)
            } else {
                placements[e.id.rawValue] = OscPlacement(e.id, slot: e.slot, enabled: e.enabled, panel: panel)
            }
        }
        return placements
    }

    /// The gear: the editor's next mode, with its toast; leaving it saves the layout.
    func cycleMode() {
        releaseAll()
        switch mode {
        case .active:
            mode = .disableEnable
            output.announce(L("configuration_mode_disable_enable_buttons"))
        case .disableEnable:
            mode = .move
            output.announce(L("configuration_mode_move_buttons"))
        case .move:
            mode = .resize
            output.announce(L("configuration_mode_resize_buttons"))
        case .resize:
            mode = .active
            output.writeLayout(placements())
            output.announce(L("configuration_mode_exiting"))
        }
    }

    // MARK: Touches

    enum Phase: Sendable { case began, moved, ended, cancelled }

    /// The element or the gear a touch at ([x], [y]) lands on, topmost first; nil: the touch is the stream's. A fixed stick
    /// takes only a touch inside its ring in play.
    func hit(x: Float, y: Float) -> HitTarget? {
        guard visible else { return nil }
        for e in elements.reversed() where shows(e) && e.slot.contains(x: x, y: y) {
            if mode == .active, case .stick(_, false) = e.kind, held[e.id] == nil {
                let local = local(x, y, e)
                let relX = -(Float(e.slot.width / 2) - local.x), relY = -(Float(e.slot.height / 2) - local.y)
                if Double((relX * relX + relY * relY).squareRoot()) > Double(radii(e).complete) { continue }
            }
            return .element(e.id)
        }
        return gearSlot.contains(x: x, y: y) ? .gear : nil
    }

    enum HitTarget: Equatable { case element(OscElementID), gear }

    /// A touch [id] at ([x], [y]) in pixels of the panel at [time] (milliseconds). True when the controls own it: it began on
    /// one of them (or the gear), and the stream must not get it.
    @discardableResult
    func touch(_ id: Int, _ phase: Phase, x: Float, y: Float, time: Double) -> Bool {
        if phase == .began {
            guard let target = hit(x: x, y: y) else { return false }
            switch target {
            case .gear: touches[id] = .gear
            case .element(let element):
                touches[id] = .element(element)
                points[id] = (x, y)
                var list = held[element] ?? []
                list.append(id)
                held[element] = list
                // A second finger on a control is ignored
                if list.count == 1 { event(element, .began, x: x, y: y, time: time) }
            }
            return true
        }
        guard let owner = touches[id] else { return false }
        switch owner {
        case .gear:
            if phase == .ended, gearSlot.contains(x: x, y: y) { cycleMode() }
            if phase == .ended || phase == .cancelled { touches.removeValue(forKey: id) }
        case .element(let element):
            if phase == .moved {
                points[id] = (x, y)
                // The control follows its first finger
                if let first = held[element]?.first, let p = points[first] { event(element, .moved, x: p.x, y: p.y, time: time) }
                return true
            }
            touches.removeValue(forKey: id)
            points.removeValue(forKey: id)
            var list = held[element] ?? []
            list.removeAll { $0 == id }
            held[element] = list.isEmpty ? nil : list
            if list.isEmpty { event(element, phase, x: x, y: y, time: time) }
        }
        return true
    }

    private func index(_ id: OscElementID) -> Int? { elements.firstIndex { $0.id == id } }

    private func local(_ x: Float, _ y: Float, _ e: OscElement) -> (x: Float, y: Float) {
        (x - Float(e.slot.left), y - Float(e.slot.top))
    }

    /// One event of an element's first finger (`VirtualControllerElement.onTouchEvent`): the editor's while it runs, else the
    /// control's own.
    private func event(_ id: OscElementID, _ phase: Phase, x: Float, y: Float, time: Double) {
        guard let i = index(id) else { return }
        if mode.configuring {
            edit(i, phase, x: x, y: y)
            return
        }
        switch elements[i].kind {
        case .button, .trigger: button(i, phase, x: x, y: y)
        case .dpad: dpad(i, phase, x: x, y: y)
        case .stick(_, false): fixedStick(i, phase, x: x, y: y, time: time)
        case .stick(_, true): freeStick(i, phase, x: x, y: y, time: time)
        }
    }

    // MARK: The editor

    private func edit(_ i: Int, _ phase: Phase, x: Float, y: Float) {
        let l = local(x, y, elements[i])
        switch phase {
        case .began:
            switch mode {
            case .move, .resize:
                elements[i].drag = OscDrag(
                    resize: mode == .resize, pressedX: Int(l.x), pressedY: Int(l.y),
                    startWidth: elements[i].slot.width, startHeight: elements[i].slot.height)
            case .disableEnable:
                elements[i].enabled.toggle()
            case .active:
                break
            }
        case .moved:
            guard let drag = elements[i].drag else { return }
            if drag.resize {
                // `resizeElement`: the size follows the finger, at least 20 pixels
                elements[i].slot.width = max(20, Int(l.x) + (drag.startWidth - drag.pressedX))
                elements[i].slot.height = max(20, Int(l.y) + (drag.startHeight - drag.pressedY))
            } else {
                // `moveElement`: the element follows the finger, never past the top or left edge
                elements[i].slot.left = max(0, elements[i].slot.left + Int(l.x) - drag.pressedX)
                elements[i].slot.top = max(0, elements[i].slot.top + Int(l.y) - drag.pressedY)
            }
        case .ended, .cancelled:
            elements[i].drag = nil
        }
    }

    // MARK: Buttons and triggers (`DigitalButton`)

    private func button(_ i: Int, _ phase: Phase, x: Float, y: Float) {
        switch phase {
        case .began:
            elements[i].heldBy = nil
            elements[i].pressed = true
            click(i)
        case .moved:
            slide(from: i, x: x, y: y)
        case .ended, .cancelled:
            elements[i].pressed = false
            release(i)
            slide(from: i, x: x, y: y)
        }
    }

    /// `checkMovementForAllButtons`: the buttons of [i]'s layer under the finger take its pressed state, and the ones it held
    /// and left are released. Only the controls on screen take part.
    private func slide(from i: Int, x: Float, y: Float) {
        let moving = elements[i]
        guard let layer = moving.kind.layer else { return }
        for j in elements.indices where j != i && elements[j].kind.layer == layer && shows(elements[j]) {
            let was = elements[j].pressed
            if (elements[j].heldBy == nil || elements[j].heldBy == moving.id) && elements[j].slot.contains(x: x, y: y) {
                if elements[j].pressed != moving.pressed { elements[j].pressed = moving.pressed }
            } else if elements[j].heldBy == moving.id {
                elements[j].pressed = false
            }
            guard was != elements[j].pressed else { continue }
            if elements[j].pressed {
                elements[j].heldBy = moving.id
                click(j)
            } else {
                elements[j].heldBy = nil
                release(j)
            }
        }
    }

    private func click(_ i: Int) {
        let id = elements[i].id
        switch elements[i].kind {
        case .button(_, _, let flag):
            state.buttons.insert(flag)
            send(.press)
        case .trigger(_, _, let right):
            if right { state.rightTrigger = 0xFF } else { state.leftTrigger = 0xFF }
            send(.press)
        default: return
        }
        longClicks[id]?.cancel()
        longClicks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(Self.longClickMilliseconds)) } catch { return }
            self?.longClick(id)
        }
    }

    /// A button held for 3 s: its long press (no button of the layout has one of its own, so the state is sent again); a
    /// trigger does nothing.
    private func longClick(_ id: OscElementID) {
        longClicks.removeValue(forKey: id)
        guard let i = index(id), case .button = elements[i].kind else { return }
        send(.press)
    }

    private func release(_ i: Int) {
        switch elements[i].kind {
        case .button(_, _, let flag):
            state.buttons.remove(flag)
        case .trigger(_, _, let right):
            if right { state.rightTrigger = 0 } else { state.leftTrigger = 0 }
        default: return
        }
        send(.press)
        longClicks.removeValue(forKey: elements[i].id)?.cancel()
    }

    // MARK: D-pad (`DigitalPad`)

    private func dpad(_ i: Int, _ phase: Phase, x: Float, y: Float) {
        let slot = elements[i].slot
        let l = local(x, y, elements[i])
        var directions = OscDirections()
        if phase == .began || phase == .moved {
            if l.x < Float(slot.width) / 100 * 33 { directions.insert(.left) }
            if l.x > Float(slot.width) / 100 * 66 { directions.insert(.right) }
            if l.y > Float(slot.height) / 100 * 66 { directions.insert(.down) }
            if l.y < Float(slot.height) / 100 * 33 { directions.insert(.up) }
        }
        elements[i].directions = directions
        let flags: [(OscDirections, ControllerButtons)] = [(.left, .left), (.right, .right), (.up, .up), (.down, .down)]
        for (direction, flag) in flags {
            if directions.contains(direction) { state.buttons.insert(flag) } else { state.buttons.remove(flag) }
        }
        send(.dpad)
    }

    // MARK: Sticks (`AnalogStick`, `AnalogStickFree`)

    /// A stick's radii in pixels: its reach, its dead zone and its knob, from the element's shorter side.
    func radii(_ e: OscElement) -> (complete: Float, deadZone: Float, knob: Float) {
        let half = Float(min(e.slot.width, e.slot.height) / 2)
        return (half / 100 * 100 - Float(2 * configStroke), half / 100 * 30, half / 100 * 20)
    }

    /// `getAngle`, as Android computes it (straight up and down from the centre, the one exact float, read the other way).
    static func angle(_ wayX: Float, _ wayY: Float) -> Double {
        if wayX == 0 { return wayY < 0 ? .pi : 0 }
        if wayY == 0 {
            if wayX > 0 { return .pi * 3 / 2 }
            if wayX < 0 { return .pi / 2 }
        }
        if wayX > 0 {
            return wayY < 0 ? 3 * .pi / 2 + atan(Double(-wayY / wayX)) : .pi + atan(Double(wayX / wayY))
        }
        return wayY > 0 ? .pi / 2 + atan(Double(wayY / -wayX)) : atan(Double(-wayX / -wayY))
    }

    private func fixedStick(_ i: Int, _ phase: Phase, x: Float, y: Float, time: Double) {
        let e = elements[i]
        let l = local(x, y, e)
        let relX = -(Float(e.slot.width / 2) - l.x), relY = -(Float(e.slot.height / 2) - l.y)
        stickEvent(i, phase, relX: relX, relY: relY, time: time, centerX: Float(e.slot.width / 2), centerY: Float(e.slot.height / 2), deadZoneTime: true)
    }

    private func freeStick(_ i: Int, _ phase: Phase, x: Float, y: Float, time: Double) {
        let l = local(x, y, elements[i])
        if phase == .began, !elements[i].stick.fingerDown {
            elements[i].stick.startX = l.x
            elements[i].stick.startY = l.y
            elements[i].stick.fingerDown = true
        }
        if phase == .ended || phase == .cancelled { elements[i].stick.fingerDown = false }
        let s = elements[i].stick
        // The free stick lifts its dead zone only by distance: Android compares the event's uptime with a wall-clock press time,
        // so its time rule never fires
        stickEvent(i, phase, relX: -(s.startX - l.x), relY: -(s.startY - l.y), time: time, centerX: s.startX, centerY: s.startY, deadZoneTime: false)
    }

    private func stickEvent(_ i: Int, _ phase: Phase, relX: Float, relY: Float, time: Double, centerX: Float, centerY: Float, deadZoneTime: Bool) {
        let r = radii(elements[i])
        var s = elements[i].stick
        let wasDouble = s.doubleClick
        s.movementRadius = Double((relX * relX + relY * relY).squareRoot())
        s.movementAngle = Self.angle(relX, relY)
        s.movementRadius = min(s.movementRadius, Double(r.complete - r.knob))
        switch phase {
        case .began:
            s.motion = .inDeadZone
            // A fixed stick counts the bound itself, a free one does not (`<=` and `>` in Android)
            let since = time - s.lastClick
            if !wasDouble && (deadZoneTime ? since <= Self.doubleClickMilliseconds : since < Self.doubleClickMilliseconds) {
                s.doubleClick = true
                stickClick(i, down: true)
            } else {
                s.doubleClick = false
            }
            s.lastClick = time
            elements[i].pressed = true
        case .ended, .cancelled:
            elements[i].pressed = false
        case .moved:
            break
        }
        if elements[i].pressed {
            let complete = r.complete - r.knob
            let correlatedY = Float(sin(.pi / 2 - s.movementAngle) * s.movementRadius)
            let correlatedX = Float(cos(.pi / 2 - s.movementAngle) * s.movementRadius)
            s.knobX = centerX - correlatedX
            s.knobY = centerY - correlatedY
            s.motion = s.motion == .active || (deadZoneTime && time - s.lastClick > Self.deadZoneMilliseconds)
                || s.movementRadius > Double(r.deadZone) ? .active : .inDeadZone
            elements[i].stick = s
            if s.motion == .active { stickMoved(i, x: -correlatedX / complete, y: correlatedY / complete) }
        } else {
            s.motion = .none
            elements[i].stick = s
            stickClick(i, down: false)
            stickMoved(i, x: 0, y: 0)
        }
    }

    /// A double press of a stick holds L3 / R3 until it is let go.
    private func stickClick(_ i: Int, down: Bool) {
        guard case .stick(let right, _) = elements[i].kind else { return }
        let flag: ControllerButtons = right ? .rightStick : .leftStick
        if down { state.buttons.insert(flag) } else { state.buttons.remove(flag) }
        send(.press)
    }

    private func stickMoved(_ i: Int, x: Float, y: Float) {
        guard case .stick(let right, _) = elements[i].kind else { return }
        if right {
            state.rightStickX = Self.axis(x)
            state.rightStickY = Self.axis(y)
        } else {
            state.leftStickX = Self.axis(x)
            state.leftStickY = Self.axis(y)
        }
        send(.stick)
    }

    /// `(short) (value * 0x7FFE)`: Java's float to int (towards zero, NaN to 0, saturated), then to a short.
    static func axis(_ value: Float) -> Int16 {
        let scaled = value * 0x7FFE
        let integer: Int32 = scaled.isNaN ? 0 : scaled >= Float(Int32.max) ? .max : scaled <= Float(Int32.min) ? .min : Int32(scaled)
        return Int16(truncatingIfNeeded: integer)
    }

    // MARK: Sending

    /// Sends the state, plays [vibration] when presses vibrate, and sends the state again 25, 50 and 75 ms later unless
    /// another change comes first.
    private func send(_ vibration: OscVibration?) {
        retransmit?.cancel()
        output.send(state)
        if let vibration, options.pressHaptics { output.vibrate(vibration) }
        let state = self.state
        retransmit = Task { [weak self] in
            var elapsed = 0
            for at in Self.retransmitMilliseconds {
                do { try await Task.sleep(for: .milliseconds(at - elapsed)) } catch { return }
                elapsed = at
                self?.output.send(state)
            }
        }
    }
}
