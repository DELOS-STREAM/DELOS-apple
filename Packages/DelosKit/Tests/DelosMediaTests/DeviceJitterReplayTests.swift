import Foundation
import Testing
@testable import DelosMedia

/// Synthetic jitter models using the scale of assembly/decode percentiles in the retained iPad performance log.
/// The source contains per-second aggregates, NOT decoded-frame arrival times, callback times, or their correlations.
/// Distribution shape, within-second ordering, clock drift and missing-callback placement below are assumptions.
/// These tests are not a replay of measured arrivals and cannot establish hardware FPS or latency.
enum ModeledDeviceEnvelope {
    /// Selected assembly p50/p99 and callback-count aggregates. They constrain an illustrative envelope only;
    /// a sample generated from them is not a measured frame arrival.
    static let seconds: [(assembly50: Double, assembly99: Double, ticks: Int)] = [
        (2.06, 7.03, 115), (2.54, 9.72, 119), (2.06, 5.02, 111), (2.55, 7.92, 120), (2.09, 8.74, 118), (2.51, 8.37, 115),
        (3.04, 9.52, 120), (3.06, 6.69, 119), (3.20, 6.78, 120), (2.85, 8.97, 119), (2.69, 6.16, 120), (2.72, 7.29, 120),
        (2.66, 6.99, 120), (2.90, 7.63, 119), (3.02, 6.94, 117), (3.18, 6.93, 117), (2.98, 8.13, 120), (3.68, 7.49, 117),
        (4.05, 6.27, 116), (4.04, 8.32, 113), (3.81, 10.35, 111), (3.69, 7.38, 115), (3.70, 6.15, 117), (3.92, 8.02, 115),
        (3.59, 6.90, 120), (3.69, 10.65, 120), (3.06, 7.09, 119), (3.04, 6.39, 120), (3.29, 6.88, 121), (3.00, 7.02, 120),
        (3.20, 5.59, 119), (3.71, 6.65, 121), (3.77, 20.18, 118), (3.58, 11.89, 119), (3.31, 6.74, 120), (3.39, 6.18, 121),
        (3.29, 7.44, 118), (3.52, 9.79, 120), (3.49, 7.07, 119), (3.56, 10.58, 120), (3.77, 7.53, 120), (3.31, 6.01, 120),
        (3.64, 7.12, 119), (3.63, 7.62, 121), (3.75, 10.28, 119), (4.11, 9.76, 119), (4.01, 9.68, 121), (4.13, 9.94, 119),
        (4.26, 7.39, 120), (4.33, 9.55, 119), (3.88, 8.19, 119), (3.78, 9.53, 120), (3.72, 6.11, 120), (3.36, 6.84, 116),
        (3.40, 6.73, 120), (3.41, 6.66, 119), (3.24, 6.20, 119), (3.05, 8.65, 118), (3.11, 6.55, 117), (4.27, 6.91, 112),
        (3.65, 7.71, 118), (4.06, 7.04, 119), (4.05, 8.69, 115), (4.15, 7.52, 119), (4.03, 8.62, 116), (4.24, 7.66, 116),
        (4.05, 7.93, 120), (4.22, 8.06, 116), (4.12, 6.67, 117), (4.10, 7.15, 118), (4.10, 6.64, 117), (4.20, 9.01, 118),
        (4.42, 8.15, 119), (4.11, 7.71, 116), (4.16, 6.53, 118), (4.12, 9.32, 116), (4.22, 6.35, 114), (4.04, 6.98, 115),
        (4.34, 8.53, 112), (4.04, 8.77, 110), (4.41, 7.35, 113), (4.20, 8.18, 115), (4.08, 7.10, 115), (3.98, 9.11, 116),
        (3.83, 6.77, 111), (3.95, 8.08, 115), (3.75, 6.80, 118), (3.84, 7.25, 115), (3.77, 7.53, 118), (3.81, 7.83, 112),
        (3.81, 6.04, 120), (4.11, 6.94, 113), (4.03, 6.66, 115), (4.04, 6.66, 119), (4.05, 6.17, 116), (4.06, 6.54, 115),
        (4.41, 8.89, 116), (4.21, 6.66, 114), (3.94, 6.77, 112), (4.19, 6.92, 112), (4.09, 7.79, 113), (4.11, 6.52, 114),
        (4.20, 7.82, 111), (4.11, 7.96, 114), (3.69, 6.89, 119), (3.96, 6.08, 119), (3.87, 9.75, 121), (4.21, 7.61, 119),
        (3.92, 7.06, 121), (4.22, 6.03, 120), (3.82, 8.76, 120), (3.76, 5.97, 119), (3.75, 6.66, 119), (3.79, 7.89, 119),
        (3.73, 7.46, 119), (3.69, 6.57, 119), (3.62, 6.50, 119), (3.81, 6.99, 121), (3.77, 8.82, 120), (3.91, 7.24, 119),
        (3.77, 8.56, 120), (3.64, 7.48, 115), (3.83, 8.77, 121), (3.87, 6.61, 118), (3.72, 6.05, 120), (3.70, 11.68, 118),
        (3.63, 7.65, 118), (3.60, 8.11, 121), (3.79, 8.06, 120), (3.59, 7.26, 120), (3.41, 6.45, 117), (3.61, 6.55, 120),
        (3.62, 6.56, 115), (3.34, 9.79, 118), (3.71, 6.22, 118), (3.74, 7.65, 120), (3.75, 6.84, 119), (3.80, 6.97, 119),
        (3.73, 6.24, 119), (3.63, 6.45, 118), (3.72, 6.63, 118), (3.42, 7.28, 118), (3.59, 6.25, 116), (3.51, 6.75, 119),
        (3.46, 8.27, 119), (3.62, 6.06, 119), (3.62, 6.86, 120), (4.06, 6.34, 118), (4.15, 7.60, 119), (3.23, 7.54, 119),
        (2.99, 6.87, 120), (3.41, 8.11, 119), (3.03, 6.46, 121), (2.92, 6.99, 120), (2.82, 6.23, 119), (2.81, 6.35, 120),
        (2.96, 7.37, 121), (3.02, 6.69, 120), (2.98, 6.11, 120), (2.84, 6.88, 120), (2.87, 5.95, 120), (2.72, 5.81, 120),
        (2.87, 7.17, 120), (3.01, 6.00, 119), (3.20, 8.36, 120), (2.92, 5.78, 121), (2.89, 7.07, 120), (2.97, 6.03, 116),
        (3.03, 6.77, 116), (2.74, 8.15, 120),
    ]

