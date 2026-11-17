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

    @Test func theFocusedPillsRingAndGrowthStayClearOfTheNextPill() {
        // A pill is 300 to 600 px wide; the neighbour must not be reached by the ring that glides to it
        for width in stride(from: 150.0, through: 600.0, by: 50) {
            #expect(GlideLook.pill.reach(width: width) <= GlideLook.pillGap + 0.001, "a pill \(width) px wide")
        }
        // 8 % growth of a 400 px pill is 16 px on a side, and the ring's band (twice its width) 8 px beyond that
        #expect(abs(GlideLook.pill.reach(width: 400) - 24) < 0.001)
        // Chips grow and ring less, and are 12 px apart or more
        #expect(GlideLook.chip.reach(width: 100) < GlideLook.pill.reach(width: 100))
    }
}
