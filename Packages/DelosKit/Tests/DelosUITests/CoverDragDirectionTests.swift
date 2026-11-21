import CoreGraphics
import Testing
@testable import DelosUI

@Suite struct CoverDragDirectionTests {
    @Test(arguments: [CGSize(width: 40, height: -12), CGSize(width: -40, height: -12), CGSize(width: 80, height: 4), CGSize(width: -80, height: 4)])
    func horizontalFingerDragsBelongToTheRow(_ translation: CGSize) {
        #expect(CoverDragDirection.of(translation: translation, minimumDistance: 10) == .horizontalScroll)
    }

    @Test(arguments: [CGSize(width: 2, height: -60), CGSize(width: -2, height: -60), CGSize(width: 2, height: 60)])
    func clearVerticalMotionHasItsOwnAxis(_ translation: CGSize) {
        #expect(CoverDragDirection.of(translation: translation, minimumDistance: 10) == .verticalSwipe)
    }

    @Test(arguments: [CGSize.zero, CGSize(width: 9, height: -9), CGSize(width: -8, height: 2), CGSize(width: 2, height: -8)])
    func smallMovementsDoNotClaimATap(_ translation: CGSize) {
        #expect(CoverDragDirection.of(translation: translation, minimumDistance: 10) == .undecided)
    }

    @Test(arguments: [CGSize(width: 20, height: -20), CGSize(width: -20, height: -20), CGSize(width: 20, height: -22)])
    func almostDiagonalDragsWaitForClearIntent(_ translation: CGSize) {
        #expect(CoverDragDirection.of(translation: translation, minimumDistance: 10) == .undecided)
    }
}
