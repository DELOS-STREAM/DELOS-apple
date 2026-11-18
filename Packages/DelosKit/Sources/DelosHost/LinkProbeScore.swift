/// Why a probe did not pass, in the order the reference client checks them (ProbeScore.kt).
public enum ProbeFailure: Equatable, Sendable {
    /// The host sent fewer than 98 % of the planned packets (it is overloaded, or its send buffer overflowed).
    case notAllSent
    /// Nothing authenticated arrived (blocked UDP, wrong network, firewall).
    case noPackets
    /// The host's sending took more than 2 % longer or shorter than the requested two seconds.
    case senderDuration
    case loss
    case windowLoss
    case delayGrowth
}

/// What one probe measured, graded against ``LinkPolicy``. [failure] is nil when the probe passed.
public struct ProbeScore: Equatable, Sendable {
    public var requestedKbps: Int
    public var expected: Int
    public var sent: Int
    public var received: Int
    public var senderMs: Double
    public var lossPercent: Double
    public var worstWindowLossPercent: Double
    /// 99th percentile of the packets' transit time above the fastest one, in ms.
    public var delayP99Ms: Double
    /// Mean transit of the last 100 ms window less that of the first, in ms; infinite when a window is empty.
    public var delayGrowthMs: Double
    public var failure: ProbeFailure?
    /// What the OS granted for the receive buffer (0 = unknown) and the longest the receive loop was busy with one datagram.
    public var receiveBufferBytes: Int
    public var maxStallMs: Double

    public init(
        requestedKbps: Int, expected: Int, sent: Int, received: Int, senderMs: Double, lossPercent: Double,
        worstWindowLossPercent: Double, delayP99Ms: Double, delayGrowthMs: Double, failure: ProbeFailure?,
        receiveBufferBytes: Int = 0, maxStallMs: Double = 0
    ) {
        self.requestedKbps = requestedKbps
        self.expected = expected
        self.sent = sent
        self.received = received
        self.senderMs = senderMs
        self.lossPercent = lossPercent
        self.worstWindowLossPercent = worstWindowLossPercent
        self.delayP99Ms = delayP99Ms
        self.delayGrowthMs = delayGrowthMs
        self.failure = failure
        self.receiveBufferBytes = receiveBufferBytes
        self.maxStallMs = maxStallMs
    }

    public var passed: Bool { failure == nil }

    /// p99 transit variation above 4 ms: a warning on a passing probe, never a failure (the reference's rule).
    public var jitterWarning: Bool { delayP99Ms > LinkPolicy.jitterWarningP99Ms }

    /// A loss failure that our own receiver may have caused: a small granted buffer or a late receive loop.
    public var receiverSuspect: Bool {
        (failure == .loss || failure == .windowLoss)
            && (maxStallMs > LinkPolicy.receiverStallMs
                || (1..<LinkPolicy.minGoodReceiveBufferBytes).contains(receiveBufferBytes))
    }
}

/// Packets a probe of [kbps] plans: the host's `kbps * 2000 / (8 * (packetsize + 134))`, truncated.
public func expectedProbePackets(kbps: Int, packetSize: Int) -> Int {
    Int(Int64(kbps) * Int64(LinkPolicy.probeDurationMs) / (8 * Int64(packetSize + LinkPolicy.wireOverheadBytes)))
}

/// Grades one probe. [arrivalsUs] has one entry per planned sequence number: the packet's arrival time in microseconds
/// on any local clock, or a negative value when it never arrived. [expected], [sent] and [senderMs] are the host's own
/// numbers from the HTTPS answer.
///
/// Delay is relative: transit is the arrival time less the packet's slot in the host's 1 ms schedule, so the two
/// clocks' offset never enters the grade, only the spread of the transits and their growth do.
public func scoreProbe(
    requestedKbps: Int, expected: Int, sent: Int, senderMs: Double, arrivalsUs: [Int64],
    receiveBufferBytes: Int = 0, maxStallMs: Double = 0
) -> ProbeScore {
    let windows = LinkPolicy.windowCount
    let duration = Int64(LinkPolicy.probeDurationMs)
    var received = 0
    var worstWindow = 0.0
    var firstSum = 0.0, firstCount = 0, lastSum = 0.0, lastCount = 0
    var transit = [Double]()
    transit.reserveCapacity(max(expected, 0))
    for window in 0..<windows {
        let begin = Int(Int64(expected) * Int64(window) / Int64(windows))
        let end = Int(Int64(expected) * Int64(window + 1) / Int64(windows))
        var count = 0
        for seq in begin..<max(begin, end) {
            let arrival = seq < arrivalsUs.count ? arrivalsUs[seq] : -1
            if arrival < 0 { continue }
            count += 1
            // The sender's own 1 ms group schedule: packet seq leaves in group ceil((seq + 1) * 2000 / expected) - 1
            let tick = ((Int64(seq) + 1) * duration + Int64(expected) - 1) / Int64(expected) - 1
            let delta = Double(arrival) / 1000 - Double(tick)
            transit.append(delta)
            if window == 0 { firstSum += delta; firstCount += 1 }
            if window == windows - 1 { lastSum += delta; lastCount += 1 }
        }
        received += count
        if end > begin { worstWindow = max(worstWindow, 100.0 * Double(end - begin - count) / Double(end - begin)) }
    }
    let loss = expected > 0 ? 100.0 * Double(expected - received) / Double(expected) : 100.0
    var p99 = 0.0
    if !transit.isEmpty {
        transit.sort()
        p99 = transit[(transit.count - 1) * 99 / 100] - transit[0]
    }
    let growth = firstCount > 0 && lastCount > 0 ? lastSum / Double(lastCount) - firstSum / Double(firstCount) : .infinity
    let probeMs = Double(LinkPolicy.probeDurationMs)
    let failure: ProbeFailure? =
        if expected <= 0 || sent > expected || Double(sent) < Double(expected) * LinkPolicy.minSentShare { .notAllSent }
        else if received == 0 { .noPackets }
        else if !senderMs.isFinite || abs(senderMs - probeMs) > probeMs * LinkPolicy.durationTolerance { .senderDuration }
        else if loss >= LinkPolicy.maxLossPercent { .loss }
        else if worstWindow >= LinkPolicy.maxWindowLossPercent { .windowLoss }
        else if growth > LinkPolicy.maxDelayGrowthMs { .delayGrowth }
        else { nil }
    return ProbeScore(
        requestedKbps: requestedKbps, expected: expected, sent: sent, received: received, senderMs: senderMs,
        lossPercent: loss, worstWindowLossPercent: worstWindow, delayP99Ms: p99, delayGrowthMs: growth, failure: failure,
        receiveBufferBytes: receiveBufferBytes, maxStallMs: maxStallMs)
}
