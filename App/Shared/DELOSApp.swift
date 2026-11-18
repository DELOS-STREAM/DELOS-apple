import DelosUI
import SwiftUI
#if os(iOS)
import UIKit

/// Locks the app to landscape. The Info.plist lists only the landscape orientations, but iPadOS 26 and later no longer
/// honour `UIRequiresFullScreen`, and the device still started to turn to portrait before snapping back (owner's iPad
/// and iPhone); the application delegate's answer is the one the system asks at every rotation.
final class OrientationLock: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscape
    }

    /// Also tells each window scene that it is landscape only, so the system does not start a rotation it then
    /// refuses (the device still played the rotation animation with the delegate's answer alone). The scene of an
    /// external display gets its own delegate: the companion screen or the app's window may go there
    /// (``CompanionDisplays``).
    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = connectingSceneSession.role == .windowExternalDisplayNonInteractive ? ExternalDisplayScene.self : LandscapeScene.self
        return configuration
    }
}

/// The scene of an external display (an HDMI or USB-C display, an AirPlay screen): it shows nothing of its own, so the
/// system mirrors the device's screen, until ``CompanionDisplays`` puts the companion screen or the app's window there.
final class ExternalDisplayScene: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        CompanionDisplays.shared.externalSceneConnected(windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        CompanionDisplays.shared.externalSceneDisconnected(windowScene)
    }
}

/// Asks the scene's geometry for landscape when it connects, and once SwiftUI has made its window, puts the hosting
/// controller inside ``OrientationLockedContainer``: since iPadOS 26 (and iOS 27 with its SDK) the system rotates a
/// landscape-only app's scene and plays the rotation animation before it refuses portrait (owner's iPad and iPhone);
/// the supported way to hold the orientation is a view controller that prefers it locked (TN3192), and SwiftUI's own
/// hosting controller cannot be told so. That first window is the app's own, which ``CompanionDisplays`` may move to an
/// external display; a later window of the scene (the companion's) is left alone.
final class LandscapeScene: NSObject, UIWindowSceneDelegate {
    private var registered = false

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard !registered, let windowScene = scene as? UIWindowScene, let window = windowScene.keyWindow, let root = window.rootViewController
        else { return }
        registered = true
        if !(root is OrientationLockedContainer) { window.rootViewController = OrientationLockedContainer(content: root) }
        CompanionDisplays.shared.mainWindowReady(window, in: windowScene)
    }
}

/// Holds SwiftUI's hosting controller as its only child, prefers the landscape orientation locked and, while a stream wants
/// it, the pointer locked (iPadOS asks only the root view controller; SwiftUI's hosting controller cannot be told).
final class OrientationLockedContainer: UIViewController {
    private let content: UIViewController

    init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)
        if #available(iOS 26, *) { setNeedsUpdateOfPrefersInterfaceOrientationLocked() }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersInterfaceOrientationLocked: Bool { true }
    override var prefersPointerLocked: Bool { StreamPointerLock.prefersLocked }
    override var childForStatusBarHidden: UIViewController? { content }
    override var childForHomeIndicatorAutoHidden: UIViewController? { content }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { content }
}
#endif

@main
struct DELOSApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(OrientationLock.self) private var orientationLock
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var macDelegate
    #endif

    init() {
        DelosFonts.register()
    }

    var body: some Scene {
        #if os(macOS)
        // One window: a second one would be a second interface over the one streaming core. It opens at 1920 × 1080
        // points (the system keeps it on the screen), resizes to any shape (the Stage adapts) and goes full screen.
        // The title bar is hidden, so the traffic lights lie over the corner of the stage; below 960 × 540 points
        // the status bar's first button would reach them.
        Window("DELOS", id: "main") {
            DelosRoot()
                .frame(minWidth: 960, minHeight: 540)
        }
        .defaultSize(width: 1920, height: 1080)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        #else
        WindowGroup {
            DelosRoot()
        }
        #endif
    }
}
