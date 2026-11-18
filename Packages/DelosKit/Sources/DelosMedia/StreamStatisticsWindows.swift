import Foundation

/// The 1 % low frame rate of the frames shown recently (Android `FrameTimes.java`): 1 over the average of the longest 1 %
/// of the intervals between shown frames. Every renderer stamps a frame when it hands it to the display; intervals of half
/// a second or more are a still picture (the host sends nothing new), not a hitch. No allocation per frame.
public struct FrameTimes: Sendable {
    /// About ten seconds at 120 FPS.
    static let capacity = 1200
    static let idleGap = 0.5
    static let minimumFrames = 100

    private var intervals = [Double](repeating: 0, count: FrameTimes.capacity)
    private var count = 0
    private var next = 0
    private var last: Double?

    public init() {}

    /// A frame was shown at `time` (seconds).
    public mutating func add(_ time: Double) {
        if let last {
            let interval = time - last
            if interval > 0, interval < Self.idleGap {
                intervals[next] = interval
                next = (next + 1) % Self.capacity
                count = min(count + 1, Self.capacity)
            }
        }
        last = time
    }

    /// The 1 % low frame rate, nil while there are fewer than 100 intervals.
    public var onePercentLowFPS: Double? {
        guard count >= Self.minimumFrames else { return nil }
        let sorted = intervals[0..<count].sorted()
        let worst = max(1, count / 100)
        let total = sorted[(count - worst)...].reduce(0, +)
        return 1 / (total / Double(worst))
    }

    /// Forgets the frames (a new stream).
    public mutating func reset() {
        self = FrameTimes()
    }
}

/// Average, 95th percentile and maximum of one latency stage over a statistics window, in milliseconds (Android
/// `StageSummary.java`).
public struct StageSummary: Sendable, Equatable {
    public var count: Int
    public var averageMilliseconds: Double
    public var p95Milliseconds: Double
    public var maximumMilliseconds: Double

    public init(count: Int, averageMilliseconds: Double, p95Milliseconds: Double, maximumMilliseconds: Double) {
        self.count = count
        self.averageMilliseconds = averageMilliseconds
        self.p95Milliseconds = p95Milliseconds
        self.maximumMilliseconds = maximumMilliseconds
    }
}

/// The samples of one latency stage in the current window (Android `LatencyStages.java`, one stage): a preallocated ring of
/// the last 512 samples and running sums; ``summarize()`` closes the window once a second.
public struct StageWindow: Sendable {
    static let capacity = 512
    private var ring = [Double](repeating: 0, count: StageWindow.capacity)
    private var count = 0
    private var sum = 0.0
    private var maximum = 0.0

    public init() {}

    /// Adds one sample in seconds; negative values (an unavailable timestamp) are ignored.
    public mutating func record(_ seconds: Double) {
        guard seconds >= 0 else { return }
        ring[count % Self.capacity] = seconds
        count += 1
        sum += seconds
        maximum = max(maximum, seconds)
    }

    /// The window's figures, nil without samples; the window starts empty again.
    public mutating func summarize() -> StageSummary? {
        guard count > 0 else { return nil }
        let kept = min(count, Self.capacity)
        let sorted = ring[0..<kept].sorted()
        let summary = StageSummary(
            count: count, averageMilliseconds: sum / Double(count) * 1000,
            p95Milliseconds: sorted[Self.percentileIndex(size: kept, fraction: 0.95)] * 1000, maximumMilliseconds: maximum * 1000)
        count = 0
        sum = 0
        maximum = 0
        return summary
    }

    /// Index of the nearest-rank percentile in a sorted array of `size` samples.
    static func percentileIndex(size: Int, fraction: Double) -> Int {
        max(0, min(size - 1, Int((fraction * Double(size)).rounded(.up)) - 1))
    }
}

/// What the Sharpen only mode cost per frame in the last statistics window (Android `SharpenCost.java`): the pass and the
/// preparation it needs before it, here the Y'CbCr to RGB conversion at the stream's size, which the direct drawing does in
/// the same pass as its placing.
public struct SharpenCost: Sendable, Equatable {
    /// True when the times are the GPU's own (always on Metal: each part runs in a command buffer of its own).
    public var gpuTimed: Bool
    public var passAverageMilliseconds: Double
    public var passMaximumMilliseconds: Double
    /// Nil when the preparation was not measured.
    public var prepareAverageMilliseconds: Double?
    public var prepareMaximumMilliseconds: Double?
    /// What the preparation is, for the panel.
    public var prepareName: String
    public var samples: Int

    public init(
        gpuTimed: Bool, passAverageMilliseconds: Double, passMaximumMilliseconds: Double, prepareAverageMilliseconds: Double?,
        prepareMaximumMilliseconds: Double?, prepareName: String, samples: Int
    ) {
        self.gpuTimed = gpuTimed
        self.passAverageMilliseconds = passAverageMilliseconds
        self.passMaximumMilliseconds = passMaximumMilliseconds
        self.prepareAverageMilliseconds = prepareAverageMilliseconds
        self.prepareMaximumMilliseconds = prepareMaximumMilliseconds
        self.prepareName = prepareName
        self.samples = samples
    }
}

/// Collects Sharpen only's GPU times over a window (Android `SharpenMeter.java`, with Metal's command buffer times instead
/// of timer queries).
struct SharpenMeter {
    private var pass = (sum: 0.0, maximum: 0.0, count: 0)
    private var prepare = (sum: 0.0, maximum: 0.0, count: 0)

    mutating func record(passSeconds: Double, prepareSeconds: Double?) {
        let ms = passSeconds * 1000
        pass = (pass.sum + ms, max(pass.maximum, ms), pass.count + 1)
        if let prepareSeconds {
            let prepareMs = prepareSeconds * 1000
            prepare = (prepare.sum + prepareMs, max(prepare.maximum, prepareMs), prepare.count + 1)
        }
    }

    /// The window's cost, nil when no frame was sharpened; the window starts empty again.
    mutating func summarize() -> SharpenCost? {
        defer { self = SharpenMeter() }
        guard pass.count > 0 else { return nil }
        return SharpenCost(
            gpuTimed: true, passAverageMilliseconds: pass.sum / Double(pass.count), passMaximumMilliseconds: pass.maximum,
            prepareAverageMilliseconds: prepare.count > 0 ? prepare.sum / Double(prepare.count) : nil,
            prepareMaximumMilliseconds: prepare.count > 0 ? prepare.maximum : nil, prepareName: "conversion", samples: pass.count)
    }
}
