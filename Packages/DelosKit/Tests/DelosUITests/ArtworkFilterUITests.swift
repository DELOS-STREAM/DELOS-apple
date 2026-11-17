import DelosData
import Testing
@testable import DelosUI

@Suite struct ArtworkFilterUITests {
    @Test func theResultLineNamesTheTotalWhenItDiffers() {
        #expect(ArtworkTab.cover.resultLine(shown: 10, total: 41, all: false) == "10 of 41 covers")
        #expect(ArtworkTab.cover.resultLine(shown: 41, total: 41, all: true) == "All 41 covers")
        #expect(ArtworkTab.cover.resultLine(shown: 1, total: nil, all: false) == "1 cover")
        #expect(ArtworkTab.wide.resultLine(shown: 3, total: 1, all: false).contains("3"))
    }

    @Test func theEmptyExplanationShowsTheGameAndTheTotal() {
        #expect(ArtworkTab.cover.has(game: "Hades", total: 41).hasPrefix("Hades has 41 covers"))
    }
}
