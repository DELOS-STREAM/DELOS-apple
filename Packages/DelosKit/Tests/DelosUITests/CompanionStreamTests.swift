import Foundation
import Testing
@testable import DelosMedia
@testable import DelosUI

@Suite struct CompanionStreamTests {
    /// Ten fit pixels a character, on one line until the width is used up.
    private struct Monospace: CompanionTextMetrics {
        func lines(_ text: String, width: Double, kind: FitText) -> Int {
            text.isEmpty ? 0 : Int((Double(text.count) * 10 / max(width, 1)).rounded(.up))
        }

        func width(_ text: String, kind: FitText) -> Double { Double(text.count) * 10 }
    }

    private func statistics(rendering: Double? = 59.64, network: Double? = 11.4, decode: Double? = 2.14, hdr: Bool = false) -> StreamStatistics {
        StreamStatistics(
            width: 1920, height: 1080, codec: "HEVC", hdr: hdr, incomingFPS: 60, renderingFPS: rendering, bandwidthKiBPerSecond: 2400,
            lostFramesPercent: nil, networkMilliseconds: network, networkVarianceMilliseconds: nil, hostMinimumMilliseconds: nil,
            hostMaximumMilliseconds: nil, hostAverageMilliseconds: nil, presentationDelayMilliseconds: nil, videoPackets: 0, fecPackets: 0,
            decodeMilliseconds: decode)
    }

    // MARK: Readout

    @Test func noStatisticsYetShowsDashes() {
        #expect(CompanionStatsReadout.of(nil) == .empty)
        #expect(CompanionStatsReadout.empty.picture == nil)
    }

    @Test func theReadoutFormatsLikeAndroid() {
        let readout = CompanionStatsReadout.of(statistics(hdr: true))
        #expect(readout.fps == "59.6")
        #expect(readout.network == "11 ms")
        #expect(readout.decode == "2.1 ms")
        #expect(readout.bandwidth == "19.7 Mb/s")
        #expect(readout.picture == "1920 \u{00D7} 1080 \u{00B7} 60 FPS \u{00B7} HEVC HDR")
    }

    @Test func missingReadingsFallBack() {
        let readout = CompanionStatsReadout.of(statistics(rendering: nil, network: nil, decode: nil))
        #expect(readout.fps == "60.0")
        #expect(readout.network == CompanionStatsReadout.dash)
        #expect(readout.decode == CompanionStatsReadout.dash)
    }

    // MARK: Tiles

    @Test func theDangerTilesShareTheLastRow() {
        #expect(CompanionTileLayout.rows(BarItem.allCases) == [[.resume, .keyboard, .overlay], [.brightness], [.more, .disconnect, .quit]])
        #expect(CompanionTileLayout.rows([.resume, .overlay, .more, .disconnect, .quit]) == [[.resume, .overlay], [.more, .disconnect, .quit]])
    }

    @Test func aShortTileIsFlat() {
        #expect(CompanionTileLayout.flat(height: 120))
        #expect(!CompanionTileLayout.flat(height: 140))
        #expect(CompanionTileLayout.showsState(height: 90))
        #expect(!CompanionTileLayout.showsState(height: 70))
        #expect(CompanionTileLayout.showsState(height: 200))
    }

    // MARK: Paging

    @Test func everythingFitsWithoutAPager() {
        let plan = CompanionGridPaging.plan(height: 300, rowHeight: 64, gap: 8, columns: 3, count: 9)
        #expect(plan == CompanionGridPlan(rows: 3, perPage: 9, pages: 1, pager: false))
    }

    @Test func aLongListPagesAndThePagerTakesARow() {
        let plan = CompanionGridPaging.plan(height: 300, rowHeight: 64, gap: 8, columns: 2, count: 20)
        // Four rows fit 300; the pager takes one, three rows of two are a page
        #expect(plan == CompanionGridPlan(rows: 3, perPage: 6, pages: 4, pager: true))
        #expect(CompanionGridPaging.range(page: 3, plan: plan, count: 20) == 18..<20)
        #expect(CompanionGridPaging.range(page: 9, plan: plan, count: 20) == 18..<20)
    }

