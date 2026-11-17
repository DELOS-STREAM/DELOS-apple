import CoreGraphics
import SwiftUI
import Testing
@testable import DelosUI

/// The one caret of every card that grows out of something: the context menus, the stream menu's popover and the settings popovers.
/// (Depth is checked by containment: a path's bounding box does not follow a quadratic's peak.)
@Suite struct CardCaretTests {
    private let card = CGRect(x: 100, y: 100, width: 600, height: 400)
    private let sides: [CaretSide] = [.left, .right, .top, .bottom]

    private func center(_ side: CaretSide) -> CGFloat { side == .left || side == .right ? 300 : 400 }

    /// The point [v] stage px out of the card's [side] edge at [along] stage px from the caret's center, scaled by [k].
    private func point(_ side: CaretSide, _ c: CGFloat, _ along: CGFloat, _ v: CGFloat, _ k: CGFloat = 1) -> CGPoint {
        switch side {
        case .left: CGPoint(x: card.minX - v * k, y: c + along * k)
        case .right: CGPoint(x: card.maxX + v * k, y: c + along * k)
        case .top: CGPoint(x: c + along * k, y: card.minY - v * k)
        default: CGPoint(x: c + along * k, y: card.maxY + v * k)
        }
    }

    @Test func theNumbersAreAndroids() {
        #expect(CardCaret.width == 60 && CardCaret.depth == 24)
        #expect(CardCaret.minInset >= 72)
    }

    @Test func theCaretIsAsWideAndAsDeepAsItsNumbersOnEverySide() {
        for k in [1.0, 0.5] as [CGFloat] {
            for side in sides {
                let c = center(side)
                let tip = CardCaret.tip(side: side, center: c, card: card, unit: k)
                let box = tip.cgPath.boundingBox
                let along = side == .left || side == .right ? box.height : box.width
                #expect(abs(along - CardCaret.width * k) < 0.01, "\(side) width at \(k)")
                // Just under the apex is in the caret, just past it is not
                #expect(tip.contains(point(side, c, 0, CardCaret.depth - 1, k)), "\(side) inside the apex at \(k)")
                #expect(!tip.contains(point(side, c, 0, CardCaret.depth + 1, k)), "\(side) past the apex at \(k)")
                // At its base the caret is the full width, 20 px up its flank it is narrower than at the join
                #expect(tip.contains(point(side, c, 28, 1, k)) && !tip.contains(point(side, c, 31, 1, k)))
                #expect(!tip.contains(point(side, c, 20, 16, k)), "\(side) the flank is round, not a box")
            }
        }
    }

    @Test func theCaretIsCenteredAndItsTipIsOnTheCentersLine() {
        for side in sides {
            let c = center(side)
            let tip = CardCaret.tip(side: side, center: c, card: card, unit: 1)
            // Mirror symmetry about the caret's center
            for v in [2.0, 10.0, 20.0] as [CGFloat] {
                for u in [4.0, 12.0, 25.0] as [CGFloat] {
                    #expect(tip.contains(point(side, c, u, v)) == tip.contains(point(side, c, -u, v)), "\(side) u \(u) v \(v)")
                }
            }
            let nominal = CardCaret.tipPoint(side: side, center: c, card: card, unit: 1)
            let along = side == .left || side == .right ? nominal.y : nominal.x
            #expect(along == c)
        }
        #expect(Double(CardCaret.tipPoint(side: .left, center: 300, card: card, unit: 1).x) == 100 - 24)
        #expect(Double(CardCaret.tipPoint(side: .right, center: 300, card: card, unit: 1).x) == 700 + 24)
        #expect(Double(CardCaret.tipPoint(side: .top, center: 400, card: card, unit: 1).y) == 100 - 24)
        #expect(Double(CardCaret.tipPoint(side: .bottom, center: 400, card: card, unit: 1).y) == 500 + 24)
    }

    @Test func theOutlineHasTheCaretAndKeepsTheRoundCorners() {
        for side in sides {
            let c = center(side)
            let outline = CardCaret.outline(card: card, radius: 40, side: side, center: c, unit: 1)
            #expect(outline.contains(point(side, c, 0, 23)), "\(side) apex")
            #expect(!outline.contains(point(side, c, 0, 26)), "\(side) past the apex")
            #expect(outline.contains(CGPoint(x: card.midX, y: card.midY)))
            #expect(!outline.contains(CGPoint(x: card.minX + 1, y: card.minY + 1)), "the corner is round")
        }
    }

    @Test func everyCardUsesTheSameCaret() {
        let k: CGFloat = 1
        let d = CGFloat(CardCaret.depth)
        // The stream popover: the caret on the bottom edge, in the last depth of its rect
        let stream = StreamCardShape(caretX: 300, unit: k).path(in: CGRect(x: 0, y: 0, width: 600, height: 400 + d))
        #expect(stream.contains(CGPoint(x: 300, y: 400 + d - 1)))
        #expect(!stream.contains(CGPoint(x: 100, y: 405)), "beside the caret the card ends at its bottom edge")
        // The settings popovers: on the left edge, or the right edge when flipped
        let rowRect = CGRect(x: 0, y: 0, width: 600 + d, height: 300)
        let left = RowCardShape(caretY: 150, unit: k).path(in: rowRect)
        #expect(left.contains(CGPoint(x: 1, y: 150)) && !left.contains(CGPoint(x: 1, y: 60)))
        let right = RowCardShape(caretY: 150, flipped: true, unit: k).path(in: rowRect)
        #expect(right.contains(CGPoint(x: 600 + d - 1, y: 150)) && !right.contains(CGPoint(x: 600 + d - 1, y: 60)))
        // The context menu: the caret on every side inside the rect, its room ``caretDepth`` (30) in from each side
        let room = CGFloat(ContextMenuLayout.caretDepth)
        let edge = room - d + 1
        let size = CGSize(width: 600 + 2 * room, height: 300 + 2 * room)
        let probes: [(CaretSide, CGPoint, CGPoint)] = [
            (.left, CGPoint(x: edge, y: room + 150), CGPoint(x: edge, y: 60)),
            (.right, CGPoint(x: size.width - edge, y: room + 150), CGPoint(x: size.width - edge, y: 60)),
            (.top, CGPoint(x: room + 150, y: edge), CGPoint(x: 60, y: edge)),
            (.bottom, CGPoint(x: room + 150, y: size.height - edge), CGPoint(x: 60, y: size.height - edge)),
        ]
        for (side, onCaret, offCaret) in probes {
            let path = MenuCardShape(side: side, caret: 150, unit: k).path(in: CGRect(origin: .zero, size: size))
            #expect(path.contains(onCaret), "\(side)")
            #expect(!path.contains(offCaret), "\(side)")
        }
        #expect(ContextMenuLayout.caretWidth == CardCaret.width && ContextMenuLayout.caretDepth == 30)
        #expect(StreamMenuLayout.caretWidth == CardCaret.width && StreamMenuLayout.caretHeight == CardCaret.depth)
        #expect(RowPopoverLayout.caretWidth == CardCaret.width && RowPopoverLayout.caretHeight == CardCaret.depth)
    }

    @Test func noCaretOnACardWithoutOne() {
        #expect(CardCaret.tip(side: .none, center: 0, card: card, unit: 1).isEmpty)
    }
}
