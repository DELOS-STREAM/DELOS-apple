import Testing
@testable import DelosUI

@Suite struct HintBarLayoutTests {
    @Test func theHintBarSitsMidwayBetweenTheContentAndTheBottomEdge() {
        // 1080 px stage: the home's row ends 87 px above the bottom (ring included): the bar's middle is 43.5 px up
        let bottom = HintBarLayout.rowBottom(scale: 1, safeTop: 0, stageHeight: 1080)
        #expect(abs((1080 - bottom) - 87) < 1)
        let center = HintBarLayout.centerFromBottom(stageHeight: 1080, safeBottom: 0, contentBottom: bottom)
        #expect(abs(center - (1080 - bottom) / 2) < 0.001)
        // Another stage height keeps the same distance (the row is anchored to the bottom)
        let tall = HintBarLayout.rowBottom(scale: 1, safeTop: 0, stageHeight: 1200)
        #expect(abs(HintBarLayout.centerFromBottom(stageHeight: 1200, safeBottom: 0, contentBottom: tall) - center) < 0.001)
        // Screens without the row use the same line
        #expect(abs(HintBarLayout.centerFromBottom(stageHeight: 1200, safeBottom: 0, contentBottom: nil) - center) < 0.001)
        // The glyph never dips under the safe edge (the iPad's home indicator)
        #expect(HintBarLayout.centerFromBottom(stageHeight: 1080, safeBottom: 60, contentBottom: bottom) == 60 + 19)
        // A bigger interface scale lifts the row, and the bar goes with it
        let zoomed = HintBarLayout.rowBottom(scale: 1.2, safeTop: 0, stageHeight: 1080)
        #expect(zoomed < bottom)
        #expect(HintBarLayout.centerFromBottom(stageHeight: 1080, safeBottom: 0, contentBottom: zoomed) > center)
    }
}
