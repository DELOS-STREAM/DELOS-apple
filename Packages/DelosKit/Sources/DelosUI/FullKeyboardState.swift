import DelosInput
import Foundation
import Observation

/// What the keyboard asks of whoever hosts it (`FullKeyboardHost` of DELOS for Android; the ``StreamController`` here).
@MainActor
protocol FullKeyboardHost: AnyObject {
    /// `checkbox_enable_sticky_modifier_key_virtual_keyboard`.
    var stickyModifiers: Bool { get }

    /// One key (a Windows virtual key, ``KeyCode``) goes down or up at the PC.
    func sendKey(_ code: Int, down: Bool)

    func haptic(_ haptic: KeyHaptic)

    /// The Hide key or B: the keyboard goes away.
    func closeFullKeyboard()
}

/// The vibration cues of the keyboard (`checkbox_vibrate_keyboard`): a key down, a key up, a modifier latched, the keyboard
/// hidden.
enum KeyHaptic: Sendable {
    case press, release, latch, hide
}

/// What drives the keyboard now: the touch screen (or the pointer) hides the focus ring and the hints, the controller
/// brings them back.
enum KeyboardInputMode: Sendable {
    case touch, controller
}

/// The popup above the pressed key [code].
struct KeyPopup: Equatable, Sendable {
    let code: Int
    let text: String
}

/// The timers the keyboard runs (latching, repeats, the popup, the press that shows a moment): named, so starting one
/// again replaces it.
enum KeyboardTimer: Hashable, Sendable {
    case leave, popup, dpadRepeat, stickRepeat
    case bound(Int), latch(Int), release(Int), tap(Int)
}

/// The clock and the timers of the keyboard; tests drive a manual one.
@MainActor
protocol KeyboardClock: AnyObject {
    /// Milliseconds of a monotonic clock.
    var now: Int64 { get }
    func schedule(_ timer: KeyboardTimer, after milliseconds: Int64, _ action: @escaping @MainActor () -> Void)
    func cancel(_ timer: KeyboardTimer)
}

/// The keyboard's timers as tasks on the main actor.
@MainActor
final class TaskKeyboardClock: KeyboardClock {
    private static let epoch = ContinuousClock.now
    private var tasks: [KeyboardTimer: Task<Void, Never>] = [:]

    var now: Int64 {
        let elapsed = (ContinuousClock.now - Self.epoch).components
        return elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
    }

    func schedule(_ timer: KeyboardTimer, after milliseconds: Int64, _ action: @escaping @MainActor () -> Void) {
        tasks[timer]?.cancel()
        tasks[timer] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(max(milliseconds, 0))) } catch { return }
            self?.tasks[timer] = nil
            action()
        }
    }

    func cancel(_ timer: KeyboardTimer) {
        tasks.removeValue(forKey: timer)?.cancel()
    }
}

/// Everything the Delos full keyboard shows and does (`FullKeyboardState` of DELOS for Android): open or closed, the focused
/// key, which keys are pressed and which modifiers latched, the popup, and the touch and controller input that changes them.
/// The views only read it; keys reach the PC through ``FullKeyboardHost/sendKey(_:down:)``.
@MainActor
@Observable
final class FullKeyboardState {
    @ObservationIgnored weak var host: (any FullKeyboardHost)?
    /// Whether a game controller is connected when the keyboard opens: it then starts in the controller's mode.
    @ObservationIgnored var hasController: @MainActor () -> Bool
    @ObservationIgnored private let clock: any KeyboardClock
    @ObservationIgnored private let grid = KeyGrid.standard
    @ObservationIgnored private var latch = ModifierLatch()
    @ObservationIgnored private var analog = DirectionalRepeater()
    @ObservationIgnored private var dpad = DpadTracker()
    /// Where the left stick points now (it reports only when it moves, so its repeat asks this).
    @ObservationIgnored private var stick: KeyDirection?

