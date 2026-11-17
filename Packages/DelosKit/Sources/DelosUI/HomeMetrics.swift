import Foundation

/// The size of the covers and where the row starts, stage pixels (`CoverGeometry` of DELOS for Android): a cover is
/// ``scale`` times the prototype's 300 × 450 (the wide first one three covers and two gaps wide, so it keeps its ratio too),
/// its gap and corner scale with it, and ``start`` is the first cover's left edge. Everywhere but on a compact stage the
/// scale is 1 and the start 150, which are the prototype's numbers.
struct CoverGeometry: Equatable {
    let scale: Double
    let start: Double

    static let prototypeTile = 300.0, prototypeHeight = 450.0, prototypeGap = 44.0, prototypeCorner = 26.0
    static let focusScale = 1.055

    var tile: Double { Self.prototypeTile * scale }
    var height: Double { Self.prototypeHeight * scale }
    /// Between two covers: the prototype's 44 scaled, on a compact stage at least the room a focused cover needs.
    var gap: Double { scale < 1 ? HomeCompact.coverGap(scale) : Self.prototypeGap }
    var wide: Double { 3 * tile + 2 * Self.prototypeGap * scale }
    var corner: Double { Self.prototypeCorner * scale }

    /// The room after the last cover (`CoverGeometry.endPadding`): the focused wide first cover grows only to the left, so
    /// it ends closer to the edge than the others, which grow evenly; the last cover, focused, is as far from the right
    /// edge as the first one, focused, is from the left one (about 104 px for the first cover's 150 px). [start] is the
    /// row's start including the safe area's inset on that side.
    func endPadding(start: Double) -> Double {
        start - wide * (Self.focusScale - 1) + tile * (Self.focusScale - 1) / 2
    }

    /// Where cover [index] starts in the row, stage pixels from the first one.
    func itemStart(_ index: Int) -> Double {
        index == 0 ? 0 : wide + gap + Double(index - 1) * (tile + gap)
    }

    static let standard = CoverGeometry(scale: 1, start: 150)
}

/// Where the home's blocks stand on the stage shown, stage pixels: the compact family lays everything out top-down
/// (``HomeCompact``), every other shape uses ``HomeLayout`` with the prototype's covers.
struct HomeMetrics: Equatable {
    let compact: Bool
    let titleTop: Double
    let titleBox: Double
    let titleGap: Double
    let infoHeight: Double
    let coverTop: Double
    /// The streaming-time block stands above the badges (a very narrow compact stage).
    let blockAbove: Bool
    let covers: CoverGeometry
    /// The room above and below the covers for the focus scale, the ring, the pulse and the glow, which the scroll view would cut.
    let rowPad: Double
    /// The left edge of the title and the info row, and the width the info row may take.
    let infoStart: Double
    let infoWidth: Double
    /// The row's right fade: opaque up to this far from the edge, clear at the least distance.
    let fadeSolid: Double
    let fadeClear: Double
    /// The row's end padding, including the safe area.
    let rowEnd: Double

    /// The standard layouts' room above and below the covers, and the compact one's.
    static let standardRowPad = 40.0, compactRowPad = 48.0

    init(stage: Stage) {
        compact = stage.compact
        if stage.compact {
            let home = HomeCompact.layout(
                stageWidth: stage.width, stageHeight: stage.height, scale: stage.textScale, safeTop: stage.safe.top, safeBottom: stage.safe.bottom)
            titleTop = home.titleTop
            titleBox = home.titleBox
            titleGap = home.titleGap
            infoHeight = home.infoHeight
            coverTop = home.coverTop
            blockAbove = home.blockAbove
            covers = CoverGeometry(scale: home.coverScale, start: HomeCompact.rowStart(home.coverScale))
            rowPad = Self.compactRowPad
            infoStart = HomeCompact.side + stage.safe.leading
            infoWidth = max(stage.width - 2 * HomeCompact.side - stage.safe.leading - stage.safe.trailing, 0)
            fadeSolid = HomeCompact.fadeSolid
            fadeClear = HomeCompact.fadeClear
        } else {
            let layout = HomeLayout(scale: stage.textScale, safeTop: stage.safe.top, stageHeight: stage.height)
            titleTop = layout.titleTop
            titleBox = layout.titleBox
            titleGap = layout.titleGap
            infoHeight = layout.infoHeight
            coverTop = layout.coverTop
            blockAbove = false
            covers = .standard
            rowPad = Self.standardRowPad
            infoStart = 150 + stage.safe.leading
            infoWidth = 1620
            fadeSolid = RowFade.endSolid
            fadeClear = RowFade.endClear
        }
        rowEnd = covers.endPadding(start: covers.start + stage.safe.trailing)
    }

    /// The row's content starts here: the covers' start and the safe area's inset.
    func rowStart(safeLeading: Double) -> Double { covers.start + safeLeading }

    /// The font size of the title as text at [length] characters (`GameInfo` of Android: a compact stage sets it smaller).
    func titleSize(length: Int) -> Double {
        switch length {
        case 23...: compact ? 44 : 56
        case 14...: compact ? 50 : 68
        default: compact ? 60 : 84
        }
    }

    /// The logo's air above and below it in the title box: 10 px, 4 in a box that is only as tall as the title.
    var logoPad: Double { compact && titleBox < 100 ? 4 : HomeLayout.logoPad }

    /// The logo's widest.
    func logoWidth(stageWidth: Double) -> Double { compact ? min(900, stageWidth - 2 * HomeCompact.side) : 900 }
}
