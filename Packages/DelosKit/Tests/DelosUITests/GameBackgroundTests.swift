import Testing
@testable import DelosUI

@Suite struct GameBackgroundTests {
    @Test func onlyTheLibraryShowsTheGameBackground() {
        #expect(Screen.home(hostID: "h").showsGameBackground)
        // The app settings have their own banner; a second copy of the art behind them zoomed and faded away
        #expect(!Screen.appSettings(hostID: "h", appID: 1).showsGameBackground)
        #expect(!Screen.artwork(hostID: "h", appID: 1).showsGameBackground)
        #expect(!Screen.settings.showsGameBackground && !Screen.start.showsGameBackground)
    }
}
