/// Ports `LinkSearchTest.kt` (LinkSearchTest and LinkSearchLowerLimitTest, DELOS for Android).
import Testing
@testable import DelosHost

private func score(_ kbps: Int, _ ok: Bool) -> ProbeScore {
    ProbeScore(
        requestedKbps: kbps, expected: 1000, sent: 1000, received: ok ? 1000 : 900, senderMs: 2000, lossPercent: ok ? 0 : 10,
        worstWindowLossPercent: 0, delayP99Ms: 0, delayGrowthMs: 0, failure: ok ? nil : .loss)
}

/// Records every probe's rate; the path carries [capacity] and fails above it.
private final class Path {
    var seen: [Int] = []
    let capacity: Int
    let flaky: (Int, Int) -> Bool

    init(_ capacity: Int, flaky: @escaping (Int, Int) -> Bool = { _, _ in false }) {
        self.capacity = capacity
        self.flaky = flaky
    }

    func probe(_ kbps: Int) -> ProbeScore {
        seen.append(kbps)
        return score(kbps, kbps <= capacity && !flaky(kbps, seen.count { $0 == kbps }))
    }
}

private func search(_ start: Int, _ cap: Int, _ path: Path, cancelled: () -> Bool = { false }) async throws -> LinkSearchResult {
    try await searchLink(startKbps: start, capKbps: cap, probe: { path.probe($0) }, cancelled: cancelled)
}

private func confirmed(_ result: LinkSearchResult) -> (wireKbps: Int, score: ProbeScore)? {
    if case .confirmed(let wire, let score) = result { (wire, score) } else { nil }
}

private func noRate(_ result: LinkSearchResult) -> (last: ProbeScore?, bestPassKbps: Int)? {
    if case .noRate(let last, let best) = result { (last, best) } else { nil }
}

