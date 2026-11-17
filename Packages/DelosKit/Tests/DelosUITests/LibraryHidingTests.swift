import DelosData
import Foundation
import DelosHost
import Testing
@testable import DelosUI

@Suite @MainActor struct LibraryHidingTests {
    private let apps = [HostApp(id: 1, title: "A"), HostApp(id: 2, title: "B"), HostApp(id: 3, title: "C")]

    @Test func hiddenGamesAreLeftOutUnlessTheyAreShown() {
        #expect(LibraryHiding.visible(apps, hidden: [2], showHidden: false).map(\.id) == [1, 3])
        #expect(LibraryHiding.visible(apps, hidden: [2], showHidden: true).map(\.id) == [1, 2, 3])
        #expect(LibraryHiding.visible(apps, hidden: [], showHidden: false).map(\.id) == [1, 2, 3])
        #expect(LibraryHiding.visible(apps, hidden: [1, 2, 3], showHidden: false).isEmpty)
    }

    @Test func gamesThePCNoLongerHasDoNotCount() {
        #expect(LibraryHiding.count(apps, hidden: [2, 9]) == 1)
        #expect(LibraryHiding.count(apps, hidden: []) == 0)
    }

    @Test func theSideMenuRowIsThereWhileSomethingIsHiddenOrTheSwitchIsOn() {
        #expect(LibraryHiding.sideRow(count: 0, showing: false, pcName: "PC") == nil)
        #expect(LibraryHiding.sideRow(count: 2, showing: false, pcName: "PC")?.showing == false)
        #expect(LibraryHiding.sideRow(count: 0, showing: true, pcName: "PC")?.showing == true)
        #expect(LibraryHiding.sideRow(count: 2, showing: false, pcName: "PC")?.note == "2 hidden on PC")
        #expect(LibraryHiding.sideRow(count: 2, showing: false, pcName: nil)?.note == "2 hidden on this PC")
    }

    @Test func theModelReadsAgainAfterAChange() {
        let model = HiddenLibrary(store: HiddenGames(suiteName: "delos.tests.\(UUID().uuidString)"))
        #expect(model.ids(profile: "p", hostID: "h").isEmpty)
        model.set(true, appID: 4, profile: "p", hostID: "h")
        #expect(model.ids(profile: "p", hostID: "h") == [4])
        model.set(true, appID: 4, profile: nil, hostID: "h")
        #expect(model.ids(profile: nil, hostID: "h").isEmpty)
    }
}
