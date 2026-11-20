import CoreGraphics
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
        // Pills up to 400 px and chips up to 400 px wide keep twice their reach and the clear space between them
        for width in stride(from: 150.0, through: GlideLook.pillMaxWidth, by: 50) {
            #expect(FocusSpacing.gap(reach: GlideLook.pill.reach(width: width)) <= GlideLook.pillGap + 0.001, "a pill \(width) px wide")
        }
        for width in stride(from: 60.0, through: GlideLook.chipMaxWidth, by: 20) {
            #expect(FocusSpacing.gap(reach: GlideLook.chip.reach(width: width)) <= GlideLook.chipGap + 0.001, "a chip \(width) px wide")
        }
        // 8 % growth of a 400 px pill is 16 px on a side, and the ring's band (twice its width) 8 px beyond that
        #expect(abs(GlideLook.pill.reach(width: 400) - 24) < 0.001)
        #expect(GlideLook.chip.reach(width: 100) < GlideLook.pill.reach(width: 100))
    }

    @Test func theGlidingRingStartsWhereItWasAndEndsExactlyOnTheElement() {
        let search = CGRect(x: 700, y: 0, width: 296, height: 46), filter = CGRect(x: 1018, y: 0, width: 142, height: 46)
        let glide = RingGlide(from: search, to: filter, at: 100)
        #expect(glide.rect(on: filter, at: 100) == search)
        // A tenth of the way in (the curve has done about 37 % of the distance) it is between the two, as wide as neither
        let early = glide.rect(on: filter, at: 100 + RingGlide.duration / 10)
        #expect(early.minX > search.minX + 60 && early.minX < filter.minX - 60)
        #expect(early.width < search.width - 20 && early.width > filter.width + 20)
        let end = glide.rect(on: filter, at: 100 + RingGlide.duration)
        #expect(abs(end.minX - filter.minX) < 0.001 && abs(end.width - filter.width) < 0.001)
        #expect(glide.rect(on: filter, at: 200) == filter)
    }

    @Test func theGlidingRingTravelsWithAnElementThatScrollsWhileItGlides() {
        let from = CGRect(x: 0, y: 0, width: 100, height: 60), to = CGRect(x: 300, y: 0, width: 140, height: 60)
        let glide = RingGlide(from: from, to: to, at: 0)
        let time = RingGlide.duration * 0.3
        // The row scrolls the target 80 points to the left: the ring is 80 points further left, its size the same
        let scrolled = glide.rect(on: to.offsetBy(dx: -80, dy: 0), at: time)
        let still = glide.rect(on: to, at: time)
        #expect(abs(scrolled.minX - (still.minX - 80)) < 0.001)
        #expect(abs(scrolled.width - still.width) < 0.001)
        #expect(glide.rect(on: to.offsetBy(dx: -80, dy: 0), at: RingGlide.duration) == to.offsetBy(dx: -80, dy: 0))
    }
}
