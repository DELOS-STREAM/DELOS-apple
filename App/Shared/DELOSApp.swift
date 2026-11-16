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
