import Foundation

/// Home on a compact stage, laid out top-down (`HomeCompactLayout` of DELOS for Android, issue #9), stage pixels from the
/// stage's top: the status bar, the title (or logo) box, the info row (the badges, scrolling, with the streaming-time block
/// at its start; on a very narrow stage the block stands above the badges), the covers and the hint bar, with the gaps
/// between them. The title box is centred between the status bar and the info row: ``statusGap`` and ``titleGap`` are
/// equal. ``HomeCompact/layout(stageWidth:stageHeight:scale:safeTop:safeBottom:)`` computes it; pure.
struct HomeCompactLayout: Equatable {
    /// The covers' scale against the prototype's 300 × 450 (the wide first one 988 × 450).
    let coverScale: Double
    let titleTop: Double
    let titleBox: Double
    let infoTop: Double
    let infoHeight: Double
    /// The streaming-time block does not fit beside the badges: it stands above them, inside ``infoHeight``.
    let blockAbove: Bool
    let coverTop: Double
    let coverHeight: Double
    /// How far the focused cover's ring reaches above and below the cover.
    let ringReach: Double
    let statusBottom: Double
    let hintTop: Double

    var titleBottom: Double { titleTop + titleBox }
    var infoBottom: Double { infoTop + infoHeight }
    var coverBottom: Double { coverTop + coverHeight }

    /// The four gaps: status bar to title, title to the info row (equal to the first), info row to the focused cover's
    /// ring, that ring to the hint bar.
    var statusGap: Double { titleTop - statusBottom }
    var titleGap: Double { infoTop - titleBottom }
    var chipsGap: Double { coverTop - ringReach - infoBottom }
    var hintGap: Double { hintTop - (coverBottom + ringReach) }
}

/// The numbers of the compact home (`HomeCompact` of DELOS for Android) and its layout.
enum HomeCompact {
    /// The prototype's cover and the wide first one (three covers and two gaps), which every scale keeps the ratio of.
    static let tile = 300.0, coverHeight = 450.0, coverGap = 44.0
    static let wide = 3 * tile + 2 * coverGap

    /// The focused cover grows to this and wears a ring (5 px gap, 5 px ring) that grows with it.
    static let focusScale = 1.055
    static let ring = 10.0

    /// `Compact.SIDE`, `STATUS_BAR` and `HINT_BAR`: the screen's side margin and the bars' heights.
    static let side = 72.0, statusBar = 104.0, hintBar = 92.0

    /// The least gaps: status bar to title, title to the info row, info row to the focused cover's ring, ring to hint bar.
    static let gapStatus = 16.0, gapTitle = 16.0, gapChips = 24.0, gapHint = 28.0

    /// The info row: the streaming-time block at its start and the badges; its height at interface scale 1.
    static let infoRowHeight = 44.0

    /// The air between the block and the first badge, and the least visible room of the badges beside the block.
    static let blockGapX = 30.0, minBadgesWidth = 160.0

    /// The widest the full block gets at interface scale 1; with the two above it decides ``blockAbove(areaWidth:scale:)``.
    static let blockWidest = 460.0

    /// On a very narrow stage the block stands above the badges, this far from them.
    static let blockAboveGap = 12.0

    /// The title box: tall enough for the 60 px title at the least; the comfortable gaps count it ``titleMax`` tall,
    /// leftover room grows it up to ``titleBoxMax`` (a logo up to 140 high).
    static let titleMin = 64.0, titleMax = 120.0, titleBoxMax = 160.0

    /// An info chip is 12 px of padding around a 23 px line of text.
    static let chipPadding = 12.0, chipLine = 23.0

    /// The gaps above and under the covers that a stage with room to spare gives them before the covers grow further.
    static let comfortChips = 40.0, comfortHint = 44.0

    /// A cover is at most this share of the stage's height; it takes what the comfortable gaps leave and is never under
    /// ``floorScale`` (where that does not fit the gaps give way to their least).
    static let maxHeightShare = 0.40
    static let floorScale = 0.45

    /// Where the covers stop shrinking for good.
    static let hardFloor = 0.30

    /// How the room that is left over is shared: a little above and under the title (each), most of it between the info
    /// row and the covers and under the covers.
    static let shareStatus = 0.5, shareChips = 2.0, shareHint = 2.0

    /// The row's right fade on a compact stage: opaque up to this far from the edge, clear at the least distance.
    static let fadeSolid = 72.0, fadeClear = 8.0

    /// The peeking cover ends this far from the stage's right edge (inside the fade).
    static let peekEdge = 24.0

    /// The least air between a focused cover's ring and the cover next to it (the growth, the ring and 12 px).
    static let focusAir = 12.0

    /// The info row at interface scale [scale] (its texts grow with it).
    static func blockHeight(_ scale: Double) -> Double { infoRowHeight * scale }

    /// The room the badges need next to the block's widest form and its gap.
    static func besideWidth(_ scale: Double) -> Double { blockWidest * scale + blockGapX + minBadgesWidth }

    /// Whether the info area [areaWidth] wide is too narrow for the block beside the badges.
    static func blockAbove(areaWidth: Double, scale: Double) -> Bool { areaWidth < besideWidth(scale) }

    /// The room one row of chips takes at interface scale [scale].
    static func chipRowHeight(_ scale: Double) -> Double { chipPadding + chipLine * scale }

    /// The height of the info row: the block's, or with the block above the badges the block, ``blockAboveGap`` and a row of badges.
    static func infoHeight(scale: Double, above: Bool) -> Double {
        blockHeight(scale) + (above ? blockAboveGap + chipRowHeight(scale) : 0)
    }

