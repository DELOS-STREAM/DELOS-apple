/// Ports `ProbeScoreTest.kt` (ProbeScoreTest and the text-free parts of ProbeVerdictTextTest, DELOS for Android).
import Testing
@testable import DelosHost

@Suite struct ProbeScoreTests {
    private let expected = 20_000

    /// Every packet arrives in its sender slot plus a constant transit (the clocks' offset is irrelevant).
    private func perfect(transitMs: Double = 5, extra: (Int) -> Double = { _ in 0 }) -> [Int64] {
        (0..<expected).map { seq in
            let tick = ((Int64(seq) + 1) * 2000 + Int64(expected) - 1) / Int64(expected) - 1
            return Int64((Double(tick) + transitMs + extra(seq)) * 1000)
        }
    }

    private func score(_ arrivals: [Int64], sent: Int? = nil, senderMs: Double = 2000) -> ProbeScore {
        scoreProbe(requestedKbps: 400_000, expected: expected, sent: sent ?? expected, senderMs: senderMs, arrivalsUs: arrivals)
    }

    private func dropping(_ indices: some Sequence<Int>) -> [Int64] {
        var arrivals = perfect()
        for i in indices { arrivals[i] = -1 }
        return arrivals
    }

    @Test func plannedPacketsFollowTheHostsFormula() {
        #expect(expectedProbePackets(kbps: 250_000, packetSize: 1392) == 40956)
        #expect(expectedProbePackets(kbps: 40_000, packetSize: 1392) == 6553)
        // The packet size changes the wire charge: packetsize + 134 bytes
        #expect(expectedProbePackets(kbps: 1_000_000, packetSize: 256) == 1_000_000 * 2000 / (8 * (256 + 134)))
    }

    @Test func aCleanProbePasses() {
        let result = score(perfect())
        #expect(result.failure == nil)
        #expect(result.passed)
        #expect(result.received == expected)
        #expect(result.lossPercent == 0)
        #expect(abs(result.delayP99Ms) <= 1e-9)
        #expect(abs(result.delayGrowthMs) <= 1e-9)
    }

    @Test func aggregateLossBelowTwoPercentPassesAndTwoPercentFails() {
        // The reference client's limit: lossPercent < 2.0
        let below = dropping((0..<380).map { $0 * 52 })
        #expect(abs(score(below).lossPercent - 1.9) <= 1e-9)
        #expect(score(below).failure == nil)
        let limit = dropping((0..<400).map { $0 * 50 })
        #expect(abs(score(limit).lossPercent - 2.0) <= 1e-9)
        #expect(score(limit).failure == .loss)
    }

    @Test func oneBadWindowFailsAtFivePercentEvenWhenTheAggregateIsFine() {
        // Window 7 holds sequences 7000..7999: 50 of 1000 lost is 5 % there but 0.25 % overall
        let result = score(dropping((0..<50).map { 7000 + $0 * 20 }))
        #expect(abs(result.lossPercent - 0.25) <= 1e-9)
        #expect(abs(result.worstWindowLossPercent - 5.0) <= 1e-9)
        #expect(result.failure == .windowLoss)
        #expect(score(dropping((0..<49).map { 7000 + $0 * 20 })).failure == nil)
    }

    @Test func transitVariationIsOnlyAWarning() {
        // 2 % of the packets arrive 6 ms late: p99 sits in them, the probe still passes
        let result = score(perfect { $0 % 50 == 0 ? 6 : 0 })
        #expect(abs(result.delayP99Ms - 6.0) <= 1e-9)
        #expect(result.failure == nil)
        #expect(result.passed)
        #expect(result.jitterWarning)
        // 4 ms exactly and a clean probe carry no warning
        #expect(!score(perfect { $0 % 50 == 0 ? 4 : 0 }).jitterWarning)
        #expect(!score(perfect()).jitterWarning)
    }

    @Test func aGrowingQueueFailsOnDelayGrowth() {
        // Transit grows from 0 to 3 ms over the two seconds: p99 3 ms passes, the last window is ~2.85 ms above the first
        let result = score(perfect { 3.0 * Double($0) / Double(expected) })
        #expect(result.delayP99Ms <= LinkPolicy.jitterWarningP99Ms)
        #expect(result.delayGrowthMs > LinkPolicy.maxDelayGrowthMs)
        #expect(result.failure == .delayGrowth)
        // 1.5 ms of growth is fine
        #expect(score(perfect { 1.5 * Double($0) / Double(expected) }).failure == nil)
    }

    @Test func theHostsOwnNumbersGradeTheProbeToo() {
        // 98 % of the planned packets must have been sent; unsent ones are not in the arrivals either, so loss counts them
        #expect(score(perfect(), sent: expected - 1).failure == nil)
        #expect(score(perfect(), sent: expected * 98 / 100).failure == nil)
        #expect(score(perfect(), sent: expected * 97 / 100).failure == .notAllSent)
        #expect(score(perfect(), sent: expected + 1).failure == .notAllSent)
        #expect(score([Int64](repeating: -1, count: expected)).failure == .noPackets)
        #expect(score(perfect(), senderMs: 2041).failure == .senderDuration)
        #expect(score(perfect(), senderMs: 1959).failure == .senderDuration)
        #expect(score(perfect(), senderMs: 2039).failure == nil)
        #expect(score(perfect(), senderMs: .nan).failure == .senderDuration)
    }

    @Test func anEmptyWindowCannotPassBecauseDelayGrowthIsUnknown() {
        // A whole window is lost: loss fails first, but growth is infinite as well
        let result = score(dropping(19_000..<expected))
        #expect(result.delayGrowthMs == .infinity)
        #expect(result.failure == .loss)
    }

    @Test func clockOffsetDoesNotMatter() {
        #expect(score(perfect()) == score(perfect().map { $0 + 987_654_321 }))
    }
}

@Suite struct ProbeScoreReceiverSuspectTests {
    private func failed(_ kbps: Int, _ failure: ProbeFailure, loss: Double = 0, window: Double = 0, rcvBuf: Int = 0, stall: Double = 0) -> ProbeScore {
        ProbeScore(
            requestedKbps: kbps, expected: 1000, sent: 1000, received: 900, senderMs: 2000, lossPercent: loss,
            worstWindowLossPercent: window, delayP99Ms: 0, delayGrowthMs: 0, failure: failure, receiveBufferBytes: rcvBuf, maxStallMs: stall)
    }

    @Test func aLossOurOwnReceiverMayHaveCausedIsSaidSo() {
        #expect(failed(450_000, .loss, loss: 3.0, rcvBuf: 212_992).receiverSuspect)
        #expect(failed(450_000, .windowLoss, window: 9.0, rcvBuf: 8 * 1024 * 1024, stall: 12.0).receiverSuspect)
        // A big buffer and a quick loop: the loss is the network's
        #expect(!failed(450_000, .loss, loss: 3.0, rcvBuf: 8 * 1024 * 1024, stall: 0.2).receiverSuspect)
        // Unknown buffer size is not a suspicion by itself
        #expect(!failed(450_000, .loss, loss: 3.0).receiverSuspect)
    }
}
