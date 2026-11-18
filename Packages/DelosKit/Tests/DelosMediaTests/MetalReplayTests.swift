import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing
@testable import DelosMedia

/// The replay harness: the fixtures' frames go into the Metal renderer's pipeline at times given by a list of arrival
/// times, on a virtual clock, against a virtual display. VideoToolbox really decodes every frame and Metal really draws
/// every refresh's picture (into an offscreen texture); only the clock and the display's refreshes are made up, so the
/// result does not depend on how busy the machine is.
struct PipelineRun {
    var shown: [MetalPipeline.PresentedFrame] = []
    var counters: VideoPresentationCounters?
    var pixels: (width: Int, height: Int, bytes: [UInt8])?
    var intervals: [Double] { zip(shown, shown.dropFirst()).map { $1.presentation - $0.presentation } }
}

/// A clock the replay moves by hand.
final class VirtualClock: Sendable {
    private let value = Mutex(0.0)

    func set(_ time: Double) { value.withLock { $0 = time } }

    var reading: MetalPipeline.Clock { { [self] in value.withLock { $0 } } }
}

enum PipelineReplay {
    /// The display link calls back `lead` refreshes before the picture appears.
    static func run(
        fixture: String, codec: VideoCodec, arrivals: [Double], pacing: FramePacing, fps: Int, display: VirtualDisplay,
        lead: Double = 1
    ) throws -> PipelineRun {
        let clock = VirtualClock()
        let pipeline = try #require(MetalPipeline(pacing: pacing, fps: fps, clock: clock.reading))
        defer { pipeline.invalidate() }
        let shown = Mutex<[MetalPipeline.PresentedFrame]>([])
        pipeline.observePresented { frame in shown.withLock { $0.append(frame) } }
        var stream = try ReplayStream(fixture: fixture, codec: codec)
        var next = 0
        for tick in display.refreshes(in: (arrivals.first ?? 0)...((arrivals.last ?? 0) + 0.1)) {
            let callback = tick - lead * display.refresh
            while next < arrivals.count, arrivals[next] <= callback {
                clock.set(arrivals[next])
                #expect(pipeline.enqueue(try stream.sample(next)))
                // The decoded picture arrives on the virtual clock's time, not after it moved on
                pipeline.waitForDecodes()
                next += 1
            }
            clock.set(callback)
            pipeline.tick(RefreshTick(presentation: tick, refresh: display.refresh, drawable: nil))
        }
        return PipelineRun(shown: shown.withLock { $0 }, counters: pipeline.counters(), pixels: pipeline.offscreenPixels())
    }
}

/// The display layer as `AVSampleBufferDisplayLayer` documents itself, for the comparison: each frame gets the time
/// ``FramePacer`` gives it, the layer shows it at the first refresh at or after that time, and when the times of several
/// frames have passed it shows the newest and drops the others. A model, not a measurement: the layer's own presentation
/// cannot be observed without a display (a headless layer takes every frame and reports no lateness).
enum DisplayLayerModel {
    static func run(arrivals: [Double], pacing: FramePacing, fps: Int, display: VirtualDisplay) -> QueueRun {
        var pacer = FramePacer(pacing: pacing, fps: fps)
        var waiting: [(frame: Int, time: Double)] = []
        var run = QueueRun()
        var next = 0
        var shownOnce = false
        for tick in display.refreshes(in: (arrivals.first ?? 0)...((arrivals.last ?? 0) + 0.1)) {
            while next < arrivals.count, arrivals[next] <= tick - display.refresh {
                waiting.append((next, pacer.presentationTime(arrival: arrivals[next]) ?? arrivals[next]))
                run.counters.pushed += 1
                next += 1
            }
            run.counters.refreshes += 1
            guard let last = waiting.lastIndex(where: { $0.time <= tick }) else {
                if shownOnce { run.counters.repeatedRefreshes += 1 }
                continue
            }
            run.counters.dropped += last
            let frame = waiting[last]
            waiting.removeSubrange(0...last)
            run.counters.presented += 1
            run.counters.accumulatedLateness += tick - frame.time
            run.shown.append((frame.frame, frame.time, tick))
            shownOnce = true
        }
        return run
    }
}

