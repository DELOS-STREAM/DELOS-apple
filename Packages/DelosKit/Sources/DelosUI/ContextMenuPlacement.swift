import CoreGraphics

/// The side of the card its caret sits on: `left` for a card to the right of its element, `top` for one below it.
enum CaretSide: Sendable {
    case none, left, right, top, bottom
}

/// Geometry of the context menu card, stage pixels (`ContextMenuLayout` of DELOS for Android; its docs/gui/
/// MENUS_AND_SETTINGS.md, "Context menu").
enum ContextMenuLayout {
    static let corner = 34.0
    static let padding = 14.0
    static let minWidth = 470.0
    static let maxWidth = 640.0

    /// The caret (the shared ``CardCaret``): ``caretWidth`` along the card's edge; ``caretDepth`` is its nominal distance for the placement
    /// (the room around the card, 30 as on Android), the drawn tip is ``CardCaret/depth`` out of the card.
    static let caretWidth = CardCaret.width
    static let caretDepth = 30.0
    /// The caret keeps this far from the card's corners (the stream popover's `CARET_MIN_INSET`).
    static let caretInset = CardCaret.minInset
    /// The caret's tip relative to the element's edge: negative reaches into the element (half the caret over the
    /// element with its 10 px focus ring).
    static let tipGap = -5.0

    /// The card keeps the stream popover's margin from the top and bottom of the stage, and a smaller one from its sides.
    static let marginY = 120.0
    static let marginX = 60.0
    /// A compact stage keeps the card this far from the top and the sides.
    static let compactMargin = 48.0

    /// The tallest card: the stage's height between the two vertical margins.
    static func maxHeight(stageHeight: Double, marginY: Double = marginY, marginBottom: Double? = nil) -> Double {
        stageHeight - marginY - (marginBottom ?? marginY)
    }

    /// Where a card without an element to point at sits.
    static let fallbackX = 760.0
    static let fallbackY = 300.0

    static let rowHeight = 64.0
    /// The gap between two rows (``FocusSpacing``): the focused row's plate and ring lie inside it and it does not grow,
    /// so only the clearance is needed.
    static let rowGap = FocusSpacing.clearance
    static let rowRadius = 28.0
    static let rowRing = 3.0
}

/// Where the card is, stage pixels: its top-left corner, the side its caret is on, the caret's center along that edge
/// from the card's top-left corner, and the caret's tip, which the card opens from.
struct MenuPlacement: Equatable, Sendable {
    let x: Double
    let y: Double
    let side: CaretSide
    let caret: Double
    let tipX: Double
    let tipY: Double
}

private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), max(low, high)) }

/// The card of size [w] × [h] for the element [anchor] (stage pixels; `placeContextMenu` of DELOS for Android). Beside
/// the element by default: to its right with the caret on the card's left, flipped to its left when it would leave the
/// stage, vertically centered on the element and kept inside the margins of the stage. With [below] under the element,
/// centered on it, caret on top; when it does not fit there but fits above (and not [underOnly]), above it with the caret
/// on the bottom; when it fits neither, pushed up from the bottom edge over the element, or with [besideWhenCramped] (a
/// compact stage, where that would cover the element) beside it like a card that is not [below]. [underOnly] is for an
/// element under a heading (the Devices screen's PCs): a card above would cover the heading, so it stays under the
/// element as on DELOS for Android, whose 16:9 stage never has the room above.
func placeContextMenu(
    anchor: CGRect?, w: Double, h: Double, below: Bool, stageW: Double, stageH: Double,
    marginX: Double = ContextMenuLayout.marginX, marginY: Double = ContextMenuLayout.marginY, marginBottom: Double? = nil,
    besideWhenCramped: Bool = false, underOnly: Bool = false
) -> MenuPlacement {
    typealias L = ContextMenuLayout
    let bottomLimit = stageH - (marginBottom ?? marginY)
    guard let anchor else {
        let x = clamp(L.fallbackX, marginX, stageW - marginX - w)
        let y = clamp(L.fallbackY, marginY, bottomLimit - h)
        return MenuPlacement(x: x, y: y, side: .none, caret: 0, tipX: x, tipY: y)
    }
    let reach = L.tipGap + L.caretDepth
    if below {
        let x = clamp(anchor.midX - w / 2, marginX, stageW - marginX - w)
        let caret = caretAlong(anchor.midX - x, length: w)
        let under = anchor.maxY + reach
        let fitsUnder = under + h <= bottomLimit
        let fitsAbove = !underOnly && anchor.minY - reach - h >= marginY
        if fitsUnder || (!fitsAbove && !besideWhenCramped) {
            let y = min(under, max(bottomLimit - h, marginY))
            return MenuPlacement(x: x, y: y, side: .top, caret: caret, tipX: x + caret, tipY: y - L.caretDepth)
        }
        if fitsAbove {
            let y = anchor.minY - reach - h
            return MenuPlacement(x: x, y: y, side: .bottom, caret: caret, tipX: x + caret, tipY: y + h + L.caretDepth)
        }
        // Neither under nor above the element (a short compact stage): beside it, as every other card, instead of over it
    }
    let y = clamp(anchor.midY - h / 2, marginY, bottomLimit - h)
    let caret = caretAlong(anchor.midY - y, length: h)
    let right = anchor.maxX + reach
    if right + w <= stageW - marginX || anchor.minX - reach - w < marginX {
        let x = min(right, max(stageW - marginX - w, marginX))
        return MenuPlacement(x: x, y: y, side: .left, caret: caret, tipX: x - L.caretDepth, tipY: y + caret)
    }
    let x = anchor.minX - reach - w
    return MenuPlacement(x: x, y: y, side: .right, caret: caret, tipX: x + w + L.caretDepth, tipY: y + caret)
}

/// The caret's center along an edge of [length]: the element's center [at], kept ``ContextMenuLayout/caretInset`` from
/// both corners.
func caretAlong(_ at: Double, length: Double) -> Double {
    clamp(at, ContextMenuLayout.caretInset, length - ContextMenuLayout.caretInset)
}

/// The submenus of a context menu (`MenuPath` of DELOS for Android): a path is the index of the opened item at each
/// level, empty at the menu itself. A path that no longer fits the items (they changed) resolves as far as it goes.
enum MenuPath {
    /// The items shown at [path].
    static func items(_ root: [MenuItem], _ path: [Int]) -> [MenuItem] {
        var items = root
        for index in path {
            guard items.indices.contains(index), let children = items[index].children else { break }
            items = children
        }
        return items
    }

    /// The item whose children [path] shows, nil at the root.
    static func parent(_ root: [MenuItem], _ path: [Int]) -> MenuItem? {
        var items = root
        var parent: MenuItem?
        for index in path {
            guard items.indices.contains(index), let children = items[index].children else { break }
            parent = items[index]
            items = children
        }
        return parent
    }

    /// The path after choosing the item [index] of [path]: one level deeper when it has children, else nil (it is an
    /// action).
    static func open(_ root: [MenuItem], _ path: [Int], _ index: Int) -> [Int]? {
        let items = items(root, path)
        guard items.indices.contains(index), items[index].children != nil else { return nil }
        return path + [index]
    }

    /// One level up.
    static func back(_ path: [Int]) -> [Int] { Array(path.dropLast()) }
}