    /// The decoder's time per frame over the run, median and 99th percentile in milliseconds (`dect`).
    static let decode = (p50: 2.72, p99: 3.30)

    /// A delay with the given median and 99th percentile (log-normal: delays have a floor and a tail), in seconds.
    static func delay(p50: Double, p99: Double, random: inout SeededRandom) -> Double {
        // 2.326 standard deviations above the median is the 99th percentile
        let sigma = log(max(p99, p50) / p50) / 2.326
        return p50 * exp(sigma * random.gaussian()) / 1000
    }

    /// Modeled decoded arrivals: source intervals plus synthetic assembly and serial-decode delays.
    /// Assembly duration alone does not determine the phase or timing of a decoded frame on a real network.
    static func arrivals(count: Int, hostFPS: Double, seed: UInt64, assembly: (Int, inout SeededRandom) -> Double) -> [Double] {
        var random = SeededRandom(seed: seed)
        var received = -Double.infinity, decoded = -Double.infinity
        return (0..<count).map { i in
            received = max(1 + Double(i) / hostFPS + assembly(i, &random), received)
            decoded = max(received, decoded) + delay(p50: decode.p50, p99: decode.p99, random: &random)
            return decoded
        }
    }

    /// One assumed log-normal distribution near the aggregate percentiles, optionally truncated at `longest`.
    /// Truncation is a model scenario, not a claim that the measured run had no longer frames.
    static func typicalArrivals(seconds: Int, hostFPS: Double, seed: UInt64, longest: Double = .infinity) -> [Double] {
        arrivals(count: seconds * 120, hostFPS: hostFPS, seed: seed) { _, random in
            min(delay(p50: 3.5, p99: 8, random: &random), longest / 1000)
        }
    }