@Suite struct MetalReplayTests {
    let refresh = 1.0 / 120

    @Test(arguments: ReplayStream.fixtures)
    func everyFixtureReplaysAt120FPSWithJitterThroughRealDecodingAndDrawing(name: String, codec: VideoCodec) throws {
        guard ReplayStream.isDecodable(codec) else { return }
        let arrivals = QueueReplay.arrivals(count: 240, fps: 120, jitter: 0.003)
        let display = VirtualDisplay(refresh: refresh, phase: 0.0021)
        let run = try PipelineReplay.run(
            fixture: name, codec: codec, arrivals: arrivals, pacing: .balanced, fps: 120, display: display)
        // The pipeline shows what the queue alone would: decoding and drawing change nothing about the pacing
        let model = QueueReplay.run(arrivals: arrivals, pacing: .balanced, fps: 120, display: display)
        #expect(run.shown.map(\.sequence) == model.shown.map(\.frame))
        #expect(zip(run.shown, model.shown).allSatisfy { abs($0.presentation - $1.presentation) < 1e-9 })
        // Everything was decoded and every frame is accounted for as shown or dropped
        let counters = try #require(run.counters)
        #expect(counters.decodedFrames == 240)
        #expect(counters.totalFrames == run.shown.count + counters.droppedFrames)
        #expect(counters.totalFrames == 240)
        #expect((counters.accumulatedDecodeSeconds ?? 0) > 0)
        // A picture was drawn: the pattern is not black
        let pixels = try #require(run.pixels)
        #expect(pixels.width == 64 && pixels.height == 64)
        #expect(pixels.bytes.reduce(0) { $0 + Int($1) } > 64 * 64 * 20)
        // Order is kept, and the intervals are one refresh for nearly every frame
        #expect(run.shown.map(\.sequence) == run.shown.map(\.sequence).sorted())
        let exact = run.intervals.filter { abs($0 - refresh) < 1e-9 }.count
        #expect(Double(exact) / Double(run.intervals.count) > 0.9)
    }

    @Test func aPictureThatIsNotAKeyFrameWaitsForOne() throws {
        let pipeline = try #require(MetalPipeline(pacing: .latency, fps: 60))
        defer { pipeline.invalidate() }
        var stream = try ReplayStream(fixture: "frames.h264", codec: .h264)
        // The first sample of a stream sets its format, so it is made first
        let key = try stream.sample(0)
        let delta = try stream.sample(1)
        // Nothing to decode a P frame against yet: refused, so the host is asked for a key frame
        #expect(!pipeline.enqueue(delta))
        #expect(pipeline.enqueue(key))
        #expect(pipeline.enqueue(delta))
        pipeline.waitForDecodes()
        #expect(pipeline.counters().decodedFrames == 2)
        // After a flush (a new stream) it waits for a key frame again
        pipeline.flush()
        #expect(!pipeline.enqueue(delta))
    }

    @Test func aRefreshWithoutANewPictureDrawsNothing() throws {
        let clock = VirtualClock()
        let pipeline = try #require(MetalPipeline(pacing: .latency, fps: 60, clock: clock.reading))
        defer { pipeline.invalidate() }
        let drawn = Mutex(0)
        pipeline.observePresented { _ in drawn.withLock { $0 += 1 } }
        var stream = try ReplayStream(fixture: "frames.h264", codec: .h264)
        clock.set(1)
        #expect(pipeline.enqueue(try stream.sample(0)))
        pipeline.waitForDecodes()
        pipeline.tick(RefreshTick(presentation: 1.02, refresh: refresh, drawable: nil))
        pipeline.tick(RefreshTick(presentation: 1.03, refresh: refresh, drawable: nil))
        pipeline.tick(RefreshTick(presentation: 1.04, refresh: refresh, drawable: nil))
        #expect(drawn.withLock { $0 } == 1)
        let counters = pipeline.counters()
        #expect(counters.refreshes == 3)
        #expect(counters.repeatedRefreshes == 2)
        // The watchdog's reading (`presentationCounters`): one picture shown, none dropped
        #expect(counters.totalFrames == 1 && counters.droppedFrames == 0 && counters.decodedFrames == 1)
    }

