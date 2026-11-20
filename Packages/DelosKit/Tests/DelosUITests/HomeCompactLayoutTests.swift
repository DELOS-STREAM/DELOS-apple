import Testing
@testable import DelosUI

/// Home on a compact stage (`HomeCompactLayoutTest` of DELOS for Android): the gaps hold on every compact stage, the
/// covers keep their ratio and a second game shows.
@Suite struct HomeCompactLayoutTests {
    private typealias C = HomeCompact
    /// The compact stages of the handhelds: Thor bottom, RG DDS top and bottom, Retroid Pocket Mini, a 1:1 panel, Pocket Micro.
    private let stages: [(Double, Double)] = [(1099, 957), (1488, 893), (1191, 893), (1108, 831), (1051, 1051), (1082, 722)]
    private let scales = [1.0, 1.15]

    private func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) <= tolerance }

    @Test func theBlocksFollowEachOtherFromTheStatusBarToTheHintBar() {
        for stage in stages { for scale in scales {
            let l = C.layout(stageWidth: stage.0, stageHeight: stage.1, scale: scale)
            #expect(close(l.statusBottom, C.statusBar * scale))
            #expect(close(l.hintTop, stage.1 - C.hintBar * scale))
            #expect(l.statusBottom <= l.titleTop && l.titleBottom <= l.infoTop && l.infoBottom <= l.coverTop && l.coverBottom <= l.hintTop)
            let used = l.statusGap + l.titleBox + l.titleGap + l.infoHeight + l.chipsGap + 2 * l.ringReach + l.coverHeight + l.hintGap
            #expect(close(l.hintTop - l.statusBottom, used, 0.05))
        } }
    }

    @Test func theGapsTheUserAskedFor() {
        for stage in stages { for scale in scales {
            let l = C.layout(stageWidth: stage.0, stageHeight: stage.1, scale: scale)
            #expect(l.statusGap >= 16 - 0.05)
            #expect(l.titleGap >= 16 - 0.05)
            #expect(close(l.statusGap, l.titleGap))
            #expect(l.chipsGap >= 24 - 0.05)
            #expect(l.hintGap >= 28 - 0.05)
            // The left-over room is not piled above the title
            #expect(l.chipsGap - 24 >= (l.statusGap - 16) * 4 - 0.05)
            #expect(l.hintGap - 28 >= (l.statusGap - 16) * 4 - 0.05)
            #expect(l.titleBox >= 64 * scale - 0.01 && l.titleBox <= 160.01)
        } }
    }

    @Test func theInfoRowIsAsTallAsTheBlockBesideTheBadgesOnEveryHandheldStage() {
        for stage in stages { for scale in scales {
            let l = C.layout(stageWidth: stage.0, stageHeight: stage.1, scale: scale)
            #expect(!l.blockAbove)
            #expect(close(l.infoHeight, 44 * scale))
        } }
    }

    @Test func onAVeryNarrowStageTheBlockStandsAboveTheBadgesAndStillFits() {
        #expect(close(C.besideWidth(1.15), 460 * 1.15 + 30 + 160))
        #expect(C.blockAbove(areaWidth: C.besideWidth(1) - 1, scale: 1))
        #expect(!C.blockAbove(areaWidth: C.besideWidth(1), scale: 1))
        for scale in scales {
            let narrow = C.layout(stageWidth: 2 * C.side + C.besideWidth(scale) - 1, stageHeight: 1080, scale: scale)
            let wide = C.layout(stageWidth: 2 * C.side + C.besideWidth(scale), stageHeight: 1080, scale: scale)
            #expect(narrow.blockAbove && !wide.blockAbove)
            #expect(close(narrow.infoHeight, C.infoHeight(scale: scale, above: true)))
            #expect(close(narrow.infoHeight, 44 * scale + C.blockAboveGap + C.chipRowHeight(scale)))
            #expect(narrow.statusGap >= 16 - 0.05 && narrow.chipsGap >= 24 - 0.05 && narrow.hintGap >= 28 - 0.05)
        }
        #expect(close(2 * C.side + C.besideWidth(1.15), 863))
    }

    @Test func theRingIsTheFocusedCoversGrowthAndItsRing() {
        #expect(close(C.ringReach(450), 12.375 + 10.55, 0.001))
        for stage in stages {
            let l = C.layout(stageWidth: stage.0, stageHeight: stage.1)
            #expect(close(l.ringReach, C.ringReach(l.coverHeight), 0.001))
        }
    }

    @Test func theCoverIsNeverNeedlesslyHugeAndNeverUnderTheFloor() {
        for stage in stages { for scale in scales {
            let l = C.layout(stageWidth: stage.0, stageHeight: stage.1, scale: scale)
            #expect(close(450 * l.coverScale, l.coverHeight))
            #expect(l.coverHeight <= stage.1 * 0.40 + 0.01)
            #expect(l.coverScale <= 1)
            let gapsFit = l.statusGap >= 16 - 0.05 && l.hintGap >= 28 - 0.05 && l.chipsGap >= 24 - 0.05
            #expect(l.coverScale >= C.floorScale - 0.0002 || (gapsFit && l.coverScale >= C.hardFloor))
        } }
    }

    @Test func aSecondGameIsAlwaysClearlyThere() {
        for stage in stages { for scale in scales {
            let s = C.layout(stageWidth: stage.0, stageHeight: stage.1, scale: scale).coverScale
            let tile = C.tile * s
            let shown = stage.0 - C.peekEdge - (C.side + C.wide * C.focusScale * s + C.coverGap(s) + tile + C.coverGap(s))
            #expect(shown >= tile / 3 - 0.5)
            #expect(C.rowStart(s) - C.wide * s * (C.focusScale - 1) - C.ring * C.focusScale >= 48)
        } }
    }

    @Test func aFocusedCoverKeepsItsRingOffItsNeighbour() {
        for s in [0.45, 0.5, 0.6, 0.7, 0.8, 1.0] {
            let reach = C.tile * s * (C.focusScale - 1) / 2 + C.ring * C.focusScale
            #expect(C.coverGap(s) >= 2 * reach + 8 - 0.001)
            #expect(C.coverGap(s) >= 44 * s)
        }
        // The rule's floor is the larger at every scale: 45.6 at 1, 37.35 at 0.5
        #expect(close(C.coverGap(1), 45.6, 0.01))
        #expect(close(C.coverGap(0.5), 37.35, 0.01))
    }

    @Test func theNumbersOfTheSixStages() {
        // The width-bound stages (1099, 1191, 1051 wide) give the covers' gaps the focus spacing rule's room
        let expected = [0.6404, 0.7665, 0.7028, 0.6359, 0.6079, 0.45]
        for (stage, scale) in zip(stages, expected) {
            #expect(close(C.layout(stageWidth: stage.0, stageHeight: stage.1).coverScale, scale, 0.0005))
        }
        let low = C.layout(stageWidth: 1082, stageHeight: 722)
        #expect(low.titleBox >= 64 - 0.1 && low.statusGap >= 16 - 0.1 && low.chipsGap >= 24 - 0.1 && low.hintGap >= 28 - 0.1)
        #expect(close(C.layout(stageWidth: 1488, stageHeight: 893, scale: 1.15).coverScale, 0.69, 0.0005))
        #expect(close(C.layout(stageWidth: 1108, stageHeight: 831, scale: 1.15).coverScale, 0.5595, 0.0005))
        for stage in stages where stage.1 > 800 { for scale in scales {
            #expect(close(C.layout(stageWidth: stage.0, stageHeight: stage.1, scale: scale).titleBox, 160))
        } }
    }

    @Test func aLargerInterfaceScaleGrowsTheBarsAndStillKeepsTheOrder() {
        for stage in stages { for scale in [1.1, 1.2, 1.3] {
            let l = C.layout(stageWidth: stage.0, stageHeight: stage.1, scale: scale)
            #expect(close(l.statusBottom, C.statusBar * scale))
            #expect(l.statusBottom <= l.titleTop + 0.05 && l.titleBottom <= l.infoTop && l.infoBottom <= l.coverTop - l.ringReach + 0.05)
            #expect(l.coverBottom + l.ringReach <= l.hintTop + 0.05)
            #expect(l.coverScale >= C.floorScale - 0.0002 || l.coverScale >= C.hardFloor)
        } }
    }

    @Test func theCutoutMovesTheBars() {
        let l = C.layout(stageWidth: 1099, stageHeight: 957, safeTop: 30, safeBottom: 20)
        #expect(l.statusBottom == 134)
        #expect(l.hintTop == 957 - 20 - 92)
        #expect(l.statusGap >= 16 && l.hintGap >= 28)
    }
}
