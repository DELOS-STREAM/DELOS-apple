import Foundation
import Testing
@testable import DelosUI

/// The touch drag of the side menu: the arithmetic (``SideMenuSwipe``) and what the router does with a drag.
@Suite struct SideMenuSwipeTests {
    private let width = 1000.0
    private let fling = 1500.0
    private let slop = 16.0

    @Test func onlyATouchInTheEdgeBandStartsTheOpeningDrag() {
        #expect(SideMenuSwipe.startsAtEdge(0))
        #expect(SideMenuSwipe.startsAtEdge(39.9))
        #expect(!SideMenuSwipe.startsAtEdge(40))
        #expect(!SideMenuSwipe.startsAtEdge(-1))
    }

    @Test func aDragBelongsToTheMenuOnlyWhenItGoesSidewaysTheRightWay() {
        // Still within the slop: undecided
        #expect(SideMenuSwipe.claims(opening: true, dx: 10, dy: 4, slop: slop) == nil)
        // Opening: to the right, more sideways than vertical
        #expect(SideMenuSwipe.claims(opening: true, dx: 30, dy: 10, slop: slop) == true)
        #expect(SideMenuSwipe.claims(opening: true, dx: -30, dy: 0, slop: slop) == false)
        // A vertical scroll is left to the screen
        #expect(SideMenuSwipe.claims(opening: true, dx: 20, dy: 40, slop: slop) == false)
        // Closing: to the left
        #expect(SideMenuSwipe.claims(opening: false, dx: -30, dy: 5, slop: slop) == true)
        #expect(SideMenuSwipe.claims(opening: false, dx: 30, dy: 5, slop: slop) == false)
    }

    @Test func theProgressFollowsTheFingerAndIsDampedPastFullyOpen() {
        #expect(abs(SideMenuSwipe.progress(start: 0, travel: 250, width: width) - 0.25) < 1e-9)
        #expect(abs(SideMenuSwipe.progress(start: 1, travel: -400, width: width) - 0.6) < 1e-9)
        // Never below closed
        #expect(SideMenuSwipe.progress(start: 0, travel: -300, width: width) == 0)
        #expect(SideMenuSwipe.progress(start: 1, travel: -1500, width: width) == 0)
        // Past fully open it moves less than the finger and never reaches the limit
        let pulled = SideMenuSwipe.progress(start: 0, travel: 1100, width: width)
        #expect(pulled > 1 && pulled < 1.1)
        #expect(SideMenuSwipe.progress(start: 0, travel: 100_000, width: width) < 1 + SideMenuSwipe.rubber)
        // The pull starts as fast as the finger: no jump at fully open
        #expect(abs(SideMenuSwipe.progress(start: 0, travel: 1001, width: width) - 1.001) < 1e-4)
    }

    @Test func aSlowReleaseOpensOrClosesByTheDistance() {
        #expect(!SideMenuSwipe.settlesOpen(opening: true, progress: 0.4, velocity: 0, fling: fling))
        #expect(SideMenuSwipe.settlesOpen(opening: true, progress: 0.41, velocity: 0, fling: fling))
        // From open, 40 % of the width to the left closes it
        #expect(SideMenuSwipe.settlesOpen(opening: false, progress: 0.61, velocity: 0, fling: fling))
        #expect(!SideMenuSwipe.settlesOpen(opening: false, progress: 0.59, velocity: 0, fling: fling))
        // A speed below the fling does not decide
        #expect(!SideMenuSwipe.settlesOpen(opening: true, progress: 0.2, velocity: fling - 1, fling: fling))
    }

    @Test func aFlingGoesTheWayItMoves() {
        #expect(SideMenuSwipe.settlesOpen(opening: true, progress: 0.1, velocity: fling, fling: fling))
        #expect(!SideMenuSwipe.settlesOpen(opening: true, progress: 0.9, velocity: -fling, fling: fling))
        #expect(!SideMenuSwipe.settlesOpen(opening: false, progress: 0.9, velocity: -fling, fling: fling))
        #expect(SideMenuSwipe.settlesOpen(opening: false, progress: 0.2, velocity: fling, fling: fling))
        // 600 points per second is a fling by default
        #expect(SideMenuSwipe.settlesOpen(opening: true, progress: 0.05, velocity: 600))
    }