    /// An aggregate-derived synthetic scenario. Two arbitrarily chosen frames per modeled second use its p99.
    /// The remaining frames follow an assumed distribution; no measured per-frame ordering is recovered.
    static func loggedArrivals(hostFPS: Double, seed: UInt64) -> [Double] {
        var slow: Set<Int> = []
        var pick = SeededRandom(seed: seed &+ 1)
        for second in seconds.indices {
            while slow.count < 2 * (second + 1) { slow.insert(second * 120 + Int(pick.next() * 120)) }
        }
        return arrivals(count: seconds.count * 120, hostFPS: hostFPS, seed: seed) { i, random in
            let second = seconds[i / 120]
            if slow.contains(i) { return second.assembly99 / 1000 }
            // The other frames: the second's median with the run's usual spread, below its 99th percentile
            let usual = min(second.assembly99, second.assembly50 * 8 / 3.5)
            return min(delay(p50: second.assembly50, p99: usual, random: &random), second.assembly99 / 1000)
        }
    }

    /// Synthetic missing callbacks: aggregate deficits are randomly placed on an assumed 120 Hz grid.
    /// Counts above 120 can arise from window boundaries; the model cannot reconstruct those boundaries.
    static func lostRefreshes(seed: UInt64) -> Set<Int> {
        var random = SeededRandom(seed: seed)
        var lost: Set<Int> = []
        for (second, entry) in seconds.enumerated() {
            var missing = max(0, 120 - entry.ticks)
            while missing > 0 {
                if lost.insert(second * 120 + Int(random.next() * 120)).inserted { missing -= 1 }
            }
        }
        return lost
    }
}

extension SeededRandom {
    /// A standard normal value (Box-Muller).
    mutating func gaussian() -> Double {
        let u = max(next(), .leastNonzeroMagnitude)
        return sqrt(-2 * log(u)) * cos(2 * .pi * next())
    }
}

/// What a replay showed, second by second, and how long its frames waited beyond the first refresh that could show them.
struct ReplaySummary {
    /// Frames shown in each whole second of the replay (by the refresh they appeared at).
    var shownPerSecond: [Int] = []
    var dropped = 0
    var repeated = 0
    /// Seconds each shown frame waited after the first refresh whose callback came after it arrived.
    var added: [Double] = []

    var meanShown: Double { Double(shownPerSecond.reduce(0, +)) / Double(max(shownPerSecond.count, 1)) }

