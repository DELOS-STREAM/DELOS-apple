import Foundation
import GameController

/// A command for moving through the interface, from a game controller or a hardware keyboard.
public enum MenuCommand: Sendable, Hashable {
    case up, down, left, right
    /// A (or Return): activate the focused item.
    case accept
    /// B (or Escape): go back.
    case back
    /// L1 and R1: the previous and the next tab.
    case previousTab, nextTab
    /// The left menu button (View, Select, Create): the side menu.
    case menu
    /// The right menu button (Menu, Start, Options), X or the keyboard's menu key: the focused item's context menu
    /// (`KEYCODE_BUTTON_START` and `KEYCODE_BUTTON_X` of DELOS for Android).
    case options
    /// Y: the action of the toast that is shown (Undo).
    case toastAction
}

/// Turns game controller and keyboard input into ``MenuCommand``s: the D-pad, the left stick (past half of its travel,
/// once per push), A, B, X, Y, L1, R1 and both menu buttons, and the arrow, Return, Escape and menu keys. Each press
/// emits one command; a direction held down repeats like a held key on Android: after 500 ms, every 50 ms, with the
/// number of the repeat (0 for the press itself).
///
/// Used on iPhone, iPad and Mac, where a controller does not drive SwiftUI's focus. tvOS uses the system focus engine
/// for the directions and A, and Menu is its exit command; there ``MenuInput`` only brings the commands the system has
/// no event for (``tvCommands``).
@MainActor
public final class MenuInput {
    /// Where the stick has to be pushed for a direction, and where it has to come back before the next one.
    nonisolated static let pressThreshold: Float = 0.5
    nonisolated static let releaseThreshold: Float = 0.3
    /// Android's key repeat (`ViewConfiguration`): the first repeat after the long-press time, then at the repeat delay.
    nonisolated static let repeatAfter = Duration.milliseconds(500)
    nonisolated static let repeatEvery = Duration.milliseconds(50)

    /// The commands tvOS has no event for: the left menu button, X, Y, L1 and R1. A controller's directions, A and Menu
    /// reach the app as the system's move, select and exit commands.
    public nonisolated static let tvCommands: Set<MenuCommand> = [.menu, .options, .toastAction, .previousTab, .nextTab]

    private let only: Set<MenuCommand>?
    private let handler: @MainActor (MenuCommand, Int) -> Void
    private var observers: [NSObjectProtocol] = []
    private var stickDirection: [ObjectIdentifier: MenuCommand] = [:]
    /// The direction that is held (and who holds it: a button, a stick or a key) and its repeats.
    private var held: (source: AnyHashable, repeating: Task<Void, Never>)?
    /// Every source that is down now. A second "down" of a source that has not come up is the system's own key repeat
    /// (or a device that reports twice), not a new press: it would start the repeats again and move the focus a step
    /// ahead of them.
    private var down: Set<AnyHashable> = []
    private let repeatAfter: Duration
    private let repeatEvery: Duration

    /// - Parameters:
    ///   - only: the commands to emit; nil: all of them.
    ///   - handler: gets each command and how often it has repeated while held (0: a new press).
    public init(only: Set<MenuCommand>? = nil, handler: @escaping @MainActor (MenuCommand, _ repeatCount: Int) -> Void) {
        self.only = only
        self.handler = handler
        repeatAfter = Self.repeatAfter
        repeatEvery = Self.repeatEvery
    }

    /// For tests: the repeat timing of a hold.
    init(
        only: Set<MenuCommand>? = nil, repeatAfter: Duration, repeatEvery: Duration,
        handler: @escaping @MainActor (MenuCommand, _ repeatCount: Int) -> Void
    ) {
        self.only = only
        self.handler = handler
        self.repeatAfter = repeatAfter
        self.repeatEvery = repeatEvery
    }

    private func emits(_ command: MenuCommand) -> Bool { only?.contains(command) ?? true }