    @Test func reducedMotionTogglesOnlyAfterTheThreshold() {
        #expect(!SideMenuSwipe.reducedToggles(opening: true, travel: 399, width: width))
        #expect(SideMenuSwipe.reducedToggles(opening: true, travel: 400, width: width))
        #expect(!SideMenuSwipe.reducedToggles(opening: true, travel: -500, width: width))
        #expect(SideMenuSwipe.reducedToggles(opening: false, travel: -400, width: width))
        #expect(!SideMenuSwipe.reducedToggles(opening: false, travel: 400, width: width))
    }

    @Test func theReleaseSpringStartsWhereTheFingerLeftAndSettles() {
        let spring = SettleSpring(from: 0.5, to: 1, velocity: 2, began: .now)
        #expect(abs(spring.value(at: 0) - 0.5) < 1e-9)
        // Moving with the finger's speed at first
        #expect(spring.value(at: 0.01) > 0.5 + 0.015)
        #expect(abs(spring.value(at: 2) - 1) < 1e-4)
    }
}

#if os(macOS)
/// What the router does with a touch drag of the side menu.
@MainActor @Suite struct SideMenuDragRouterTests {
    private func shell() -> ShellHarness {
        let shell = ShellHarness(root: .start)
        shell.router.sideWidth = 1000
        shell.router.settle = { _, change, done in
            change()
            done()
        }
        return shell
    }

    @Test func aDragFromTheEdgeOpensTheMenuAtOnceAndThePanelFollowsTheFinger() {
        let shell = shell()
        #expect(shell.router.sideSwipeOpens)
        shell.router.beginSideDrag(opening: true)
        #expect(shell.router.sideMenu != nil && shell.router.sideDrag.engaged)
        #expect(shell.router.sideDrag.progress == 0)
        shell.router.moveSideDrag(travel: 300)
        #expect(abs(shell.router.sideDrag.progress - 0.3) < 1e-9)
        // Released short of 40 %: springs back and closes
        shell.router.endSideDrag(opening: true, travel: 300, velocity: 0)
        #expect(shell.router.sideMenu == nil && !shell.router.sideDrag.engaged)
    }

    @Test func aReleasePastTheThresholdOrAFlingOpensIt() {
        let shell = shell()
        shell.router.beginSideDrag(opening: true)
        shell.router.moveSideDrag(travel: 450)
        shell.router.endSideDrag(opening: true, travel: 450, velocity: 0)
        #expect(shell.router.sideMenu != nil && !shell.router.sideDrag.engaged)
        #expect(shell.router.sideDrag.progress == 1)

        let flung = self.shell()
        flung.router.beginSideDrag(opening: true)
        flung.router.moveSideDrag(travel: 60)
        flung.router.endSideDrag(opening: true, travel: 60, velocity: 900)
        #expect(flung.router.sideMenu != nil)
    }

    @Test func aDragToTheLeftOnTheOpenMenuClosesIt() {
        let shell = shell()
        shell.router.openSideMenu()
        #expect(!shell.router.sideSwipeOpens)
        shell.router.beginSideDrag(opening: false)
        #expect(shell.router.sideDrag.progress == 1)
        shell.router.moveSideDrag(travel: -200)
        shell.router.endSideDrag(opening: false, travel: -200, velocity: 0)
        #expect(shell.router.sideMenu != nil, "20 % is not enough")
        shell.router.beginSideDrag(opening: false)
        shell.router.moveSideDrag(travel: -450)
        shell.router.endSideDrag(opening: false, travel: -450, velocity: 0)
        #expect(shell.router.sideMenu == nil)
    }

    @Test func theMenuButtonWaitsForADragToSettle() {
        let shell = shell()
        shell.router.settle = { _, change, _ in change() }
        shell.router.beginSideDrag(opening: true)
        shell.router.moveSideDrag(travel: 500)
        shell.router.endSideDrag(opening: true, travel: 500, velocity: 0)
        shell.press(.back)
        #expect(shell.router.sideMenu != nil, "the drag still owns the menu")
    }

    @Test func withReducedMotionTheDragOnlyTogglesAfterTheThreshold() {
        let shell = shell()
        shell.router.reducedMotion = true
        shell.router.beginSideDrag(opening: true)
        #expect(shell.router.sideMenu == nil && !shell.router.sideDrag.engaged)
        shell.router.endSideDrag(opening: true, travel: 300, velocity: 2000)
        #expect(shell.router.sideMenu == nil)
        shell.router.endSideDrag(opening: true, travel: 400, velocity: 0)
        #expect(shell.router.sideMenu != nil)
        shell.router.endSideDrag(opening: false, travel: -400, velocity: 0)
        #expect(shell.router.sideMenu == nil)
    }
}
#endif
