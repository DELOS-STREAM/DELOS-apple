import Testing
@testable import DelosUI

@Suite struct TopBarBackTests {
    @Test func dashboardHasNoBackArrowEvenWithConnectionHistory() {
        let dashboard = Screen.home(hostID: "fixture")
        #expect(!dashboard.showsTopBarBack(canGoBack: true, capturingBack: false))
        #expect(!dashboard.showsTopBarBack(canGoBack: false, capturingBack: false))
    }

    @Test func gameInfoKeepsTheUniversalBackButtonWithoutRequiringHistory() {
        let dashboard = Screen.home(hostID: "fixture")
        #expect(dashboard.showsTopBarBack(canGoBack: false, capturingBack: true))
        #expect(dashboard.showsTopBarBack(canGoBack: true, capturingBack: true))
    }

    @Test func otherScreensKeepNavigationAndSearchBack() {
        #expect(Screen.settings.showsTopBarBack(canGoBack: true, capturingBack: false))
        #expect(!Screen.start.showsTopBarBack(canGoBack: false, capturingBack: false))
        #expect(Screen.settings.showsTopBarBack(canGoBack: false, capturingBack: true))
    }

    /// The back button fades and scales in and out with game info on the dashboard only; other screens' back comes with
    /// the screen's own transition, and reduced motion has none.
    @MainActor @Test func onlyGameInfoAnimatesTheBackButton() {
        #expect(Screen.home(hostID: "fixture").animatesTopBarBack)
        #expect(!Screen.settings.animatesTopBarBack && !Screen.start.animatesTopBarBack)
        #expect(TopBar.backAnimation(true, reduced: false) != nil)
        #expect(TopBar.backAnimation(true, reduced: true) == nil && TopBar.backAnimation(false, reduced: false) == nil)
    }
}