    // MARK: Comparison with the display layer

    /// The Metal renderer's queue against the display layer as modelled, for the same arrivals, over eight phases of the
    /// stream's clock against the display's (the two clocks drift, so every phase comes round). The numbers are printed;
    /// the assertions are the design's promises: no more dropped frames, no more judder (an interval that is not one
    /// refresh) and a delay that is at most one refresh longer, which is the price of not dropping.
    @Test(arguments: [0.001, 0.002, 0.003, 0.004], FramePacing.allCases)
    func theQueueDropsAndJuddersLessThanTheDisplayLayerModelOn120HzDisplays(jitter: Double, pacing: FramePacing) {
        let arrivals = QueueReplay.arrivals(count: 1200, fps: 120, jitter: jitter, seed: 11)
        let result = Self.compare(arrivals: arrivals, pacing: pacing, fps: 120, refresh: refresh)
        print(result.row("120 fps on 120 Hz, jitter ±\(Int(jitter * 1000)) ms, \(pacing)"))
        #expect(result.metal.dropped <= result.layer.dropped)
        #expect(result.metal.judder <= result.layer.judder + 8)
        #expect(result.metal.lateMilliseconds <= result.layer.lateMilliseconds + refresh * 1000 + 0.01)
    }

    @Test(arguments: FramePacing.allCases)
    func aStreamWithStallsAndCatchUpBurstsIsNoWorseThanTheLayerModel(pacing: FramePacing) {
        var arrivals = QueueReplay.arrivals(count: 1200, fps: 120, jitter: 0.001, seed: 5)
        // Every 40th frame is held back 25 ms and delivered with the next two (a bunching router)
        for i in stride(from: 40, to: 1190, by: 40) {
            let release = arrivals[i + 2]
            for j in i...(i + 2) { arrivals[j] = release + Double(j - i) * 0.0001 }
        }
        let result = Self.compare(arrivals: arrivals, pacing: pacing, fps: 120, refresh: refresh)
        print(result.row("120 fps on 120 Hz, bursts every 40 frames, \(pacing)"))
        #expect(result.metal.dropped <= result.layer.dropped + 8)
        #expect(result.metal.judder <= result.layer.judder + 8)
    }

    @Test(arguments: FramePacing.allCases)
    func a120FPSStreamOnA60HzDisplayShowsTheDisplaysRateAsTheLayerModelDoes(pacing: FramePacing) {
        let arrivals = QueueReplay.arrivals(count: 1200, fps: 120, jitter: 0.002, seed: 3)
        let result = Self.compare(arrivals: arrivals, pacing: pacing, fps: 120, refresh: 1.0 / 60)
        print(result.row("120 fps on 60 Hz, jitter ±2 ms, \(pacing)"))
        // About half of the frames are shown, and the delay stays within a refresh of the model's
        #expect(abs(Double(result.metal.shown) - Double(result.layer.shown)) <= 8 * 24)
        #expect(result.metal.lateMilliseconds <= result.layer.lateMilliseconds + 1000.0 / 60 + 0.01)
    }

    struct Totals {
        var shown = 0
        var dropped = 0
        var judder = 0
        var lateSum = 0.0
        var intervals = 0
        var lateMilliseconds: Double { shown > 0 ? lateSum * 1000 / Double(shown) : 0 }

        mutating func add(_ run: QueueRun, refresh: Double, fps: Int) {
            shown += run.counters.presented
            dropped += run.counters.dropped
            lateSum += run.counters.accumulatedLateness
            // Judder: an interval a refresh or more away from the cadence the stream and the display allow (the slower of
            // the two), a frame that stayed on screen too long or too short
            let ideal = max(refresh, 1.0 / Double(fps))
            judder += run.intervals.filter { abs($0 - ideal) > 0.5 * refresh }.count
            intervals += run.intervals.count
        }
    }

