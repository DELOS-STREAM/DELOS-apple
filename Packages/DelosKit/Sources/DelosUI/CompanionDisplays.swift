import DelosData
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Puts the interface and the companion screen on the right screens (`CompanionHost`, `CompanionSession`,
/// `ShellPlacement` and the external-display mode of DELOS for Android, docs/DUAL_SCREEN.md §5–6 and
/// docs/EXTERNAL_DISPLAY.md). ``ScreenPlanner`` decides from the screens and the settings; this class carries it out
/// whenever a screen comes or goes, a display setting changes or a stream starts or ends:
///
/// - iPhone and iPad: the second screen is the scene the system offers with the external-display role
///   (`UIWindowScene` of `.windowExternalDisplayNonInteractive`). The app's own window moves between the two scenes
///   (`UIWindow.windowScene`, which keeps the interface's whole state), and the companion window goes into the other
///   one. Without a plan the external scene keeps no window, so the system mirrors the device's screen as before.
/// - Mac: the second screen is another `NSScreen` (the device's own is the built-in one, else the one with the menu
///   bar). The app's window moves to the main screen (full screen there while a stream runs on a monitor or TV in Fully
///   External Display Mode, and back afterwards), the companion is a borderless window filling the other screen. Without
///   a plan nothing is moved.
///
/// Android's key-focus workaround (`returnFocusToOwner`) has no counterpart: the companion window never takes the key
/// focus (a non-interactive scene on iOS, a borderless window that cannot become key on the Mac).
@MainActor
public final class CompanionDisplays {
    public static let shared = CompanionDisplays()
    private let hub = CompanionHub.shared
    private var observer: (any NSObjectProtocol)?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: DisplaySettings.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CompanionDisplays.shared.reconcile() }
        }
        hub.planInputsChanged = { CompanionDisplays.shared.reconcile() }
        #if os(macOS)
        screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CompanionDisplays.shared.reconcile() }
        }
        #endif
    }

    /// The plan for the screens of this moment, nil when the second screen (if any) is not DELOS's.
    private func plan(device: ScreenSize, second: ScreenSize?) -> ScreenPlan? {
        let role = SecondDisplayRole.load()
        hub.paired = ScreenPlanner.paired(second: second, role: role)
        return ScreenPlanner.plan(
            device: device, second: second, role: role, choice: MainScreenChoice.load(), fullExternal: hub.stream?.fullExternal ?? false,
            streaming: hub.stream != nil)
    }

    #if os(iOS)
    private weak var deviceScene: UIWindowScene?
    private weak var externalScene: UIWindowScene?
    /// The app's own window (the interface and the stream).
    private weak var mainWindow: UIWindow?
    private var companionWindow: UIWindow?

    /// The app's scene has its window: it is the one that moves.
    public func mainWindowReady(_ window: UIWindow, in scene: UIWindowScene) {
        guard mainWindow !== window else { return }
        deviceScene = scene
        mainWindow = window
        reconcile()
    }

    /// The system offered the scene of an external display.
    public func externalSceneConnected(_ scene: UIWindowScene) {
        externalScene = scene
        reconcile()
    }

    /// The external display went: what was on it comes back to the device's screen; a stream that was on a monitor or TV
    /// is left (`listenForExternalDisplayRemoval`).
    public func externalSceneDisconnected(_ scene: UIWindowScene) {
        guard scene === externalScene else { return }
        let streamWasThere = mainWindow?.windowScene === scene
        externalScene = nil
        reconcile()
        if streamWasThere { hub.secondScreenLost() }
    }

    private static func size(_ scene: UIWindowScene) -> ScreenSize {
        let size = scene.screen.nativeBounds.size
        return ScreenSize(width: Int(size.width), height: Int(size.height))
    }

    func reconcile() {
        guard let deviceScene, let mainWindow else { return }
        let plan = plan(device: Self.size(deviceScene), second: externalScene.map(Self.size))
        guard let plan, let externalScene else {
            place(mainWindow, in: deviceScene)
            removeCompanion()
            return
        }
        let mainScene = plan.main == .device ? deviceScene : externalScene
        let companionScene = plan.companion == .device ? deviceScene : externalScene
        place(mainWindow, in: mainScene)
        if let companionWindow, companionWindow.windowScene === companionScene { return }
        removeCompanion()
        let window = UIWindow(windowScene: companionScene)
        window.rootViewController = UIHostingController(rootView: CompanionRoot())
        window.isHidden = false
        companionWindow = window
        hub.shown = true
    }

    private func place(_ window: UIWindow, in scene: UIWindowScene) {
        guard window.windowScene !== scene else { return }
        window.windowScene = scene
        window.isHidden = false
        if scene === deviceScene { window.makeKey() }
    }

    /// Takes the companion window off its screen; an external scene left without a window mirrors the device again.
    private func removeCompanion() {
        guard let window = companionWindow else { return }
        window.isHidden = true
        window.windowScene = nil
        companionWindow = nil
        hub.shown = false
    }
    #elseif os(macOS)
    private var screens: (any NSObjectProtocol)?
    private var companionWindow: NSWindow?
    /// Where the app's window was before it was moved, and whether it was put in full screen for a stream, to undo both.
    private var moved: (frame: NSRect, fullScreen: Bool)?

    /// The device's own screen: the built-in one, else the one with the menu bar.
    private static var deviceScreen: NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
        } ?? NSScreen.screens.first
    }

    private static func size(_ screen: NSScreen) -> ScreenSize {
        ScreenSize(width: Int(screen.frame.width * screen.backingScaleFactor), height: Int(screen.frame.height * screen.backingScaleFactor))
    }

    /// The app's own window: the one that is not the companion's.
    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0 !== companionWindow && $0.canBecomeMain }
    }

    /// Starts following the screens and the settings once the app has launched.
    public func start() {
        // SwiftUI makes the app's window after the launch: the first plan is carried out once it is the main window
        windowReady = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CompanionDisplays.shared.reconcile() }
        }
        // Closing the app's window ends the app (`MacAppDelegate`): the companion window must not keep it alive
        windowClosing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                let displays = CompanionDisplays.shared
                if let window, window !== displays.companionWindow, window.canBecomeMain { displays.removeCompanion() }
            }
        }
        reconcile()
    }

    private var windowReady: (any NSObjectProtocol)?
    private var windowClosing: (any NSObjectProtocol)?

    func reconcile() {
        guard let device = Self.deviceScreen, let mainWindow else { return }
        let second = NSScreen.screens.first { $0 !== device }
        let plan = plan(device: Self.size(device), second: second.map(Self.size))
        guard let plan, let second else {
            // The monitor or TV a stream filled went away: the stream is left (`listenForExternalDisplayRemoval`)
            let streamWasThere = second == nil && moved?.fullScreen == true
            restore(mainWindow)
            removeCompanion()
            if streamWasThere { hub.secondScreenLost() }
            return
        }
        let mainScreen = plan.main == .device ? device : second
        let companionScreen = plan.companion == .device ? device : second
        // A stream on a monitor or TV in Fully External Display Mode fills it
        move(mainWindow, to: mainScreen, fullScreen: plan.main == .second && SecondDisplayRole.load() != .builtIn)
        if let companionWindow {
            companionWindow.setFrame(companionScreen.frame, display: true)
        } else {
            let window = CompanionNSWindow(contentRect: companionScreen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
            window.contentView = NSHostingView(rootView: CompanionRoot())
            window.setFrame(companionScreen.frame, display: true)
            window.orderFront(nil)
            companionWindow = window
            hub.shown = true
        }
    }

    private func move(_ window: NSWindow, to screen: NSScreen, fullScreen: Bool) {
        guard window.screen !== screen else { return }
        let wasFullScreen = window.styleMask.contains(.fullScreen)
        if moved == nil { moved = (window.frame, false) }
        // A window in full screen cannot change screens: it leaves full screen first
        if wasFullScreen { window.toggleFullScreen(nil) }
        let visible = screen.visibleFrame
        let size = NSSize(width: min(window.frame.width, visible.width), height: min(window.frame.height, visible.height))
        window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
        if fullScreen || wasFullScreen {
            window.toggleFullScreen(nil)
            if fullScreen, !wasFullScreen { moved?.fullScreen = true }
        }
    }

    private func restore(_ window: NSWindow) {
        guard let moved else { return }
        self.moved = nil
        if moved.fullScreen, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        window.setFrame(moved.frame, display: true)
    }

    private func removeCompanion() {
        guard let window = companionWindow else { return }
        window.orderOut(nil)
        companionWindow = nil
        hub.shown = false
    }
    #else
    func reconcile() {}
    #endif
}

#if os(macOS)
/// The companion's window on the Mac: borderless, never the key or main window, so the keyboard and the controllers stay
/// with the app's window.
private final class CompanionNSWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
#endif