@Suite struct LinkSearchTests {
    @Test func growsByAQuarterThenBisectsThenConfirmsFivePercentBelowTwice() async throws {
        let path = Path(300_000)
        let result = try await search(100_000, 3_000_000, path)
        #expect(path.seen == [
            100_000, 125_000, 155_000, 190_000, 235_000, 290_000, 360_000, // grow x1.25, rounded down to 5 Mbps, until 360 fails
            325_000, 305_000, 295_000, 300_000,                            // bisect the 290..360 bracket down to 5 Mbps
            285_000, 285_000,                                              // 95 % of 300, twice afresh
        ])
        let found = try #require(confirmed(result))
        #expect(found.wireKbps == 285_000)
        #expect(found.score.passed)
    }

    @Test func aFailedConfirmationLowersTheRateByTwentyPercentAndTestsAgain() async throws {
        // 95 Mbps fails its second confirmation run, so a lucky pass is not inherited
        let path = Path(1_000_000) { kbps, count in kbps == 95_000 && count == 2 }
        let result = try await search(100_000, 100_000, path)
        #expect(path.seen == [100_000, 95_000, 95_000, 75_000, 75_000])
        #expect(confirmed(result)?.wireKbps == 75_000)
    }

    @Test func theStartIsRoundedAndBoundedByTheCap() async throws {
        let seen = Path(10_000)
        _ = try await search(12_345, 3_000_000, seen)
        #expect(seen.seen.first == 10_000)
        let high = Path(1_000_000)
        _ = try await search(900_000, 250_000, high)
        #expect(high.seen.first == 250_000)
        let low = Path(1_000_000)
        _ = try await search(1_000, 250_000, low)
        #expect(low.seen.first == 5_000)
    }

    @Test func aFailingStartBisectsDownToFiveMbpsAndGivesNoRate() async throws {
        let path = Path(0)
        let result = try await search(100_000, 3_000_000, path)
        #expect(path.seen == [100_000, 50_000, 25_000, 10_000, 5_000])
        #expect(noRate(result)?.last?.failure == .loss)
    }

    @Test func aFailingStartThatPassesLowerFindsTheBracket() async throws {
        let path = Path(60_000)
        let result = try await search(200_000, 3_000_000, path)
        // 200 fails, 100 fails, 50 passes, then the 50..100 bracket is bisected to 5 Mbps and confirmed at 95 % of 60
        #expect(Array(path.seen.prefix(8)) == [200_000, 100_000, 50_000, 75_000, 60_000, 65_000, 55_000, 55_000])
        #expect(confirmed(result)?.wireKbps == 55_000)
    }

    @Test func theCapEndsTheGrowthAtTheCap() async throws {
        let path = Path(10_000_000)
        let result = try await search(100_000, 130_000, path)
        #expect(path.seen == [100_000, 125_000, 130_000, 120_000, 120_000])
        #expect(confirmed(result)?.wireKbps == 120_000)
    }

    @Test func aCapBelowTheMinimumHasNothingToTest() async throws {
        let path = Path(1_000_000)
        #expect(try await search(100_000, 4_000, path) == .noRate(last: nil, bestPassKbps: 0))
        #expect(path.seen.isEmpty)
    }

    @Test func persistentFailureAfterAPassEndsWithoutARate() async throws {
        // Passes while searching, then every confirmation fails: the rate steps down to the 5 Mbps floor and stops
        var calls = 0
        let result = try await searchLink(startKbps: 100_000, capKbps: 100_000, probe: { kbps in
            calls += 1
            return score(kbps, calls == 1)
        }, cancelled: { false })
        let none = try #require(noRate(result))
        #expect(none.last?.failure == .loss)
        // The rate that passed once is reported, so the message is not a bare "unstable"
        #expect(none.bestPassKbps == 100_000)
    }

    @Test func cancellingBetweenProbesDiscardsEverything() async throws {
        let path = Path(300_000)
        let result = try await search(100_000, 3_000_000, path, cancelled: { path.seen.count >= 3 })
        #expect(result == .cancelled)
        #expect(path.seen.count == 3)
        let atConfirm = Path(1_000_000)
        let inConfirm = try await search(100_000, 100_000, atConfirm, cancelled: { atConfirm.seen.count >= 2 })
        #expect(inConfirm == .cancelled)
    }

    @Test func aProbeFailureEndsTheSearch() async {
        await #expect(throws: LinkTestError(.network, "down")) {
            try await searchLink(startKbps: 100_000, capKbps: 3_000_000, probe: { _ in throw LinkTestError(.network, "down") })
        }
    }

    @Test func progressNamesTheRateAndWhetherItConfirms() async throws {
        var steps: [LinkStep] = []
        let path = Path(1_000_000)
        _ = try await searchLink(startKbps: 100_000, capKbps: 100_000, probe: { path.probe($0) }, cancelled: { false },
                                 onStep: { steps.append($0) })
        #expect(steps == [
            LinkStep(kbps: 100_000, confirming: false, probe: 1),
            LinkStep(kbps: 95_000, confirming: true, probe: 2),
            LinkStep(kbps: 95_000, confirming: true, probe: 3),
        ])
    }
}

@Suite struct LinkSearchLowerLimitTests {
    @Test func aStartThatFailsButALowerRatePassesIsAResultNotAnError() async throws {
        // The user's case: the 225 Mbps start fails, the link carries about 160: the search reports that rate
        let result = try await searchLink(startKbps: 225_000, capKbps: 3_000_000, probe: { score($0, $0 <= 160_000) }, cancelled: { false })
        #expect(confirmed(result)?.wireKbps == 150_000)
    }

    @Test func aPassingProbeWithOnlyJitterIsAPassingProbe() async throws {
        let result = try await searchLink(startKbps: 225_000, capKbps: 225_000, probe: { kbps in
            var jittery = score(kbps, true)
            jittery.delayP99Ms = 9
            return jittery
        }, cancelled: { false })
        let found = try #require(confirmed(result))
        #expect(found.score.jitterWarning)
        #expect(found.wireKbps == 210_000)
    }
}
