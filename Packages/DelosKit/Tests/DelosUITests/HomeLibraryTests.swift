import DelosInput
import SwiftUI
import Testing
@testable import DelosUI

@Suite struct GameActivationTests {
    @Test func startsTheGameWhenNothingElseRuns() {
        #expect(GameActivation.of(app: 7, running: nil) == .start)
    }

    @Test func resumesTheGameThatRuns() {
        #expect(GameActivation.of(app: 7, running: 7) == .start)
    }

    @Test func offersTheChoicesInsteadOfQuittingAnotherRunningGame() {
        #expect(GameActivation.of(app: 7, running: 3) == .offerChoices)
    }
}

@Suite struct LibraryFocusTests {
    @Test func theFocusTheScreenStillHoldsWinsOverTheRemembered() {
        #expect(LibraryFocus.initial(apps: [5, 6, 7, 8], focused: 7, remembered: 6) == 2)
    }

    @Test func theRememberedGameIsTheOneAfterTheWayBack() {
        // A new screen's focus holds nothing of the library: Settings and back, or the library opened again
        #expect(LibraryFocus.initial(apps: [5, 6, 7, 8], focused: nil, remembered: 8) == 3)
    }

    @Test func aGameThatIsGoneFallsBackToTheNextOneKnownElseTheFirst() {
        #expect(LibraryFocus.initial(apps: [5, 6, 7], focused: 99, remembered: 6) == 1)
        #expect(LibraryFocus.initial(apps: [5, 6, 7], focused: 99, remembered: 98) == 0)
        #expect(LibraryFocus.initial(apps: [5, 6, 7], focused: nil, remembered: nil) == 0)
    }

    @Test func theNeighbourTakesTheFocusOfAGameThatDisappeared() {
        // The third of five was hidden: the fourth now stands at index 2
        #expect(LibraryFocus.afterRemoval(count: 4, lastIndex: 2) == 2)
        // The last one was hidden: the new last one
        #expect(LibraryFocus.afterRemoval(count: 4, lastIndex: 4) == 3)
        #expect(LibraryFocus.afterRemoval(count: 1, lastIndex: 0) == 0)
    }

    @Test @MainActor func theFocusOfAScreenSurvivesItsCoversLeaving() {
        // The covers unregister one after the other when the screen goes (Settings opens above the library): the
        // focused game stays the focused one for the way back
        let model = FocusModel()
        for id in ["app-1", "app-2", "app-3"] {
            model.register(AnyHashable(id), frame: CGRect(x: 0, y: 0, width: 10, height: 10), action: {})
        }
        model.focus("app-2")
        for id in ["app-1", "app-2", "app-3"] { model.unregister(AnyHashable(id)) }
        #expect(model.focused == AnyHashable("app-2"))
    }
}

@Suite struct LibraryWrapTests {
    let ids: [AnyHashable] = ["a", "b", "c"]

    @Test func leftOnTheFirstGoesToTheLastAndRightOnTheLastToTheFirst() {
        #expect(LibraryWrap.moves(index: 0, ids: ids) == [.left: "c"])
        #expect(LibraryWrap.moves(index: 2, ids: ids) == [.right: "a"])
        #expect(LibraryWrap.moves(index: 1, ids: ids).isEmpty)
    }

    @Test func aSingleGameHasNothingToWrapTo() {
        #expect(LibraryWrap.moves(index: 0, ids: ["a"]).isEmpty)
    }

    @Test @MainActor func theFocusModelFollowsTheWrap() {
        let model = FocusModel(initial: "a")
        for (index, id) in ["a", "b", "c"].enumerated() {
            model.register(
                AnyHashable(id), frame: CGRect(x: 100 * index, y: 0, width: 80, height: 80),
                moves: LibraryWrap.moves(index: index, ids: ids), action: {})
        }
        #expect(model.handle(.left))
        #expect(model.focused == AnyHashable("c"))
        #expect(model.handle(.right))
        #expect(model.focused == AnyHashable("a"))
        #expect(model.handle(.right) && model.focused == AnyHashable("b"))
    }

    @Test func onlyTheJumpBetweenTheEndsIsAWrap() {
        #expect(LibraryWrap.isWrap(from: 0, to: 9, count: 10))
        #expect(LibraryWrap.isWrap(from: 9, to: 0, count: 10))
        #expect(!LibraryWrap.isWrap(from: 3, to: 4, count: 10))
        #expect(!LibraryWrap.isWrap(from: nil, to: 0, count: 10))
        // Two games: a step to the other one is not a trip round the row
        #expect(!LibraryWrap.isWrap(from: 0, to: 1, count: 2))
    }

    @Test func theOvershootGrowsWithTheGlideUpToACap() {
        #expect(LibraryWrap.bounce(distance: 0) == 0)
        #expect(LibraryWrap.bounce(distance: 344) < LibraryWrap.bounce(distance: 3000))
        #expect(LibraryWrap.bounce(distance: 100_000) == 4200 * 0.035)
    }
}

@Suite struct CoverToneTests {
    @Test func theFocusedCoverKeepsItsColors() {
        #expect(CoverTone.of(focused: true, menuOpen: false) == (1, 1))
        #expect(CoverTone.of(focused: true, menuOpen: true) == (1, 1))
    }

    @Test func theOthersAreMutedAndDimmedBehindAMenu() {
        #expect(CoverTone.of(focused: false, menuOpen: false) == (0.86, 0.92))
        #expect(CoverTone.of(focused: false, menuOpen: true) == (0.6, 0.5))
    }

    @Test func theInfoDimsToFortyPercent() {
        #expect(CoverTone.info(menuOpen: false) == 1)
        #expect(CoverTone.info(menuOpen: true) == 0.4)
    }
}

@Suite struct RowFadeTests {
    @Test func bothEdgesFadeWhereMoreCoversContinue() {
        let stops = RowFade.stops(width: 1920, startClear: 0, startSolid: 120, endSolid: 260, endClear: 20)
        let expected: [Double] = [0, 0, 120.0 / 1920.0, 1 - 260.0 / 1920.0, 1 - 20.0 / 1920.0, 1]
        #expect(stops.map(\.location) == expected)
        let opacities: [Double] = [0, 0, 1, 1, 0, 0]
        #expect(stops.map(\.opacity) == opacities)
    }

    @Test func anEdgeWithNothingBeyondItIsNotFaded() {
        let stops = RowFade.stops(width: 1920, startClear: 0, startSolid: 0, endSolid: 0, endClear: 0)
        // Opaque from the left edge to the right edge
        let locations: [Double] = [0, 0, 0, 1, 1, 1]
        let opacities: [Double] = [0, 0, 1, 1, 0, 0]
        #expect(stops.map(\.location) == locations)
        #expect(stops.map(\.opacity) == opacities)
    }

    @Test func theLocationsNeverGoBackwards() {
        let stops = RowFade.stops(width: 100, startClear: 0, startSolid: 400, endSolid: 400, endClear: 20)
        let locations = stops.map(\.location)
        #expect(locations.allSatisfy { (0...1).contains($0) })
    }
}

@MainActor @Suite struct LibraryEndTests {
    @Test func theLastCoverIsAsFarFromTheRightEdgeAsTheFirstOneIsFromTheLeft() {
        // 150 - 988 × .055 + 300 × .055 / 2
        let end = CoverGeometry.standard.endPadding(start: 150)
        #expect(abs(end - 103.91) < 0.01)
    }
}
