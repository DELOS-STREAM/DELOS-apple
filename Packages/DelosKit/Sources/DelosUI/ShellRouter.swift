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
    /// The focus of the portal while it is up: nothing under it takes the focus, and B is the only command that passes.
    let portalFocus = FocusModel(initial: "portal")

    @ObservationIgnored let navigator: Navigator
    @ObservationIgnored let layers: Layers
    @ObservationIgnored let toasts: Toasts
    @ObservationIgnored let actions: ShellActions
    /// The sounds and haptics; nil until the input starts (the commands then play nothing).
    @ObservationIgnored var feedback: Feedback?
    /// A quick setting of the side menu stepped by a direction (1 or -1): applied and kept with the current profile's
    /// appearance by the root, which owns it. False when nothing changed.
    @ObservationIgnored var stepQuickSetting: (_ id: String, _ direction: Int) -> Bool = { _, _ in false }
    /// Runs a change of screen with the shared screen transition (``go(_:)``); tests run it at once.
    @ObservationIgnored var transition: (() -> Void) -> Void = { go($0) }
    /// Opens and closes the side menu inside an animation (the root's); tests run it at once.
    @ObservationIgnored var animate: (Double, () -> Void) -> Void = { duration, change in withAnimation(.easeOut(duration: duration), change) }

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
        return navigator.screenModal
    }

    /// Whether Menu is ours: something is open, or there is a screen to go back to. At the first screen it is the system's
    /// (tvOS: Home).
    var handlesExit: Bool { sideMenu != nil || layers.isOpen || navigator.screenModal != nil || navigator.canGoBack || actions.connection.isActive }

    private func activate(_ cue: Cue?, _ run: () -> Bool) {
        if let feedback { feedback.activate(cue, run) } else { _ = run() }
    }

    // MARK: Side menu

    func openSideMenu() {
        feedback?.play(.open)
        animate(0.56) { sideMenu = FocusModel(initial: QuickSettings.ids[0]) }
    }

    func closeSideMenu(sound: Cue?) {
        if let sound { feedback?.play(sound) }
        animate(0.24) { sideMenu = nil }
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
        if let sideMenu {
            // The side menu takes every command while it is open
            switch command {
            case .back, .menu: closeSideMenu(sound: .back)
            case .accept: activate(sideMenu.acceptCue) { sideMenu.handle(.accept) }
            case .up, .down: if sideMenu.handle(command) { feedback?.play(.move) }
            case .left, .right: adjustQuickSetting(of: sideMenu, command == .right ? 1 : -1)
            case .previousTab, .nextTab, .options, .toastAction: break
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
