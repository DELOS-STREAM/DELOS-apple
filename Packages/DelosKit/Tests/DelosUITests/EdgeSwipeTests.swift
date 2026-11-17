import CoreGraphics
import Testing
@testable import DelosUI

/// The swipe in from the left edge that opens the side menu on touch.
@Suite struct EdgeSwipeTests {
    @Test func aSwipeRightFromTheEdgeOpensTheMenu() {
        #expect(EdgeSwipeRule.opens(start: CGPoint(x: 6, y: 500), translation: CGSize(width: 140, height: 20)))
    }

    @Test func aShortDragAVerticalDragOrOneFromInsideTheScreenDoesNot() {
        #expect(!EdgeSwipeRule.opens(start: CGPoint(x: 6, y: 500), translation: CGSize(width: 40, height: 0)))
        #expect(!EdgeSwipeRule.opens(start: CGPoint(x: 6, y: 500), translation: CGSize(width: 100, height: 90)))
        #expect(!EdgeSwipeRule.opens(start: CGPoint(x: 200, y: 500), translation: CGSize(width: 300, height: 0)))
        #expect(!EdgeSwipeRule.opens(start: CGPoint(x: 6, y: 500), translation: CGSize(width: -120, height: 0)))
    }
}
