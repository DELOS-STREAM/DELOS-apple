import DelosData
import DelosInput
import Observation
import SwiftUI

/// Who a controller, keyboard or remote command belongs to, in front of the screen's own focus (the routing half of
/// `Shell` in DELOS for Android): the portal into a PC, the side menu, an open layer (menu, dialog, typed text), the screen
/// that captures the commands (the stream, Settings, a filter sheet), then the screen's focus and its way back. It holds
/// the one thing the root view used to keep only for this, the side menu's focus, so the rules can be tested without a
/// window.
@MainActor
@Observable
final class ShellRouter {
    /// The side menu's focus while it is open.
    private(set) var sideMenu: FocusModel?
    /// The current profile's whole streaming time, read each time the side menu opens (its header's summary).
    private(set) var sidePlaytime = Playtime.none
    /// The focus of the portal while it is up: nothing under it takes the focus, and B is the only command that passes.
    let portalFocus = FocusModel(initial: "portal")

    @ObservationIgnored let navigator: Navigator
    @ObservationIgnored let layers: Layers
    @ObservationIgnored let toasts: Toasts
    @ObservationIgnored let actions: ShellActions
    /// The sounds and haptics; nil until the input starts (the commands then play nothing).
    @ObservationIgnored var feedback: Feedback?
    /// The controller and keyboard input, read for where the command being routed comes from (``MenuInput/fromReturn``).
    @ObservationIgnored weak var input: MenuInput?
    /// A quick setting of the side menu stepped by a direction (1 or -1): applied and kept with the current profile's
    /// appearance by the root, which owns it. False when nothing changed.
    @ObservationIgnored var stepQuickSetting: (_ id: String, _ direction: Int) -> Bool = { _, _ in false }
    /// Runs a change of screen with the shared screen transition (``go(_:)``); tests run it at once.
    @ObservationIgnored var transition: (() -> Void) -> Void = { go($0) }
    /// Opens and closes the side menu inside an animation (the root's); tests run it at once.
    @ObservationIgnored var animate: (Double, () -> Void) -> Void = { duration, change in withAnimation(.easeOut(duration: duration), change) }
    /// The side menu while a touch drag owns it (``SideMenuSwipe``).
    let sideDrag = SideMenuDrag()
    /// The panel's width in points, what a drag's travel is measured against; the root keeps it to the stage's.
    @ObservationIgnored var sideWidth = SideMenuStyle.width
    /// Reduced motion (the system's or the profile's): a drag only toggles the menu; the root keeps it.
    @ObservationIgnored var reducedMotion = false
    /// Runs a drag's release [change] inside [animation], then [done] once the animation has ended; tests run both at once.
    @ObservationIgnored var settle: (_ animation: Animation, _ change: () -> Void, _ done: @escaping @MainActor () -> Void) -> Void = { animation, change, done in
        withAnimation(animation, completionCriteria: .removed, change) { MainActor.assumeIsolated { done() } }
    }

    init(navigator: Navigator, layers: Layers, toasts: Toasts, actions: ShellActions) {
        self.navigator = navigator
        self.layers = layers
        self.toasts = toasts
        self.actions = actions
    }

    /// The focus that holds every other item back from the system focus (tvOS): the portal, else the side menu, else an open
    /// layer, else the sheet of the screen shown. Nil: nothing is open.
    var modalFocus: FocusModel? {
        if actions.connection.isActive { return portalFocus }
        if let sideMenu { return sideMenu }
        if layers.isOpen { return layers.focus }
        if let card = problemCard() { return card }
        return navigator.screenModal
    }

    /// The problem card's focus while it shows (``ProblemOffers``); the root keeps it. It has the commands then, and B is Dismiss.
    @ObservationIgnored var problemCard: () -> FocusModel? = { nil }
    /// Dismiss of the problem card (B wherever the focus is while it shows).
    @ObservationIgnored var dismissProblem: () -> Void = {}

    /// Whether Menu is ours: something is open, or there is a screen to go back to. At the first screen it is the system's
    /// (tvOS: Home).
    var handlesExit: Bool {
        sideMenu != nil || layers.isOpen || navigator.screenModal != nil || navigator.canGoBack || actions.connection.isActive
            || problemCard() != nil
    }

    private func activate(_ cue: Cue?, _ run: () -> Bool) {
        if let feedback { feedback.activate(cue, run) } else { _ = run() }
    }

    // MARK: Side menu

    func openSideMenu() {
        // A touch drag owns the menu until it has settled
        guard !sideDrag.engaged else { return }
        feedback?.play(.open)
        sidePlaytime = actions.profilePlaytime()
        animate(0.56) { sideMenu = FocusModel(initial: QuickSettings.ids[0]) }
    }

