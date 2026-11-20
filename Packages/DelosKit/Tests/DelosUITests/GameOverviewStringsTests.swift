import Testing
@testable import DelosUI

/// The overview's plurals that show a formatted count ("1,284 ratings"): the quantity picks the form, the text is shown.
@Suite struct GameOverviewStringsTests {
    @Test func formattedCountPlurals() {
        #expect(LPlural("overview_ratings", 1284, "1,284") == "1,284 ratings")
        #expect(LPlural("overview_reviews", 1, "1") == "1 review")
        #expect(LPlural("overview_ratings_few", 23, "23") == "23 ratings · few so far")
        #expect(LPlural("overview_languages", 14, 14) == "14 languages")
    }
}
