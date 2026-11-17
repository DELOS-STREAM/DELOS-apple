import Foundation

/// The decisions of the stream menu that need no SwiftUI (`StreamMenuLayout.kt` of DELOS for Android): which tile of the
/// dock a page belongs to, where the focus goes when a page closes, and where the popover with its caret sits. Sizes are
/// stage pixels.

/// The tiles of the dock, in the order they appear. Android has nine; Bitrate and Upscaler are left out here because the
/// streaming core cannot change the bitrate of a running stream and the renderer has no upscaler, Keyboard and
/// Brightness exist only where the device has them (``StreamMenuCapabilities``).
enum BarItem: Int, CaseIterable, Sendable {
    case resume, keyboard, overlay, brightness, more, disconnect, quit

    /// The tile's focus id.
    var id: String {
        switch self {
        case .resume: "stream-resume"
        case .keyboard: "stream-keyboard"
        case .overlay: "stream-statistics"
        case .brightness: "stream-brightness"
        case .more: "stream-more"
        case .disconnect: "stream-disconnect"
        case .quit: "stream-quit"
        }
    }

    init?(id: AnyHashable?) {
        guard let id = id?.base as? String, let item = Self.allCases.first(where: { $0.id == id }) else { return nil }
        self = item
    }

    /// The page this tile opens in the popover; nil: the tile acts at once.
    var page: MenuPage? {
        switch self {
        case .brightness: .brightness
        case .more: .more
        default: nil
        }
    }
}

/// What this device can do for the menu's tiles and pages.
struct StreamMenuCapabilities: Equatable, Sendable {
    /// The system keyboard can be raised over the stream (iPhone and iPad; the Mac has its keyboard, Apple TV none).
    var keyboard: Bool
    /// The screen's brightness can be changed (iPhone and iPad).
    var brightness: Bool

    static let platform: StreamMenuCapabilities = {
        #if os(iOS)
        StreamMenuCapabilities(keyboard: true, brightness: true)
        #else
        StreamMenuCapabilities(keyboard: false, brightness: false)
        #endif
    }()

    /// The tiles of the dock for these capabilities, in Android's order.
    var tiles: [BarItem] {
        BarItem.allCases.filter { item in
            switch item {
            case .keyboard: keyboard
            case .brightness: brightness
            default: true
            }
        }
    }
}

/// What the popover above the dock shows; ``main`` is no popover (the dock alone).
enum MenuPage: Equatable, Sendable {
    case main, more, keys, commands, brightness

    /// The page B goes back to: the dock for the pages of a tile, More for the pages that More opens.
    var parent: MenuPage? {
        switch self {
        case .main: nil
        case .keys, .commands: .more
        case .more, .brightness: .main
        }
    }

    /// The tile that opens this page, directly or through More.
    var barItem: BarItem? {
        switch self {
        case .main: nil
        case .more, .keys, .commands: .more
        case .brightness: .brightness
        }
    }

    /// The row of the parent page that opened this page (the focus returns to it), or nil when the dock's tile did.
    var openedByRow: MenuRowID? {
        switch self {
        case .keys: .keys
        case .commands: .commands
        default: nil
        }
    }
}

/// The rows of the pages by their focus id (the rows of More that open a page of their own, which the focus returns to).
enum MenuRowID: String, Sendable {
    case keys = "more-keys"
    case commands = "more-commands"
    case taskManager = "more-task-manager"
    case brightness = "brightness-screen"
}

/// Where the menu goes after a page closes: the [page] to show and what gets the focus there.
struct PageExit: Equatable, Sendable {
    let page: MenuPage
    let focusTile: BarItem?
    let focusRow: MenuRowID?
}

enum StreamMenuNavigation {
    /// B (or the back chevron) on [page]: one level up, to the row that opened it or to its tile on the dock. Nil on the
    /// dock itself: there B resumes the stream.
    static func afterBack(_ page: MenuPage) -> PageExit? {
        guard let parent = page.parent else { return nil }
        return parent == .main ? PageExit(page: parent, focusTile: page.barItem, focusRow: nil)
            : PageExit(page: parent, focusTile: nil, focusRow: page.openedByRow)
    }

    /// A tap outside the popover: the whole popover closes and its tile gets the focus. Nil when none is open.
    static func afterDismiss(_ page: MenuPage) -> PageExit? {
        page == .main ? nil : PageExit(page: .main, focusTile: page.barItem, focusRow: nil)
    }

    /// What a tap outside the menu's dock and popover does: with a popover open, the popover closes first; with none, the menu
    /// itself closes. Either way the tap is the menu's: it never quits, and never reaches the game.
    enum OutsideTap: Equatable, Sendable {
        case dismissPopover(PageExit)
        case closeMenu
    }

    static func afterOutsideTap(_ page: MenuPage) -> OutsideTap {
        afterDismiss(page).map(OutsideTap.dismissPopover) ?? .closeMenu
    }

    /// The tile to press while a popover is open: nothing for a tile without a page (it is dimmed and does nothing).
    static func tileWorks(opensPage: Bool, popoverOpen: Bool) -> Bool { !popoverOpen || opensPage }

    /// The tiles one step from [index] in [count] tiles, cyclic: Right on the last goes to the first, Left on the first
    /// to the last (the dock wraps; the popover's rows do not).
    static func wrapped(_ index: Int, count: Int, step: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + step) % count + count) % count
    }
}

