import Testing
@testable import DelosMedia

/// A virtual clock: the tests run a stream against a display that refreshes every `refresh` seconds, without a wall clock.
struct VirtualDisplay {
    var refresh: Double
    var phase = 0.0

    /// The refresh times in `range`.
    func refreshes(in range: ClosedRange<Double>) -> [Double] {
        var times: [Double] = []
        var k = ((range.lowerBound - phase) / refresh).rounded(.up)
        while phase + k * refresh <= range.upperBound {
            times.append(phase + k * refresh)
            k += 1
        }
        return times
    }
}

/// A seeded random sequence, so a "jittered" run is the same run every time.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// Uniform in `-bound...bound`.
    mutating func jitter(_ bound: Double) -> Double { (next() * 2 - 1) * bound }
}

/// What a replay of arrival times against refreshes showed.
struct QueueRun {
    var shown: [(frame: Int, due: Double, presentation: Double)] = []
    var counters = FrameQueueCounters()

    /// Seconds between the refreshes that showed a new frame.
    var intervals: [Double] { zip(shown, shown.dropFirst()).map { $1.presentation - $0.presentation } }
}

enum QueueReplay {
    /// Pushes frame i at `arrivals[i]` and asks for a frame at every refresh of `display`, in time order. The display
    /// link calls back `lead` refreshes before the picture appears; it skips the refreshes numbered in `lost` (counted
    /// from the first one).
    static func run(
        arrivals: [Double], pacing: FramePacing, fps: Int, display: VirtualDisplay, capacity: Int = 4, lead: Double = 1,
        lost: Set<Int> = []
    ) -> QueueRun {
        var queue = FrameQueue<Int>(pacing: pacing, fps: fps, capacity: capacity)
        var run = QueueRun()
        let end = (arrivals.last ?? 0) + 0.1
        let ticks = display.refreshes(in: (arrivals.first ?? 0)...end)
        var next = 0
        for (index, tick) in ticks.enumerated() where !lost.contains(index) {
            // Frames that arrived before this refresh's callback
            while next < arrivals.count, arrivals[next] <= tick - lead * display.refresh {
                queue.push(next, arrival: arrivals[next])
                next += 1
            }
            if let taken = queue.take(at: tick, refresh: display.refresh) {
                run.shown.append((taken.frame, taken.due, tick))
            }
        }
        run.counters = queue.counters
        return run
    }

    /// 120 fps arrivals starting at `start`, each displaced by up to `jitter` seconds (never out of order).
    static func arrivals(count: Int, fps: Int, start: Double = 1, jitter: Double, seed: UInt64 = 7) -> [Double] {
        var random = SeededRandom(seed: seed)
        var last = -Double.infinity
        return (0..<count).map { i in
            let time = max(start + Double(i) / Double(fps) + random.jitter(jitter), last + 0.000_05)
            last = time
            return time
        }
    }
}

@Suite struct FrameQueueTests {
    let refresh = 1.0 / 120

    @Test func theLowestLatencyModeShowsFramesInOrderWithOneFrameOfBacklog() {
        var queue = FrameQueue<Int>(pacing: .latency, fps: 120)
        // Two frames landed in one refresh: the older is shown, the newer waits for the next refresh
        queue.push(1, arrival: 1.000)
        queue.push(2, arrival: 1.002)
        #expect(queue.take(at: 1.006, refresh: refresh)?.frame == 1)
        #expect(queue.take(at: 1.006 + refresh, refresh: refresh)?.frame == 2)
        #expect(queue.counters.dropped == 0)
        // Three wait: one more than the backlog, so the oldest is skipped
        for frame in 3...5 { queue.push(frame, arrival: 1.02) }
        #expect(queue.take(at: 1.03, refresh: refresh)?.frame == 4)
        #expect(queue.counters.dropped == 1)
        #expect(queue.counters.presented == 3)
        #expect(queue.waiting == 1)
    }

    @Test func aBacklogDrainsAtARefreshWithoutANewFrame() {
        for pacing in [FramePacing.latency, .balanced, .smoothness] {
            var queue = FrameQueue<Int>(pacing: pacing, fps: 120)
            queue.push(1, arrival: 1.000)
            queue.push(2, arrival: 1.002)
            #expect(queue.take(at: 1.1, refresh: refresh)?.frame == 1, "\(pacing)")
            // No frame arrived for this refresh: the one that waited is shown instead of the previous picture again
            #expect(queue.take(at: 1.1 + refresh, refresh: refresh)?.frame == 2, "\(pacing)")
            #expect(queue.counters.repeatedRefreshes == 0, "\(pacing)")
            #expect(queue.take(at: 1.1 + 2 * refresh, refresh: refresh) == nil, "\(pacing)")
            #expect(queue.counters.repeatedRefreshes == 1, "\(pacing)")
        }
    }

