import DelosInput
import Foundation
import Observation

/// A screen of the interface (`Screen` in DELOS for Android's `shell/ShellState.kt`, as far as the screens exist here).
public enum Screen: Hashable, Sendable {
    /// First run: the logo, the tagline and "Get started".
    case boot
    /// Creating a profile, or changing the current one's avatar and name ([editing]).
    case createProfile(editing: Bool)
    /// The start screen: the greeting, the profile chip and the PCs.
    case start
    /// The current profile and what can be done with it.
    case profile
    /// Pairing: the PCs found on the network, entering an address, searching again.
    case pair
    /// Entering a PC's address to add and pair it.
    case pairAddress
    /// The PIN to type on the PC [hostID] while pairing with it waits; leaving it cancels the attempt.
    case pin(hostID: String)
    /// A paired PC's library: its apps.
    case home(hostID: String)
    /// A stream of the app [appID] of the PC [hostID].
    case stream(hostID: String, appID: Int)
}

/// Where the interface is: a back stack of screens, each with its own ``FocusModel``, so going back returns to the item
/// that was focused. B (Escape, the Menu button of the Siri Remote) pops the top screen; at the root it does nothing
/// and the system handles it.
@MainActor
@Observable
public final class Navigator {
    /// A screen on the stack with the focus it keeps.
    public struct Entry {
        public let screen: Screen
        public let focus: FocusModel
    }

    public private(set) var stack: [Entry]
    /// True while a text field is being typed in: the controller and the keyboard's arrows, Return and Escape belong to
    /// the field, not to the focus.
    public var isEditingText = false {
        didSet { if oldValue, !isEditingText { textEditingEnded = .now } }
    }
    @ObservationIgnored private var textEditingEnded = Date.distantPast
    /// While set, every controller and keyboard command goes here first; true: consumed (the stream screen owns the
    /// controller).
    @ObservationIgnored public var commandCapture: (@MainActor (MenuCommand) -> Bool)?

    public init(root: Screen, focus: AnyHashable? = nil) {
        stack = [Entry(screen: root, focus: FocusModel(initial: focus))]
    }

    public var current: Screen { stack[stack.count - 1].screen }
    public var focus: FocusModel { stack[stack.count - 1].focus }
    public var canGoBack: Bool { stack.count > 1 }

    /// Opens [screen] above the current one, with the focus on [focus] (nil: the first item that appears).
    public func push(_ screen: Screen, focus: AnyHashable? = nil) {
        stack.append(Entry(screen: screen, focus: FocusModel(initial: focus)))
    }

    /// Goes back one screen. False at the root.
    @discardableResult
    public func back() -> Bool {
        guard canGoBack else { return false }
        stack.removeLast()
        return true
    }

    /// Replaces the whole stack with [screen] (the first run is over, or starts again).
    public func reset(to screen: Screen, focus: AnyHashable? = nil) {
        stack = [Entry(screen: screen, focus: FocusModel(initial: focus))]
    }

    /// Opens the library of the PC [hostID] above the start screen (from the start screen, or once pairing is done:
    /// B then returns to the start screen, not to the pairing screens).
    public func openHome(hostID: String) {
        if let start = stack.firstIndex(where: { $0.screen == .start }) {
            stack.removeSubrange((start + 1)...)
            stack[start].focus.focus(StartScreen.pcID(hostID))
        } else {
            stack = [Entry(screen: .start, focus: FocusModel(initial: StartScreen.pcID(hostID)))]
        }
        push(.home(hostID: hostID), focus: HomeScreen.initialFocus)
    }

    /// Starts streaming the app [appID] of the PC [hostID].
    public func openStream(hostID: String, appID: Int) {
        push(.stream(hostID: hostID, appID: appID))
    }

    /// Return ends typing and is then delivered as a key press too: an A or Return within this time after the field
    /// let go of the keyboard is the same press and must not activate the focused item.
    func swallowsAccept(at now: Date = .now) -> Bool {
        now.timeIntervalSince(textEditingEnded) < 0.3
    }
}
