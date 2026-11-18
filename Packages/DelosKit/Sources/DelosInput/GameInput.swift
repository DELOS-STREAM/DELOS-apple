import DelosCore
import Foundation
import GameController
import OSLog

/// Where the input of a stream goes: the running `StreamSession`, or a fake in tests.
public protocol StreamInputSink: Sendable {
    func sendControllerArrival(
        number: UInt8, activeGamepadMask: UInt16, type: ControllerType, supportedButtons: ControllerButtons,
        capabilities: ControllerCapabilities) throws(InputError)
    func sendController(number: UInt8, activeGamepadMask: UInt16, state: ControllerState) throws(InputError)
    func sendControllerMotion(number: UInt8, sensor: MotionSensor, x: Float, y: Float, z: Float) throws(InputError)
    func sendControllerBattery(number: UInt8, state: BatteryState, percentage: UInt8) throws(InputError)
    func sendControllerTouch(
        number: UInt8, _ type: TouchEventType, pointerID: UInt32, x: Float, y: Float, pressure: Float) throws(InputError)
    func sendMouseMove(deltaX: Int16, deltaY: Int16) throws(InputError)
    func sendMouseButton(_ button: MouseButton, pressed: Bool) throws(InputError)
    func sendKey(code: Int16, pressed: Bool, modifiers: KeyModifiers, nonNormalized: Bool) throws(InputError)
    func sendText(_ text: String) throws(InputError)
    func sendServerCommand(_ id: UInt8) throws(InputError)
    func sendScroll(clicks: Int8) throws(InputError)
    func sendHorizontalScroll(clicks: Int8) throws(InputError)
    func sendHighResolutionScroll(amount: Int16) throws(InputError)
    func sendHighResolutionHorizontalScroll(amount: Int16) throws(InputError)
    // The touch modes, the Apple Pencil and the local cursor (``TouchScreen``)
    func sendMousePosition(x: Int16, y: Int16, referenceWidth: Int16, referenceHeight: Int16) throws(InputError)
    func sendMouseMoveAsMousePosition(deltaX: Int16, deltaY: Int16, referenceWidth: Int16, referenceHeight: Int16) throws(InputError)
    func sendTouch(
        _ type: TouchEventType, pointerID: UInt32, x: Float, y: Float, pressureOrDistance: Float,
        contactAreaMajor: Float, contactAreaMinor: Float, rotation: UInt16?) throws(InputError)
    func sendPen(
        _ type: TouchEventType, tool: PenTool, buttons: PenButtons, x: Float, y: Float, pressureOrDistance: Float,
        contactAreaMajor: Float, contactAreaMinor: Float, rotation: UInt16?, tilt: UInt8?) throws(InputError)
}

extension StreamSession: StreamInputSink {}

/// The game controllers, the hardware keyboard and the mouse during a stream: their input goes to the host, and the
/// host's rumble, motion requests and light colour come back to the controllers (`ControllerHandler`,
/// `StreamKeyHandler` and `StreamPointerHandler` of DELOS for Android).
///
/// Each controller gets the lowest free controller number (all of them player 1 with ``ControllerOptions/multiController``
/// off, their states fused) and is announced to the host with its type, buttons and the capabilities this app delivers:
/// rumble, trigger rumble, the light, the battery, the touchpad and the motion sensors. Its state is sent whenever an
/// element changes, through the stick dead zone and flipped face buttons of ``ControllerOptions``. The system gestures of
/// the controllers' buttons (the Home button's Game Center overlay and the system's games overlay, a held Share button's
/// screenshot) are off while the input runs, so the stream gets those buttons. A tap of Home opens the stream menu and
/// sends nothing to the PC; a hold of Home (``GuideTapHold``) is Guide on the PC. The buttons and keys the player recorded
/// (``MenuShortcut``, none by default) open the menu too, and so does a quick double Start held the second time; a held
/// Start (¾ s) toggles the mouse emulation (``MouseEmulation``). While ``paused`` (the menu is open) nothing is sent and
/// every held control is released at the host.
///
/// The handlers are GameController's profile-level `valueChangedHandler` of the gamepad and the per-key handlers of
/// the keyboard, so ``MenuInput``'s handlers keep working next to them.
@MainActor
public final class GameInput {
    /// What the input tells the stream's screen.
    public enum Event: Equatable, Sendable {
        /// The mouse emulation of a controller went on or off (Android's `stream_mouse_emulation_on`/`_off` toast).
        case mouseEmulation(on: Bool)
        /// A controller that is not a PlayStation one was announced as a generic controller, so the PC emulates one with
        /// motion sensors (Android's `toast_controller_type_changed`).
        case controllerTypeChanged
        /// A keyboard combination of ``ClientKeyCombos``.
        case keyCombo(ClientKeyCombos.Action)
    }

