/// Ports the English texts of `LinkMonitorTest.kt`, `LinkRecommendationTest.kt`, `LinkResultTest.kt` and `ProbeScoreTest.kt` (DELOS for Android).
import DelosHost
import Foundation
import Testing
@testable import DelosUI

@MainActor
@Suite struct LinkVerdictTextTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let prague = TimeZone(identifier: "Europe/Prague")!
    private let min: Int64 = 60_000
    private var hour: Int64 { 60 * min }
    private var day: Int64 { 24 * hour }
    // 2026-11-07 12:00 UTC
    private let now: Int64 = 1_794_052_800_000

    private func sample(partial: Int64 = 0) -> LinkSample {
        LinkSample(seconds: 1, targetKbps: 225_000, totalFrames: 60, partialFrames: partial, lostFrames: 0, skippedFrames: 0, rxKbps: 28_000)
    }

    private func reading(_ count: Int, _ sample: LinkSample) throws -> LinkReading {
        let monitor = LinkMonitor()
        for _ in 0..<count { monitor.add(sample) }
        return try #require(monitor.reading())
    }

    private func age(_ nowMs: Int64, _ thenMs: Int64, _ zone: TimeZone) -> String { linkAgeText(nowMs: nowMs, thenMs: thenMs, zone: zone) }

    // MARK: LinkMonitorTest

    @Test func theReadingSaysWhetherTheLinkKeepsUp() throws {
        #expect(try reading(5, sample()).text == "Link keeps up at 225 Mbps")
        #expect(try reading(4, sample(partial: 6)).text == "Link drops frames at 225 Mbps, try 135 Mbps")
    }

    // MARK: LinkRecommendationTest

    @Test func theRecommendationLineNamesItsReason() {
        let drops = LinkReading(
            verdict: .dropping, targetKbps: 225_000, rxKbps: 180_000, partialPerSecond: 6, dropShare: 0.1, suggestedKbps: 135_000)
        #expect(recommend(staticKbps: 225_000).line == "Recommended: 225 Mbps · not tested on this link")
        #expect(recommend(staticKbps: 225_000, testedWireKbps: 340_000).line == "Recommended: 225 Mbps · link carries up to 340 Mbps")
        #expect(recommend(staticKbps: 225_000, testedWireKbps: 180_000).line == "Recommended: 180 Mbps · link carries 180 Mbps")
        #expect(recommend(staticKbps: 225_000, hostLinkKbps: 100_000).line == "Recommended: 100 Mbps · the PC's link is 100 Mbps")
        #expect(recommend(staticKbps: 225_000, testedWireKbps: 340_000, live: drops).line == "Recommended: 135 Mbps · drops frames at 225 Mbps")
        #expect(recommend(staticKbps: 225_000, testedWireKbps: 665_000).line == "Recommended: 225 Mbps · link carries up to 665 Mbps")
        let wanted = ordinaryWantedKbps(.hevc, defaultKbps: 20_000)
        #expect(recommend(staticKbps: wanted, testedWireKbps: 665_000, share: LinkPolicy.ordinaryBudgetShare, untestedKbps: 20_000).line
            == "Recommended: 40 Mbps · link carries up to 665 Mbps")
        #expect(recommend(staticKbps: ordinaryWantedKbps(.h264, defaultKbps: 20_000), testedWireKbps: 80_000, share: 0.65, untestedKbps: 20_000).line
            == "Recommended: 50 Mbps · link carries 80 Mbps")
    }

    // MARK: LinkResultTest

    @Test func recentResultsReadInMinutesAndHours() {
        #expect(age(now, now, utc) == "just now")
        #expect(age(now, now - 59_000, utc) == "just now")
        #expect(age(now, now - min, utc) == "1 min ago")
        #expect(age(now, now - 45 * min, utc) == "45 min ago")
        #expect(age(now, now - 3 * hour, utc) == "3 h ago")
    }

    @Test func olderResultsReadInCalendarDays() {
        #expect(age(now, now - 13 * hour, utc) == "yesterday")
        #expect(age(now, now - day, utc) == "yesterday")
        #expect(age(now, now - 2 * day, utc) == "2 days ago")
        #expect(age(now, now - 6 * day, utc) == "6 days ago")
        #expect(age(now, now - 7 * day, utc) == "1 week ago")
        #expect(age(now, now - 15 * day, utc) == "2 weeks ago")
        #expect(age(now, now - 30 * day, utc) == "1 month ago")
        #expect(age(now, now - 100 * day, utc) == "3 months ago")
    }

    @Test func daysAreCountedByTheLocalCalendarNotBy24HourSpans() {
        // 23:30 local the evening before is "yesterday" at 00:10 local, although only 40 minutes passed
        let midnightPrague: Int64 = 1_794_092_400_000 // 2026-11-08 00:00 CET
        #expect(age(midnightPrague + 10 * min, midnightPrague - 30 * min, prague) == "yesterday")
        #expect(age(midnightPrague + 10 * min, midnightPrague - 30 * min, utc) == "40 min ago")
    }

    @Test func aTimestampInTheFutureReadsJustNow() {
        #expect(age(now, now + 5 * day, utc) == "just now")
    }

    @Test func theSummaryNamesTheAgeAndTheNetwork() {
        var test = LinkTest(wireKbps: 340_000, testedAtMs: now - day, transport: .wifi, criticalFECPercent: 50, packetSize: 1392)
        #expect(test.summary(nowMs: now, zone: utc) == "Tested yesterday on Wi-Fi")
        test.testedAtMs = now - 2 * hour
        test.transport = .ethernet
        #expect(test.summary(nowMs: now, zone: utc) == "Tested 2 h ago on Ethernet")
    }

    // MARK: ProbeScoreTest / ProbeVerdictTextTest

    private func failed(_ kbps: Int, _ failure: ProbeFailure?, loss: Double = 0, window: Double = 0, rcvBuf: Int = 0, stall: Double = 0, p99: Double = 0) -> ProbeScore {
        ProbeScore(
            requestedKbps: kbps, expected: 1000, sent: 1000, received: 900, senderMs: 2000, lossPercent: loss,
            worstWindowLossPercent: window, delayP99Ms: p99, delayGrowthMs: 0, failure: failure, receiveBufferBytes: rcvBuf, maxStallMs: stall)
    }

    @Test func aPassingProbeIsStableWithOrWithoutJitter() {
        #expect(failed(400_000, nil, p99: 6).verdictText == "Stable, a little jitter")
        #expect(failed(400_000, nil).verdictText == "Stable")
    }

    /// L() formats numbers for the current locale (the English text gets "3,0" on a Czech Mac), as the app does.
    private func d(_ value: Double) -> String { String(format: "%.1f", locale: .current, value) }

    @Test func theReasonNamesTheRealCauseAndTheRate() {
        #expect(failed(450_000, .loss, loss: 3.0).reasonText == "Lost \(d(3.0))% of the test packets at 450 Mbps")
        #expect(failed(450_000, .windowLoss, window: 7.5).reasonText == "Lost up to \(d(7.5))% of the packets within 100 ms at 450 Mbps")
        #expect(failed(225_000, .delayGrowth).reasonText == "The delay kept growing at 225 Mbps (the link queues up)")
        #expect(failed(5_000, .noPackets).reasonText == "No test data arrived. UDP may be blocked on this network")
        let notSent = ProbeScore(
            requestedKbps: 500_000, expected: 1000, sent: 900, received: 900, senderMs: 2000, lossPercent: 10,
            worstWindowLossPercent: 0, delayP99Ms: 0, delayGrowthMs: 0, failure: .notAllSent)
        #expect(notSent.reasonText == "The PC sent only \(d(90.0))% of the test data at 500 Mbps")
    }

    @Test func aLossOurOwnReceiverMayHaveCausedIsSaidSo() {
        #expect(failed(450_000, .loss, loss: 3.0, rcvBuf: 212_992).reasonText == "This device could not receive 450 Mbps that fast")
        #expect(failed(450_000, .windowLoss, window: 9.0, rcvBuf: 8 * 1024 * 1024, stall: 12.0).reasonText
            == "This device could not receive 450 Mbps that fast")
    }

    @Test func noRateSaysWhatFailedAndWhetherAnythingPassed() {
        let last = failed(5_000, .loss, loss: 4.0)
        #expect(linkNoRateText(last: last, bestPassKbps: 0) == "Lost \(d(4.0))% of the test packets at 5 Mbps. Nothing passed, down to 5 Mbps.")
        #expect(linkNoRateText(last: last, bestPassKbps: 300_000) == "Lost \(d(4.0))% of the test packets at 5 Mbps. 300 Mbps passed once but did not hold.")
        #expect(linkNoRateText(last: nil, bestPassKbps: 0) == "No rate could be tested.")
    }
}