    struct Comparison {
        var metal = Totals()
        var layer = Totals()

        func row(_ label: String) -> String {
            func line(_ name: String, _ t: Totals) -> String {
                String(
                    format: "  %@ shown %5d dropped %4d judder %4d of %5d intervals, delay past its time %5.2f ms",
                    name, t.shown, t.dropped, t.judder, t.intervals, t.lateMilliseconds)
            }
            return "REPLAY \(label)\n\(line("metal", metal))\n\(line("layer", layer))"
        }
    }

    static func compare(arrivals: [Double], pacing: FramePacing, fps: Int, refresh: Double) -> Comparison {
        var comparison = Comparison()
        for phase in 0..<8 {
            let display = VirtualDisplay(refresh: refresh, phase: Double(phase) * refresh / 8)
            comparison.metal.add(QueueReplay.run(arrivals: arrivals, pacing: pacing, fps: fps, display: display), refresh: refresh, fps: fps)
            comparison.layer.add(DisplayLayerModel.run(arrivals: arrivals, pacing: pacing, fps: fps, display: display), refresh: refresh, fps: fps)
        }
        return comparison
    }
}

/// Presentation receipts, not scheduled refreshes, drive the counters consumed by the FPS overlay and watchdog.
@Suite struct FramePresentationLedgerTests {
    @Test func submittedAndGPUCompletedAreNotPresented() throws {
        var ledger = FramePresentationLedger()
        let submitted = ledger.submitted(sequence: 7, due: 1.001, decodedAt: 1)
        let ticket = try #require(submitted)
        #expect(ledger.shown == 0)
        ledger.gpuCompleted(ticket: ticket, succeeded: true)
        #expect(ledger.shown == 0 && ledger.dropped == 0)
        let presented = ledger.complete(ticket: ticket, at: 1.025)
        let confirmed = try #require(presented)
        #expect(confirmed.sequence == 7 && confirmed.decodedAt == 1)
        #expect(ledger.shown == 1)
        #expect(abs(ledger.accumulatedDelay - 0.024) < 1e-12)
        #expect(ledger.complete(ticket: ticket, at: 1.03) == nil)
        #expect(ledger.shown == 1)
    }

    @Test(arguments: [false, true])
    func GPUErrorAndSkippedFeedbackResolveOneFrameOnly(feedbackFirst: Bool) throws {
        var ledger = FramePresentationLedger()
        let submitted = ledger.submitted(sequence: 0, due: 1, decodedAt: 1)
        let ticket = try #require(submitted)
        if feedbackFirst { #expect(ledger.complete(ticket: ticket, at: 0) == nil) }
        ledger.gpuCompleted(ticket: ticket, succeeded: false)
        #expect(ledger.complete(ticket: ticket, at: nil) == nil)
        #expect(ledger.shown == 0 && ledger.dropped == 1)
        #expect(ledger.inFlight == 0)
    }

    @Test func encodingFailuresAndAnimationRedrawsAreNotNewPictures() throws {
        var ledger = FramePresentationLedger()
        ledger.failedToEncode(newFrame: true)
        ledger.failedToEncode(newFrame: false)
        #expect(ledger.dropped == 1 && ledger.shown == 0)
        let ticket = ledger.submitted(sequence: 0, due: nil, decodedAt: 1)
        #expect(ticket == nil)
        ledger.gpuCompleted(ticket: ticket, succeeded: true)
        #expect(ledger.shown == 0 && ledger.dropped == 1)
    }

    @Test func aFlushDoesNotPretendOutstandingGPUWorkFinished() throws {
        var ledger = FramePresentationLedger()
        let firstTicket = ledger.submitted(sequence: 0, due: 1, decodedAt: 1)
        let first = try #require(firstTicket)
        let secondTicket = ledger.submitted(sequence: 1, due: 1.008, decodedAt: 1.008)
        let second = try #require(secondTicket)
        #expect(!ledger.canDraw)
        ledger.flush()
        #expect(!ledger.canDraw)
        #expect(ledger.complete(ticket: first, at: 1.025) == nil)
        ledger.gpuCompleted(ticket: first, succeeded: true)
        #expect(ledger.canDraw && ledger.inFlight == 1)
        ledger.gpuCompleted(ticket: second, succeeded: false)
        #expect(ledger.shown == 0 && ledger.dropped == 0 && ledger.inFlight == 0)
        let freshTicket = ledger.submitted(sequence: 2, due: 2, decodedAt: 2)
        let fresh = try #require(freshTicket)
        #expect(fresh != first && fresh != second)
        #expect(ledger.complete(ticket: fresh, at: 2.016)?.sequence == 2)
        #expect(ledger.shown == 1)
    }
}

@Suite struct FrameDrawingTimingTests {
    @Test func GPUCanFinishAfterTheCPUDeadlineWithoutMissingPresentation() {
        let timing = FrameDrawingTiming(callback: 1, presentation: 1.016, submissionDeadline: 1.008)
        #expect(!timing.submittedLate(at: 1.001))
        #expect(!timing.gpuFinishedLate(at: 1.012))
        #expect(timing.gpuFinishedLate(at: 1.017))
    }

