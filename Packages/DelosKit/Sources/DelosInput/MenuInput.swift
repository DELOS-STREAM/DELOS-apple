import Foundation
import GameController

/// A command for moving through the interface, from a game controller or a hardware keyboard.
public enum MenuCommand: Sendable, Equatable {
    case up, down, left, right
    /// A (or Return): activate the focused item.
    case accept
    /// B (or Escape): go back.
    case back
}

/// Turns game controller and keyboard input into ``MenuCommand``s: the D-pad, the left stick (past half of its travel,
/// once per push), A and B, and the arrow, Return and Escape keys. Each press emits one command.
///
/// Used on iPhone, iPad and Mac, where a controller does not drive SwiftUI's focus; tvOS uses the system focus engine.
@MainActor
public final class MenuInput {
    /// Where the stick has to be pushed for a direction, and where it has to come back before the next one.
    nonisolated static let pressThreshold: Float = 0.5
    nonisolated static let releaseThreshold: Float = 0.3

    private let handler: @MainActor (MenuCommand) -> Void
    private var observers: [NSObjectProtocol] = []
    private var stickDirection: [ObjectIdentifier: MenuCommand] = [:]

    public init(handler: @escaping @MainActor (MenuCommand) -> Void) {
        self.handler = handler
    }

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
    }

    private func emit(_ command: MenuCommand) { handler(command) }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let id = ObjectIdentifier(controller)
        pad.dpad.up.pressedChangedHandler = press(.up)
        pad.dpad.down.pressedChangedHandler = press(.down)
        pad.dpad.left.pressedChangedHandler = press(.left)
        pad.dpad.right.pressedChangedHandler = press(.right)
        pad.buttonA.pressedChangedHandler = press(.accept)
        pad.buttonB.pressedChangedHandler = press(.back)
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                let previous = self.stickDirection[id]
                let next = Self.stickCommand(x: x, y: y, previous: previous)
                self.stickDirection[id] = next
                if let next, next != previous { self.emit(next) }
            }
        }
    }

    private func press(_ command: MenuCommand) -> GCControllerButtonValueChangedHandler {
        { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { self?.emit(command) }
        }
    }

    private func attach(_ keyboard: GCKeyboard) {
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] _, _, key, pressed in
            guard pressed, let command = Self.keyCommand(key) else { return }
            MainActor.assumeIsolated { self?.emit(command) }
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