    /// One frame arrives per refresh while one more waits from the start; each is shown two refreshes after it arrived.
    private func standingBacklog(_ pacing: FramePacing, refreshes: Int) -> (shown: [Int], dropped: Int) {
        var queue = FrameQueue<Int>(pacing: pacing, fps: 120)
        queue.push(0, arrival: 0.999)
        var shown: [Int] = []
        for tick in 0..<refreshes {
            let arrival = 1 + Double(tick) * refresh
            queue.push(tick + 1, arrival: arrival)
            if let taken = queue.take(at: arrival + 2 * refresh, refresh: refresh) { shown.append(taken.frame) }
        }
        return (shown, queue.counters.dropped)
    }

    @Test func aUsefulJitterReserveIsNotDiscardedOnATimer() {
        for pacing in FramePacing.allCases {
            let run = standingBacklog(pacing, refreshes: 600)
            #expect(run.shown == Array(0..<600), "\(pacing)")
            #expect(run.dropped == 0, "\(pacing)")
        }
    }

    @Test func latencyDoesNotAddAScheduledBufferToASteadyStream() {
        var queue = FrameQueue<Int>(pacing: .latency, fps: 120)
        for frame in 0..<600 {
            let arrival = 1 + Double(frame) * refresh
            #expect(queue.push(frame, arrival: arrival) == arrival)
            #expect(queue.take(at: arrival, refresh: refresh)?.frame == frame)
            #expect(queue.waiting == 0)
        }
        #expect(queue.counters.dropped == 0)
        #expect(queue.counters.repeatedRefreshes == 0)
    }
    @Test func aStreamFasterThanTheDisplayKeepsNoBacklogInTheModesWithoutABuffer() {
        // Warp: 240 fps on a 120 Hz display, two frames per refresh: the newer one is shown.
        var queue = FrameQueue<Int>(pacing: .warp, fps: 240)
        queue.push(1, arrival: 1.000)
        queue.push(2, arrival: 1.004)
        #expect(queue.take(at: 1.01, refresh: refresh)?.frame == 2)
        #expect(queue.counters.dropped == 1)
        #expect(queue.waiting == 0)
    }

    @Test func theSmoothestModeKeepsTwoFramesOfBacklog() {
        var queue = FrameQueue<Int>(pacing: .smoothness, fps: 120, capacity: 6)
        for i in 0..<5 { queue.push(i, arrival: 1 + Double(i) * 0.0005) }
        // Five frames due: one is shown, two may wait, the two oldest are skipped
        #expect(queue.take(at: 2, refresh: refresh)?.frame == 2)
        #expect(queue.waiting == 2)
        #expect(queue.counters.dropped == 2)
    }

    @Test func aRefreshThatCannotDrawKeepsTheFramesAndThePreviousPicture() {
        var queue = FrameQueue<Int>(pacing: .latency, fps: 120)
        queue.push(1, arrival: 1)
        #expect(queue.take(at: 1.01, refresh: refresh)?.frame == 1)
        queue.push(2, arrival: 1.012)
        queue.idle()
        #expect(queue.waiting == 1)
        #expect(queue.counters.refreshes == 2)
        #expect(queue.counters.repeatedRefreshes == 1)
        #expect(queue.counters.waitingSum == 2)
        #expect(queue.take(at: 1.03, refresh: refresh)?.frame == 2)
    }

    @Test func aFrameThatIsNotDueYetStaysForALaterRefresh() {
        var queue = FrameQueue<Int>(pacing: .balanced, fps: 120)
        // Due one frame after it arrived
        queue.push(1, arrival: 1)
        #expect(queue.take(at: 1 + 0.4 * refresh, refresh: refresh) == nil)
        #expect(queue.take(at: 1 + refresh, refresh: refresh)?.frame == 1)
    }

    @Test func aFrameIsShownAtTheRefreshNearestToItsTime() {
        var queue = FrameQueue<Int>(pacing: .latency, fps: 120)
        queue.push(1, arrival: 10)
        // Latency mode: due at arrival; a refresh half a frame before it already shows it, one more than that does not
        #expect(queue.take(at: 10 - 0.6 * refresh, refresh: refresh) == nil)
        #expect(queue.take(at: 10 - 0.4 * refresh, refresh: refresh)?.frame == 1)
    }

