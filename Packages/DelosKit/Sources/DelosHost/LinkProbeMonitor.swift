import Synchronization

/// One second of the PyroWave renderer's counters, taken at the stream's [targetKbps] (the live bitrate) (LinkMonitor.kt).
public struct LinkSample: Equatable, Sendable {
    public var seconds: Float
    public var targetKbps: Int
    /// Frames the host sent (received, partial and lost) in the second.
    public var totalFrames: Int64
    /// Frames delivered with holes, whole frames never delivered, and frames the device did not submit in time.
    public var partialFrames: Int64
    public var lostFrames: Int64
    public var skippedFrames: Int64
    /// Bytes the app received per second, in kbps; -1 when unknown.
    public var rxKbps: Float

    public init(seconds: Float, targetKbps: Int, totalFrames: Int64, partialFrames: Int64, lostFrames: Int64, skippedFrames: Int64, rxKbps: Float) {
        self.seconds = seconds
        self.targetKbps = targetKbps
        self.totalFrames = totalFrames
        self.partialFrames = partialFrames
        self.lostFrames = lostFrames
        self.skippedFrames = skippedFrames
        self.rxKbps = rxKbps
    }
}

public enum LinkVerdict: Equatable, Sendable {
    /// Too little data at this bitrate yet.
    case measuring
    /// Frames arrive whole.
    case keepingUp
    /// The network drops frames at this bitrate.
    case dropping
    /// Frames arrive whole but the device skips them; lowering the bitrate is not the cure.
    case deviceBehind
}

/// The rolling window's reading, at [targetKbps].
public struct LinkReading: Equatable, Sendable {
    public var verdict: LinkVerdict
    public var targetKbps: Int
    /// Average over the window, -1 when unknown.
    public var rxKbps: Float
    public var partialPerSecond: Float
    public var lostPerSecond: Float
    public var skippedPerSecond: Float
    /// Partial plus lost frames as a share of the window's frames.
    public var dropShare: Double
    /// What to try when [verdict] is `dropping`.
    public var suggestedKbps: Int

    public init(
        verdict: LinkVerdict, targetKbps: Int, rxKbps: Float = -1, partialPerSecond: Float = 0, lostPerSecond: Float = 0,
        skippedPerSecond: Float = 0, dropShare: Double = 0, suggestedKbps: Int
    ) {
        self.verdict = verdict
        self.targetKbps = targetKbps
        self.rxKbps = rxKbps
        self.partialPerSecond = partialPerSecond
        self.lostPerSecond = lostPerSecond
        self.skippedPerSecond = skippedPerSecond
        self.dropShare = dropShare
        self.suggestedKbps = suggestedKbps
    }
}

/// The suggested bitrate for a link that drops [dropShare] of the frames at [targetKbps].
public func suggestedBitrate(targetKbps: Int, dropShare: Double) -> Int {
    let cut = min(max(dropShare * LinkPolicy.hintCutPerShare, LinkPolicy.hintMinCut), LinkPolicy.hintMaxCut)
    let reduced = Int(Double(targetKbps) * (1 - cut) / Double(LinkPolicy.stepKbps)) * LinkPolicy.stepKbps
    return max(LinkPolicy.minKbps, reduced)
}

/// The passive part of the guidance: a rolling window of the last ~5 s of the stream's own counters. Samples taken at an
/// earlier bitrate are ignored once the bitrate changed, so the verdict always describes the bitrate in use. Thread-safe:
/// the statistics thread adds, the interface reads.
public final class LinkMonitor: Sendable {
    private let windowSeconds: Float
    private let samples = Mutex<[LinkSample]>([])

    public init(windowSeconds: Float = LinkPolicy.hintWindowSeconds) {
        self.windowSeconds = windowSeconds
    }

    public func add(_ sample: LinkSample) {
        guard sample.seconds > 0 else { return }
        samples.withLock { samples in
            samples.append(sample)
            var total = samples.reduce(0.0) { $0 + Double($1.seconds) }
            while samples.count > 1, total - Double(samples[0].seconds) >= Double(windowSeconds) {
                total -= Double(samples.removeFirst().seconds)
            }
        }
    }

    public func clear() { samples.withLock { $0.removeAll() } }

    /// The reading over the trailing samples that share the newest sample's bitrate, or nil before the first sample.
    public func reading() -> LinkReading? {
        samples.withLock { samples in
            guard let newest = samples.last else { return nil }
            let run = samples.reversed().prefix { $0.targetKbps == newest.targetKbps }
            let seconds = Float(run.reduce(0.0) { $0 + Double($1.seconds) })
            let total = run.reduce(Int64(0)) { $0 + $1.totalFrames }
            let partial = run.reduce(Int64(0)) { $0 + $1.partialFrames }
            let lost = run.reduce(Int64(0)) { $0 + $1.lostFrames }
            let skipped = run.reduce(Int64(0)) { $0 + $1.skippedFrames }
            let known = run.filter { $0.rxKbps >= 0 }
            let knownSeconds = known.reduce(0.0) { $0 + Double($1.seconds) }
            let rx: Float = knownSeconds > 0 ? Float(known.reduce(0.0) { $0 + Double($1.rxKbps) * Double($1.seconds) } / knownSeconds) : -1
            let dropShare = total > 0 ? Double(partial + lost) / Double(total) : 0
            let skipShare = total > 0 ? Double(skipped) / Double(total) : 0
            let verdict: LinkVerdict =
                if seconds < LinkPolicy.hintMinSeconds || total <= 0 { .measuring }
                else if dropShare >= LinkPolicy.hintDropShare { .dropping }
                else if skipShare >= LinkPolicy.hintDropShare { .deviceBehind }
                else { .keepingUp }
            return LinkReading(
                verdict: verdict, targetKbps: newest.targetKbps, rxKbps: rx, partialPerSecond: Float(partial) / seconds,
                lostPerSecond: Float(lost) / seconds, skippedPerSecond: Float(skipped) / seconds, dropShare: dropShare,
                suggestedKbps: verdict == .dropping ? suggestedBitrate(targetKbps: newest.targetKbps, dropShare: dropShare) : newest.targetKbps)
        }
    }

    /// The in-stream hint, only while the link drops frames.
    public func hint() -> LinkReading? {
        reading().flatMap { $0.verdict == .dropping ? $0 : nil }
    }
}
