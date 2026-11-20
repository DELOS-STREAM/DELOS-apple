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

/// The decoded frames waiting for the display: gives each frame the time it is due, and at each refresh hands out the
/// frame to show. Phase lock times its frames by their arrival against the host's frame times (``ArrivalPhase``), the
/// other modes by ``FramePacer`` (the same modes as the display layer's).
///
/// Paced modes: a frame is due when its time is within half a refresh of the refresh's presentation time, so it is shown
/// at the refresh nearest to its time. At a refresh the queue gives out the oldest frame that is due: frames keep their
/// order, one per refresh, and a frame that landed in the same refresh as the one before it is shown at the next refresh
/// instead of being dropped. Only when more than `backlog` frames would stay due behind the one shown does the queue
/// skip ahead (the frames skipped are dropped), so a stall that caught up cannot build delay.
///
/// Phase lock: a frame is due at a refresh when its safe arrival time (the time its arrival makes 99 times out of 100)
/// is before the refresh's `latest` drawing time. So each frame goes to the earliest refresh it safely makes, and one that
/// arrived early is held for its own refresh rather than shown a refresh before its neighbours, which would leave a gap
/// where the next jittery frame misses. The hold is the jitter's margin (a few milliseconds), never a whole frame. The
/// backlog is one frame: two frames due at once (a late arrival next to an early one) are shown one after the other. A
/// frame shown after its own refresh went by puts the queue a refresh behind; after a second of that, the queue catches
/// up: it waits for the next frame (``waitsForFrame(before:)``) and drops the frame behind, so the delay cannot settle
/// at a whole frame more. When the display link skipped refreshes, the frames whose refresh went by are dropped at once
/// and the picture keeps the phase. ``waitsForFrame(before:)`` tells the renderer to keep the refresh's drawable while
/// the next frame is due before `latest`.
///
/// The backlog of the other modes (the delay it adds is one refresh per waiting frame, and it drains at a refresh
/// without a new frame, which shows the waiting one instead of repeating the picture):
/// - Warp: at most one frame, without delaying a frame that can be drawn now. A stream faster than the display keeps no
///   backlog: the newest due frame wins.
/// - Balanced, Balanced with FPS limit: one frame, kept until a late arrival drains it, not on a timer that would discard
///   a still-useful jitter reserve.
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
    /// Warp selects the newest frame when the stream is faster than the display.
    private let unbuffered: Bool
    public private(set) var counters = FrameQueueCounters()
    private var pacer: FramePacer
    /// Phase lock's arrival estimate; nil in the other modes.
    private var phase: ArrivalPhase?
    /// Phase lock: the presentation time of the last refresh the display link called back for.
    private var lastPresentation: Double?
    /// Phase lock: since when the frames shown were due a refresh or more before the refresh that showed them.
    private var behindSince: Double?
    private var entries: [Entry] = []
    private var shownOnce = false

    /// How far before its due time a frame may be shown, in refreshes.
    static var earlyTolerance: Double { 0.5 }
    /// A stream whose frame interval is below this share of the refresh is faster than the display.
    static var fasterStream: Double { 0.9 }
    /// Phase lock: seconds the frames may be shown a refresh behind before the queue catches up by dropping one.
    static var behindLimit: Double { 1 }

    public init(pacing: FramePacing, fps: Int, capacity: Int = 4) {
        self.capacity = max(capacity, 1)
        unbuffered = pacing == .warp || pacing == .warp2
        backlog = pacing == .smoothness ? 2 : 1
        pacer = FramePacer(pacing: pacing, fps: fps)
        phase = pacing == .phaseLock ? ArrivalPhase() : nil
        entries.reserveCapacity(self.capacity + 1)
    }

    /// Paces the frames at [fps] from now on (``FramePacer/retime(fps:)``).
    public mutating func retime(fps: Int) {
        pacer.retime(fps: fps)
    }

    public var waiting: Int { entries.count }

    /// Phase lock: how long frames are held for the network's jitter (the 99th percentile arrival minus the median),
    /// seconds; nil in the other modes and before the first frame.
    public var phaseMargin: Double? { phase?.margin }

    /// Adds a frame decoded at `arrival` (seconds); `source` is the host's time of the frame on the host's clock (seconds),
    /// nil when unknown. Returns when it is due.
    @discardableResult
    public mutating func push(_ frame: Frame, arrival: Double, source: Double? = nil) -> Double {
        let due = phase?.due(arrival: arrival, source: source, interval: pacer.interval)
            ?? pacer.presentationTime(arrival: arrival) ?? arrival
        counters.pushed += 1
        if entries.count == capacity {
            entries.removeFirst()
            counters.dropped += 1
        }
        entries.append(Entry(frame: frame, due: due))
        return due
    }

    /// Phase lock: the next frame is safely due before `latest`, and no frame waits or the queue is catching up (the
    /// frames waiting are a refresh behind, as they have been for ``behindLimit``), so the refresh's drawing should wait
    /// for it. Always false in the other modes.
    public func waitsForFrame(before latest: Double) -> Bool {
        guard let next = phase?.nextDue(interval: pacer.interval), next <= latest else { return false }
        return entries.isEmpty || catchingUp && entries.allSatisfy { $0.due <= latest - pacer.interval }
    }

    /// Phase lock: the frames have been shown a refresh behind for ``behindLimit``.
    private var catchingUp: Bool {
        guard let behindSince, let lastPresentation else { return false }
        return lastPresentation - behindSince >= Self.behindLimit
    }

    /// The frame to show at the refresh whose picture appears at `presentation` (seconds), `refresh` seconds long; nil
    /// when no frame is due, which leaves the previous picture on screen. `latest`: phase lock's last moment a frame can
    /// still be drawn for this refresh (without it, the presentation time); the paced modes do not use it.
    public mutating func take(at presentation: Double, refresh: Double, latest: Double? = nil) -> (frame: Frame, due: Double)? {
        counters.refreshes += 1
        counters.waitingSum += entries.count
        counters.peakWaiting = max(counters.peakWaiting, entries.count)
        let missed = lastPresentation.map { presentation - $0 > 1.5 * refresh } ?? false
        let catchingUp = catchingUp
        if phase != nil { lastPresentation = presentation }
        let horizon = phase == nil ? presentation + Self.earlyTolerance * refresh : latest ?? presentation
        var dueCount = 0
        while dueCount < entries.count, entries[dueCount].due <= horizon { dueCount += 1 }
        guard dueCount > 0 else {
            if shownOnce { counters.repeatedRefreshes += 1 }
            return nil
        }
        // Oldest due frame; skip ahead while more than the backlog would stay due behind it
        let skipped = phase == nil
            ? max(0, dueCount - 1 - (unbuffered && pacer.interval < Self.fasterStream * refresh ? 0 : backlog))
            : phaseLockedSkip(dueCount: dueCount, horizon: horizon, refresh: refresh, missed: missed, catchingUp: catchingUp)
        let entry = entries[skipped]
        entries.removeSubrange(0...skipped)
        counters.dropped += skipped
        counters.presented += 1
        counters.accumulatedLateness += max(0, presentation - entry.due)
        shownOnce = true
        if phase != nil {
            // A drop caught the queue up; still behind after it, a new second starts
            if skipped > 0 { behindSince = nil }
            behindSince = entry.due <= horizon - refresh ? behindSince ?? presentation : nil
        }
        return (entry.frame, entry.due)
    }

    /// Phase lock: the due frames to drop before the one shown.
    private func phaseLockedSkip(dueCount: Int, horizon: Double, refresh: Double, missed: Bool, catchingUp: Bool) -> Int {
        if missed {
            // The display link skipped refreshes: the frames whose refresh went by are not shown late
            var passed = 0
            while passed < dueCount - 1, entries[passed].due <= horizon - refresh { passed += 1 }
            return passed
        }
        // A second behind: the newest due frame is shown in its own refresh
        return catchingUp ? dueCount - 1 : max(0, dueCount - 1 - backlog)
    }

    /// A refresh at which nothing is drawn (the GPU is still busy, or phase lock waited for a frame that did not come in
    /// time): the frames wait and the previous picture stays.
    public mutating func idle(at presentation: Double) {
        counters.refreshes += 1
        counters.waitingSum += entries.count
        counters.peakWaiting = max(counters.peakWaiting, entries.count)
        if phase != nil { lastPresentation = presentation }
        if shownOnce { counters.repeatedRefreshes += 1 }
    }

    /// Drops the waiting frames and the pacing schedule (a new stream or after a decoder error); the counters stay.
    public mutating func flush() {
        entries.removeAll(keepingCapacity: true)
        pacer.reset()
        phase?.reset()
        lastPresentation = nil
        behindSince = nil
        shownOnce = false
    }

    /// Forgets the peak, so the next reading shows the peak of its own window.
    public mutating func resetPeak() {
        counters.peakWaiting = 0
    }
}
