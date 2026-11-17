import Foundation
import GameController
import Observation

/// Records the stream menu's buttons from every connected controller and the keyboard while Settings shows its capture
/// layer (`ButtonCaptureLayer` of DELOS for Android, which takes any key event: a keyboard's keys too, but the arrow keys):
/// the buttons held together are the combination once all are let go; without a first press within
/// ``MenuButtonRecorder/idle`` the capture ends unchanged, and ``cancel()`` (a tap anywhere) ends it unchanged too.
///
/// It reads the gamepads through their profile-level `valueChangedHandler` and the keyboard through its per-key handlers,
/// so ``MenuInput``'s handlers (per button, and the keyboard's `keyChangedHandler`) keep working next to it (the screen
/// keeps their commands from the interface while the capture runs).
@MainActor
@Observable
public final class MenuButtonCapture {
    /// The buttons pressed so far, in the order they went down (the layer shows them as they come).
    public private(set) var combination: [ShortcutButton] = []

    @ObservationIgnored private var recorder = MenuButtonRecorder()
    @ObservationIgnored private var held: [ObjectIdentifier: Set<ShortcutButton>] = [:]
    @ObservationIgnored private var keysHeld: Set<Int> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    @ObservationIgnored private var onDone: (@MainActor (Set<ShortcutButton>?) -> Void)?
    @ObservationIgnored private let idle: Duration

    /// [onDone] gets the combination, or nil when the capture ended unchanged; it runs once.
    public init(idle: Duration = MenuButtonRecorder.idle, onDone: @escaping @MainActor (Set<ShortcutButton>?) -> Void) {
        self.idle = idle
        self.onDone = onDone
    }

    /// Starts listening to every controller, and to the ones connected later, and the wait for a first press.
    public func start() {
        guard onDone != nil, observers.isEmpty else { return }
        for name in [Notification.Name.GCControllerDidConnect, .GCKeyboardDidConnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attachAll() }
            })
        }
        attachAll()
        let idle = self.idle
        idleTimer = Task { [weak self] in
            do { try await Task.sleep(for: idle) } catch { return }
            self?.finish(nil)
        }
    }

    /// Ends the capture unchanged.
    public func cancel() { finish(nil) }

    private func attachAll() {
        for controller in GCController.controllers() {
            let id = ObjectIdentifier(controller)
            controller.extendedGamepad?.valueChangedHandler = { [weak self] gamepad, _ in
                let pressed = ShortcutButton.pressed(GameInput.snapshot(gamepad))
                MainActor.assumeIsolated { self?.update(pressed, from: id) }
            }
        }
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return }
        for usage in KeyboardMapping.mappedUsages where ShortcutButton.usableKey(usage) != nil {
            keyboard.button(forKeyCode: GCKeyCode(rawValue: usage))?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { self?.key(usage, pressed: pressed) }
            }
        }
    }

    /// A key went down or up.
    func key(_ usage: Int, pressed: Bool) {
        if pressed { keysHeld.insert(usage) } else { keysHeld.remove(usage) }
        update(ShortcutButton.pressed(keys: keysHeld), from: Self.keyboardID)
    }

    /// The keyboard's place among the controllers' held buttons.
    private static let keyboardID = ObjectIdentifier(MenuButtonCapture.self)

    /// The buttons [controller] holds now.
    func update(_ pressed: Set<ShortcutButton>, from controller: ObjectIdentifier) {
        guard onDone != nil else { return }
        held[controller] = pressed
        let all = held.values.reduce(into: Set<ShortcutButton>()) { $0.formUnion($1) }
        let result = recorder.update(all)
        if combination != recorder.combination {
            combination = recorder.combination
            // A first button: the capture no longer gives up
            idleTimer?.cancel()
            idleTimer = nil
        }
        if let result { finish(result) }
    }

    private func finish(_ result: Set<ShortcutButton>?) {
        guard let done = onDone else { return }
        onDone = nil
        idleTimer?.cancel()
        idleTimer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for controller in GCController.controllers() { controller.extendedGamepad?.valueChangedHandler = nil }
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            for usage in KeyboardMapping.mappedUsages {
                keyboard.button(forKeyCode: GCKeyCode(rawValue: usage))?.pressedChangedHandler = nil
            }
        }
        done(result)
    }
}
