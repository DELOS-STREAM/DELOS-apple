import CoreGraphics
#if os(macOS)
import SwiftUI
#endif
import Testing
@testable import DelosUI

/// The focus spacing rule (docs/ENGINEERING_RULES.md, "Focus never touches the neighbour"): every gap between focusable
/// siblings is at least twice a focused one's reach and the clear space, with the ring geometry each group really draws.
@Suite struct FocusSpacingTests {
    /// The least gap by the rule, less a hair of floating-point noise (a gap may equal it exactly).
    private func gap(_ size: Double, scale: Double, outset: Double, ring: Double, scales: Bool, oneSided: Bool = false) -> Double {
        FocusSpacing.gap(reach: FocusSpacing.reach(size: size, scale: scale, outset: outset, ring: ring, ringScales: scales, oneSided: oneSided)) - 1e-9
    }

    private func least(_ reach: Double) -> Double { FocusSpacing.gap(reach: reach) - 1e-9 }

    @Test func theReachCountsTheGrowthTheBandAndTheRing() {
        // 520 px at 1.06 with a 4 px ring around the grown frame: 15.6 + 4
        #expect(abs(FocusSpacing.reach(size: 520, scale: 1.06, outset: 0, ring: 4, ringScales: false) - 19.6) < 1e-9)
        // A ring inside the scale grows with the element: (4 + 4) × 1.08
        #expect(abs(FocusSpacing.reach(size: 400, scale: 1.08, outset: 4, ring: 4, ringScales: true) - (16 + 8.64)) < 1e-9)
        // Growing from the far edge puts all the growth on one side
        #expect(abs(FocusSpacing.reach(size: 100, scale: 1.1, outset: 0, ring: 0, ringScales: false, oneSided: true) - 10) < 1e-9)
        #expect(FocusSpacing.gap(reach: 0) == FocusSpacing.clearance)
        #expect(abs(FocusSpacing.gap(reach: 19.6) - 47.2) < 1e-9)
    }

    @Test func theOverviewsRowsKeepTheirNeighboursClear() {
        let O = OverviewSpacing.self
        #expect(O.mediaGap >= gap(O.mediaWidth, scale: O.mediaScale, outset: 0, ring: O.ring, scales: false))
        // Similar games' covers are 260 px wide (`SimilarCover.width`)
        #expect(O.similarGap >= gap(260, scale: O.similarScale, outset: 0, ring: O.ring, scales: false))
        #expect(O.linkGap >= gap(O.linkMaxWidth, scale: O.linkScale, outset: 0, ring: O.ring, scales: false))
        // Play's sweep band and App settings' ring are inside the pill's scale
        #expect(O.buttonGap >= gap(O.playMaxWidth, scale: O.buttonScale, outset: O.playReachOut, ring: 0, scales: true))
        #expect(O.buttonGap >= gap(O.settingsMaxWidth, scale: O.buttonScale, outset: O.buttonRingOut, ring: 0, scales: true))
        // The summary's ring stands out the most above Read the story
        #expect(O.storyGap >= FocusSpacing.gap(reach: O.summaryPad + O.ring))
        #expect(O.storyGap >= gap(O.storyHeight, scale: O.storyScale, outset: 0, ring: O.ring, scales: false))
        // The carousel's step is one thumbnail and one gap
        #expect(O.mediaGap == 48 && O.similarGap == 32)
    }

    @Test func theDashboardsCoversKeepTheirNeighboursClear() {
        for s in stride(from: 0.3, through: 1.0, by: 0.05) {
            let reach = FocusSpacing.reach(size: HomeCompact.tile * s, scale: HomeCompact.focusScale, outset: HomeCompact.ring / 2,
                                           ring: HomeCompact.ring / 2, ringScales: true)
            #expect(HomeCompact.coverGap(s) >= FocusSpacing.gap(reach: reach) - 1e-9, "scale \(s)")
            #expect(CoverGeometry(scale: s, start: 0).gap == HomeCompact.coverGap(s))
        }
        #expect(abs(CoverGeometry.standard.gap - 45.6) < 0.001)
    }

    @Test func theArtworkGridKeepsItsNeighboursClearBothWays() {
        for tab in ArtworkTab.allCases {
            for width in [900.0, 1300.0, 1620.0] {
                let grid = ArtworkGrid(width: width, ratio: tab.ratio, columns: tab.columns)
                guard grid.columns > 1 else { continue }
                #expect(grid.gapX >= gap(grid.tileWidth, scale: ArtworkGrid.focusScale, outset: 4, ring: 4, scales: true) - 1e-6)
                #expect(grid.gapY >= gap(grid.tileHeight, scale: ArtworkGrid.focusScale, outset: 4, ring: 4, scales: true) - 1e-6)
            }
        }
    }

    @Test func pillsAndChipsKeepTheirNeighboursClear() {
        let F = FocusSpacing.self
        #expect(F.pillGap >= F.focusLookGap(size: F.pillMaxWidth, scale: F.pillScale, ring: F.pillRing) - 1e-9)
        #expect(F.pillLineGap >= F.focusLookGap(size: F.pillHeight, scale: F.pillScale, ring: F.pillRing) - 1e-9)
        #expect(GlideLook.pillGap >= least(GlideLook.pill.reach(width: GlideLook.pillMaxWidth)))
        #expect(GlideLook.chipGap >= least(GlideLook.chip.reach(width: GlideLook.chipMaxWidth)))
        #expect(LibraryFilterLayout.chipGap >= least(GlideLook.chip.reach(width: LibraryFilterLayout.chipMaxWidth)))
    }

