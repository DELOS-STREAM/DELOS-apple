#if os(macOS)
import DelosData
import SwiftUI
@testable import DelosUI

/// Settings on a tab, with the appearance it edits.
@MainActor
struct SettingsHost: View {
    let fx: ShellFixture
    let focus: FocusModel
    let tab: SettingsTab
    @State private var appearance = Appearance()

    var body: some View {
        SettingsScreen(profileID: fx.profiles.current!.id, appearance: $appearance, focus: focus, navigator: fx.navigator, feedback: nil, actions: fx.actions, tab: tab)
    }
}
#endif