    func closeSideMenu(sound: Cue?) {
        guard !sideDrag.engaged else { return }
        if let sound { feedback?.play(sound) }
        animate(0.24) { sideMenu = nil }
    }

    /// Whether a drag in from the left edge can open the side menu now: the screen has one and nothing else is open (or a
    /// drag already owns the menu).
    var sideSwipeOpens: Bool {
        sideDrag.engaged || (sideMenu == nil && !layers.isOpen && navigator.screenModal == nil && navigator.current.hasSideMenu
            && !actions.connection.isActive)
    }

    /// A touch drag took the side menu: from closed when [opening], else from open (or from where a settling panel is).
    func beginSideDrag(opening: Bool) {
        if reducedMotion { return }
        let drag = sideDrag
        let start = opening ? 0 : drag.engaged ? min(drag.settlingProgress(at: .now), 1) : 1
        drag.settles += 1
        drag.start = start
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            drag.progress = start
            drag.engaged = true
            if opening, sideMenu == nil {
                sidePlaytime = actions.profilePlaytime()
                sideMenu = FocusModel(initial: QuickSettings.ids[0])
            }
        }
    }

    /// The drag moved [travel] points to the right since it began: the panel follows.
    func moveSideDrag(travel: Double) {
        guard !reducedMotion, sideDrag.engaged else { return }
        sideDrag.progress = SideMenuSwipe.progress(start: sideDrag.start, travel: travel, width: sideWidth)
    }

    /// The drag ended [travel] points to the right of its start at [velocity] points per second: the menu springs open or
    /// closed (``SideMenuSwipe/settlesOpen(opening:progress:velocity:fling:)``), from the speed of the finger.
    func endSideDrag(opening: Bool, travel: Double, velocity: Double) {
        if reducedMotion {
            guard SideMenuSwipe.reducedToggles(opening: opening, travel: travel, width: sideWidth) else { return }
            if opening { openSideMenu() } else { closeSideMenu(sound: .back) }
            return
        }
        let drag = sideDrag
        guard drag.engaged else { return }
        let open = SideMenuSwipe.settlesOpen(opening: opening, progress: drag.progress, velocity: velocity)
        if open && opening { feedback?.play(.open) }
        if !open && !opening { feedback?.play(.back) }
        drag.settles += 1
        let settle = drag.settles
        let target = open ? 1.0 : 0.0
        let spring = SettleSpring(from: drag.progress, to: target, velocity: velocity / max(sideWidth, 1), began: .now)
        drag.spring = spring
        self.settle(spring.animation, { drag.progress = target }) { [weak self] in
            guard let self, drag.settles == settle else { return }
            drag.spring = nil
            var instant = Transaction()
            instant.disablesAnimations = true
            // The panel and the scrim left from where the drag left them: no exit transition
            withTransaction(instant) {
                if !open { self.sideMenu = nil }
                drag.engaged = false
            }
        }
    }

    /// Left or right on the side menu's focused row: a quick setting takes the next or the previous value.
    private func adjustQuickSetting(of menu: FocusModel, _ direction: Int) {
        guard let id = menu.focused as? String, stepQuickSetting(id, direction) else { return }
        feedback?.play(.move)
    }

    #if os(tvOS)
    /// A swipe or a controller's direction: the focus engine moves the focus on its own; only a screen that takes over left and
    /// right (the value of a Settings row) gets them first.
    func routeMove(_ direction: MoveCommandDirection) {
        if let sideMenu, direction == .left || direction == .right {
            adjustQuickSetting(of: sideMenu, direction == .right ? 1 : -1)
            return
        }
        guard sideMenu == nil, !layers.isOpen, !navigator.isEditingText, let capture = navigator.commandCapture else { return }
        switch direction {
        case .left: navigator.commandRepeat = 0; _ = capture(.left)
        case .right: navigator.commandRepeat = 0; _ = capture(.right)
        default: break
        }
    }
    #endif

    // MARK: Commands

    /// A controller, keyboard or remote command, to whoever owns it. [fromRemote]: the Siri Remote's Menu or Play/Pause.
    func route(_ command: MenuCommand, repeatCount: Int, fromRemote: Bool = false) {
        // The portal into a PC holds every command; B stops waiting for a PC that wakes up
        if actions.connection.isActive {
            if command == .back { actions.connection.cancel() }
            return
        }
        navigator.commandRepeat = repeatCount
        navigator.commandFromRemote = fromRemote
        navigator.commandFromReturn = input?.fromReturn ?? false
        if let sideMenu {
            // The side menu takes every command while it is open
            switch command {
            case .back, .menu: closeSideMenu(sound: .back)
            case .accept: activate(sideMenu.acceptCue) { sideMenu.handle(.accept) }
            case .up, .down: if sideMenu.handle(command) { feedback?.play(.move) }
            case .left, .right: adjustQuickSetting(of: sideMenu, command == .right ? 1 : -1)
            case .previousTab, .nextTab, .options, .toastAction, .mute: break
            }
            return
        }
        if layers.isOpen {
            // An open layer takes every command; the text field of a dialog takes the keys while it is typed in
            if navigator.isEditingText {
                if command == .back { navigator.isEditingText = false }
            } else if command == .toastAction {
                toasts.runAction()
            } else if command != .accept || !navigator.swallowsAccept() {
                layers.handle(command)
            }
            return
        }
        if let card = problemCard() {
            // The report card has the commands while it shows; the menu button still opens the side menu
            switch command {
            case .back:
                feedback?.play(.back)
                dismissProblem()
            case .accept: activate(card.acceptCue) { card.handle(.accept) }
            case .up, .down, .left, .right: if card.handle(command) { feedback?.play(.move) }
            case .menu where navigator.current.hasSideMenu: openSideMenu()
            case .toastAction: toasts.runAction()
            case .menu, .options, .previousTab, .nextTab, .mute: break
            }
            return
        }
        if let capture = navigator.commandCapture, capture(command) { return }
        if command == .menu, navigator.current.hasSideMenu {
            openSideMenu()
            return
        }
        // While a text field is typed in, the keys belong to it; B and Escape stop typing
        if navigator.isEditingText {
            if command == .back { navigator.isEditingText = false }
            return
        }
        switch command {
        case .toastAction:
            toasts.runAction()
            return
        case .options:
            layers.openContextMenu(of: navigator.focus)
            return
        default:
            break
        }
        if command == .accept, navigator.swallowsAccept() { return }
        if command == .back {
            if navigator.canGoBack {
                feedback?.play(.back)
                transition { _ = navigator.back() }
            }
            return
        }
        if command == .accept {
            // The item's own cue (a Cancel or Back goes BACK), unless its action played one
            activate(navigator.focus.acceptCue) { navigator.focus.handle(.accept) }
            return
        }
        guard navigator.focus.handle(command) else { return }
        feedback?.play(.move)
    }

    // MARK: Pointer

    /// The focus the pointer's own entry point acts on (``secondaryClick(at:)``): the side menu's, an open layer's or a
    /// sheet's, else the screen's. Nil while the portal is up and on the stream screen, where the pointer is the PC's mouse
    /// (the stream menu's items take the hover and clicks themselves, as ``FocusItem``s).
    var pointerFocus: FocusModel? {
        if actions.connection.isActive { return nil }
        if case .stream = navigator.current { return nil }
        return modalFocus ?? navigator.focus
    }

    /// A right click or a two-finger click at [point] (global points): the item under it takes the focus where it is (the
    /// pointer's move, ``FocusModel/point(to:)``: nothing scrolls) and gets the command of the right menu button
    /// (``MenuCommand/options``, its context menu). Over an item without a menu it only takes the focus; with a layer open a
    /// click beside its items is Options too (the button that opened a context menu closes it). True when the click did
    /// something.
    @discardableResult
    func secondaryClick(at point: CGPoint) async -> Bool {
        guard let focus = pointerFocus else { return false }
        guard let (id, _) = focus.item(at: point) else {
            guard layers.isOpen else { return false }
            route(.options, repeatCount: 0)
            return true
        }
        focus.point(to: id)
        guard focus.hasMenu(id) else { return true }
        route(.options, repeatCount: 0)
        return true
    }
}

extension View {
    /// The screen has a sheet or a list of values open with this focus (nil: none): the commands are the screen's own
    /// (``Navigator/commandCapture``), and the focus engine of tvOS keeps everything else, the top navigation included, from
    /// taking the focus meanwhile (``Navigator/screenModal``).
    func screenModal(_ focus: FocusModel?) -> some View {
        modifier(ScreenModal(focus: focus))
    }
}

private struct ScreenModal: ViewModifier {
    let focus: FocusModel?
    @Environment(Navigator.self) private var navigator

    func body(content: Content) -> some View {
        content
            .onChange(of: focus.map(ObjectIdentifier.init), initial: true) { _, _ in navigator.screenModal = focus }
            .onDisappear { if navigator.screenModal === focus { navigator.screenModal = nil } }
    }
}
