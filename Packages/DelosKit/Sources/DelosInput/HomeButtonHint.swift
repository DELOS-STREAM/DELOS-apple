import DelosCore
import Foundation
import GameController

/// What the system does with a controller's Home button while DELOS is in front: the per-app Home action of Settings →
/// General → Game Controller (iOS, iPadOS and macOS 27).
public enum HomeButtonInAppAction: Sendable, Equatable {
    /// The system keeps the button (its Quick Settings, the Games app) whatever the app asks for, so `GameInput`'s
    /// `preferredSystemGestureState = .disabled` does nothing and a tap of Home never opens the stream menu.
    case systemDefault
    /// The system leaves the button to the app that asks for it, as `GameInput` does while it runs.
    case deferred
    /// macOS only: the system does nothing with the button, so it reaches DELOS.
    case disabled
    /// The setting could not be read (no controller is connected, or the system does not let the app read it).
    case unavailable

    /// Whether a press of Home reaches DELOS.
    public var reachesApp: Bool { self == .deferred || self == .disabled }
}

/// The way to the stream menu the Home button notice offers instead of Home: the swipe up from the bottom edge (a touch
/// screen with the swipe on), holding Escape (a keyboard: the Mac, or a hardware keyboard), else only the controller
/// buttons the user records in Controls (which the notice names in every case).
public enum StreamMenuWay: Sendable, Equatable {
    case swipe
    case keys
    case buttons

    public static func choose(touch: Bool, swipeOn: Bool, keyboard: Bool) -> StreamMenuWay {
        if touch && swipeOn { return .swipe }
        if keyboard { return .keys }
        return .buttons
    }
}

/// The system's Home button settings, as ``HomeButtonHint`` needs them; tests stand in a fake.
@MainActor
public protocol HomeButtonSettingsReader: AnyObject {
    /// The current per-app Home action (the system lets it be read only while a controller is connected).
    func inAppAction() -> HomeButtonInAppAction
    /// Opens the system's page where the per-app Home action is changed; false when it could not be opened.
    func openInAppActionSettings() -> Bool
    /// Calls [onChange] each time the system's Home button settings change, until the returned task is cancelled.
    func observeChanges(_ onChange: @escaping @MainActor () -> Void) -> Task<Void, Never>
}

/// The notice that the controller's Home button stays with the system. On iOS, iPadOS and macOS 27 the button goes to the
/// system (Quick Settings, the Games app) unless the user leaves it to DELOS in the system's game controller settings,
/// and only then does the stream menu open with a tap of Home. When a controller with a Home button connects (on the
/// interface or during a stream) and the per-app action is the system's, the notice is asked for once per launch; it is
/// taken back when the settings change to an action that lets the button reach DELOS (the user went to the page and
/// changed it). Nothing on older systems and on tvOS, which has no such setting (``systemReader()`` is nil there).
@MainActor
public final class HomeButtonHint {
    public enum Event: Equatable, Sendable {
        /// Show the notice.
        case show
        /// Take the notice back: Home reaches DELOS now.
        case hide
    }

    private let reader: HomeButtonSettingsReader
    private let onEvent: @MainActor (Event) -> Void
    /// The notice was asked for in this launch: never again until DELOS starts anew.
    public private(set) var shownThisLaunch = false
    /// The notice was asked for and not taken back yet.
    private var showing = false
    private var observers: [NSObjectProtocol] = []
    private var changes: Task<Void, Never>?

    public init(reader: HomeButtonSettingsReader, onEvent: @escaping @MainActor (Event) -> Void) {
        self.reader = reader
        self.onEvent = onEvent
    }

    /// The system's settings on iOS, iPadOS and macOS 27 and later; nil elsewhere (older systems, tvOS).
    public static func systemReader() -> HomeButtonSettingsReader? {
        #if os(iOS) || os(macOS)
        if #available(iOS 27, macOS 27, *) { return SystemHomeButtonSettings() }
        #endif
        return nil
    }

    /// Watches the controllers that connect from now on and the ones already connected, and the settings' changes.
    public func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            let hasHome = (note.object as? GCController).map(Self.hasHomeButton) ?? false
            MainActor.assumeIsolated { self?.controllerConnected(hasHomeButton: hasHome) }
        })
        changes = reader.observeChanges { [weak self] in self?.settingsChanged() }
        for controller in GCController.controllers() { controllerConnected(hasHomeButton: Self.hasHomeButton(controller)) }
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        changes?.cancel()
        changes = nil
    }

    /// Opens the system's page of the per-app Home action (the notice's action).
    @discardableResult
    public func openSettings() -> Bool {
        let opened = reader.openInAppActionSettings()
        if !opened { DiagLog.w(Self.tag, "the controller settings could not be opened") }
        return opened
    }

    /// A controller connected: the notice when it has a Home button the system keeps, once per launch.
    func controllerConnected(hasHomeButton: Bool) {
        guard hasHomeButton, !shownThisLaunch else { return }
        let action = reader.inAppAction()
        DiagLog.i(Self.tag, "in-app action of the home button: \(action)")
        guard action == .systemDefault else { return }
        shownThisLaunch = true
        showing = true
        onEvent(.show)
    }

    /// The system's Home button settings changed: the notice goes once Home reaches DELOS.
    func settingsChanged() {
        let action = reader.inAppAction()
        DiagLog.i(Self.tag, "in-app action of the home button changed: \(action)")
        guard showing, action.reachesApp else { return }
        showing = false
        onEvent(.hide)
    }

    nonisolated static func hasHomeButton(_ controller: GCController) -> Bool {
        controller.physicalInputProfile.buttons[GCInputButtonHome] != nil
    }

    private static let tag = "HomeButton"
}

#if os(iOS) || os(macOS)
/// ``HomeButtonSettingsReader`` over GameController's `GCControllerHomeButtonSettingsManager`.
@available(iOS 27, macOS 27, *)
@MainActor
private final class SystemHomeButtonSettings: HomeButtonSettingsReader {
    private let manager: GCControllerHomeButtonSettingsManager

    init() { manager = GCControllerHomeButtonSettingsManager(MainActor.shared) }

    func inAppAction() -> HomeButtonInAppAction {
        do {
            switch try manager.controllerHomeButtonInAppAction.action {
            case .systemDefault: return .systemDefault
            case .defer: return .deferred
            case .unavailable: return .unavailable
            #if os(macOS)
            case .disabled: return .disabled
            #endif
            @unknown default: return .unavailable
            }
        } catch {
            DiagLog.w("HomeButton", "the in-app action of the home button could not be read: \(error)")
            return .unavailable
        }
    }

    func openInAppActionSettings() -> Bool {
        do {
            try manager.openControllerHomeButtonSettings(for: .customizeInAppAction)
            return true
        } catch {
            DiagLog.w("HomeButton", "openControllerHomeButtonSettings failed: \(error)")
            return false
        }
    }

    func observeChanges(_ onChange: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        let updates = manager.settingsUpdates
        return Task { @MainActor in
            for await _ in updates { onChange() }
        }
    }
}
#endif