    @Test func twoDueFramesAreShownOneAfterTheOtherInsteadOfDroppingOne() {
        var queue = FrameQueue<Int>(pacing: .balanced, fps: 120)
        queue.push(1, arrival: 1)
        queue.push(2, arrival: 1.001)
        // Both are due at the second refresh: the older is shown, the newer one waits for the next refresh
        #expect(queue.take(at: 1 + 2 * refresh, refresh: refresh)?.frame == 1)
        #expect(queue.take(at: 1 + 3 * refresh, refresh: refresh)?.frame == 2)
        #expect(queue.counters.dropped == 0)
    }

    @Test func moreThanOneFrameOfBacklogSkipsAhead() {
        var queue = FrameQueue<Int>(pacing: .balanced, fps: 120, capacity: 6)
        for i in 0..<4 { queue.push(i, arrival: 1 + Double(i) * 0.0005) }
        // Four frames due: one is shown, one may wait, the two oldest are skipped
        let taken = queue.take(at: 2, refresh: refresh)
        #expect(taken?.frame == 2)
        #expect(queue.waiting == 1)
        #expect(queue.counters.dropped == 2)
    }

    @Test func aFullQueueDropsItsOldestFrame() {
        var queue = FrameQueue<Int>(pacing: .smoothness, fps: 120, capacity: 2)
        for i in 0..<5 { queue.push(i, arrival: Double(i) * 0.001) }
        #expect(queue.waiting == 2)
        #expect(queue.counters.dropped == 3)
        #expect(queue.counters.pushed == 5)
    }

    @Test func refreshesWithoutAFrameAreCountedOnlyAfterTheFirstFrameWasShown() {
        var queue = FrameQueue<Int>(pacing: .latency, fps: 60)
        #expect(queue.take(at: 1, refresh: refresh) == nil)
        #expect(queue.counters.repeatedRefreshes == 0)
        queue.push(1, arrival: 1.5)
        #expect(queue.take(at: 1.5 + refresh, refresh: refresh)?.frame == 1)
        #expect(queue.take(at: 1.5 + 2 * refresh, refresh: refresh) == nil)
        #expect(queue.take(at: 1.5 + 3 * refresh, refresh: refresh) == nil)
        #expect(queue.counters.repeatedRefreshes == 2)
        #expect(queue.counters.refreshes == 4)
    }

    @Test func latenessIsHowLongAfterItsTimeTheFrameWasShown() {
        var queue = FrameQueue<Int>(pacing: .latency, fps: 120)
        queue.push(1, arrival: 5)
        _ = queue.take(at: 5.004, refresh: refresh)
        #expect(abs(queue.counters.accumulatedLateness - 0.004) < 1e-12)
        // Shown early (within the tolerance): not negative
        queue.push(2, arrival: 6)
        _ = queue.take(at: 5.999, refresh: refresh)
        #expect(abs(queue.counters.accumulatedLateness - 0.004) < 1e-12)
    }

    @Test func aFlushDropsWaitingFramesAndTheScheduleButKeepsTheCounters() {
        var queue = FrameQueue<Int>(pacing: .balanced, fps: 120)
        queue.push(1, arrival: 1)
        queue.push(2, arrival: 1.001)
        queue.flush()
        #expect(queue.waiting == 0)
        #expect(queue.counters.pushed == 2)
        // The schedule starts again from the next frame instead of continuing after the flushed ones
        #expect(queue.push(3, arrival: 1.002) == 1.002 + refresh)
    }

    @Test func thePeakIsTheLargestWaitSinceTheLastReset() {
        var queue = FrameQueue<Int>(pacing: .smoothness, fps: 120)
        queue.push(1, arrival: 1)
        queue.push(2, arrival: 1)
        _ = queue.take(at: 1.001, refresh: refresh)
        #expect(queue.counters.peakWaiting == 2)
        queue.resetPeak()
        // Both are due now: one is shown, the other waits (one frame of backlog is allowed)
        #expect(queue.take(at: 2, refresh: refresh)?.frame == 1)
        #expect(queue.counters.peakWaiting == 2)
        queue.resetPeak()
        _ = queue.take(at: 3, refresh: refresh)
        #expect(queue.counters.peakWaiting == 1)
    }

