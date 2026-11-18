/// What the search is doing now, for the progress line (LinkSearch.kt).
public struct LinkStep: Equatable, Sendable {
    public var kbps: Int
    public var confirming: Bool
    public var probe: Int

    public init(kbps: Int, confirming: Bool, probe: Int) {
        self.kbps = kbps
        self.confirming = confirming
        self.probe = probe
    }
}

public enum LinkSearchResult: Equatable, Sendable {
    /// [wireKbps] passed twice afresh (with the 5 % margin applied); [score] is the last of those probes.
    case confirmed(wireKbps: Int, score: ProbeScore)
    /// No rate held: [last] is the final probe, [bestPassKbps] the highest rate that passed once but failed its
    /// confirmation (0 = none passed).
    case noRate(last: ProbeScore?, bestPassKbps: Int)
    case cancelled
}

private func roundDown(_ kbps: Double) -> Int { Int(kbps / Double(LinkPolicy.stepKbps)) * LinkPolicy.stepKbps }

/// The host document's calibration, over [probe]. It starts at [startKbps] (the selected bitrate, within 5 Mbps and
/// [capKbps]), grows by 25 % while probes pass, then bisects the passing/failing bracket down to 5 Mbps. The best pass
/// is reduced by 5 % and measured twice afresh; a failed confirmation lowers the rate by 20 % and tries again, so a noisy
/// path can never inherit an earlier lucky pass. A start that already fails bisects downwards. [probe] may throw (a
/// network failure), which ends the search. [cancelled] is asked between probes; a cancelled search discards everything.
public func searchLink(
    startKbps: Int,
    capKbps: Int,
    isolation: isolated (any Actor)? = #isolation,
    probe: (Int) async throws -> ProbeScore,
    cancelled: () -> Bool = { Task.isCancelled },
    onStep: (LinkStep) -> Void = { _ in }
) async throws -> LinkSearchResult {
    let step = LinkPolicy.stepKbps
    let cap = min(LinkPolicy.maxKbps, capKbps / step * step)
    guard cap >= LinkPolicy.minKbps else { return .noRate(last: nil, bestPassKbps: 0) }
    var probes = 0
    func measure(_ kbps: Int, confirming: Bool) async throws -> ProbeScore {
        probes += 1
        onStep(LinkStep(kbps: kbps, confirming: confirming, probe: probes))
        return try await probe(kbps)
    }

    var low = 0
    var high = cap + step
    var next = min(max(startKbps / step * step, LinkPolicy.minKbps), cap)
    var best: ProbeScore?
    for _ in 0..<LinkPolicy.maxSearchProbes {
        if cancelled() { return .cancelled }
        let score = try await measure(next, confirming: false)
        if cancelled() { return .cancelled }
        best = score
        if score.passed {
            low = next
            if low == cap || high - low <= step { break }
            next = high <= cap
                ? roundDown(Double(low + high) / 2)
                : min(cap, max(low + step, roundDown(Double(low) * LinkPolicy.growthFactor)))
        } else {
            high = next
            if high - low <= step { break }
            next = max(LinkPolicy.minKbps, roundDown(Double(low + high) / 2))
        }
    }
    if low == 0 { return .noRate(last: best, bestPassKbps: 0) }

    next = max(LinkPolicy.minKbps, roundDown(Double(low) * LinkPolicy.confirmMargin))
    for _ in 0..<LinkPolicy.maxConfirmAttempts {
        var confirmed = true
        var last: ProbeScore?
        for _ in 0..<LinkPolicy.confirmRuns {
            if cancelled() { return .cancelled }
            let score = try await measure(next, confirming: true)
            if cancelled() { return .cancelled }
            best = score
            last = score
            if !score.passed { confirmed = false; break }
        }
        if confirmed, let last { return .confirmed(wireKbps: next, score: last) }
        if next == LinkPolicy.minKbps { break }
        next = max(LinkPolicy.minKbps, roundDown(Double(next) * LinkPolicy.confirmBackoff))
    }
    return .noRate(last: best, bestPassKbps: low)
}