    func addedPercentile(_ fraction: Double) -> Double {
        let sorted = added.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    init(shown: [(frame: Int, presentation: Double)], dropped: Int, repeated: Int, arrivals: [Double], display: VirtualDisplay, lead: Double) {
        self.dropped = dropped
        self.repeated = repeated
        let first = Int((arrivals.first ?? 0).rounded(.up)) + 1, last = Int((arrivals.last ?? 0).rounded(.down)) - 1
        var counts = [Int](repeating: 0, count: max(0, last - first))
        for frame in shown {
            let second = Int(frame.presentation.rounded(.down)) - first
            if counts.indices.contains(second) { counts[second] += 1 }
            // The first refresh whose callback came at or after the arrival
            let callbacks = ((arrivals[frame.frame] + lead * display.refresh - display.phase) / display.refresh).rounded(.up)
            added.append(max(0, frame.presentation - (display.phase + callbacks * display.refresh)))
        }
        shownPerSecond = counts
    }

    init(_ run: QueueRun, arrivals: [Double], display: VirtualDisplay, lead: Double) {
        self.init(
            shown: run.shown.map { ($0.frame, $0.presentation) }, dropped: run.counters.dropped,
            repeated: run.counters.repeatedRefreshes, arrivals: arrivals, display: display, lead: lead)
    }

    func row(_ label: String) -> String {
        String(
            format: "MODEL %@: shown/s mean %.1f min %d, seconds below 119: %d of %d, dropped %d, repeated %d, added delay p50 %.1f p99 %.1f max %.1f ms",
            label, meanShown, shownPerSecond.min() ?? 0, shownPerSecond.filter { $0 < 119 }.count, shownPerSecond.count,
            dropped, repeated, addedPercentile(0.5) * 1000, addedPercentile(0.99) * 1000, (added.max() ?? 0) * 1000)
    }
}

/// The queue before this change in the Lowest latency mode, for the "before" number of the same replay: at each refresh
/// the newest frame that had arrived was shown and the others were dropped.
enum NewestWinsModel {
    static func run(arrivals: [Double], display: VirtualDisplay, lead: Double, lost: Set<Int> = []) -> QueueRun {
        var run = QueueRun()
        var next = 0
        var shownOnce = false
        let ticks = display.refreshes(in: (arrivals.first ?? 0)...((arrivals.last ?? 0) + 0.1))
        for (index, tick) in ticks.enumerated() where !lost.contains(index) {
            let waiting = next
            while next < arrivals.count, arrivals[next] <= tick - lead * display.refresh { next += 1 }
            run.counters.refreshes += 1
            guard next > waiting else {
                if shownOnce { run.counters.repeatedRefreshes += 1 }
                continue
            }
            run.counters.dropped += next - waiting - 1
            run.counters.presented += 1
            run.shown.append((next - 1, arrivals[next - 1], tick))
            shownOnce = true
        }
        return run
    }
}

@Suite struct ModeledDeviceJitterTests {
    let refresh = 1.0 / 120
    /// An assumed two-refresh callback lead. preferredFrameLatency is a request, not a guaranteed measured lead.
    let lead = 2.0
    let display = VirtualDisplay(refresh: 1.0 / 120, phase: 0.0004)

    /// Assumed source/display drift in both directions; no host clock rate was recovered from aggregate windows.
    static let hostRates = [119.98, 119.988, 120.012, 120.02]

    /// The refreshes of delay a waiting frame may add in each mode.
    static func backlog(_ pacing: FramePacing) -> Double { pacing == .smoothness ? 2 : 1 }

    private func replay(_ arrivals: [Double], _ pacing: FramePacing, lost: Set<Int> = []) -> (before: ReplaySummary, after: ReplaySummary) {
        let before = ReplaySummary(
            NewestWinsModel.run(arrivals: arrivals, display: display, lead: lead, lost: lost), arrivals: arrivals,
            display: display, lead: lead)
        let run = QueueReplay.run(arrivals: arrivals, pacing: pacing, fps: 120, display: display, lead: lead, lost: lost)
        #expect(run.shown.map(\.frame) == run.shown.map(\.frame).sorted(), "frames keep their order")
        return (before, ReplaySummary(run, arrivals: arrivals, display: display, lead: lead))
    }

    /// Truncated synthetic jitter across clock drift, with every modeled callback delivered.
    /// These cadence and bounded-delay assertions apply to this deterministic model only.
    @Test(arguments: hostRates, FramePacing.allCases)
    func truncatedModeledJitterPreservesCadence(hostFPS: Double, pacing: FramePacing) {
        let arrivals = ModeledDeviceEnvelope.typicalArrivals(seconds: 169, hostFPS: hostFPS, seed: 20_261_118, longest: 8)
        let (before, after) = replay(arrivals, pacing)
        print(before.row("jitter 3.5/8 ms, host \(hostFPS) fps, before (the newest frame wins)"))
        print(after.row("jitter 3.5/8 ms, host \(hostFPS) fps, \(pacing)"))
        #expect(before.meanShown < 112)
        #expect(after.shownPerSecond.allSatisfy { $0 >= 119 })
        #expect(after.meanShown >= 119.8)
        #expect((after.added.max() ?? 0) <= Self.backlog(pacing) * refresh + 1e-9)
    }

