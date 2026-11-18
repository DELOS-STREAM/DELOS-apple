import Foundation

/// What a ``FrameQueue`` did with its frames, cumulative since it was made.
public struct FrameQueueCounters: Sendable, Equatable {
    /// Frames handed to the queue (decoded frames).
    public var pushed = 0
    /// Frames taken to be drawn. Selection is not confirmation of presentation on a display.
    public var presented = 0
    /// Frames that were never shown: more than the backlog waited, or the queue was full.
    public var dropped = 0
    /// Refreshes that had no new frame to show after the first frame was shown (the previous picture stayed).
    public var repeatedRefreshes = 0
    /// Refreshes the queue was asked about.
    public var refreshes = 0
    /// Frames waiting in the queue, summed over the refreshes (divide by `refreshes` for the average).
    public var waitingSum = 0
    /// Most frames waiting at a refresh since the last ``FrameQueue/resetPeak()``.
    public var peakWaiting = 0
    /// Seconds the shown frames were late: the refresh's time minus the frame's due time, never below zero.
    public var accumulatedLateness = 0.0

    public init() {}
}

/// The decoded frames waiting for the display: gives each frame the time it is due (``FramePacer``, the same modes as
/// the display layer's), and at each refresh hands out the frame to show.
///
/// A frame is due when its time is within half a refresh of the refresh's presentation time, so it is shown at the
/// refresh nearest to its time. At a refresh the queue gives out the oldest frame that is due: frames keep their order,
/// one per refresh, and a frame that landed in the same refresh as the one before it is shown at the next refresh
/// instead of being dropped. Only when more than `backlog` frames would stay due behind the one shown does the queue
/// skip ahead (the frames skipped are dropped), so a stall that caught up cannot build delay.
///
/// The backlog per mode (the delay it adds is one refresh per waiting frame, and it drains at a refresh without a new
/// frame, which shows the waiting one instead of repeating the picture):
/// - Lowest latency, Warp: at most one frame, without delaying a frame that can be drawn now. Arrival jitter can put
///   none in one refresh and two in the next; keeping the second frame avoids a skip followed by a repeat. The backlog
///   drains when an arrival is late, not on a timer that would discard a still-useful jitter reserve.
///   A stream faster than the display keeps no backlog in these modes: the newest due frame wins.
/// - Balanced, Balanced with FPS limit: one frame, kept until a late arrival drains it.
/// - Smoothest: two frames, kept likewise.
///
/// A struct without a clock or a lock: the caller passes the times (seconds on one clock, the host clock in the app, a
/// virtual one in tests) and serializes the calls.
public struct FrameQueue<Frame> {
    private struct Entry {
        var frame: Frame
        var due: Double
    }

    /// Most frames held; a newer frame pushes the oldest one out (a decoder's output pool is small, so the queue is
    /// too).
    public let capacity: Int
    /// Frames that may stay due behind the one shown.
    public let backlog: Int
    /// Unbuffered modes select the newest frame when the stream is faster than the display.
    private let unbuffered: Bool
    public private(set) var counters = FrameQueueCounters()
    private var pacer: FramePacer
    private var entries: [Entry] = []
    private var shownOnce = false

    /// How far before its due time a frame may be shown, in refreshes.
    static var earlyTolerance: Double { 0.5 }
    /// A stream whose frame interval is below this share of the refresh is faster than the display.
    static var fasterStream: Double { 0.9 }

    public init(pacing: FramePacing, fps: Int, capacity: Int = 4) {
        self.capacity = max(capacity, 1)
        unbuffered = pacing.bufferFrames == 0
        backlog = unbuffered ? 1 : Int(pacing.bufferFrames)
        pacer = FramePacer(pacing: pacing, fps: fps)
        entries.reserveCapacity(self.capacity + 1)
    }

    /// Paces the frames at [fps] from now on (``FramePacer/retime(fps:)``).
    public mutating func retime(fps: Int) {
        pacer.retime(fps: fps)
    }

    public var waiting: Int { entries.count }

    /// Adds a frame decoded at `arrival` (seconds). Returns when it is due.
    @discardableResult
    public mutating func push(_ frame: Frame, arrival: Double) -> Double {
        let due = pacer.presentationTime(arrival: arrival) ?? arrival
        counters.pushed += 1
        if entries.count == capacity {
            entries.removeFirst()
            counters.dropped += 1
        }
        entries.append(Entry(frame: frame, due: due))
        return due
    }

    /// The frame to show at the refresh whose picture appears at `presentation` (seconds), `refresh` seconds long; nil
    /// when no frame is due, which leaves the previous picture on screen.
    public mutating func take(at presentation: Double, refresh: Double) -> (frame: Frame, due: Double)? {
        counters.refreshes += 1
        counters.waitingSum += entries.count
        counters.peakWaiting = max(counters.peakWaiting, entries.count)
        let horizon = presentation + Self.earlyTolerance * refresh
        var dueCount = 0
        while dueCount < entries.count, entries[dueCount].due <= horizon { dueCount += 1 }
        guard dueCount > 0 else {
            if shownOnce { counters.repeatedRefreshes += 1 }
            return nil
        }
        // Oldest due frame; skip ahead while more than the backlog would stay due behind it
        let allowed = unbuffered && pacer.interval < Self.fasterStream * refresh ? 0 : backlog
        let skipped = max(0, dueCount - 1 - allowed)
        let entry = entries[skipped]
        entries.removeSubrange(0...skipped)
        counters.dropped += skipped
        counters.presented += 1
        counters.accumulatedLateness += max(0, presentation - entry.due)
        shownOnce = true
        return (entry.frame, entry.due)
    }

    /// A refresh at which nothing can be drawn (the GPU is still busy): the frames wait and the previous picture stays.
    public mutating func idle() {
        counters.refreshes += 1
        counters.waitingSum += entries.count
        counters.peakWaiting = max(counters.peakWaiting, entries.count)
        if shownOnce { counters.repeatedRefreshes += 1 }
    }


    /// Drops the waiting frames and the pacing schedule (a new stream or after a decoder error); the counters stay.
    public mutating func flush() {
        entries.removeAll(keepingCapacity: true)
        pacer.reset()
        shownOnce = false
    }

    /// Forgets the peak, so the next reading shows the peak of its own window.
    public mutating func resetPeak() {
        counters.peakWaiting = 0
    }
}