    /// The room two rows of badges took before the info row (the badges used to wrap), 6 px apart.
    static func twoRowsHeight(_ scale: Double) -> Double { 2 * chipRowHeight(scale) + 6 }

    /// How far the ring of a focused cover [height] high reaches above and below it.
    static func ringReach(_ height: Double) -> Double { height * (focusScale - 1) / 2 + ring * focusScale }

    /// The gap between two covers at [scale]: the prototype's 44 scaled with them, but never less than a focused cover's
    /// growth to one side, its ring and ``focusAir``.
    static func coverGap(_ scale: Double) -> Double {
        max(coverGap * scale, tile * scale * (focusScale - 1) / 2 + ring * focusScale + focusAir)
    }

    /// Where the row starts: the focused wide first cover grows to the left only, so its unfocused left edge lies that far
    /// right of ``side`` and the focused one (with the ring 10 px further out) stands exactly on it.
    static func rowStart(_ scale: Double) -> Double { side + wide * scale * (focusScale - 1) }

    /// The cover scale below which ``coverGap(_:)``'s floor is the larger one.
    private static let gapFloorScale = (ring * focusScale + focusAir) / (coverGap - tile * (focusScale - 1) / 2)

    /// The widest cover scale at which, next to the focused wide first cover, one whole cover and a third of the next one
    /// end ``peekEdge`` before the stage's right edge: a second game is always clearly there.
    static func widthScale(stageWidth: Double) -> Double {
        let room = stageWidth - side - peekEdge
        let proto = room / (wide * focusScale + 2 * coverGap + tile * 4 / 3)
        if proto >= gapFloorScale { return proto }
        let floorGap = tile * (focusScale - 1) / 2
        let floorBase = ring * focusScale + focusAir
        return (room - 2 * floorBase) / (wide * focusScale + 2 * floorGap + tile * 4 / 3)
    }

    /// The layout on a stage [stageWidth] × [stageHeight] at interface scale [scale], [safeTop] and [safeBottom] being the
    /// display cutout. The cover height is the smallest of what the height leaves after the comfortable gaps (after the
    /// least gaps below ``floorScale``), 0.40 of the stage's height and ``widthScale(stageWidth:)``; what is left over then
    /// widens the title box (up to ``titleBoxMax``) and is shared between the gaps by ``shareStatus`` : ``shareChips`` :
    /// ``shareHint``.
    static func layout(stageWidth: Double, stageHeight: Double, scale: Double = 1, safeTop: Double = 0, safeBottom: Double = 0) -> HomeCompactLayout {
        let statusBottom = safeTop + statusBar * scale
        let hintTop = stageHeight - safeBottom - hintBar * scale
        let room = hintTop - statusBottom
        let above = blockAbove(areaWidth: stageWidth - 2 * side, scale: scale)
        let info = infoHeight(scale: scale, above: above)
        let titleMin = titleMin * scale
        let titleMax = max(titleMax, titleMin)
        // Everything but the cover and the part of its ring that grows with it
        let fixed = gapStatus + titleMin + gapTitle + info + gapChips + gapHint + 2 * ring * focusScale
        let byHeight = (room - fixed) / focusScale / coverHeight
        // The same with the logo's comfortable box and comfortable gaps, still counting the two rows the badges took before
        let comfortable = gapStatus + titleMax + gapTitle + max(info, twoRowsHeight(scale)) + comfortChips + comfortHint + 2 * ring * focusScale
        let byComfort = (room - comfortable) / focusScale / coverHeight
        let byShare = stageHeight * maxHeightShare / coverHeight
        let coverScale = max(min(byShare, widthScale(stageWidth: stageWidth), byComfort), max(min(floorScale, byHeight), hardFloor))
        let cover = coverHeight * coverScale
        let reach = ringReach(cover)
        var left = room - (gapStatus + titleMin + gapTitle + info + gapChips + cover + 2 * reach + gapHint)
        var statusGap = gapStatus, titleGap = gapTitle, chipsGap = gapChips, hintGap = gapHint
        var title = titleMin
        if left > 0 {
            let grow = min(left, max(titleBoxMax, titleMin) - titleMin)
            title += grow
            left -= grow
            // The title stays centred: the gap above it and the one under it grow by the same
            let shares = 2 * shareStatus + shareChips + shareHint
            statusGap += left * shareStatus / shares
            titleGap += left * shareStatus / shares
            chipsGap += left * shareChips / shares
            hintGap += left * shareHint / shares
        } else if left < 0 {
            // Not even the floor fits: the gaps give way, the one above the hint bar first, then the two round the title
            // together, then the one above the covers
            var over = -left
            func give(_ gap: Double) -> Double {
                let cut = min(over, gap)
                over -= cut
                return gap - cut
            }
            hintGap = give(hintGap)
            let pair = give(statusGap + titleGap) / 2
            statusGap = pair
            titleGap = pair
            chipsGap = give(chipsGap)
        }
        let titleTop = statusBottom + statusGap
        let infoTop = titleTop + title + titleGap
        let coverTop = infoTop + info + chipsGap + reach
        return HomeCompactLayout(
            coverScale: coverScale, titleTop: titleTop, titleBox: title, infoTop: infoTop, infoHeight: info, blockAbove: above,
            coverTop: coverTop, coverHeight: cover, ringReach: reach, statusBottom: statusBottom, hintTop: hintTop)
    }
}
