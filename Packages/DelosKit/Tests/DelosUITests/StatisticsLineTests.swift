import Foundation
import Testing
@testable import DelosMedia
@testable import DelosUI

@Suite struct StatisticsLineTests {
    /// Android's English `stream_stats_compact_tail`.
    private let tail = "Network %1$d ms  ·  Decode %2$@ ms  ·  Total %3$@ ms  ·  Lost %4$@ %%"

    private func statistics(
        shown: Double? = 59.6, network: Double? = 11.4, decode: Double? = 2.14, loss: Double? = 0.03, kib: Double = 2400
    ) -> StreamStatistics {
        StreamStatistics(
            width: 1920, height: 1080, codec: "HEVC", hdr: false, incomingFPS: 60, renderingFPS: shown, bandwidthKiBPerSecond: kib,
            lostFramesPercent: loss, networkMilliseconds: network, networkVarianceMilliseconds: 1, hostMinimumMilliseconds: nil,
            hostMaximumMilliseconds: nil, hostAverageMilliseconds: nil, presentationDelayMilliseconds: nil, videoPackets: 0,
            fecPackets: 0, decodeMilliseconds: decode)
    }

    @Test func theLineHasTheFramesTheBandwidthAndTheTailOfAndroidsPanel() {
        let line = StatisticsLine.text(statistics(), tail: tail)
        #expect(line == "60 FPS  ·  2.3 MB/s · 19.7 Mb/s  ·  Network 11 ms  ·  Decode 2.1 ms  ·  Lost 0.0 %")
    }

    @Test func aPartWithoutItsReadingIsLeftOutWithItsLabel() {
        let line = StatisticsLine.text(statistics(shown: nil, network: nil, decode: nil, loss: nil, kib: 800), tail: tail)
        #expect(line == "— FPS  ·  800 KB/s · 6.6 Mb/s")
        let noDecode = StatisticsLine.tailText(statistics(decode: nil), template: tail)
        #expect(noDecode == "Network 11 ms  ·  Lost 0.0 %")
    }

    @Test func theTotalIsNeverShownBecauseNeitherRendererReportsIt() {
        #expect(!StatisticsLine.text(statistics(), tail: tail).contains("Total"))
    }

    @Test func aLanguageThatReordersThePartsKeepsItsOrder() {
        let reordered = "Ztraceno %4$@ %%  ·  Celkem %3$@ ms  ·  Síť %1$d ms  ·  Dekódování %2$@ ms"
        #expect(StatisticsLine.tailText(statistics(), template: reordered) == "Ztraceno 0.0 %  ·  Síť 11 ms  ·  Dekódování 2.1 ms")
    }

    @Test func theCatalogsTailHasFourPartsSeparatedLikeAndroids() {
        #expect(L("stream_stats_compact_tail").components(separatedBy: StatisticsLine.separator).count == 4)
        #expect(!StatisticsLine.tailText(statistics(), template: L("stream_stats_compact_tail")).isEmpty)
    }

    @Test func aNarrowStageBreaksTheLineOnlyAfterASeparator() {
        let kept = StatisticsLine.keepingFiguresTogether("60 FPS  ·  Network 11 ms  ·  Lost 0.0 %")
        #expect(kept == "60\u{00A0}FPS\u{00A0}\u{00A0}·  Network\u{00A0}11\u{00A0}ms\u{00A0}\u{00A0}·  Lost\u{00A0}0.0\u{00A0}%")
    }
}