    /// The keyboard is up (it takes the controller).
    private(set) var open = false
    /// The keyboard is on screen: open, or still leaving.
    private(set) var present = false
    private(set) var input = KeyboardInputMode.touch
    var prefs = KeyboardPrefs()
    /// The key the controller focus is on, nil before the first controller input.
    private(set) var focus: KeyPos?
    /// The keyboard has settled after opening, so the ring may appear (it follows the keys in 560 ms).
    private(set) var ringReady = false
    private(set) var latched: Set<Int> = []
    /// A Shift key is held by a finger right now (not yet, or no longer, latched).
    private var shiftTouched = false
    /// Caps Lock as this keyboard tracks it: toggled on every press of the Caps key, whether or not the PC agrees (its real
    /// state is not readable), and kept when the keyboard hides, like the PC's.
    private(set) var capsOn = false
    private(set) var pressed: Set<Int> = []
    private(set) var popup: KeyPopup?
    private(set) var popupOn = false
    /// Counts the moves that hit the edge of the keyboard; the ring nudges toward ``nudgeDirection`` for each.
    private(set) var nudgeCount = 0
    private(set) var nudgeDirection = KeyDirection.right

    /// Shift is down (held or latched), so the keys show their shifted characters.
    var shifted: Bool { shiftTouched || latched.contains(where: KeyCode.isShift) }

    /// Both the ring and the focused key's look are for the controller.
    var focusVisible: Bool { open && ringReady && input == .controller }

    @ObservationIgnored private var anchorX = 0.0
    @ObservationIgnored private var held: Set<Int> = []
    @ObservationIgnored private var padHeld: Int?
    @ObservationIgnored private var padHeldSendsUp = false
    /// X / Y keys (Backspace, Space) held by the controller; each repeats on its own timer.
    @ObservationIgnored private var boundHeld: Set<Int> = []
    @ObservationIgnored private var latchPending: Set<Int> = []
    @ObservationIgnored private var pressStart: [Int: Int64] = [:]
    @ObservationIgnored private var releasePending: Set<Int> = []

    /// A modifier held this long stays latched (`timerLongClickTimeout` of the old keyboard).
    static let latchHoldMs: Int64 = 300
    /// The popup stays this long after the release.
    static let popupMs: Int64 = 75
    /// The keyboard stays on screen this much longer than its exit animation.
    static let leaveMarginMs: Int64 = 40

    init(clock: any KeyboardClock = TaskKeyboardClock(), hasController: @escaping @MainActor () -> Bool = { ConnectedControllers.hasGamepad }) {
        self.clock = clock
        self.hasController = hasController
    }

    func show() {
        clock.cancel(.leave)
        analog.reset()
        resetDpad()
        input = hasController() ? .controller : .touch
        present = true
        open = true
    }

    func hide() {
        guard open else { return }
        host?.haptic(.hide)
        releaseHeld()
        releaseLatched()
        analog.reset()
        resetDpad()
        shiftTouched = false
        open = false
        ringReady = false
        clock.cancel(.popup)
        popupOn = false
        clock.schedule(.leave, after: Int64(Motion.exit) + Self.leaveMarginMs) { [weak self] in self?.present = false }
    }

    /// The stream menu opened over the keyboard: what a finger or the controller holds comes up at the PC (their releases
    /// go to the menu); the latched modifiers stay.
    func releaseInput() {
        guard open else { return }
        releaseHeld()
        analog.reset()
        resetDpad()
        shiftTouched = false
    }

    /// The first controller focus (Q) and the ring, once the keys are in.
    func settled() {
        guard open else { return }
        if focus == nil, let first = grid.find(KeyGrid.firstKey) { focusAt(first) }
        ringReady = true
    }

    // MARK: Touch

    /// A finger (or the pointer) went down on [code]; false when the keyboard takes no input (it is leaving): then nothing
    /// happens, and its release must not be reported.
    @discardableResult
    func touchDown(_ code: Int) -> Bool {
        guard open else { return false }
        input = .touch
        addPressed(code)
        if code == KeyDef.hideCode { return true }
        let sticky = host?.stickyModifiers ?? false
        let send = latch.touchDown(code, sticky: sticky)
        syncLatched()
        if send == .down {
            if KeyCode.isShift(code) { shiftTouched = true }
            showPopup(code)
            keyDown(code)
            if sticky, KeyCode.isModifier(code) { scheduleLatch(code) }
        }
        return true
    }

    func touchUp(_ code: Int) {
        clock.cancel(.latch(code))
        latchPending.remove(code)
        removePressed(code)
        if KeyCode.isShift(code) { shiftTouched = false }
        if code == KeyDef.hideCode {
            if open { host?.closeFullKeyboard() }
            return
        }
        hidePopupSoon()
        if latch.touchUp(code, sticky: host?.stickyModifiers ?? false) == .up { keyUp(code) }
    }

