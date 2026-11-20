import Foundation

/// The `fraction` percentile (nearest rank) of the last `capacity` values. The values are kept sorted as they come and
/// go, so a new value moves at most `capacity` numbers and nothing is allocated once the window is full.
struct RunningPercentile: Sendable {
    let capacity: Int
    let fraction: Double
    /// The window in arrival order; `oldest` is the next one to leave once it is full.
    private var ring: [Double] = []
    private var oldest = 0
    private var sorted: [Double] = []

    init(capacity: Int, fraction: Double) {
        self.capacity = max(capacity, 1)
        self.fraction = fraction
        ring.reserveCapacity(self.capacity)
        sorted.reserveCapacity(self.capacity)
    }

    var count: Int { sorted.count }

    /// The percentile of the window; nil while it is empty.
    var value: Double? { percentile(fraction) }

    /// Another percentile of the same window (the median for the throughput line).
    func percentile(_ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((Double(sorted.count) * fraction).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    /// Adds a finite value; the oldest leaves once the window is full.
    mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        if ring.count < capacity {
            ring.append(value)
        } else {
            sorted.remove(at: lowerBound(ring[oldest]))
            ring[oldest] = value
            oldest = (oldest + 1) % capacity
        }
        sorted.insert(value, at: lowerBound(value))
    }

    mutating func reset() {
        ring.removeAll(keepingCapacity: true)
        sorted.removeAll(keepingCapacity: true)
        oldest = 0
    }

    private func lowerBound(_ value: Double) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// Phase lock's estimate of when the stream's frames arrive: each decoded frame's arrival minus the host's time of the
/// frame (its capture time, ``DecodedFrame/sourceTime``) is the network, the core and the decoder together, plus the
/// constant difference of the two clocks. The 99th percentile of the last two seconds of it, added to a frame's host time,
/// is the time that frame has arrived by 99 times out of 100. The window follows the host's clock running a little
/// faster or slower than the device's (the difference drifts by about 0.1 ms a second at 100 ppm) and a network whose
/// jitter changes.
struct ArrivalPhase: Sendable {
    /// Frames in the window: two seconds at 120 fps.
    static let window = 240
    static let percentile = 0.99

    private var residuals = RunningPercentile(capacity: window, fraction: percentile)
    private var lastSource: Double?

    /// The time the frame of host time `source` that arrived at `arrival` is safely due, never more than `interval` (one
    /// frame) after its arrival, so a jump in the host's times cannot hold the picture; a frame without a host time is
    /// due when it arrived.
    mutating func due(arrival: Double, source: Double?, interval: Double) -> Double {
        guard let source, source.isFinite else { return arrival }
        residuals.add(arrival - source)
        lastSource = source
        return min(source + (residuals.value ?? arrival - source), arrival + interval)
    }

    /// When the frame after the last one is safely due if the host keeps its pace (`interval` seconds a frame); nil
    /// before the first frame with a host time.
    func nextDue(interval: Double) -> Double? {
        guard let lastSource, let reserve = residuals.value else { return nil }
        return lastSource + interval + reserve
    }

    /// How long a frame is held for the jitter: the 99th percentile minus the median arrival, seconds; nil before any.
    var margin: Double? {
        guard let high = residuals.value, let median = residuals.percentile(0.5) else { return nil }
        return high - median
    }

    mutating func reset() {
        residuals.reset()
        lastSource = nil
    }
}