    // MARK: Replays against a virtual display

    @Test func aSteady120FPSStreamOnA120HzDisplayShowsEveryFrameOnceInOrder() {
        let arrivals = QueueReplay.arrivals(count: 240, fps: 120, jitter: 0)
        for pacing in FramePacing.allCases {
            let run = QueueReplay.run(arrivals: arrivals, pacing: pacing, fps: 120, display: VirtualDisplay(refresh: refresh, phase: 0.0031))
            #expect(run.shown.map(\.frame) == Array(0..<240), "\(pacing)")
            #expect(run.counters.dropped == 0, "\(pacing)")
            // One frame per refresh, so every interval is one refresh
            #expect(run.intervals.allSatisfy { abs($0 - refresh) < 1e-9 }, "\(pacing)")
        }
    }

    @Test func jitterIsAbsorbedByTheBufferInTheBalancedMode() {
        // ±3 ms of network jitter on 8.3 ms frames
        let arrivals = QueueReplay.arrivals(count: 600, fps: 120, jitter: 0.003)
        let run = QueueReplay.run(arrivals: arrivals, pacing: .balanced, fps: 120, display: VirtualDisplay(refresh: refresh, phase: 0.002))
        // Order is kept, almost nothing is dropped, and the intervals are mostly one refresh
        #expect(run.shown.map(\.frame) == run.shown.map(\.frame).sorted())
        #expect(run.counters.dropped <= 6)
        let exact = run.intervals.filter { abs($0 - refresh) < 1e-9 }.count
        #expect(Double(exact) / Double(run.intervals.count) > 0.9)
        // No picture stays longer than two refreshes
        #expect(run.intervals.allSatisfy { $0 < 2.5 * refresh })
    }

    @Test func aStallThatCatchesUpDoesNotLeaveALastingDelay() {
        var arrivals = QueueReplay.arrivals(count: 360, fps: 120, jitter: 0)
        // 80 ms stall after frame 120: frames 120…129 arrive together afterwards, the rest as before
        let stalledUntil = arrivals[120] + 0.08
        for i in 120..<130 { arrivals[i] = stalledUntil + Double(i - 120) * 0.0001 }
        let run = QueueReplay.run(arrivals: arrivals, pacing: .balanced, fps: 120, display: VirtualDisplay(refresh: refresh, phase: 0.001))
        // After the catch-up the display shows frames as late as at the start (the pacer's one frame + the refresh's wait)
        let late = run.shown.suffix(60).map { $0.presentation - arrivals[$0.frame] }
        #expect(late.allSatisfy { $0 < 3 * refresh })
        #expect(run.counters.dropped >= 5, "the burst's oldest frames are skipped")
    }

    @Test func aStreamFasterThanTheDisplayShowsTheNewestFramesAtTheDisplaysRate() {
        // 240 fps stream on a 120 Hz display
        let arrivals = QueueReplay.arrivals(count: 480, fps: 240, jitter: 0)
        let run = QueueReplay.run(arrivals: arrivals, pacing: .balanced, fps: 240, display: VirtualDisplay(refresh: refresh, phase: 0.0017))
        #expect(abs(Double(run.counters.presented) - 240) <= 3)
        #expect(run.counters.dropped >= 235)
        // The delay is bounded and does not grow once the backlog formed (the last frames, after the stream ended, drain)
        let delays = run.shown.dropFirst(10).map { $0.presentation - arrivals[$0.frame] }
        #expect(delays.dropLast(5).allSatisfy { $0 < 0.016 })
        #expect(delays.dropLast(5).suffix(60).max()! <= delays[60..<120].max()! + 0.001)
    }

    @Test func aSlowStreamOnAFastDisplayRepeatsTheRefreshesBetweenFrames() {
        // 60 fps on 120 Hz: every other refresh shows the previous picture again
        let arrivals = QueueReplay.arrivals(count: 120, fps: 60, jitter: 0)
        let run = QueueReplay.run(arrivals: arrivals, pacing: .latency, fps: 60, display: VirtualDisplay(refresh: refresh, phase: 0.001))
        #expect(run.counters.dropped == 0)
        #expect(run.shown.count == 120)
        #expect(abs(Double(run.counters.repeatedRefreshes) - 120) <= 14, "the refreshes after the last frame included")
        #expect(run.intervals.allSatisfy { abs($0 - 2 * refresh) < 1e-9 })
    }
}
