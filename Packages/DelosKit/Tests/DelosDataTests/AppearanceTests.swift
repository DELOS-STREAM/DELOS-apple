import Foundation
import Testing
@testable import DelosData

@Suite struct AppearanceTests {
    @Test func unknownAndMissingValuesFallBackOneByOne() throws {
        // A background removed in a later version and a missing palette keep the rest of the settings
        let json = #"{"dark":false,"background":"starfield","heroBlur":90,"uiScale":50,"sounds":false}"#
        let a = try JSONDecoder().decode(Appearance.self, from: Data(json.utf8))
        #expect(a.dark == false)
        #expect(a.sounds == false)
        #expect(a.background == .contour)
        #expect(a.palette == .delos)
        #expect(a.heroBlur == 40)
        #expect(a.uiScale == 100)
    }

    @Test func settersClampToTheRanges() {
        var a = Appearance()
        a.heroOpacity = 140
        a.uiScale = 200
        #expect(a.heroOpacity == 100)
        #expect(a.uiScale == 130)
    }

    @Test func eachProfileKeepsItsOwnAppearance() throws {
        let suite = "delos.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = AppearanceStore(suiteName: suite)
        var mine = Appearance()
        mine.palette = .mint
        store.save(mine, profile: "a")
        #expect(store.load(profile: "a").palette == .mint)
        #expect(store.load(profile: "b") == Appearance())
    }
}