    @Test func aPageAlwaysHasARow() {
        let plan = CompanionGridPaging.plan(height: 100, rowHeight: 64, gap: 8, columns: 2, count: 5)
        #expect(plan.rows == 1)
        #expect(plan.pages == 3)
    }

    @Test func columnsShrinkForLongLabels() {
        #expect(CompanionGridPaging.columns(labelWidths: [100], width: 900, gap: 8, chrome: 48, max: 3) == 3)
        #expect(CompanionGridPaging.columns(labelWidths: [300], width: 900, gap: 8, chrome: 48, max: 3) == 2)
        #expect(CompanionGridPaging.columns(labelWidths: [600], width: 900, gap: 8, chrome: 48, max: 3) == 1)
    }

    // MARK: Keyboard

    @Test func aWidePanelHasTheQwertyRows() {
        #expect(CompanionKeyRows.columns(width: 1824) == 10)
        let rows = CompanionKeyRows.rows(symbols: false, columns: 10)
        #expect(rows.count == 5)
        #expect(rows[1] == "qwertyuiop".map { CompanionKeyCell.char($0) })
        #expect(rows[0].last == .action(.backspace, weight: 1.6))
    }

    @Test func aNarrowPanelHasRowsOfEightAndKeysStayAThumbWide() {
        #expect(CompanionKeyRows.columns(width: 800) == 8)
        let rows = CompanionKeyRows.rows(symbols: false, columns: 8)
        #expect(rows.dropLast(2).allSatisfy { $0.count <= 8 })
        #expect(rows.flatMap { $0 }.contains(.action(.enter, weight: 4)))
    }

    @Test func everyLetterIsOnTheSymbolsAndLetterPages() {
        let letters = CompanionKeyRows.rows(symbols: false, columns: 10).flatMap { $0 }.compactMap { cell -> Character? in
            if case .char(let c, _) = cell { return c }
            return nil
        }
        #expect(Set("abcdefghijklmnopqrstuvwxyz").isSubset(of: Set(letters)))
    }

    // MARK: Echo

    @Test func theEchoShowsTheHintTheTextOrTheCount() {
        let metrics = Monospace()
        let count: (Int) -> String = { "\($0) chars" }
        #expect(CompanionEcho.view("", hint: "Tap the keys", hintShort: "Tap", width: 200, metrics: metrics, count: count)
            == CompanionEcho(text: "Tap the keys", placeholder: true))
        #expect(CompanionEcho.view("", hint: "Tap the keys", hintShort: "Tap", width: 50, metrics: metrics, count: count)
            == CompanionEcho(text: "Tap", placeholder: true))
        #expect(CompanionEcho.view("", hint: "Tap the keys", hintShort: "Tap", width: 10, metrics: metrics, count: count).text.isEmpty)
        #expect(CompanionEcho.view("hello", hint: "h", hintShort: "h", width: 200, metrics: metrics, count: count)
            == CompanionEcho(text: "hello", placeholder: false))
        #expect(CompanionEcho.view(String(repeating: "x", count: 30), hint: "h", hintShort: "h", width: 200, metrics: metrics, count: count)
            == CompanionEcho(text: "30 chars", placeholder: false))
    }

    @Test func typedEchoKeepsTheLastCharactersAndMarksReturn() {
        var echo = TypedEcho()
        for c in String(repeating: "a", count: 45) { echo = echo.typed(c) }
        #expect(echo.value.count == TypedEcho.max)
        echo = echo.cleared().typed("h").typed("i").enter()
        #expect(echo.value == "hi\u{21B5}")
        #expect(echo.backspace().value == "hi")
    }
}