    /// The assumed distribution's untruncated tail tests a few longer delays; it is not the measured tail.
    @Test(arguments: hostRates, FramePacing.allCases)
    func modeledTailKeepsCadenceAndDelayBounded(hostFPS: Double, pacing: FramePacing) {
        let arrivals = ModeledDeviceEnvelope.typicalArrivals(seconds: 169, hostFPS: hostFPS, seed: 20_261_118)
        let (before, after) = replay(arrivals, pacing)
        print(before.row("jitter 3.5/8 ms with its tail, host \(hostFPS) fps, before"))
        print(after.row("jitter 3.5/8 ms with its tail, host \(hostFPS) fps, \(pacing)"))
        #expect(before.meanShown < 112)
        #expect(after.shownPerSecond.allSatisfy { $0 >= 118 })
        #expect(after.shownPerSecond.filter { $0 < 119 }.count <= 1)
        #expect(after.meanShown >= 119.8)
        #expect((after.added.max() ?? 0) <= Self.backlog(pacing) * refresh + 1e-9)
    }

    /// Aggregate percentiles plus invented within-second ordering and callback placement.
    /// Missing callbacks impose an independent ceiling; no output here is the original device's shown rate.
    @Test(arguments: hostRates, [FramePacing.latency, .balanced])
    func aggregateDerivedSyntheticScenarios(hostFPS: Double, pacing: FramePacing) {
        let arrivals = ModeledDeviceEnvelope.loggedArrivals(hostFPS: hostFPS, seed: 20_261_118)
        let whole = replay(arrivals, pacing)
        print(whole.before.row("aggregate-derived synthetic arrivals, host \(hostFPS) fps, before"))
        print(whole.after.row("aggregate-derived synthetic arrivals, host \(hostFPS) fps, \(pacing)"))
        #expect(whole.before.meanShown < 112)
        #expect(whole.after.meanShown >= 119.7)
        #expect(whole.after.shownPerSecond.filter { $0 < 119 }.count <= 4)
        let lost = ModeledDeviceEnvelope.lostRefreshes(seed: 7)
        let delivered = Double(ModeledDeviceEnvelope.seconds.map { min(120, $0.ticks) }.reduce(0, +))
            / Double(ModeledDeviceEnvelope.seconds.count)
        let modeled = replay(arrivals, pacing, lost: lost)
        print(modeled.before.row("synthetic arrivals and missing callbacks, host \(hostFPS) fps, before"))
        print(modeled.after.row("synthetic arrivals and missing callbacks, host \(hostFPS) fps, \(pacing)"))
        #expect(modeled.after.meanShown > modeled.before.meanShown)
        #expect(modeled.after.meanShown >= delivered - 0.5)
    }

    /// Synthetic arrivals through actual fixture decoding and offscreen drawing. The virtual refresh and completed
    /// drawing are modeled presentation, not evidence of physical scanout or this machine meeting a 120 Hz budget.
    @Test(arguments: [FramePacing.latency, .balanced])
    func modeledJitterThroughFixtureDecodeAndOffscreenDrawing(pacing: FramePacing) throws {
        let arrivals = ModeledDeviceEnvelope.typicalArrivals(seconds: 20, hostFPS: 120.012, seed: 20_261_118, longest: 8)
        let run = try PipelineReplay.run(
            fixture: "frames.hevc", codec: .hevc, arrivals: arrivals, pacing: pacing, fps: 120, display: display, lead: lead)
        let model = QueueReplay.run(arrivals: arrivals, pacing: pacing, fps: 120, display: display, lead: lead)
        #expect(run.shown.map(\.sequence) == model.shown.map(\.frame))
        let counters = try #require(run.counters)
        #expect(counters.decodedFrames == 2400)
        #expect(counters.totalFrames == run.shown.count + counters.droppedFrames)
        let summary = ReplaySummary(
            shown: run.shown.map { ($0.sequence, $0.presentation) }, dropped: counters.droppedFrames,
            repeated: counters.repeatedRefreshes ?? 0, arrivals: arrivals, display: display, lead: lead)
        let before = ReplaySummary(
            NewestWinsModel.run(arrivals: arrivals, display: display, lead: lead), arrivals: arrivals, display: display, lead: lead)
        print(before.row("modeled baseline before offscreen replay"))
        print(summary.row("modeled arrivals, fixture decode and offscreen draw, \(pacing)"))
        #expect(summary.shownPerSecond.allSatisfy { $0 >= 119 })
        #expect((summary.added.max() ?? 0) <= refresh + 1e-9)
    }
}
