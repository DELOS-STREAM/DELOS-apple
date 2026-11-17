import DelosCore
import Foundation
import GameController

/// Where the input of a stream goes: the running `StreamSession`, or a fake in tests.
public protocol StreamInputSink: Sendable {
    func sendControllerArrival(
        number: UInt8, activeGamepadMask: UInt16, type: ControllerType, supportedButtons: ControllerButtons,
        capabilities: ControllerCapabilities) throws(InputError)
    func sendController(number: UInt8, activeGamepadMask: UInt16, state: ControllerState) throws(InputError)
    func sendMouseMove(deltaX: Int16, deltaY: Int16) throws(InputError)
    func sendMouseButton(_ button: MouseButton, pressed: Bool) throws(InputError)
    func sendKey(code: Int16, pressed: Bool, modifiers: KeyModifiers, nonNormalized: Bool) throws(InputError)
    func sendText(_ text: String) throws(InputError)
    func sendServerCommand(_ id: UInt8) throws(InputError)
    func sendHighResolutionScroll(amount: Int16) throws(InputError)
    func sendHighResolutionHorizontalScroll(amount: Int16) throws(InputError)
}

extension StreamSession: StreamInputSink {}

/// The game controllers, the hardware keyboard and the mouse during a stream: their input goes to the host, and the
/// host's rumble comes back to the controllers.
///
/// Each controller gets the lowest free controller number and is announced to the host with its type, buttons and
/// capabilities; its state is sent whenever an element changes. The system gestures of the controllers' buttons (the
/// Home button's Game Center overlay, a held Share button's screenshot) are off while the input runs, so the host gets
/// those buttons. L3 + R3 (``MenuShortcut``) opens the stream menu; while ``paused`` (the menu is open) nothing is
/// sent and every held control is released at the host.
///
/// The handlers are GameController's profile-level `valueChangedHandler` of the gamepad and the per-key handlers of
/// the keyboard, so ``MenuInput``'s handlers keep working next to them.
@MainActor
public final class GameInput {
    private let sink: any StreamInputSink
    private let onMenu: @MainActor () -> Void
    private var observers: [NSObjectProtocol] = []
    private var slots = ControllerSlots<ObjectIdentifier>()
    private var pads: [ObjectIdentifier: Pad] = [:]
    private var heldKeys: Set<Int> = []
    private var heldMouseButtons: Set<MouseButton> = []
    private var mouseRemainder = (x: 0.0, y: 0.0)
    private var scrollRemainder = (x: 0.0, y: 0.0)
    private var running = false
    /// Counts down while Escape is held (``MenuKeyShortcut``).
    private var escapeHold: Task<Void, Never>?
    private let escapeHoldDuration: Duration

    /// Moonlight's divisor of GameController's mouse motion.
    nonisolated static let mouseSpeedDivisor = 1.25
    /// High-resolution wheel units per GameController scroll unit (Moonlight).
    nonisolated static let scrollUnit = 20.0

    @MainActor
    private final class Pad {
        let controller: GCController
        let number: UInt8
        let haptics: ControllerHaptics
        var shortcut = MenuShortcut()
        var announced = false

        init(controller: GCController, number: UInt8) {
            self.controller = controller
            self.number = number
            haptics = ControllerHaptics(controller: controller)
        }
    }

    /// - Parameters:
    ///   - onMenu: the menu shortcut was pressed (L3 + R3 on a controller, ``MenuKeyShortcut`` on a keyboard).
    ///   - escapeHold: how long Escape is held to open the menu.
    public init(
        sink: any StreamInputSink, escapeHold: Duration = MenuKeyShortcut.holdDuration,
        onMenu: @escaping @MainActor () -> Void
    ) {
        self.sink = sink
        self.onMenu = onMenu
        escapeHoldDuration = escapeHold
    }

    /// While true (the stream menu is open) no input reaches the host.
    public var paused = false {
        didSet {
            guard paused, !oldValue else { return }
            releaseAll()
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
        running = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for id in Array(pads.keys) { detach(id) }
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            for usage in KeyboardMapping.mappedUsages {
                keyboard.button(forKeyCode: GCKeyCode(rawValue: usage))?.pressedChangedHandler = nil
            }
        }
        for mouse in GCMouse.mice() { detach(mouse) }
    }

