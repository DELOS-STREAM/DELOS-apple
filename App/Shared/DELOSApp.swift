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

/// Asks the scene's geometry for landscape when it connects.
final class LandscapeScene: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
    }
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
