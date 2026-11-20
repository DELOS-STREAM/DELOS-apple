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
}