    private let sink: any StreamInputSink
    private let onMenu: @MainActor () -> Void
    private let options: ControllerOptions
    /// Called with what the screen shows or does (``Event``).
    public var onEvent: (@MainActor (Event) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var slots = ControllerSlots<ObjectIdentifier>()
    private var pads: [ObjectIdentifier: Pad] = [:]
    /// The controllers in the order they arrived (the first one of a number gets the motion sensors).
    private var padOrder: [ObjectIdentifier] = []
    private var heldKeys: Set<Int> = []
    /// ``heldKeys`` in the order they went down.
    private var keyOrder: [Int] = []
    /// The keys physically down, sent or not (the stream menu's recorded keys).
    private var keysDown: Set<Int> = []
    /// The keys of the Delos full keyboard down at the PC (``sendVirtualKey(_:pressed:)``), in the order they went down.
    private var virtualKeysDown: [UInt8] = []
    private var heldMouseButtons: Set<MouseButton> = []
    private var mouseRemainder = (x: 0.0, y: 0.0)
    private var scrollRemainder = (x: 0.0, y: 0.0)
    private var wheelRemainder = (x: 0.0, y: 0.0)
    private var shortcut: MenuShortcut
    private var keyCombos = ClientKeyCombos()
    private let deviceHaptics = ControllerHaptics()
    public var rumbleConfiguration = RumbleConfiguration() {
        didSet {
            pads.values.forEach { $0.haptics.configuration = rumbleConfiguration }
            deviceHaptics.configuration = rumbleConfiguration
            if !rumbleConfiguration.deviceFallback && !rumbleConfiguration.deviceEnabled { deviceHaptics.stop() }
        }
    }
    public var rumbleProblem: RumbleProblem? {
        deviceHaptics.problem ?? pads.values.lazy.compactMap { $0.haptics.problem }.first
    }
    public var adaptiveTriggerUnsupported: Bool { pads.values.contains { $0.haptics.adaptiveTriggerUnsupported } }
    /// The gyro smoothing in use, 0…100 (``GyroSmoother``); the stream menu changes it while the stream runs.
    public var gyroSmoothing: Int
    /// Whether the keyboard and the mouse reach the PC (Control + Alt + Shift + Z toggles it, ``ClientKeyCombos``).
    /// Released, a key or button that is down at the PC still gets its release.
    public private(set) var inputGrabbed = true
    /// The mouse's motion goes to the PC as absolute positions within an area of this size, the picture's
    /// (`checkbox_absolute_mouse_mode`, `sendMouseMoveAsMousePosition`); nil: as relative motion.
    public var absoluteMouseArea: TouchViewSize?
    /// The local pointer shows (`toggleMouseLocalCursor`): where the system pointer is over the picture is the PC's
    /// pointer (``TouchScreen/pointerMoved(x:y:)``), so the mouse's relative motion is not sent.
    public var localCursor = false
    /// A trackpad's scrolling (the Mac's, ``scrollWheel(dx:dy:precise:)``): its axes swapped and its speed in percent
    /// (`checkbox_trackpad_swap_axis`, `seekbar_trackpad_sensitivity_x`, `_y`).
    public var trackpadSwapAxis = false
    public var trackpadSensitivity = (x: 100, y: 100)
    private var running = false
    /// The on-screen controls' state while they are on (controller 0, `defaultContext` of Android's `ControllerHandler`):
    /// fused with the physical controllers of number 0, if any, and counted in the mask. Nil: off.
    private var onScreen: ControllerState?
    /// Whether the host's rumble of controller 0 with no physical controller 0 plays on this device (the on-screen controls
    /// are on, more than L3 and R3 show, `checkbox_vibrate_osc`).
    public var onScreenRumble = false
    /// Counts down while Escape is held (``MenuKeyShortcut``).
    private var escapeHold: Task<Void, Never>?
    private let escapeHoldDuration: Duration
    /// The motion readings the host asked for, by controller number (kept for a controller that arrives later).
    private var motionRequests: [UInt8: [MotionSensor: Int]] = [:]
    private let deviceMotion = DeviceMotion()
    private var motionRate = MotionSendRate()
    private var motionLog: Task<Void, Never>?
    private static let logger = Logger(subsystem: "io.github.meitoncz.delos", category: "input")
    /// Milliseconds of the clock the timers sleep on; tests move it.
    var clock: @MainActor () -> Int64 = { GameInput.milliseconds() }

    /// Moonlight's divisor of GameController's mouse motion.
    nonisolated static let mouseSpeedDivisor = 1.25
    /// High-resolution wheel units per GameController scroll unit (Moonlight).
    nonisolated static let scrollUnit = 20.0
    /// Pointer pixels per unit of a PlayStation touchpad's axes (−1…1) when it is the mouse: the DualShock 4 and
    /// DualSense touchpads report 1920 × 943 points, one pixel each.
    nonisolated static let touchpadPixels = (x: 960.0, y: 471.5)

    /// Where a controller's motion comes from.
    private enum MotionSource {
        case controller(GCMotion)
        /// This device's sensors (player 1 with the motion fallback).
        case device
    }

    @MainActor
    private final class Pad {
        let controller: GCController
        let number: UInt8
        let haptics: ControllerHaptics
        var announced = false
        /// Home's tap or hold, whether it is down now, and the timer of its hold.
        var guide = GuideTapHold()
        var homeDown = false
        var guideTimer: Task<Void, Never>?
        /// Start's hold (mouse emulation, double Start).
        var start = StartButtonHold()
        var startDown = false
        /// Running while the controller is the mouse.
        var emulation: MouseEmulation?
        var emulationTimer: Task<Void, Never>?
        var combos: ButtonCombos
        /// The controller's last reading, sent again when the hold makes Home Guide.
        var last = GamepadSnapshot()
        /// The state for the PC that this controller adds to its number.
        var state = ControllerState()
        let motionSource: MotionSource?
        var motion: [MotionSensor: MotionStream] = [:]
        /// The touchpad's fingers (−1…1, nil when lifted) and whether it is the mouse.
        var touches: [CGPoint?] = [nil, nil]
        var touchpadAsMouse: Bool
        var battery: BatteryReport?
        var batteryTimer: Task<Void, Never>?

        init(controller: GCController, number: UInt8, motionSource: MotionSource?, combos: ButtonCombos, touchpadAsMouse: Bool) {
            self.controller = controller
            self.number = number
            self.motionSource = motionSource
            self.combos = combos
            self.touchpadAsMouse = touchpadAsMouse
            haptics = ControllerHaptics(controller: controller)
        }

        /// Forgets Home's and Start's presses and Home's timer.
        func forgetGestures() {
            guideTimer?.cancel()
            guideTimer = nil
            guide.reset()
            start.reset()
            startDown = false
            combos.reset()
        }

        var touchpads: [GCControllerDirectionPad] {
            [GCInputDualShockTouchpadOne, GCInputDualShockTouchpadTwo].compactMap { controller.physicalInputProfile.dpads[$0] }
        }
    }

    /// - Parameters:
    ///   - menuButtons: the stream menu's own combination of controller buttons and keys (``MenuShortcut``).
    ///   - options: the controller, keyboard and mouse settings of the profile.
    ///   - onMenu: the stream menu is asked for (a tap of Home, the recorded buttons, ``MenuKeyShortcut`` on a keyboard).
    ///   - escapeHold: how long Escape is held to open the menu.
    public init(
        sink: any StreamInputSink, menuButtons: Set<ShortcutButton> = [], options: ControllerOptions = ControllerOptions(),
        escapeHold: Duration = MenuKeyShortcut.holdDuration, onMenu: @escaping @MainActor () -> Void
    ) {
        self.sink = sink
        self.options = options
        shortcut = MenuShortcut(buttons: menuButtons)
        gyroSmoothing = options.gyroSmoothing
        self.onMenu = onMenu
        escapeHoldDuration = escapeHold
    }

    /// While true (the stream menu is open) no input reaches the host; a Home or Start press in progress is forgotten
    /// (Guide is released with the rest).
    public var paused = false {
        didSet {
            guard paused, !oldValue else { return }
            pads.values.forEach { $0.forgetGestures() }
            releaseAll()
            deviceHaptics.stop()
            pads.values.forEach { $0.haptics.stop() }
        }
    }

    /// While set (the Delos full keyboard is up) the controllers drive it instead of the PC (`setInputSuspended` of
    /// DELOS for Android's `ControllerHandler`): every reading goes here as the controller's previous and new snapshot,
    /// and the PC's controllers get a neutral state, so what was held comes up there. The stream menu's shortcut and a tap
    /// of Home still open the menu (Android checks them before the keyboard); Guide, Start's hold and the mouse emulation
    /// do nothing meanwhile. Setting it to nil gives the controllers back, again from a neutral state.
    public var padCapture: (@MainActor (_ old: GamepadSnapshot, _ new: GamepadSnapshot) -> Void)? {
        didSet {
            guard (oldValue == nil) != (padCapture == nil) else { return }
            pads.values.forEach { $0.forgetGestures() }
            for pad in pads.values { pad.state = ControllerState() }
            for number in Set(pads.values.map(\.number) + (onScreen == nil ? [] : [0])) {
                try? sink.sendController(number: number, activeGamepadMask: activeMask, state: ControllerState())
            }
        }
    }

    /// While true the mouse is the system's pointer (it clicks the Delos full keyboard's keys) and none of it reaches the
    /// PC; a button down at the PC comes up there.
    public var mouseSuspended = false {
        didSet {
            guard mouseSuspended, !oldValue else { return }
            for button in heldMouseButtons { try? sink.sendMouseButton(button, pressed: false) }
            heldMouseButtons.removeAll()
        }
    }

    /// True while a mouse is connected: the system pointer's touches are then the mouse's and must not move the
    /// pointer a second time.
    public var hasMouse: Bool { !GCMouse.mice().isEmpty }

    /// Starts sending; call once the stream runs (the host takes controller arrivals only then).
    public func start() {
        guard !running else { return }
        running = true
        let center = NotificationCenter.default
        let attach: [Notification.Name] = [.GCControllerDidConnect, .GCKeyboardDidConnect, .GCMouseDidConnect]
        for name in attach {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attachAll() }
            })
        }
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            let id = (note.object as? GCController).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                if let id { self?.detach(id) }
            }
        })
        attachAll()
    }

    /// Stops sending, releases what is held at the host and gives the controllers their system gestures back.
    public func stop() {
        guard running else { return }
        releaseAll()
        deviceHaptics.stop()
        running = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for id in padOrder { detach(id) }
        motionLog?.cancel()
        motionLog = nil
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            for usage in KeyboardMapping.mappedUsages {
                keyboard.button(forKeyCode: GCKeyCode(rawValue: usage))?.pressedChangedHandler = nil
            }
        }
        for mouse in GCMouse.mice() { detach(mouse) }
    }

    // MARK: Rumble

    public func rumble(controller number: UInt16, low: UInt16, high: UInt16) {
        guard running, !paused else { return }
        let matching = pads(number)
        matching.forEach { $0.haptics.rumble(low: low, high: high) }
        let supports = matching.contains { ControllerHaptics.capabilities(of: $0.controller).rumble }
        if matching.isEmpty, number == 0, onScreenRumble {
            // The on-screen controls triggered it: the device vibrates at full strength (Android's rumbleSingleVibrator); a
            // device without a Taptic Engine (an iPad) has nothing to vibrate
            if ControllerHaptics.deviceAvailable { deviceHaptics.rumble(low: low, high: high, strength: 100) }
        } else if rumbleConfiguration.usesDevice(controllerCanRumble: supports, controllerNumber: number) {
            deviceHaptics.rumble(low: low, high: high)
        }
    }

    public func rumbleTriggers(controller number: UInt16, left: UInt16, right: UInt16) {
        guard running, !paused else { return }
        pads(number).forEach { $0.haptics.rumbleTriggers(left: left, right: right) }
    }

    public func adaptiveTriggers(controller number: UInt16, flags: UInt8, typeLeft: UInt8, typeRight: UInt8, left: [UInt8], right: [UInt8]) {
        guard running, !paused else { return }
        pads(number).forEach {
            $0.haptics.adaptiveTriggers(flags: flags, typeLeft: typeLeft, typeRight: typeRight, left: left, right: right)
        }
    }

    /// The controllers of `number` in the order they arrived.
    private func pads(_ number: UInt16) -> [Pad] {
        padOrder.compactMap { pads[$0] }.filter { UInt16($0.number) == number }
    }

    // MARK: Light

    /// The host's colour for the light of controller `number` (`handleSetControllerLED`): every controller of that number
    /// with a light takes it.
    public func controllerLED(controller number: UInt16, red: UInt8, green: UInt8, blue: UInt8) {
        guard running else { return }
        for pad in pads(number) {
            pad.controller.light?.color = GCColor(red: Float(red) / 255, green: Float(green) / 255, blue: Float(blue) / 255)
        }
    }

    // MARK: Motion

    /// The host wants `motionType` (`LI_MOTION_TYPE_*`) of controller `number` at `reportRateHz`, 0 to stop
    /// (`handleSetMotionEventState`). The request is kept, so a controller that arrives later gets it too; the first
    /// controller of the number with a motion source delivers it.
    public func motionEventState(controller number: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        guard running, let sensor = MotionSensor(rawValue: motionType), let number = UInt8(exactly: number) else { return }
        motionRequests[number, default: [:]][sensor] = Int(reportRateHz)
        applyMotion(number)
    }

    /// Turns the sensors of controller `number`'s motion source on or off as the host asked.
    private func applyMotion(_ number: UInt8) {
        guard let pad = pads(UInt16(number)).first, let source = pad.motionSource else { return }
        for sensor in MotionSensor.allCases {
            let rate = motionRequests[number]?[sensor] ?? 0
            let stream = MotionStream(sensor: sensor, requestedHz: rate, smoothing: gyroSmoothing)
            guard stream?.rateHz != pad.motion[sensor]?.rateHz else { continue }
            pad.motion[sensor] = stream
            if case .device = source {
                if let stream, DeviceMotion.has(sensor) {
                    deviceMotion.start(sensor, rateHz: stream.rateHz) { [weak self] x, y, z, time in
                        let value = MotionAxes.device(sensor, x: x, y: y, z: z, rotation: DeviceMotion.rotation())
                        self?.motionReading(value, sensor: sensor, at: time, number: number)
                    }
                } else {
                    deviceMotion.stop(sensor)
                }
            }
        }
        if case .controller(let motion) = source {
            let wanted = !pad.motion.isEmpty
            if motion.sensorsRequireManualActivation { motion.sensorsActive = wanted }
            motion.valueChangedHandler = wanted ? { [weak self] motion in
                let a = motion.acceleration, r = motion.rotationRate
                let accel = MotionAxes.controller(.accelerometer, x: a.x, y: a.y, z: a.z)
                let gyro = motion.hasRotationRate ? MotionAxes.controller(.gyroscope, x: r.x, y: r.y, z: r.z) : nil
                let time = ProcessInfo.processInfo.systemUptime
                MainActor.assumeIsolated {
                    self?.motionReading(accel, sensor: .accelerometer, at: time, number: number)
                    if let gyro { self?.motionReading(gyro, sensor: .gyroscope, at: time, number: number) }
                }
            } : nil
        }
        updateMotionLog()
    }

    /// One reading on the host's axes and units: through the rate, the duplicate check and the gyro filter to the host.
    func motionReading(_ value: (Float, Float, Float), sensor: MotionSensor, at time: TimeInterval, number: UInt8) {
        guard let pad = pads(UInt16(number)).first, var stream = pad.motion[sensor] else { return }
        motionRate.onSensorCallback(pad: number, sensor: sensor)
        let out = stream.process(value, timestamp: time, smoothing: gyroSmoothing)
        pad.motion[sensor] = stream
        guard let out, !paused else { return }
        let accepted = (try? sink.sendControllerMotion(number: number, sensor: sensor, x: out.0, y: out.1, z: out.2)) != nil
        motionRate.onHandedOver(pad: number, sensor: sensor, accepted: accepted)
    }

    /// The `MotionSend` line every second while a controller's sensors are on (Android's motion rate logging).
    private func updateMotionLog() {
        let listening = Set(pads.values.filter { !$0.motion.isEmpty }.map(\.number))
        if listening.isEmpty {
            motionLog?.cancel()
            motionLog = nil
            return
        }
        guard motionLog == nil else { return }
        motionLog = Task { [weak self] in
            var started = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                let window = (now - started).components
                started = now
                let seconds = Double(window.seconds) + Double(window.attoseconds) / 1e18
                let listening = Set(self.pads.values.filter { !$0.motion.isEmpty }.map(\.number))
                for line in self.motionRate.drainLines(window: seconds, listening: listening) {
                    Self.logger.info("\(line, privacy: .public)")
                }
            }
        }
    }

    // MARK: Controllers

    /// The controllers the host is told about; while the on-screen controls are on, controller 0 is one of them.
    private var activeMask: UInt16 { (options.multiController ? slots.mask : 1) | (onScreen == nil ? 0 : 1) }

    private func attachAll() {
        guard running else { return }
        GCController.controllers().forEach(attach)
        if let keyboard = GCKeyboard.coalesced { attach(keyboard) }
        GCMouse.mice().forEach(attach)
    }

    func attach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard pads[id] == nil, let gamepad = controller.extendedGamepad else { return }
        let number: UInt8
        if options.multiController {
            guard let free = slots.number(for: id) else { return }
            number = free
        } else {
            number = 0
        }
        let source = motionSource(of: controller, number: number)
        let combos = ButtonCombos(
            hasSelect: gamepad.buttonOptions != nil, hasHome: gamepad.buttonHome != nil,
            touchpadEmulation: source != nil && Self.type(of: controller) != .playStation)
        let pad = Pad(controller: controller, number: number, motionSource: source, combos: combos, touchpadAsMouse: options.touchpadAsMouse)
        pad.haptics.configuration = rumbleConfiguration
        pads[id] = pad
        padOrder.append(id)
        for element in controller.physicalInputProfile.allElements {
            element.preferredSystemGestureState = .disabled
        }
        if let home = gamepad.buttonHome {
            Self.logger.info("""
                home button of \(controller.vendorName ?? "?", privacy: .public): bound to a system gesture \
                \(home.isBoundToSystemGesture), preferred state \(home.preferredSystemGestureState.rawValue)
                """)
        } else {
            Self.logger.info("\(controller.vendorName ?? "?", privacy: .public) reports no home button")
        }
        controller.playerIndex = GCControllerPlayerIndex(rawValue: Int(number)) ?? .indexUnset
        announce(pad)
        gamepad.valueChangedHandler = { [weak self] gamepad, _ in
            let snapshot = Self.snapshot(gamepad)
            MainActor.assumeIsolated { self?.send(snapshot, from: id) }
        }
        for (index, touchpad) in pad.touchpads.enumerated() {
            touchpad.valueChangedHandler = { [weak self] _, x, y in
                MainActor.assumeIsolated { self?.touch(index, x: x, y: y, from: id) }
            }
        }
        applyMotion(number)
        send(Self.snapshot(gamepad), from: id)
    }

    /// The controller's own sensors (when on in Settings), or this device's for player 1 with the motion fallback when
    /// the controller has none or the fallback is forced (`assignControllerNumberIfNeeded`).
    private func motionSource(of controller: GCController, number: UInt8) -> MotionSource? {
        let own = options.motionSensors ? controller.motion : nil
        let deviceHasSensors = MotionSensor.allCases.contains(where: DeviceMotion.has)
        if options.motionFallbackToDevice, number == 0, own == nil || options.forceDeviceMotion, deviceHasSensors {
            return .device
        }
        return own.map(MotionSource.controller)
    }

    private func detach(_ id: ObjectIdentifier) {
        guard let pad = pads.removeValue(forKey: id) else { return }
        padOrder.removeAll { $0 == id }
        pad.forgetGestures()
        pad.emulationTimer?.cancel()
        pad.batteryTimer?.cancel()
        pad.haptics.stop()
        if pad.number == 0 { deviceHaptics.stop() }
        pad.controller.extendedGamepad?.valueChangedHandler = nil
        pad.touchpads.forEach { $0.valueChangedHandler = nil }
        switch pad.motionSource {
        case .controller(let motion)?:
            motion.valueChangedHandler = nil
            if motion.sensorsRequireManualActivation { motion.sensorsActive = false }
        case .device? where !pad.motion.isEmpty:
            // Only the controller the readings went to stops this device's sensors (another player 1 may follow)
            MotionSensor.allCases.forEach(deviceMotion.stop)
        case .device?, nil:
            break
        }
        // A gyro that stops reporting leaves the PC's controller turning; a last still reading stops it (`disableSensors`)
        if pad.motion[.gyroscope] != nil {
            try? sink.sendControllerMotion(number: pad.number, sensor: .gyroscope, x: 0, y: 0, z: 0)
        }
        for element in pad.controller.physicalInputProfile.allElements {
            element.preferredSystemGestureState = .enabled
        }
        if options.multiController { slots.remove(id) }
        if pads.values.contains(where: { $0.number == pad.number }) || (pad.number == 0 && onScreen != nil) {
            // Another controller is still this player (multiple controllers off): its state alone, and its motion
            sendState(of: pad.number)
            applyMotion(pad.number)
        } else {
            // The host removes a controller whose bit left the mask
            try? sink.sendController(number: pad.number, activeGamepadMask: activeMask, state: ControllerState())
        }
        updateMotionLog()
    }

    private func announce(_ pad: Pad) {
        let haptics = ControllerHaptics.capabilities(of: pad.controller)
        var capabilities: ControllerCapabilities = [.analogTriggers]
        if haptics.rumble { capabilities.insert(.rumble) }
        if haptics.triggers { capabilities.insert(.triggerRumble) }
        if pad.controller.light != nil { capabilities.insert(.rgbLED) }
        if pad.controller.battery != nil { capabilities.insert(.batteryState) }
        if !pad.touchpads.isEmpty { capabilities.insert(.touchpad) }
        var type = Self.type(of: pad.controller)
        switch pad.motionSource {
        case .controller(let motion)?:
            // GameController reports the total acceleration of every controller with motion
            capabilities.insert(.accelerometer)
            if motion.hasRotationRate { capabilities.insert(.gyroscope) }
        case .device?:
            if DeviceMotion.has(.accelerometer) { capabilities.insert(.accelerometer) }
            if DeviceMotion.has(.gyroscope) { capabilities.insert(.gyroscope) }
        case nil:
            break
        }
        let typeChanged = pad.motionSource != nil && type != .playStation
        // The PC emulates a controller with motion sensors (a PlayStation one) only for a generic controller
        if typeChanged { type = .unknown }
        let wasAnnounced = pad.announced
        pad.announced = (try? sink.sendControllerArrival(
            number: pad.number, activeGamepadMask: activeMask, type: type,
            supportedButtons: Self.supportedButtons(pad.controller), capabilities: capabilities)) != nil
        guard pad.announced, !wasAnnounced else { return }
        if typeChanged { onEvent?(.controllerTypeChanged) }
        startBatteryReports(pad)
    }

    /// The battery now and every ``BatteryReport/interval`` while the controller is connected, when on in Settings.
    private func startBatteryReports(_ pad: Pad) {
        guard options.batteryReport, pad.controller.battery != nil else { return }
        pad.batteryTimer?.cancel()
        pad.batteryTimer = Task { [weak self, weak pad] in
            while !Task.isCancelled {
                guard let pad else { return }
                self?.reportBattery(pad)
                do { try await Task.sleep(for: BatteryReport.interval) } catch { return }
            }
        }
    }

    private func reportBattery(_ pad: Pad) {
        guard let battery = pad.controller.battery else { return }
        let report = BatteryReport(state: battery.batteryState, level: battery.batteryLevel)
        guard report != pad.battery else { return }
        try? sink.sendControllerBattery(number: pad.number, state: report.state, percentage: report.percentage)
        pad.battery = report
    }

    func send(_ snapshot: GamepadSnapshot, from id: ObjectIdentifier) {
        guard let pad = pads[id] else { return }
        let previous = pad.last
        pad.last = snapshot
        var state = GamepadMapping.state(snapshot, options: options)
        let (swallowed, open) = updateShortcut(pad: ShortcutButton.pressed(snapshot), from: id)
        ShortcutButton.remove(swallowed, from: &state, flippedFaceButtons: options.flipFaceButtons)
        home(snapshot.home && !swallowed.contains(.home), on: pad, id: id)
        startButton(snapshot.menu && !swallowed.contains(.start) && padCapture == nil, on: pad)
        // Home reaches the PC only as Guide, once it was held
        state.buttons.remove(.special)
        if pad.guide.isGuideDown { state.buttons.insert(.special) }
        state.buttons = pad.combos.apply(state.buttons, now: clock())
        pad.state = state
        if open { onMenu() }
        guard !paused else { return }
        if let padCapture {
            // The keyboard has the controller: the PC keeps the neutral state it got, the mouse emulation stands still
            pad.state = ControllerState()
            padCapture(previous, snapshot)
            return
        }
        if !pad.announced { announce(pad) }
        if pad.emulation != nil {
            emulateMouse(pad)
        } else {
            sendState(of: pad.number)
        }
    }

    /// The state of controller `number`: its controllers' states fused (more than one only with multiple controllers
    /// off), without the ones that are the mouse now.
    private func sendState(of number: UInt8) {
        var states = pads(UInt16(number)).filter { $0.emulation == nil }.map(\.state)
        if number == 0, let onScreen { states.append(onScreen) }
        guard !states.isEmpty else { return }
        try? sink.sendController(number: number, activeGamepadMask: activeMask, state: GamepadMapping.fuse(states))
    }

    /// The shared stream menu shortcut takes what every controller and the keyboard hold now (Android's one
    /// `ButtonShortcut` for every key event).
    private var padsPressed: [ObjectIdentifier: Set<ShortcutButton>] = [:]

    private func updateShortcut(pad pressed: Set<ShortcutButton>, from id: ObjectIdentifier) -> (swallowed: Set<ShortcutButton>, open: Bool) {
        padsPressed[id] = pressed
        return updateShortcut()
    }

    private func updateShortcut() -> (swallowed: Set<ShortcutButton>, open: Bool) {
        var all = ShortcutButton.pressed(keys: keysDown)
        for (id, pressed) in padsPressed where pads[id] != nil { all.formUnion(pressed) }
        return shortcut.update(all)
    }

    /// Home went down or up: a press starts the hold timer, a release before it is a tap (the menu), a release after it
    /// lets go of Guide. A press while the menu is open (or the loader) belongs to no tap or hold.
    private func home(_ down: Bool, on pad: Pad, id: ObjectIdentifier) {
        guard down != pad.homeDown else { return }
        pad.homeDown = down
        Self.logger.info("home \(down ? "down" : "up", privacy: .public)")
        if down {
            guard !paused, pad.guide.onDown(clock()) else { return }
            pad.guideTimer = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(GuideTapHold.holdMilliseconds)) } catch { return }
                self?.homeHeld(id)
            }
        } else {
            pad.guideTimer?.cancel()
            pad.guideTimer = nil
            if pad.guide.onUp() == .tapMenu { onMenu() }
        }
    }

    /// The hold time of Home passed: Guide goes down on the PC while the button stays down.
    private func homeHeld(_ id: ObjectIdentifier) {
        guard let pad = pads[id] else { return }
        pad.guideTimer = nil
        guard !paused, pad.guide.onHoldTimeout(clock()) == .guideDown else { return }
        send(pad.last, from: id)
    }

    /// Start went down or up (``StartButtonHold``): a long press toggles the mouse emulation, a double Start opens the menu.
    private func startButton(_ down: Bool, on pad: Pad) {
        guard down != pad.startDown else { return }
        pad.startDown = down
        if down {
            guard !paused else { return }
            pad.start.onDown(clock())
            return
        }
        switch pad.start.onUp(clock(), mouseEmulation: options.mouseEmulation) {
        case .openMenu: onMenu()
        case .toggleMouseEmulation: toggleMouseEmulation(pad)
        case .none: break
        }
    }

    private func toggleMouseEmulation(_ pad: Pad) {
        pad.emulationTimer?.cancel()
        pad.emulationTimer = nil
        if pad.emulation == nil {
            pad.emulation = MouseEmulation()
            pad.emulationTimer = Task { [weak self, weak pad] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: MouseEmulation.period) } catch { return }
                    guard let self, let pad, let emulation = pad.emulation else { return }
                    guard !self.paused else { continue }
                    emulation.tick(pad.state, scrollStick: self.options.scrollStick).forEach(self.perform)
                }
            }
        } else {
            pad.emulation = nil
        }
        onEvent?(.mouseEmulation(on: pad.emulation != nil))
    }

    /// The controller is the mouse: its buttons click and scroll, the PC's controller gets a neutral state.
    private func emulateMouse(_ pad: Pad) {
        guard var emulation = pad.emulation else { return }
        let actions = emulation.buttons(pad.state.buttons)
        pad.emulation = emulation
        actions.forEach(perform)
        if pad.number == 0, onScreen != nil {
            sendState(of: 0)
        } else {
            try? sink.sendController(number: pad.number, activeGamepadMask: activeMask, state: ControllerState())
        }
    }

    // MARK: On-screen controls

    /// The on-screen controls' state (``OnScreenControls`` in DelosUI); nil turns them off. Sent at once as controller 0,
    /// fused with the physical controllers of number 0 (``GamepadMapping/fuse(_:)``).
    public func setOnScreenControls(_ state: ControllerState?) {
        let wasOn = onScreen != nil
        onScreen = state
        guard running, !paused, state != nil || wasOn else { return }
        if state != nil || pads(0).contains(where: { $0.emulation == nil }) {
            sendState(of: 0)
        } else {
            // Off with no controller 0 left: the host removes it, its bit left the mask
            try? sink.sendController(number: 0, activeGamepadMask: activeMask, state: ControllerState())
        }
    }

    private func perform(_ action: MouseEmulation.Action) {
        guard !paused else { return }
        switch action {
        case let .button(button, pressed):
            if pressed { heldMouseButtons.insert(button) } else { guard heldMouseButtons.remove(button) != nil else { return } }
            try? sink.sendMouseButton(button, pressed: pressed)
        case let .scroll(clicks): try? sink.sendScroll(clicks: clicks)
        case let .horizontalScroll(clicks): try? sink.sendHorizontalScroll(clicks: clicks)
        case let .move(dx, dy): try? sink.sendMouseMove(deltaX: dx, deltaY: dy)
        case let .highResolutionScroll(amount): try? sink.sendHighResolutionScroll(amount: amount)
        case let .highResolutionHorizontalScroll(amount): try? sink.sendHighResolutionHorizontalScroll(amount: amount)
        }
    }

    // MARK: Touchpad

    /// A finger of a PlayStation controller's touchpad moved (x and y −1…1, both 0 when lifted, as GameController reports
    /// it): a touch on the PC's controller (`sendControllerTouchEvent`), or the mouse when the touchpad is the mouse in
    /// Settings or the host takes no controller touches (`tryHandleTouchpadEvent`).
    func touch(_ index: Int, x: Float, y: Float, from id: ObjectIdentifier) {
        guard let pad = pads[id], pad.touches.indices.contains(index) else { return }
        let point: CGPoint? = x == 0 && y == 0 ? nil : CGPoint(x: Double(x), y: Double(y))
        let previous = pad.touches[index]
        pad.touches[index] = point
        guard !paused else { return }
        if pad.touchpadAsMouse {
            guard index == 0, let point, let previous else { return }
            mouseMoved(
                dx: (point.x - previous.x) * Self.touchpadPixels.x * Self.mouseSpeedDivisor,
                dy: (point.y - previous.y) * Self.touchpadPixels.y * Self.mouseSpeedDivisor)
            return
        }
        let type: TouchEventType
        switch (previous, point) {
        case (nil, .some): type = .down
        case (.some, nil): type = .up
        case let (.some(a), .some(b)) where a != b: type = .move
        default: return
        }
        // SDL's mapping of GameController's touchpad axes to 0…1 from the top left
        guard let at = point ?? previous else { return }
        do {
            try sink.sendControllerTouch(
                number: pad.number, type, pointerID: UInt32(index),
                x: Float((1 + at.x) / 2), y: Float(1 - (1 + at.y) / 2), pressure: 0)
        } catch .unsupportedByHost {
            pad.touchpadAsMouse = true
        } catch {}
    }

    nonisolated static func snapshot(_ pad: GCExtendedGamepad) -> GamepadSnapshot {
        var s = GamepadSnapshot()
        s.a = pad.buttonA.isPressed
        s.b = pad.buttonB.isPressed
        s.x = pad.buttonX.isPressed
        s.y = pad.buttonY.isPressed
        s.up = pad.dpad.up.isPressed
        s.down = pad.dpad.down.isPressed
        s.left = pad.dpad.left.isPressed
        s.right = pad.dpad.right.isPressed
        s.leftShoulder = pad.leftShoulder.isPressed
        s.rightShoulder = pad.rightShoulder.isPressed
        s.leftStickButton = pad.leftThumbstickButton?.isPressed ?? false
        s.rightStickButton = pad.rightThumbstickButton?.isPressed ?? false
        s.menu = pad.buttonMenu.isPressed
        s.options = pad.buttonOptions?.isPressed ?? false
        s.home = pad.buttonHome?.isPressed ?? false
        if let buttons = pad.controller?.physicalInputProfile.buttons {
            s.paddle1 = buttons[GCInputXboxPaddleOne]?.isPressed ?? false
            s.paddle2 = buttons[GCInputXboxPaddleTwo]?.isPressed ?? false
            s.paddle3 = buttons[GCInputXboxPaddleThree]?.isPressed ?? false
            s.paddle4 = buttons[GCInputXboxPaddleFour]?.isPressed ?? false
            s.touchpadButton = buttons[GCInputDualShockTouchpadButton]?.isPressed ?? false
            s.share = buttons[GCInputButtonShare]?.isPressed ?? false
        }
        s.leftTrigger = pad.leftTrigger.value
        s.rightTrigger = pad.rightTrigger.value
        s.leftTriggerPressed = pad.leftTrigger.isPressed
        s.rightTriggerPressed = pad.rightTrigger.isPressed
        s.leftStickX = pad.leftThumbstick.xAxis.value
        s.leftStickY = pad.leftThumbstick.yAxis.value
        s.rightStickX = pad.rightThumbstick.xAxis.value
        s.rightStickY = pad.rightThumbstick.yAxis.value
        return s
    }

    private static func supportedButtons(_ controller: GCController) -> ControllerButtons {
        guard let pad = controller.extendedGamepad else { return [] }
        var buttons: ControllerButtons = [.a, .b, .x, .y, .up, .down, .left, .right, .leftShoulder, .rightShoulder, .play]
        if pad.leftThumbstickButton != nil { buttons.insert(.leftStick) }
        if pad.rightThumbstickButton != nil { buttons.insert(.rightStick) }
        if pad.buttonOptions != nil { buttons.insert(.back) }
        if pad.buttonHome != nil { buttons.insert(.special) }
        let profile = controller.physicalInputProfile.buttons
        let extra: [(String, ControllerButtons)] = [
            (GCInputXboxPaddleOne, .paddle1), (GCInputXboxPaddleTwo, .paddle2), (GCInputXboxPaddleThree, .paddle3),
            (GCInputXboxPaddleFour, .paddle4), (GCInputDualShockTouchpadButton, .touchpad), (GCInputButtonShare, .misc),
        ]
        for (name, flag) in extra where profile[name] != nil { buttons.insert(flag) }
        return buttons
    }

    private static func type(of controller: GCController) -> ControllerType {
        switch PadDescriptor(controller).family {
        case .xbox: .xbox
        case .dualSense, .dualShock: .playStation
        case .nintendo: .nintendo
        case .generic: .unknown
        }
    }

    private nonisolated static let epoch = ContinuousClock.now

    /// Milliseconds on the clock the hold timers sleep on.
    nonisolated static func milliseconds() -> Int64 {
        let elapsed = (ContinuousClock.now - epoch).components
        return elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
    }

    // MARK: Keyboard and mouse

    private func attach(_ keyboard: GCKeyboard) {
        guard let input = keyboard.keyboardInput else { return }
        for usage in KeyboardMapping.mappedUsages {
            input.button(forKeyCode: GCKeyCode(rawValue: usage))?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { self?.key(usage, pressed: pressed) }
            }
        }
    }

    /// A key went down or up (HID usage): the stream menu's recorded keys, the menu's keyboard shortcuts
    /// (``MenuKeyShortcut``), the keyboard's own combinations (``ClientKeyCombos``), then the PC, while the input is
    /// grabbed (`handleKeyDown`/`handleKeyUp` of DELOS for Android).
    func key(_ usage: Int, pressed: Bool) {
        let rightAltAsMeta = options.rightAltAsMeta
        guard let vk = KeyboardMapping.virtualKey(hidUsage: usage, rightAltAsMeta: rightAltAsMeta) else { return }
        if pressed { keysDown.insert(usage) } else { keysDown.remove(usage) }
        let (swallowed, open) = updateShortcut()
        if open { onMenu() }
        // The key that completed the recorded shortcut never reaches the PC
        if pressed, swallowed.contains(.key(usage)) { return }
        if pressed {
            guard !paused else { return }
            if MenuKeyShortcut.completesChord(usage: usage, held: heldKeys) {
                // The menu pauses the input, which lets go of the modifiers at the PC; the M never reached it
                onMenu()
                return
            }
            if usage == MenuKeyShortcut.escape { startEscapeHold() }
        } else if usage == MenuKeyShortcut.escape {
            cancelEscapeHold()
        }
        let combo = keyCombos.key(usage, pressed: pressed, rightAltAsMeta: rightAltAsMeta)
        if let action = combo.action { keyAction(action) }
        if combo.consumed { return }
        if pressed {
            guard !paused, inputGrabbed, heldKeys.insert(usage).inserted else { return }
            keyOrder.append(usage)
        } else {
            // A key pressed while paused or not grabbed never reached the host
            guard heldKeys.remove(usage) != nil else { return }
            keyOrder.removeAll { $0 == usage }
        }
        try? sink.sendKey(
            code: KeyboardMapping.keyCode(vk), pressed: pressed,
            modifiers: KeyboardMapping.modifiers(held: heldKeys, rightAltAsMeta: rightAltAsMeta).union(virtualModifiers), nonNormalized: false)
    }

    /// Control + Alt + Shift + Z toggles the grab a moment later (Android's `toggleInputGrabLater`, 250 ms) and tells the
    /// screen once it did; C grabs the input again if it was released (`toggleMouseLocalCursor`) and the screen shows or
    /// hides the local pointer; Q is the screen's.
    private func keyAction(_ action: ClientKeyCombos.Action) {
        switch action {
        case .toggleInputGrab:
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.setInputGrabbed(!self.inputGrabbed)
                self.onEvent?(.keyCombo(.toggleInputGrab))
            }
        case .toggleLocalCursor:
            setInputGrabbed(true)
            onEvent?(.keyCombo(action))
        case .quit:
            onEvent?(.keyCombo(action))
        }
    }

    private func setInputGrabbed(_ grabbed: Bool) {
        inputGrabbed = grabbed
        if !grabbed {
            // The mouse is the system's again: the buttons it holds come up at the PC
            for button in heldMouseButtons { try? sink.sendMouseButton(button, pressed: false) }
            heldMouseButtons.removeAll()
        }
    }

    /// The stream menu's Local mouse cursor grabs the input first, as Control + Alt + Shift + C does.
    public func grabInput() {
        setInputGrabbed(true)
    }

    /// The window lost the focus (another app or window took the keyboard): a key released meanwhile never reaches the
    /// app, so every key down at the PC is released there now, the last pressed first (`releaseHeldKeys` of DELOS for
    /// Android), and the modifiers start from nothing.
    public func releaseKeys() {
        cancelEscapeHold()
        for usage in keyOrder.reversed() {
            if let vk = KeyboardMapping.virtualKey(hidUsage: usage, rightAltAsMeta: options.rightAltAsMeta) {
                try? sink.sendKey(code: KeyboardMapping.keyCode(vk), pressed: false, modifiers: [], nonNormalized: false)
            }
        }
        heldKeys.removeAll()
        keyOrder.removeAll()
        keysDown.removeAll()
        keyCombos.reset()
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            MainActor.assumeIsolated { self?.mouseMoved(dx: Double(dx), dy: Double(dy)) }
        }
        var buttons: [(GCControllerButtonInput?, MouseButton)] = [
            (input.leftButton, .left), (input.rightButton, .right), (input.middleButton, .middle),
        ]
        // Back and forward are X1 and X2 only when on in Settings; off, they send nothing (`mouseNavButtons`)
        if options.mouseNavButtons {
            buttons += [(input.auxiliaryButtons?.first, .x1), (input.auxiliaryButtons?.dropFirst().first, .x2)]
        }
        for (button, mouseButton) in buttons {
            button?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { self?.mouseButton(mouseButton, pressed: pressed) }
            }
        }
        // GameController's scroll of a Mac misses repeated wheel steps and halves trackpad scrolling (it reports a pad that
        // springs back to zero), so the Mac scrolls from AppKit's events (``scrollWheel(dx:dy:precise:)``)
        #if !os(macOS)
        input.scroll.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.scrolled(x: Double(x), y: Double(y)) }
        }
        #endif
    }

    private func detach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = nil
        input.scroll.valueChangedHandler = nil
        for button in [input.leftButton] + [input.rightButton, input.middleButton].compactMap({ $0 }) + (input.auxiliaryButtons ?? []) {
            button.pressedChangedHandler = nil
        }
    }

    private func startEscapeHold() {
        escapeHold?.cancel()
        let duration = escapeHoldDuration
        escapeHold = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.escapeHold = nil
            self?.onMenu()
        }
    }

    private func cancelEscapeHold() {
        escapeHold?.cancel()
        escapeHold = nil
    }

    private func mouseMoved(dx: Double, dy: Double) {
        guard !paused, inputGrabbed, !mouseSuspended, !localCursor else { return }
        // GameController's y grows upwards, the host's downwards
        mouseRemainder.x += dx / Self.mouseSpeedDivisor
        mouseRemainder.y -= dy / Self.mouseSpeedDivisor
        let x = Int16(clamping: Int(mouseRemainder.x.rounded(.towardZero)))
        let y = Int16(clamping: Int(mouseRemainder.y.rounded(.towardZero)))
        guard x != 0 || y != 0 else { return }
        mouseRemainder.x -= Double(x)
        mouseRemainder.y -= Double(y)
        if let area = absoluteMouseArea {
            try? sink.sendMouseMoveAsMousePosition(
                deltaX: x, deltaY: y, referenceWidth: Int16(clamping: area.width), referenceHeight: Int16(clamping: area.height))
        } else {
            try? sink.sendMouseMove(deltaX: x, deltaY: y)
        }
    }

    func mouseButton(_ button: MouseButton, pressed: Bool) {
        if pressed {
            guard !paused, inputGrabbed, !mouseSuspended else { return }
            heldMouseButtons.insert(button)
        } else {
            guard heldMouseButtons.remove(button) != nil else { return }
        }
        try? sink.sendMouseButton(button, pressed: pressed)
    }

    private func scrolled(x: Double, y: Double) {
        guard !paused, inputGrabbed, !mouseSuspended else { return }
        scrollRemainder.x += x
        scrollRemainder.y += y
        let h = Int(scrollRemainder.x.rounded(.towardZero)), v = Int(scrollRemainder.y.rounded(.towardZero))
        scrollRemainder.x -= Double(h)
        scrollRemainder.y -= Double(v)
        if v != 0 { try? sink.sendHighResolutionScroll(amount: Int16(clamping: v * Int(Self.scrollUnit))) }
        // Horizontal scrolling runs the other way round from vertical (Moonlight)
        if h != 0 { try? sink.sendHighResolutionHorizontalScroll(amount: Int16(clamping: -h * Int(Self.scrollUnit))) }
    }

    /// Wheel steps per line of a mouse wheel (Android's `AXIS_VSCROLL` × 120), and a trackpad's wheel units per pixel of
    /// finger motion (`TrackpadContext`'s `SCROLL_SPEED_FACTOR_X` and `_Y`).
    nonisolated static let wheelUnitsPerLine = 120.0
    nonisolated static let trackpadScrollFactor = (x: 2.0, y: 3.0)

    /// AppKit's scrolling of the Mac (`scrollingDeltaX`/`Y`, positive up and left in the user's scroll direction): a
    /// trackpad ([precise], pixels) through the trackpad settings, a wheel (lines) by notches.
    public func scrollWheel(dx: Double, dy: Double, precise: Bool) {
        guard !paused, inputGrabbed else { return }
        if precise {
            let (x, y) = trackpadSwapAxis ? (dy, dx) : (dx, dy)
            wheelRemainder.x -= x * Self.trackpadScrollFactor.x * Double(trackpadSensitivity.x) / 100
            wheelRemainder.y += y * Self.trackpadScrollFactor.y * Double(trackpadSensitivity.y) / 100
        } else {
            wheelRemainder.x -= dx * Self.wheelUnitsPerLine
            wheelRemainder.y += dy * Self.wheelUnitsPerLine
        }
        let h = Int(wheelRemainder.x.rounded(.towardZero)), v = Int(wheelRemainder.y.rounded(.towardZero))
        wheelRemainder.x -= Double(h)
        wheelRemainder.y -= Double(v)
        if v != 0 { try? sink.sendHighResolutionScroll(amount: Int16(clamping: v)) }
        if h != 0 { try? sink.sendHighResolutionHorizontalScroll(amount: Int16(clamping: h)) }
    }

    // MARK: Sent by the stream menu and the on-screen keyboard

    /// Presses a key combination once (the menu closes first: sent while the input is paused it still reaches the host).
    public func send(_ combo: KeyCombo) {
        for event in combo.events {
            try? sink.sendKey(code: event.code, pressed: event.pressed, modifiers: event.modifiers, nonNormalized: false)
        }
    }

    /// Text typed on the on-screen keyboard: Return, Tab and Backspace are keys, the rest goes as text.
    public func type(_ text: String) {
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            try? sink.sendText(run)
            run = ""
        }
        for character in text {
            switch character {
            case "\n", "\r", "\r\n": flush(); send(KeyCombo([VirtualKey.enter]))
            case "\t": flush(); send(KeyCombo([VirtualKey.tab]))
            default: run.append(character)
            }
        }
        flush()
    }

    /// The on-screen keyboard's Backspace.
    public func backspace() {
        send(KeyCombo([VirtualKey.backspace]))
    }

    /// A key of the Delos full keyboard (a Windows virtual key) goes down or up at the PC. The modifiers it carries are the
    /// keyboard's own that are down (latched or held), and the hardware keyboard's (`StreamKeyHandler`'s one modifier
    /// state of DELOS for Android, which every key event updates).
    public func sendVirtualKey(_ key: UInt8, pressed: Bool) {
        if pressed, !virtualKeysDown.contains(key) { virtualKeysDown.append(key) }
        // A modifier carries itself in its release too, like ``KeyCombo``
        let modifiers = virtualModifiers.union(KeyCombo.modifier(of: key))
            .union(KeyboardMapping.modifiers(held: heldKeys, rightAltAsMeta: options.rightAltAsMeta))
        if !pressed { virtualKeysDown.removeAll { $0 == key } }
        try? sink.sendKey(code: KeyboardMapping.keyCode(key), pressed: pressed, modifiers: modifiers, nonNormalized: false)
    }

    /// The modifiers of the Delos full keyboard that are down at the PC.
    private var virtualModifiers: KeyModifiers {
        virtualKeysDown.reduce(into: []) { $0.formUnion(KeyCombo.modifier(of: $1)) }
    }

    /// Runs the host's server command [index] (its position in the host's list).
    public func runServerCommand(_ index: Int) {
        guard let id = UInt8(exactly: index) else { return }
        try? sink.sendServerCommand(id)
    }

    /// Releases at the host every button, key, stick and touch held, so nothing stays pressed while the menu is open or
    /// after the stream.
    private func releaseAll() {
        cancelEscapeHold()
        for number in Set(pads.values.map(\.number) + (onScreen == nil ? [] : [0])) {
            try? sink.sendController(number: number, activeGamepadMask: activeMask, state: ControllerState())
        }
        for pad in pads.values {
            for (index, touch) in pad.touches.enumerated() where touch != nil {
                pad.touches[index] = nil
                if !pad.touchpadAsMouse {
                    try? sink.sendControllerTouch(number: pad.number, .cancelAll, pointerID: 0, x: 0, y: 0, pressure: 0)
                    break
                }
            }
        }
        releaseKeys()
        for button in heldMouseButtons { try? sink.sendMouseButton(button, pressed: false) }
        heldMouseButtons.removeAll()
    }
}
