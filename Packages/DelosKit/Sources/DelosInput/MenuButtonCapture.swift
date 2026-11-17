import Foundation
import GameController
import Observation

/// Records the stream menu's buttons from every connected controller while Settings shows its capture layer
/// (`ButtonCaptureLayer` of DELOS for Android): the buttons held together are the combination once all are let go; without
/// a first press within ``MenuButtonRecorder/idle`` the capture ends unchanged, and ``cancel()`` (a tap anywhere) ends it
/// unchanged too.
///
/// It reads the gamepads through their profile-level `valueChangedHandler`, so ``MenuInput``'s per-button handlers keep
/// working next to it (the screen keeps their commands from the interface while the capture runs).
@MainActor
@Observable
public final class MenuButtonCapture {
    /// The buttons pressed so far, in the order they went down (the layer shows them as they come).
    public private(set) var combination: [ShortcutButton] = []

    @ObservationIgnored private var recorder = MenuButtonRecorder()
    @ObservationIgnored private var held: [ObjectIdentifier: Set<ShortcutButton>] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?
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
        guard onDone != nil, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachAll() }
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
    }

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
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for controller in GCController.controllers() { controller.extendedGamepad?.valueChangedHandler = nil }
        done(result)
    }
}