/// The numbers of the dock and its popover that are not already in ``StreamDockLayout``.
enum StreamMenuLayout {
    static let hintsGap = 12.0
    static let headGap = 22.0
    static let headBottom = 46.0
    static let titleSize = 36.0
    static let titleMaxWidth = 900.0
    static let hintSize = 24.0
    static let hintGlyph = 44.0
    static let captionSize = 28.0
    static let captionLineHeight = 1.4
    static let captionWidth = 1100.0
    static let captionGap = 26.0
    static let captionLines = 3
    static let labelLineHeight = 1.2
    static let dockShift = 160.0
    static let dockSink = 640.0
    static let tileDimmed = 0.46
    static let labelDimmed = 0.4
    static let scrimPopover = 0.22

    // The popover
    static let popoverRadius = 44.0
    static let popoverPaddingX = 40.0
    static let popoverPaddingY = 30.0
    static let popoverPaddingBottom = 24.0
    static let popoverHead = 64.0
    static let popoverGapAfterHead = 12.0
    static let popoverHelpGap = 18.0
    static let popoverTitle = 30.0
    static let caretWidth = CardCaret.width
    static let caretHeight = CardCaret.depth
    /// The popover's box ends here above the stage's bottom: the card's bottom 734, the caret's tip about 13 above the
    /// sunk tile's ring.
    static let popoverBottom = 322.0
    static let caretMinInset = 72.0
    /// The card's gap to the left, right and top edges of the stage.
    static let popoverMargin = 120.0
    static let hiddenScale = 0.86

    // The rows
    static let rowHeight = 72.0
    static let rowRadius = 28.0
    static let rowGap = 8.0
    static let rowSize = 24.0
    static let rowIcon = 32.0
    static let rowIconColumn = 56.0
    static let rowColumnGap = 14.0
    static let rowPaddingStart = 22.0
    static let rowPaddingEnd = 28.0
    static let rowRing = 3.0
    static let sliderWidth = 240.0
    static let sliderHeight = 12.0
    static let knob = 32.0
    static let numberMinWidth = 104.0
    static let helpSize = 22.0
    static let helpLineHeight = 1.4

    /// The popover's width: wide enough for its rows. More and the pages it opens share one width.
    static func popoverWidth(_ page: MenuPage, stageWidth: Double = Stage.designWidth, margin: Double = popoverMargin) -> Double {
        let natural = switch page {
        case .main: 0.0
        case .brightness: 780.0
        case .more, .keys, .commands: 920.0
        }
        // A stage narrower than the card keeps its margins and the card gets what is left
        return min(natural, stageWidth - 2 * margin)
    }

    /// The card's left edge: centered on [anchorX] (the center of the tile that opened it), between the margins.
    static func popoverLeft(anchorX: Double, width: Double, stageWidth: Double, margin: Double = popoverMargin) -> Double {
        min(max(anchorX - width / 2, margin), max(stageWidth - margin - width, margin))
    }

    /// The caret's center from the card's left edge: the anchor kept ``caretMinInset`` from both corners.
    static func caretCenter(anchorX: Double, left: Double, width: Double) -> Double {
        min(max(anchorX - left, caretMinInset), max(width - caretMinInset, caretMinInset))
    }

    /// The lines the popover's help text reserves: 2 at the normal text scale, 3 from 1.15 up.
    static func helpLines(textScale: Double) -> Int { textScale > 1.15 ? 3 : 2 }

    static func helpHeight(textScale: Double) -> Double { helpSize * textScale * helpLineHeight * Double(helpLines(textScale: textScale)) }

    /// The height of [rows] rows with the gaps between them.
    static func rowsHeight(_ rows: Int) -> Double {
        rows <= 0 ? 0 : Double(rows) * rowHeight + Double(rows - 1) * rowGap
    }

    /// The card's height with [rows] rows when nothing scrolls, caret excluded.
    static func naturalHeight(rows: Int, textScale: Double) -> Double {
        popoverPaddingY + popoverHead + popoverGapAfterHead + rowsHeight(rows) + popoverHelpGap + helpHeight(textScale: textScale) + popoverPaddingBottom
    }

    /// The caption's box is this many lines tall at the current text scale: it never grows, nothing scrolls.
    static func captionHeight(textScale: Double) -> Double { captionSize * textScale * captionLineHeight * Double(captionLines) }

    /// The tallest the card may be on a stage [stageHeight] high: from its bottom edge (``popoverBottom`` and the caret
    /// above the stage's bottom, lifted by [lift]) up to the margin below the stage's top.
    static func maxHeight(stageHeight: Double, lift: Double = 0, top: Double = 0, margin: Double = popoverMargin) -> Double {
        stageHeight - popoverBottom - caretHeight - lift - max(margin, top + margin / 2)
    }
}

/// The geometry of the dock for [count] tiles on a stage [width] stage pixels across.
struct DockGeometry: Equatable, Sendable {
    let count: Int
    let width: Double
    /// The least room kept at each side of a row that scrolls (the ring and its glow stay on the screen).
    static let scrollSide = 80.0

    var rowWidth: Double { StreamDockLayout.rowWidth(count: count) }

    /// Whether the tiles do not fit the stage: the row scrolls sideways under the focus.
    var scrolls: Bool { rowWidth + 2 * Self.scrollSide > width }

    /// The first tile's left edge on the stage: centered, or the side margin of a scrolling row.
    var tilesLeft: Double { scrolls ? Self.scrollSide : (width - rowWidth) / 2 }

    /// The content's width: as wide as it scrolls, the stage's where it does not.
    var contentWidth: Double { scrolls ? rowWidth + 2 * Self.scrollSide : width }

    /// The center of tile [index] in the row's content.
    func tileCenter(_ index: Int) -> Double { (scrolls ? Self.scrollSide : (width - rowWidth) / 2) + StreamDockLayout.tileLeft(index) + StreamDockLayout.tile / 2 }
}