    // MARK: Rumble

    public func rumble(controller number: UInt16, low: UInt16, high: UInt16) {
        pad(number)?.haptics.rumble(low: low, high: high)
    }

    public func rumbleTriggers(controller number: UInt16, left: UInt16, right: UInt16) {
        pad(number)?.haptics.rumbleTriggers(left: left, right: right)
    }

    private func pad(_ number: UInt16) -> Pad? {
        pads.values.first { UInt16($0.number) == number }
    }

    // MARK: Controllers

    private func attachAll() {
        guard running else { return }
        GCController.controllers().forEach(attach)
        if let keyboard = GCKeyboard.coalesced { attach(keyboard) }
        GCMouse.mice().forEach(attach)
    }

    private func attach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard pads[id] == nil, let gamepad = controller.extendedGamepad, let number = slots.number(for: id) else { return }
        let pad = Pad(controller: controller, number: number)
        pads[id] = pad
        for element in controller.physicalInputProfile.allElements {
            element.preferredSystemGestureState = .disabled
        }
        controller.playerIndex = GCControllerPlayerIndex(rawValue: Int(number)) ?? .indexUnset
        announce(pad)
        gamepad.valueChangedHandler = { [weak self] gamepad, _ in
            let snapshot = Self.snapshot(gamepad)
            MainActor.assumeIsolated { self?.send(snapshot, from: id) }
        }
        send(Self.snapshot(gamepad), from: id)
    }

    private func detach(_ id: ObjectIdentifier) {
        guard let pad = pads.removeValue(forKey: id) else { return }
        pad.haptics.stop()
        pad.controller.extendedGamepad?.valueChangedHandler = nil
        for element in pad.controller.physicalInputProfile.allElements {
            element.preferredSystemGestureState = .enabled
        }
        slots.remove(id)
        // The host removes a controller whose bit left the mask
        try? sink.sendController(number: pad.number, activeGamepadMask: slots.mask, state: ControllerState())
    }

    private func announce(_ pad: Pad) {
        let haptics = ControllerHaptics.capabilities(of: pad.controller)
        var capabilities: ControllerCapabilities = [.analogTriggers]
        if haptics.rumble { capabilities.insert(.rumble) }
        if haptics.triggers { capabilities.insert(.triggerRumble) }
        if pad.controller.light != nil { capabilities.insert(.rgbLED) }
        if pad.controller.battery != nil { capabilities.insert(.batteryState) }
        if let motion = pad.controller.motion {
            if motion.hasGravityAndUserAcceleration { capabilities.insert(.accelerometer) }
            if motion.hasRotationRate { capabilities.insert(.gyroscope) }
        }
        pad.announced = (try? sink.sendControllerArrival(
            number: pad.number, activeGamepadMask: slots.mask, type: Self.type(of: pad.controller),
            supportedButtons: Self.supportedButtons(pad.controller), capabilities: capabilities)) != nil
    }

    private func send(_ snapshot: GamepadSnapshot, from id: ObjectIdentifier) {
        guard let pad = pads[id] else { return }
        let state = GamepadMapping.state(snapshot)
        let (forward, open) = pad.shortcut.update(state.buttons)
        if open { onMenu() }
        guard !paused else { return }
        if !pad.announced { announce(pad) }
        var sent = state
        sent.buttons = forward
        try? sink.sendController(number: pad.number, activeGamepadMask: slots.mask, state: sent)
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
        switch controller.extendedGamepad {
        case is GCXboxGamepad: .xbox
        case is GCDualShockGamepad, is GCDualSenseGamepad: .playStation
        default: controller.productCategory.localizedCaseInsensitiveContains("switch") ? .nintendo : .unknown
        }
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

    func key(_ usage: Int, pressed: Bool) {
        guard let vk = KeyboardMapping.virtualKey(hidUsage: usage) else { return }
        if pressed {
            guard !paused else { return }
            if MenuKeyShortcut.completesChord(usage: usage, held: heldKeys) {
                // The menu pauses the input, which lets go of the modifiers at the PC; the M never reached it
                onMenu()
                return
            }
            if usage == MenuKeyShortcut.escape { startEscapeHold() }
            heldKeys.insert(usage)
        } else {
            if usage == MenuKeyShortcut.escape { cancelEscapeHold() }
            // A key pressed while paused never reached the host
            guard heldKeys.remove(usage) != nil else { return }
        }
        try? sink.sendKey(
            code: KeyboardMapping.keyCode(vk), pressed: pressed, modifiers: KeyboardMapping.modifiers(held: heldKeys),
            nonNormalized: false)
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            MainActor.assumeIsolated { self?.mouseMoved(dx: Double(dx), dy: Double(dy)) }
        }
        let buttons: [(GCControllerButtonInput?, MouseButton)] = [
            (input.leftButton, .left), (input.rightButton, .right), (input.middleButton, .middle),
            (input.auxiliaryButtons?.first, .x1), (input.auxiliaryButtons?.dropFirst().first, .x2),
        ]
        for (button, mouseButton) in buttons {
            button?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { self?.mouseButton(mouseButton, pressed: pressed) }
            }
        }
        input.scroll.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.scrolled(x: Double(x), y: Double(y)) }
        }
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
        guard !paused else { return }
        // GameController's y grows upwards, the host's downwards
        mouseRemainder.x += dx / Self.mouseSpeedDivisor
        mouseRemainder.y -= dy / Self.mouseSpeedDivisor
        let x = Int16(clamping: Int(mouseRemainder.x.rounded(.towardZero)))
        let y = Int16(clamping: Int(mouseRemainder.y.rounded(.towardZero)))
        guard x != 0 || y != 0 else { return }
        mouseRemainder.x -= Double(x)
        mouseRemainder.y -= Double(y)
        try? sink.sendMouseMove(deltaX: x, deltaY: y)
    }

    private func mouseButton(_ button: MouseButton, pressed: Bool) {
        if pressed {
            guard !paused else { return }
            heldMouseButtons.insert(button)
        } else {
            guard heldMouseButtons.remove(button) != nil else { return }
        }
        try? sink.sendMouseButton(button, pressed: pressed)
    }

    private func scrolled(x: Double, y: Double) {
        guard !paused else { return }
        scrollRemainder.x += x
        scrollRemainder.y += y
        let h = Int(scrollRemainder.x.rounded(.towardZero)), v = Int(scrollRemainder.y.rounded(.towardZero))
        scrollRemainder.x -= Double(h)
        scrollRemainder.y -= Double(v)
        if v != 0 { try? sink.sendHighResolutionScroll(amount: Int16(clamping: v * Int(Self.scrollUnit))) }
        // Horizontal scrolling runs the other way round from vertical (Moonlight)
        if h != 0 { try? sink.sendHighResolutionHorizontalScroll(amount: Int16(clamping: -h * Int(Self.scrollUnit))) }
    }

    /// Touch on the screen as the PC's mouse (``TouchTrackpad``).
    public func send(_ action: PointerAction) {
        guard !paused else { return }
        switch action {
        case let .move(dx, dy):
            try? sink.sendMouseMove(deltaX: dx, deltaY: dy)
        case let .click(button):
            try? sink.sendMouseButton(button, pressed: true)
            try? sink.sendMouseButton(button, pressed: false)
        case let .scroll(amount):
            try? sink.sendHighResolutionScroll(amount: amount)
        }
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

    /// Runs the host's server command [index] (its position in the host's list).
    public func runServerCommand(_ index: Int) {
        guard let id = UInt8(exactly: index) else { return }
        try? sink.sendServerCommand(id)
    }

    /// Releases at the host every button, key and stick held, so nothing stays pressed while the menu is open or
    /// after the stream.
    private func releaseAll() {
        cancelEscapeHold()
        for pad in pads.values {
            try? sink.sendController(number: pad.number, activeGamepadMask: slots.mask, state: ControllerState())
        }
        for usage in heldKeys {
            if let vk = KeyboardMapping.virtualKey(hidUsage: usage) {
                try? sink.sendKey(code: KeyboardMapping.keyCode(vk), pressed: false, modifiers: [], nonNormalized: false)
            }
        }
        heldKeys.removeAll()
        for button in heldMouseButtons { try? sink.sendMouseButton(button, pressed: false) }
        heldMouseButtons.removeAll()
    }
}
