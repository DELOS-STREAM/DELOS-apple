import CoreGraphics
import SwiftUI

/// The ONE caret of every card that grows out of something: the context menus of the games and the PCs, the stream menu's popover and
/// the popovers of the settings rows, 1:1 with DELOS for Android (docs/gui/MENUS_AND_SETTINGS.md, 3.1.1): ``width`` 60 along the card's
/// edge at its base (u from -30 to 30 around the caret's center), ``depth`` 24 out of it (v). Each flank is a cubic from (30, 0) with
/// the controls (21, 3) and (14, 8) to the join (8, 16), the tip a quadratic between (-8, 16) and (8, 16) with the control (0, 32),
/// the other half mirrored. Sizes are stage pixels; the shapes below turn them into points with the stage's unit.
enum CardCaret {
    static let width = 60.0
    static let depth = 24.0
    /// The caret keeps this far from the card's corners (the stream popover's `CARET_MIN_INSET`).
    static let minInset = 72.0

    /// The caret on [side] of [card], its center [center] (in points, along that edge: an x for the top and bottom, a y for the left
    /// and right), [unit] points per stage pixel. It runs 2 px into the card under the edge, so its union with the card has no seam.
    static func tip(side: CaretSide, center: CGFloat, card: CGRect, unit k: CGFloat) -> Path {
        guard side != .none else { return Path() }
        let half = width / 2
        // (u, v) in stage pixels: u along the edge from the caret's center, v out of the card
        func point(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            switch side {
            case .left: CGPoint(x: card.minX - v * k, y: center + u * k)
            case .right: CGPoint(x: card.maxX + v * k, y: center + u * k)
            case .top: CGPoint(x: center + u * k, y: card.minY - v * k)
            case .bottom, .none: CGPoint(x: center + u * k, y: card.maxY + v * k)
            }
        }
        var path = Path()
        path.move(to: point(-30, 0))
        path.addCurve(to: point(-8, 16), control1: point(-21, 3), control2: point(-14, 8))
        path.addQuadCurve(to: point(8, 16), control: point(0, 32))
        path.addCurve(to: point(30, 0), control1: point(14, 8), control2: point(21, 3))
        path.addLine(to: point(half, -2))
        path.addLine(to: point(-half, -2))
        path.closeSubpath()
        return path
    }

    /// The nominal tip of that caret: the point the card opens from and the element is pointed at.
    static func tipPoint(side: CaretSide, center: CGFloat, card: CGRect, unit k: CGFloat) -> CGPoint {
        switch side {
        case .left: CGPoint(x: card.minX - depth * k, y: center)
        case .right: CGPoint(x: card.maxX + depth * k, y: center)
        case .top: CGPoint(x: center, y: card.minY - depth * k)
        case .bottom, .none: CGPoint(x: center, y: card.maxY + depth * k)
        }
    }

    /// The card and its caret as one outline: a continuous rounded rectangle, and on [side] the caret centered at [center].
    static func outline(card: CGRect, radius: CGFloat, side: CaretSide, center: CGFloat, unit: CGFloat) -> Path {
        let body = Path(roundedRect: card, cornerRadius: min(radius, min(card.width, card.height) / 2), style: .continuous)
        guard side != .none else { return body }
        return body.union(tip(side: side, center: center, card: card, unit: unit))
    }
}