    /// Starts listening to every connected controller and keyboard, and to the ones connected later.
    public func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // The notifications only say that something connected; every device is attached again from the main actor
        // (attaching replaces the handlers, so a device attached twice still emits once)
        for name in [Notification.Name.GCControllerDidConnect, .GCKeyboardDidConnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attachAll() }
            })
        }
        attachAll()
    }

    private func attachAll() {
        GCController.controllers().forEach(attach)
        if let keyboard = GCKeyboard.coalesced { attach(keyboard) }
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        release(nil)
        down.removeAll()
    }

    /// A press: the command at once, and for a direction the repeats while [source] holds it. A source that is already
    /// down (the keyboard's own key repeat reaches the app as more "down" events) is not a new press: one press moves
    /// the focus one step, and the repeats are this class's alone.
    func press(_ command: MenuCommand, from source: AnyHashable, input: InputKind = .controller) {
        guard down.insert(source).inserted else { return }
        ControllerGlyphs.shared.note(input)
        release(nil)
        handler(command, 0)
        guard Self.repeats(command) else { return }
        let (after, every) = (repeatAfter, repeatEvery)
        let repeating = Task { [weak self] in
            var delay = after
            var count = 1
            while true {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self else { return }
                self.handler(command, count)
                count += 1
                delay = every
            }
        }
        held = (source, repeating)
    }

    /// [source] came up: it can be pressed again, and the repeats it held end.
    func lift(_ source: AnyHashable) {
        down.remove(source)
        release(source)
    }

    /// Ends the repeats of a held direction: the stream menu opens while the player may still hold one.
    public func cancelRepeats() { release(nil) }

    /// Forgets what is down: the app lost the keyboard (another app, a locked screen), so an "up" may never come.
    public func forgetDown() {
        release(nil)
        down.removeAll()
    }

    /// Ends the repeats of [source] (nil: of whoever holds a direction).
    private func release(_ source: AnyHashable?) {
        guard let held, source == nil || held.source == source else { return }
        held.repeating.cancel()
        self.held = nil
    }

    nonisolated static func repeats(_ command: MenuCommand) -> Bool {
        switch command {
        case .up, .down, .left, .right: true
        case .accept, .back, .previousTab, .nextTab, .menu, .options, .toastAction: false
        }
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let id = ObjectIdentifier(controller)
        func bind(_ input: GCControllerButtonInput?, _ command: MenuCommand) {
            input?.pressedChangedHandler = emits(command) ? button(command, id) : nil
        }
        bind(pad.dpad.up, .up)
        bind(pad.dpad.down, .down)
        bind(pad.dpad.left, .left)
        bind(pad.dpad.right, .right)
        bind(pad.buttonA, .accept)
        bind(pad.buttonB, .back)
        bind(pad.leftShoulder, .previousTab)
        bind(pad.rightShoulder, .nextTab)
        bind(pad.buttonOptions, .menu)
        #if !os(tvOS)
        // On tvOS the right menu button is the system's Menu: the exit command
        bind(pad.buttonMenu, .options)
        #endif
        bind(pad.buttonX, .options)
        bind(pad.buttonY, .toastAction)
        guard emits(.up) else { return }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                let previous = self.stickDirection[id]
                let next = Self.stickCommand(x: x, y: y, previous: previous)
                self.stickDirection[id] = next
                guard next != previous else { return }
                // One source for each direction: turning from one to another lifts the first and presses the second
                if let previous { self.lift(Self.stickSource(id, previous)) }
                if let next { self.press(next, from: Self.stickSource(id, next)) }
            }
        }
    }

    private func button(_ command: MenuCommand, _ controller: ObjectIdentifier) -> GCControllerButtonValueChangedHandler {
        let source = AnyHashable([AnyHashable(controller), AnyHashable("\(command)")])
        return { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                if pressed { self?.press(command, from: source) } else { self?.lift(source) }
            }
        }
    }

    private static func stickSource(_ controller: ObjectIdentifier, _ direction: MenuCommand) -> AnyHashable {
        AnyHashable([AnyHashable("stick"), AnyHashable(controller), AnyHashable("\(direction)")])
    }

    private func attach(_ keyboard: GCKeyboard) {
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] _, _, key, pressed in
            guard let command = Self.keyCommand(key) else { return }
            MainActor.assumeIsolated {
                guard self?.emits(command) ?? false else { return }
                let source = AnyHashable(["key", AnyHashable(key.rawValue)])
                if pressed { self?.press(command, from: source, input: .keyboard) } else { self?.lift(source) }
            }
        }
    }

    nonisolated static func keyCommand(_ key: GCKeyCode) -> MenuCommand? {
        switch key {
        case .upArrow: .up
        case .downArrow: .down
        case .leftArrow: .left
        case .rightArrow: .right
        case .returnOrEnter, .keypadEnter, .spacebar: .accept
        case .escape: .back
        case .application: .options
        default: nil
        }
    }

    /// The direction the stick is held in: a new direction past ``pressThreshold``, the held one until the stick comes
    /// back inside ``releaseThreshold``, nil at rest. The larger axis wins.
    nonisolated static func stickCommand(x: Float, y: Float, previous: MenuCommand?) -> MenuCommand? {
        let magnitude = max(abs(x), abs(y))
        if let previous, magnitude > releaseThreshold { return previous }
        guard magnitude >= pressThreshold else { return nil }
        if abs(x) >= abs(y) { return x > 0 ? .right : .left }
        // GameController's y grows upwards
        return y > 0 ? .up : .down
    }
}

/// What is connected.
public enum ConnectedControllers {
    /// Whether a game controller with a full gamepad is connected (the Siri Remote is a micro gamepad).
    public static var hasGamepad: Bool { GCController.controllers().contains { $0.extendedGamepad != nil } }
}