    @Test func dialogsAndCardsKeepTheirNeighboursClear() {
        let F = FocusSpacing.self
        let pill = F.focusLookGap(size: F.pillHeight, scale: F.pillScale, ring: F.pillRing)
        #expect(DialogLayout.fieldGap >= F.focusLookGap(size: 84, scale: 1.05, ring: 4))
        #expect(DialogLayout.buttonsGap >= pill)
        #expect(StreamResultLayout.detailsGap >= pill)
        #expect(StreamResultLayout.detailsGap >= F.focusLookGap(size: 56, scale: 1.06, ring: 3))
        #expect(CenterColumnLayout.gap(40, min: F.pillLineGap, Stage(size: CGSize(width: 430, height: 172))) >= pill)
    }

    @Test func menusRowsAndBarsKeepTheirNeighboursClear() {
        // Plates whose ring is inside the row reach nowhere: the clear space alone
        #expect(ContextMenuLayout.rowGap >= FocusSpacing.gap(reach: 0))
        #expect(RowPopoverLayout.optionGap >= FocusSpacing.gap(reach: 0))
        #expect(StreamMenuLayout.rowGap >= FocusSpacing.gap(reach: 0))
        #expect(StreamMenuLayout.pillGap >= FocusSpacing.gap(reach: 0))
        #expect(StreamMenuLayout.popoverGapAfterHead >= gap(StreamMenuLayout.popoverHead, scale: 1.06, outset: 0, ring: 0, scales: false))
        // The settings rows lift by 2 % at the tallest
        #expect(SettingsLayout.rowGap >= gap(SettingsLayout.rowMaxHeight, scale: 1.02, outset: 0, ring: 0, scales: false))
        #expect(TabRowLayout.tvTabGap >= FocusSpacing.focusLookGap(size: TabRowLayout.tabMaxWidth, scale: TabRowLayout.tabScale, ring: TabRowLayout.tabRing) - 1e-9)
        // The top navigation's buttons lift by 12 % and have no ring
        #expect(StatusBarLayout.navGap >= gap(64, scale: 1.12, outset: 0, ring: 0, scales: false))
        // The dock's ring box stands 18 px around a tile
        #expect(StreamDockLayout.gap >= least((StreamDockLayout.ring - StreamDockLayout.tile) / 2))
        // The PC circles' gliding ring is around the grown circle
        #expect(CircleRowLayout.gap >= gap(220, scale: CircleRowLayout.focusScale, outset: CircleRowLayout.ringGap, ring: CircleRowLayout.ring, scales: false))
    }

    @Test func wrappedRowsKeepTheirRingsClearVertically() {
        let O = OverviewSpacing.self
        #expect(O.linkGap >= gap(O.linkHeight, scale: O.linkScale, outset: 0, ring: O.ring, scales: false))
        // Compact toolbar pills are 52 px high; filter chips are 44 px, or 56 px with library counts.
        #expect(GlideLook.pillGap >= least(GlideLook.pill.reach(width: 52)))
        #expect(GlideLook.chipGap >= least(GlideLook.chip.reach(width: 44)))
        #expect(LibraryFilterLayout.chipGap >= least(GlideLook.chip.reach(width: 56)))
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 430, height: 172)] {
            let L = LibraryFilterLayout.self
            let scale = Stage(size: size).compactScale
            let clearance = (L.sectionGap + L.headingHeight + L.headingGap) * scale + 2 * L.chipPadding
            #expect(clearance >= L.chipGap)
            #expect(clearance >= least(GlideLook.chip.reach(width: 56)))
        }
        // Tags and age badges are labels inside a focusable group, not independently growing controls.
        #expect(O.tagGap >= least(0))
        #expect(O.badgeGap >= least(0))
    }

    #if os(macOS)
    @MainActor @Test func wrappedLinkRowsKeepTheFullGroupGap() async throws {
        let focus = FocusModel()
        let host = ScreenHost(size: CGSize(width: 600, height: 500)) {
            WrapLayout(spacing: OverviewSpacing.linkGap) {
                ForEach(0..<2) { index in
                    FocusItem(id: index, model: focus, action: {}) { _ in
                        Color.clear.frame(width: 400, height: OverviewSpacing.linkHeight)
                    }
                }
            }
            .frame(width: 500, alignment: .leading)
        }
        let frames = await host.settle(focus, atLeast: 2)
        let first = try #require(frames[0])
        let second = try #require(frames[1])
        let clearance = second.minY - first.maxY
        #expect(abs(clearance - OverviewSpacing.linkGap) < 0.5)
        #expect(clearance >= gap(OverviewSpacing.linkHeight, scale: OverviewSpacing.linkScale, outset: 0, ring: OverviewSpacing.ring, scales: false))
    }
    #endif

    @Test func denseKeyGridsKeepTheClearSpace() {
        // No lift, the ring inside the key
        #expect(KeyboardMetrics.gap >= FocusSpacing.gap(reach: 0))
        #expect(LetterPicker.gap >= FocusSpacing.gap(reach: 0))
        #expect(LetterPicker.compactGap >= FocusSpacing.gap(reach: 0))
    }
}