    // MARK: Controller

    /// A controller's reading changed while the keyboard is up (``GameInput/padCapture``, or the Siri Remote): its buttons,
    /// its D-pad as a hat and its left stick (y up, as GameController reports it) drive the keyboard. Nothing of it
    /// reaches the game.
    func controller(_ old: GamepadSnapshot, _ new: GamepadSnapshot) {
        for action in PadAction.buttons(from: old, to: new) { act(action) }
        let now = clock.now
        let hatX = (new.left ? -1.0 : 0) + (new.right ? 1 : 0), hatY = (new.up ? -1.0 : 0) + (new.down ? 1 : 0)
        if let direction = dpad.onHat(x: hatX, y: hatY, now: now) { act(.move(direction)) }
        scheduleDpadRepeat()
        stick = analogDirection(x: Double(new.leftStickX), y: -Double(new.leftStickY))
        if analog.shouldMove(stick, now: now), let stick { act(.move(stick)) }
        scheduleStickRepeat()
    }

    /// Arms the timer for the hat's next repeat (or disarms it when the hat does not repeat).
    private func scheduleDpadRepeat() {
        guard let at = dpad.repeatAt else {
            clock.cancel(.dpadRepeat)
            return
        }
        clock.schedule(.dpadRepeat, after: at - clock.now) { [weak self] in
            guard let self else { return }
            if let direction = self.dpad.repeat(now: self.clock.now) { self.act(.move(direction)) }
            self.scheduleDpadRepeat()
        }
    }

    /// A stick held still reports nothing: its repeat comes from a timer.
    private func scheduleStickRepeat() {
        guard let at = analog.repeatAt else {
            clock.cancel(.stickRepeat)
            return
        }
        clock.schedule(.stickRepeat, after: at - clock.now) { [weak self] in
            guard let self else { return }
            if self.analog.shouldMove(self.stick, now: self.clock.now), let stick = self.stick { self.act(.move(stick)) }
            self.scheduleStickRepeat()
        }
    }

    private func resetDpad() {
        dpad.reset()
        stick = nil
        clock.cancel(.dpadRepeat)
        clock.cancel(.stickRepeat)
    }

    private func act(_ action: PadAction) {
        guard open else { return }
        input = .controller
        switch action {
        case .move(let direction): move(direction)
        case .pressDown: padDown()
        case .pressUp: padUp()
        case .close: host?.closeFullKeyboard()
        case .toggleShift: toggleShift()
        case .boundDown(let code): boundDown(code)
        case .boundUp(let code): boundUp(code)
        }
    }

    private func move(_ direction: KeyDirection) {
        guard let from = focus else {
            settled()
            return
        }
        if let next = grid.move(from, anchorX: anchorX, direction) {
            focus = next.pos
            anchorX = next.anchorX
        } else {
            nudgeDirection = direction
            nudgeCount += 1
        }
    }

    private func focusAt(_ pos: KeyPos) {
        let landed = grid.land(pos)
        focus = landed.pos
        anchorX = landed.anchorX
    }

    private func padDown() {
        guard let pos = focus else {
            settled()
            return
        }
        guard padHeld == nil else { return }
        let code = grid.key(pos).code
        padHeld = code
        addPressed(code)
        if code == KeyDef.hideCode {
            padHeldSendsUp = false
        } else if KeyCode.isModifier(code) {
            padHeldSendsUp = false
            toggleLatch(code)
        } else {
            padHeldSendsUp = true
            showPopup(code)
            keyDown(code)
        }
    }

    private func padUp() {
        guard let code = padHeld else { return }
        padHeld = nil
        removePressed(code)
        hidePopupSoon()
        if code == KeyDef.hideCode {
            host?.closeFullKeyboard()
        } else if padHeldSendsUp {
            keyUp(code)
        }
    }

    /// L3: Shift is latched (down at the PC) or, when any Shift is latched, every latched Shift is let go.
    private func toggleShift() {
        let latchedShifts = latch.codes.filter(KeyCode.isShift).sorted()
        for shift in latchedShifts.isEmpty ? [KeyCode.leftShift] : latchedShifts {
            toggleLatch(shift)
            // A tap of the key, so it shows the press like a touch would
            addPressed(shift)
            clock.schedule(.tap(shift), after: 0) { [weak self] in self?.removePressed(shift) }
        }
    }

