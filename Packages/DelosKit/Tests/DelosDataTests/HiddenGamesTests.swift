import Foundation
import Testing
@testable import DelosData

@Suite struct HiddenGamesTests {
    private func store() -> HiddenGames { HiddenGames(suiteName: "delos.tests.\(UUID().uuidString)") }

    @Test func nothingIsHiddenAtFirst() {
        #expect(store().ids(profile: "a", hostID: "pc").isEmpty)
    }

    @Test func gamesAreHiddenAndShownAgain() {
        let hidden = store()
        hidden.set(true, appID: 7, profile: "a", hostID: "pc")
        hidden.set(true, appID: 3, profile: "a", hostID: "pc")
        hidden.set(true, appID: 7, profile: "a", hostID: "pc")
        #expect(hidden.ids(profile: "a", hostID: "pc") == [3, 7])
        hidden.set(false, appID: 7, profile: "a", hostID: "pc")
        #expect(hidden.ids(profile: "a", hostID: "pc") == [3])
        hidden.set(false, appID: 3, profile: "a", hostID: "pc")
        #expect(hidden.ids(profile: "a", hostID: "pc").isEmpty)
    }

    @Test func theStateIsPerProfileAndPerPC() {
        let hidden = store()
        hidden.set(true, appID: 1, profile: "a", hostID: "pc1")
        #expect(hidden.ids(profile: "a", hostID: "pc2").isEmpty)
        #expect(hidden.ids(profile: "b", hostID: "pc1").isEmpty)
    }

    @Test func aRemovedProfileTakesItsHiddenGamesAlong() {
        let hidden = store()
        hidden.set(true, appID: 1, profile: "a", hostID: "pc1")
        hidden.set(true, appID: 2, profile: "a", hostID: "pc2")
        hidden.set(true, appID: 3, profile: "b", hostID: "pc1")
        hidden.remove(profile: "a")
        #expect(hidden.ids(profile: "a", hostID: "pc1").isEmpty)
        #expect(hidden.ids(profile: "a", hostID: "pc2").isEmpty)
        #expect(hidden.ids(profile: "b", hostID: "pc1") == [3])
    }
}