    @Test func CPUSubmissionCanBeLateWhileGPUCompletionIsOnTime() {
        let timing = FrameDrawingTiming(callback: 1, presentation: 1.016, submissionDeadline: 1.008)
        #expect(timing.submittedLate(at: 1.009))
        #expect(!timing.gpuFinishedLate(at: 1.014))
        #expect(!timing.submittedLate(at: 1.008))
        #expect(!timing.gpuFinishedLate(at: 1.016))
        let unknown = FrameDrawingTiming(callback: 1, presentation: 1.016, submissionDeadline: nil)
        #expect(!unknown.submittedLate(at: 1.02))
        #expect(unknown.gpuFinishedLate(at: 1.02))
    }
}

@Suite struct MetalPresentationLifecycleTests {
    @Test(arguments: [false, true])
    func aFlushDiscardsOldPicturesAndInvalidationRefusesNewOnes(asynchronous: Bool) throws {
        let clock = VirtualClock()
        let pipeline = try #require(MetalPipeline(
            pacing: .latency, fps: 120, options: VideoRenderOptions(asyncDecode: asynchronous), clock: clock.reading))
        defer { pipeline.invalidate() }
        var stream = try ReplayStream(fixture: "frames.hevc", codec: .hevc)
        let key = try stream.sample(0)
        let shown = Mutex<[Int]>([])
        pipeline.observePresented { frame in shown.withLock { $0.append(frame.sequence) } }
        clock.set(1)
        #expect(pipeline.enqueue(key))
        pipeline.waitForDecodes()
        pipeline.flush()
        pipeline.tick(RefreshTick(presentation: 1.016, refresh: 1.0 / 120, drawable: nil))
        #expect(pipeline.counters().totalFrames == 0)
        #expect(shown.withLock { $0 }.isEmpty)

        clock.set(2)
        #expect(pipeline.enqueue(key))
        pipeline.waitForDecodes()
        pipeline.tick(RefreshTick(presentation: 2.016, refresh: 1.0 / 120, drawable: nil))
        #expect(shown.withLock { $0 } == [1])
        let before = pipeline.counters()
        #expect(before.totalFrames == 1 && before.decodedFrames == 2)
        #expect(before.renderLatency == nil, "offscreen completion is not physical display latency")
        pipeline.invalidate()
        #expect(!pipeline.enqueue(key))
        pipeline.tick(RefreshTick(presentation: 2.024, refresh: 1.0 / 120, drawable: nil))
        #expect(pipeline.counters().totalFrames == before.totalFrames)
        #expect(shown.withLock { $0 } == [1])
    }
}