    /// X or Y went down: [code] is typed through the same path as a press of A and repeats while the button is held.
    private func boundDown(_ code: Int) {
        guard !boundHeld.contains(code), !held.contains(code) else { return }
        addPressed(code)
        showPopup(code)
        keyDown(code)
        boundHeld.insert(code)
        scheduleBoundRepeat(code, after: PadRepeat.delay)
    }

    private func scheduleBoundRepeat(_ code: Int, after delay: Int64) {
        clock.schedule(.bound(code), after: delay) { [weak self] in
            guard let self, self.boundHeld.contains(code) else { return }
            self.host?.sendKey(code, down: true)
            self.scheduleBoundRepeat(code, after: PadRepeat.interval)
        }
    }

    private func boundUp(_ code: Int) {
        guard boundHeld.remove(code) != nil else { return }
        clock.cancel(.bound(code))
        removePressed(code)
        hidePopupSoon()
        keyUp(code)
    }

    /// A or L3 on a modifier: latch it (down at the PC) or let it go.
    private func toggleLatch(_ code: Int) {
        let send = latch.padPress(code)
        syncLatched()
        host?.sendKey(code, down: send == .down)
        host?.haptic(send == .down ? .latch : .release)
    }

    // MARK: Keys

    private func keyDown(_ code: Int) {
        held.insert(code)
        if code == KeyCode.capsLock { capsOn.toggle() }
        host?.sendKey(code, down: true)
        host?.haptic(.press)
    }

    private func keyUp(_ code: Int) {
        held.remove(code)
        host?.sendKey(code, down: false)
        host?.haptic(.release)
    }

    /// Lets go of every key that is held down (the latched modifiers are ``releaseLatched()``'s): a hidden keyboard must
    /// not leave a key pressed.
    private func releaseHeld() {
        for code in latchPending { clock.cancel(.latch(code)) }
        latchPending.removeAll()
        for code in held.sorted() { host?.sendKey(code, down: false) }
        held.removeAll()
        padHeld = nil
        for code in boundHeld { clock.cancel(.bound(code)) }
        boundHeld.removeAll()
        for code in releasePending { clock.cancel(.release(code)) }
        releasePending.removeAll()
        pressed.removeAll()
    }

    /// A hidden keyboard leaves no modifier down at the PC: each latched one gets its release and the latch is cleared.
    private func releaseLatched() {
        for code in latch.releaseAll() { host?.sendKey(code, down: false) }
        syncLatched()
    }

    private func scheduleLatch(_ code: Int) {
        latchPending.insert(code)
        clock.schedule(.latch(code), after: Self.latchHoldMs) { [weak self] in
            guard let self else { return }
            self.latchPending.remove(code)
            self.latch.latchHeld(code)
            self.held.remove(code)
            self.syncLatched()
            self.host?.haptic(.latch)
        }
    }

    private func syncLatched() {
        let codes = latch.codes
        if codes != latched { latched = codes }
    }

    /// The key shows as pressed from now on.
    private func addPressed(_ code: Int) {
        clock.cancel(.release(code))
        releasePending.remove(code)
        pressStart[code] = clock.now
        pressed.insert(code)
    }

    /// The key stops showing as pressed, but not before it was shown for ``Motion/pressHold``: a tap is still seen.
    private func removePressed(_ code: Int) {
        let wait = Int64(Motion.pressHold) - (clock.now - (pressStart[code] ?? 0))
        guard wait > 0 else {
            pressed.remove(code)
            return
        }
        releasePending.insert(code)
        clock.schedule(.release(code), after: wait) { [weak self] in
            self?.releasePending.remove(code)
            self?.pressed.remove(code)
        }
    }

    private func showPopup(_ code: Int) {
        guard let pos = grid.find(code), let text = FullKeyboardKeys.popupText(grid.key(pos), shift: shifted, caps: capsOn) else { return }
        clock.cancel(.popup)
        popup = KeyPopup(code: code, text: text)
        popupOn = true
    }

    private func hidePopupSoon() {
        clock.schedule(.popup, after: Self.popupMs) { [weak self] in self?.popupOn = false }
    }
}
