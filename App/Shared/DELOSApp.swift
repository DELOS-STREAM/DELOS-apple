import DelosUI
import SwiftUI

@main
struct DELOSApp: App {
    init() {
        DelosFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            DelosRoot()
        }
    }
}
