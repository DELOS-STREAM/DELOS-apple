import CoreGraphics
import Testing
@testable import DelosUI

/// How the focus finds its way between items: Android's focus finder (beams and weights), with the sideways cone that keeps a
/// row a row.
@Suite struct FocusGeometryBeamTests {
    let current = CGRect(x: 100, y: 100, width: 100, height: 100)

    @Test func anItemInTheBeamBeatsACloserOneOutsideIt() {
        let next = FocusGeometry.next(from: current, direction: .right, candidates: [
            "in the beam, far": CGRect(x: 900, y: 110, width: 100, height: 80),
            "near, one row down": CGRect(x: 230, y: 230, width: 100, height: 100),
        ])
        #expect(next == "in the beam, far")
    }

    @Test func theNearerOfTwoItemsInTheBeamWins() {
        let next = FocusGeometry.next(from: current, direction: .down, candidates: [
            "far": CGRect(x: 100, y: 700, width: 100, height: 100),
            "near": CGRect(x: 120, y: 300, width: 100, height: 100),
        ])
        #expect(next == "near")
    }

    @Test func theEndOfARowNeverLeadsToAButtonAboveItsLastItemJustBecauseItsCenterIsAPixelFurtherRight() {
        // The Artwork grid's last tile and its Filter pill above it: the pill is 1 px narrower on the right, so its center is
        // a pixel to the right of the tile's, but it lies above the tile, not to its right
        let tile = CGRect(x: 1122, y: 288, width: 146, height: 219)
        let pill = CGRect(x: 1125, y: 171, width: 142, height: 45)
        #expect(FocusGeometry.next(from: tile, direction: .right, candidates: ["pill": pill]) == nil)
        #expect(FocusGeometry.next(from: tile, direction: .up, candidates: ["pill": pill]) == "pill")
    }

    @Test func sidewaysNeverLeadsToAnotherRow() {
        // A button at the end of the title row, the navigation above to the left and covers below to the right: Left and
        // Right stay where they are
        let button = CGRect(x: 1125, y: 301, width: 142, height: 45)
        let others: [String: CGRect] = [
            "nav": CGRect(x: 609, y: 38, width: 45, height: 45),
            "cover": CGRect(x: 2079, y: 630, width: 215, height: 322),
            "near cover": CGRect(x: 1340, y: 630, width: 215, height: 322),
        ]
        #expect(FocusGeometry.next(from: button, direction: .left, candidates: others) == nil)
        #expect(FocusGeometry.next(from: button, direction: .right, candidates: others) == nil)
    }

    @Test func upAndDownMayLeadToAnItemOffToTheSide() {
        // The navigation is centered above content that is not: Up from a cover reaches it though nothing is straight above
        let cover = CGRect(x: 847, y: 630, width: 214, height: 322)
        let nav = CGRect(x: 609, y: 38, width: 45, height: 45)
        #expect(FocusGeometry.next(from: cover, direction: .up, candidates: ["nav": nav]) == "nav")
        #expect(FocusGeometry.next(from: nav, direction: .down, candidates: ["cover": cover]) == "cover")
    }

    @Test func anItemMustLieBeyondTheCurrentOneNotOnlyHaveItsCenterThere() {
        // Inside the current item, or overlapping it with its far edge short of ours: not in that direction
        let inside = CGRect(x: 120, y: 120, width: 40, height: 40)
        let overlapping = CGRect(x: 150, y: 100, width: 100, height: 100)
        for direction in [FocusDirection.up, .down, .left, .right] {
            #expect(FocusGeometry.next(from: current, direction: direction, candidates: ["inside": inside]) == nil)
        }
        #expect(FocusGeometry.next(from: current, direction: .left, candidates: ["overlapping": overlapping]) == nil)
    }

    @Test func aTieGoesToTheSmallerIdWhateverTheOrderOfTheDictionary() {
        let a = CGRect(x: 300, y: 100, width: 100, height: 100)
        let b = CGRect(x: 300, y: 100, width: 100, height: 100)
        for _ in 0..<20 {
            #expect(FocusGeometry.next(from: current, direction: .right, candidates: ["b": b, "a": a]) == "a")
        }
    }

    @Test func theFallbackIsTheNearestItemOrTheFirstInReadingOrder() {
        let items: [String: CGRect] = [
            "bottom": CGRect(x: 0, y: 500, width: 10, height: 10),
            "top right": CGRect(x: 400, y: 0, width: 10, height: 10),
            "top left": CGRect(x: 100, y: 0, width: 10, height: 10),
        ]
        #expect(FocusGeometry.fallback(near: nil, candidates: items) == "top left")
        #expect(FocusGeometry.fallback(near: CGRect(x: 0, y: 480, width: 10, height: 10), candidates: items) == "bottom")
        #expect(FocusGeometry.fallback(near: nil, candidates: [String: CGRect]()) == nil)
    }
}

@MainActor
@Suite struct FocusModelFallbackTests {
    @Test func aFocusOnAnItemThatIsNotThereFallsToTheFirstInReadingOrderNotToAnyOne() {
        for _ in 0..<10 {
            let model = FocusModel(initial: AnyHashable("first-app"))
            model.register("b", frame: CGRect(x: 200, y: 0, width: 10, height: 10)) {}
            model.register("a", frame: CGRect(x: 100, y: 0, width: 10, height: 10)) {}
            model.register("c", frame: CGRect(x: 0, y: 300, width: 10, height: 10)) {}
            #expect(model.handle(.down))
            #expect(model.focused == AnyHashable("a"))
        }
    }

    @Test func aScreenWithNothingToFocusFirstTakesTheFirstItemAsTheyRegister() {
        let model = FocusModel(initial: AnyHashable("first-app"))
        model.focusFirstItem()
        model.register("nav-devices", frame: CGRect(x: 300, y: 0, width: 10, height: 10)) {}
        #expect(model.focused == AnyHashable("nav-devices"))
        model.register("nav-settings", frame: CGRect(x: 100, y: 0, width: 10, height: 10)) {}
        #expect(model.focused == AnyHashable("nav-settings"))
        // Whatever registers later: the focus is where the player put it
        model.focus("nav-devices")
        model.register("another", frame: CGRect(x: 0, y: 0, width: 10, height: 10)) {}
        #expect(model.focused == AnyHashable("nav-devices"))
    }

    @Test func movingTheFocusEndsTheWatchForTheFirstItem() {
        let model = FocusModel(initial: AnyHashable("first-app"))
        model.focusFirstItem()
        model.register("a", frame: CGRect(x: 0, y: 0, width: 10, height: 10)) {}
        model.register("b", frame: CGRect(x: 100, y: 0, width: 10, height: 10)) {}
        #expect(model.handle(.right))
        #expect(model.focused == AnyHashable("b"))
        model.register("c", frame: CGRect(x: 0, y: 0, width: 10, height: 10)) {}
        #expect(model.focused == AnyHashable("b"))
    }

    @Test func theFocusedItemGoingAwayHandsTheFocusToTheNearestOne() async {
        let model = FocusModel(initial: AnyHashable("b"))
        model.register("a", frame: CGRect(x: 0, y: 0, width: 10, height: 10)) {}
        model.register("b", frame: CGRect(x: 500, y: 0, width: 10, height: 10)) {}
        model.register("c", frame: CGRect(x: 600, y: 0, width: 10, height: 10)) {}
        model.unregister("b")
        await Task.yield()
        #expect(model.focused == AnyHashable("c"))
    }
}
