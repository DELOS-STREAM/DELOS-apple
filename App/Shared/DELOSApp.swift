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
    /// refuses (the device still played the rotation animation with the delegate's answer alone).
    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = LandscapeScene.self
        return configuration
    }
}

/// Asks the scene's geometry for landscape when it connects, and once SwiftUI has made its window, puts the hosting
/// controller inside ``OrientationLockedContainer``: since iPadOS 26 (and iOS 27 with its SDK) the system rotates a
/// landscape-only app's scene and plays the rotation animation before it refuses portrait (owner's iPad and iPhone);
/// the supported way to hold the orientation is a view controller that prefers it locked (TN3192), and SwiftUI's own
/// hosting controller cannot be told so.
final class LandscapeScene: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let window = (scene as? UIWindowScene)?.keyWindow, let root = window.rootViewController,
              !(root is OrientationLockedContainer) else { return }
        window.rootViewController = OrientationLockedContainer(content: root)
    }
}

/// Holds SwiftUI's hosting controller as its only child and prefers the landscape orientation locked.
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
    override var childForStatusBarHidden: UIViewController? { content }
    override var childForHomeIndicatorAutoHidden: UIViewController? { content }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { content }
}
#endif

@main
struct DELOSApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(OrientationLock.self) private var orientationLock
    #endif

    init() {
        DelosFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            DelosRoot()
        }
    }
}
