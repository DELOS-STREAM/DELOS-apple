import Observation
import Testing
@testable import DelosUI

@Suite struct EdgeFadeTests {
    @Test func anEdgeFadesOnlyAsFarAsContentIsHiddenBehindIt() {
        #expect(EdgeFadeMath.strength(hidden: 0, length: 120) == 0)
        #expect(EdgeFadeMath.strength(hidden: -5, length: 120) == 0)
        #expect(EdgeFadeMath.strength(hidden: 30, length: 120) == 0.25)
        #expect(EdgeFadeMath.strength(hidden: 120, length: 120) == 1)
        #expect(EdgeFadeMath.strength(hidden: 900, length: 120) == 1)
        // No fade at all
        #expect(EdgeFadeMath.strength(hidden: 50, length: 0) == 0)
    }

    @Test func whatIsHiddenIsMeasuredFromTheVisiblePartAndCapped() {
        // At rest at the start, with a content inset: nothing hidden before, the rest after
        let rest = EdgeFadeMath.hidden(visibleStart: -12, visibleEnd: 988, contentLength: 1500, cap: (1000, 1000))
        #expect(rest.start == 0 && rest.end == 512)
        // In the middle the amounts stop at the fade lengths, so the scroll through the middle changes nothing
        let middle = EdgeFadeMath.hidden(visibleStart: 700, visibleEnd: 1700, contentLength: 5000, cap: (60, 130))
        #expect(middle.start == 60 && middle.end == 130)
        // At the end, past the content with an inset: nothing hidden after
        let end = EdgeFadeMath.hidden(visibleStart: 4012, visibleEnd: 5012, contentLength: 5000, cap: (60, 130))
        #expect(end.start == 60 && end.end == 0)
    }

    @Test func theLibraryRowFadesAsAndroidsAtFullStrength() {
        let stops = EdgeFadeMath.stops(
            length: 1920, bleed: 0, start: FadeEdge(solid: 120), end: FadeEdge(solid: 260, clear: 20), strength: (1, 1))
        let locations: [Double] = [0, 0, 120.0 / 1920, 1 - 260.0 / 1920, 1 - 20.0 / 1920, 1]
        let opacities: [Double] = [0, 0, 1, 1, 0, 0]
        #expect(stops.map(\.location) == locations)
        #expect(stops.map(\.opacity) == opacities)
    }

    @Test func anEdgeWithNothingBehindItIsOpaqueToItsVeryEnd() {
        // The first item's ring and glow at the edge are neither dimmed nor cut, through the bleed beyond the edge too
        let stops = EdgeFadeMath.stops(
            length: 800, bleed: 40, start: FadeEdge(solid: 24), end: FadeEdge(solid: 24), strength: (0, 0))
        #expect(stops.allSatisfy { $0.opacity == 1 })
    }

    @Test func aFadeGrowsWithTheStrength() {
        let half = EdgeFadeMath.stops(
            length: 1000, bleed: 0, start: FadeEdge(solid: 100, clear: 20), end: FadeEdge(solid: 100), strength: (0.5, 0))
        // Clear up to 10, opaque from 50, and the end untouched
        #expect(half[1].location == 0.01 && half[1].opacity == 0)
        #expect(half[2].location == 0.05 && half[2].opacity == 1)
        #expect(half[4].location == 1 && half[4].opacity == 1)
    }

    @Test func atFullStrengthTheBleedBeyondTheEdgeIsClear() {
        // Items scrolled away beyond the edge of a scroll view that does not clip are cut there, and the fade starts at the edge
        let stops = EdgeFadeMath.stops(
            length: 800, bleed: 100, start: FadeEdge(solid: 50), end: FadeEdge(solid: 50), strength: (1, 1))
        #expect(stops[1].location == 0.1 && stops[1].opacity == 0)
        #expect(stops[2].location == 0.15 && stops[2].opacity == 1)
        #expect(abs(stops[3].location - 0.85) < 1e-12 && abs(stops[4].location - 0.9) < 1e-12 && stops[4].opacity == 0)
    }

    @Test func eachEdgeKeepsToItsHalfSoTheLocationsNeverGoBack() {
        let stops = EdgeFadeMath.stops(
            length: 100, bleed: 0, start: FadeEdge(solid: 400), end: FadeEdge(solid: 400, clear: 20), strength: (1, 1))
        let locations = stops.map(\.location)
        #expect(zip(locations, locations.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(locations.allSatisfy { (0...1).contains($0) })
    }
}

/// A focus step must redraw the item that loses the focus and the one that gains it, not every item of the screen: the whole
/// row of covers re-evaluated at each step of a held arrow cost the frames of its scroll (R2-15).
@MainActor
@Suite struct FocusFlagTests {
    private final class Seen: @unchecked Sendable {
        var ids: Set<String> = []
    }

    private func watch(_ model: FocusModel, _ ids: [String]) -> Seen {
        let seen = Seen()
        for id in ids {
            withObservationTracking { _ = model.isFocused(id) } onChange: { seen.ids.insert(id) }
        }
        return seen
    }

    @Test func aMoveNotifiesOnlyTheTwoItemsItConcerns() {
        let model = FocusModel(initial: "a")
        let seen = watch(model, ["a", "b", "c", "d"])
        model.focus("b")
        #expect(seen.ids == ["a", "b"])
        #expect(model.isFocused("b") && !model.isFocused("a"))
    }

    @Test func focusingTheFocusedItemAgainNotifiesNobody() {
        let model = FocusModel(initial: "a")
        let seen = watch(model, ["a", "b"])
        let whole = Seen()
        withObservationTracking { _ = model.focused } onChange: { whole.ids.insert("focused") }
        model.focus("a")
        #expect(seen.ids.isEmpty)
        #expect(whole.ids.isEmpty)
    }

    @Test func anItemAskedBeforeTheFocusComesFollowsIt() {
        let model = FocusModel()
        #expect(!model.isFocused("x"))
        model.focus("x")
        #expect(model.isFocused("x"))
        model.focus("y")
        #expect(!model.isFocused("x") && model.isFocused("y"))
    }
}
