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
    /// Pairing with the one-time [code] from the PC's web UI instead of a PIN shown here; leaving it cancels the attempt.
    case pairCode(hostID: String, code: OneTimeCode)
    /// A paired PC's library: its apps.
    case home(hostID: String)
    /// A stream of the app [appID] of the PC [hostID].
    case stream(hostID: String, appID: Int)
    /// Settings: the tabs, the rows of the selected one and the help of the focused row.
    case settings
    /// The paired PCs and what can be done with each (Android's `Screen.Devices`).
    case devices
    /// Choosing the cover, wide cover, background and logo of the app [appID] of the PC [hostID] (`Screen.Artwork`).
    case artwork(hostID: String, appID: Int)
    /// The stream settings the app [appID] of the PC [hostID] overrides (`Screen.GameSettings`).
    case appSettings(hostID: String, appID: Int)

    /// The screens of the top navigation (Android's `Screen.main`): the library, Settings, Profile and Devices. They show
    /// the navigation in the status bar.
    var showsNavigation: Bool {
        switch self {
        case .home, .settings, .profile, .devices: true
        default: false
        }
    }

    /// Settings, Profile and Devices take each other's place on the stack ([Navigator.openFromNavigation]).
    var replacesOnNavigation: Bool { self == .settings || self == .profile || self == .devices }

    /// Whether the left menu button opens the side menu here (Android's `Screen.sideMenu`: the main screens and the start
    /// screen).
    var hasSideMenu: Bool { showsNavigation || self == .start }
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
    /// An A or Return that is still being pressed when a screen changes belongs to the screen that is gone: until this
    /// time ``swallowsAccept(at:)`` is true (``armInputGate()``).
    @ObservationIgnored private var inputGateUntil = Date.distantPast
    /// How long after a screen change (and after a layer opens) an accept is ignored.
    static let inputGate: TimeInterval = 0.4

    /// Ignores `accept` for ``inputGate`` seconds: called after every navigation, and by whoever opens a layer.
    public func armInputGate(at now: Date = .now) {
        inputGateUntil = now.addingTimeInterval(Self.inputGate)
    }

    /// A text field has started or stopped being typed in. On tvOS this is not told: the system keyboard is a screen of its
    /// own that takes the remote and ends itself (Menu closes it without the app hearing of it), and a focused field is
    /// not a field being typed in, so the commands never belong to a field there.
    func textEditing(_ editing: Bool) {
        #if !os(tvOS)
        isEditingText = editing
        #endif
    }

    /// While set, every controller and keyboard command goes here first; true: consumed (the stream screen owns the
    /// controller).
    @ObservationIgnored public var commandCapture: (@MainActor (MenuCommand) -> Bool)?
    /// Ends the repeats of a held direction (``MenuInput/cancelRepeats()``); set by the screen that owns the input.
    @ObservationIgnored public var cancelRepeats: (@MainActor () -> Void)?
    /// How often the command being handled has repeated while its direction is held (0: a new press).
    @ObservationIgnored public internal(set) var commandRepeat = 0
    /// Whether the command being handled is the Siri Remote's Menu or Play/Pause (tvOS): not a button of a game
    /// controller, whose buttons the stream sends to the PC.
    @ObservationIgnored public internal(set) var commandFromRemote = false

    public init(root: Screen, focus: AnyHashable? = nil) {
        stack = [Entry(screen: root, focus: FocusModel(initial: focus))]
    }

    public var current: Screen { stack[stack.count - 1].screen }
    public var focus: FocusModel { stack[stack.count - 1].focus }
    public var canGoBack: Bool { stack.count > 1 }

    /// Opens [screen] above the current one, with the focus on [focus] (nil: the first item that appears).
    public func push(_ screen: Screen, focus: AnyHashable? = nil) {
        armInputGate()
        stack.append(Entry(screen: screen, focus: FocusModel(initial: focus)))
    }

    /// Goes back one screen. False at the root.
    @discardableResult
    public func back() -> Bool {
        guard canGoBack else { return false }
        armInputGate()
        stack.removeLast()
        return true
    }

    /// Replaces the whole stack with [screen] (the first run is over, or starts again).
    public func reset(to screen: Screen, focus: AnyHashable? = nil) {
        armInputGate()
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

    /// Opens a screen of the top navigation ([Screen.showsNavigation]). Settings, Profile and Devices take each other's
    /// place, so B returns to the screen below them (Android: their `back` is the library); the current one stays.
    public func openFromNavigation(_ screen: Screen, focus: AnyHashable? = nil) {
        guard current != screen else { return }
        if current.replacesOnNavigation, canGoBack { stack.removeLast() }
        push(screen, focus: focus)
    }

    /// Drops the libraries of the PC [hostID] from the stack (the PC was removed or unpaired): what is below the screen
    /// shown must not lead back into a PC that is gone. The screen shown stays.
    public func dropLibrary(of hostID: String) {
        let top = stack.count - 1
        var index = 0
        stack.removeAll { entry in
            defer { index += 1 }
            if index == top { return false }
            if case .home(let id) = entry.screen { return id == hostID }
            return false
        }
    }

    /// Starts streaming the app [appID] of the PC [hostID].
    public func openStream(hostID: String, appID: Int) {
        push(.stream(hostID: hostID, appID: appID))
    }

    /// Return ends typing and is then delivered as a key press too: an A or Return within this time after the field
    /// let go of the keyboard is the same press and must not activate the focused item. The same holds for the time
    /// after a screen change or a layer opening (``armInputGate(at:)``): the press that is still down is not a new one.
    func swallowsAccept(at now: Date = .now) -> Bool {
        now.timeIntervalSince(textEditingEnded) < 0.3 || now < inputGateUntil
    }
}
