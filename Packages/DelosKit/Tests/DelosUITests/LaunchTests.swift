import CoreMedia
import DelosData
import DelosMedia
import Foundation
import QuartzCore
import Synchronization
import Testing
@testable import DelosUI

private func ms(_ value: Int64) -> Int64 { value * 1_000_000 }

private func advance(_ queue: inout LaunchStageQueue, _ now: Int64) -> Bool { queue.advance(at: now) }

@Suite struct LaunchStageQueueTests {
    @Test func anEmptyQueueHasNoLineOrTimeAndIsAlreadyDrained() {
        var queue = LaunchStageQueue()
        #expect(queue.currentLine == nil)
        #expect(queue.remainingMillis(at: 0) == 0)
        #expect(queue.isDrained(at: 0))
        #expect(!advance(&queue, ms(10_000)))
        #expect(queue.currentLine == nil)
    }

    @Test func theFirstQueuedLineStartsItsTimeOnlyWhenPresented() {
        var queue = LaunchStageQueue()
        queue.enqueue("first")
        #expect(queue.currentLine == nil)
        #expect(queue.remainingMillis(at: ms(50)) == 0)
        #expect(!queue.isDrained(at: ms(50)))
        #expect(advance(&queue, ms(50)))
        #expect(queue.currentLine == "first")
        #expect(queue.remainingMillis(at: ms(50)) == 1200)
    }

    @Test func theRemainingTimeRoundsUpAndTheLastNanosecondCounts() {
        var queue = LaunchStageQueue(initialLine: "first", initialShownAt: ms(50))
        queue.enqueue("second")
        #expect(queue.remainingMillis(at: ms(50) + 1) == 1200)
        #expect(queue.remainingMillis(at: ms(51)) == 1199)
        #expect(queue.remainingMillis(at: 1_249_999_999) == 1)
        #expect(!advance(&queue, 1_249_999_999))
        #expect(queue.currentLine == "first")
        #expect(queue.remainingMillis(at: ms(1250)) == 0)
        #expect(advance(&queue, ms(1250)))
        #expect(queue.currentLine == "second")
        #expect(queue.remainingMillis(at: ms(1250)) == 1200)
    }

    @Test func aBurstStaysInOrderAndLateFramesNeverSkipOrShortenALine() {
        var queue = LaunchStageQueue(initialLine: "first")
        ["second", "third", "fourth"].forEach { queue.enqueue($0) }
        for (index, line) in ["second", "third", "fourth"].enumerated() {
            let now = ms(Int64(index + 1) * 10_000)
            #expect(advance(&queue, now))
            #expect(queue.currentLine == line)
            #expect(queue.remainingMillis(at: now) == 1200)
            #expect(!advance(&queue, now))
            #expect(!advance(&queue, now + 1_199_999_999))
            #expect(!queue.isDrained(at: now + 1_199_999_999))
        }
        #expect(queue.isDrained(at: ms(40_000) + ms(1200)))
    }

    @Test func droppingThePendingLinesLeavesTheCurrentOne() {
        var queue = LaunchStageQueue(initialLine: "first")
        queue.enqueue("second")
        queue.dropPending()
        #expect(!advance(&queue, ms(10_000)))
        #expect(queue.currentLine == "first")
    }
}

@Suite struct LaunchTravelTests {
    @Test func speedGrowsWithTheSquareOfTheProgress() {
        #expect(LaunchTravel.speed(progress: 0) == 0.9)
        #expect(abs(LaunchTravel.speed(progress: 1) - 3.5) < 1e-12)
    }

    @Test func theSmoothedProgressApproachesAndNeverOvershoots() {
        var value = 0.0
        for _ in 0..<600 {
            value = LaunchTravel.follow(value, toward: 0.5, dt: 1.0 / 60)
            #expect(value <= 0.5)
        }
        #expect(abs(value - 0.5) < 0.01)
        // A stalled frame counts for no more than a tenth of a second
        #expect(LaunchTravel.follow(0, toward: 1, dt: 5) == LaunchTravel.follow(0, toward: 1, dt: 0.1))
        #expect(LaunchTravel.follow(0.3, toward: 1, dt: -1) == 0.3)
    }

    @Test func theTravelIsTheIntegralOfTheSpeedNotTimeTimesSpeed() {
        let run = LaunchTunnelRun()
        run.step(time: 10, progress: 0, opening: 0)
        #expect(run.travel == 0)
        // A step of progress bends the speed gently: one frame later the travel moved by one frame of the old speed
        run.step(time: 10.016, progress: 1, opening: 0)
        #expect(run.travel < 0.016 * 1.0)
        #expect(run.smoothed > 0 && run.smoothed < 0.05)
    }

    @Test func theTravelFreezesOnceTheExitStarts() {
        let run = LaunchTunnelRun()
        run.step(time: 0, progress: 0.5, opening: 0)
        run.step(time: 0.05, progress: 0.5, opening: 0)
        let frozen = run.travel
        #expect(frozen > 0)
        run.step(time: 0.1, progress: 0.5, opening: 0.01)
        #expect(run.travel == frozen)
    }
}

@Suite struct LaunchTimelineTests {
    private func timeline(reduced: Bool = false, line: String? = "platform") -> LaunchTimeline {
        LaunchTimeline(now: 100, line: line, reducedMotion: reduced)
    }

    @Test func theRingFillsToThirtyPercentInTheLibrariesPartOfTheLaunch() {
        let t = timeline()
        #expect(t.progress(at: 100) == 0)
        #expect(abs(t.progress(at: 100.7) - 0.3) < 1e-9)
        #expect(t.progress(at: 100.35) > 0.2 && t.progress(at: 100.35) < 0.3)
        #expect(t.opening(at: 100.7) == 0)
    }

    @Test func eachStageMovesTheRingByEightPercentUpToNinetyTwoOverSixHundredMilliseconds() {
        var t = timeline()
        t.stage(line: "a", at: 101)
        #expect(abs(t.progress(at: 101.6) - 0.38) < 1e-9)
        for index in 0..<20 { t.stage(line: "line \(index)", at: 102 + Double(index)) }
        #expect(abs(t.progress(at: 200) - 0.92) < 1e-9)
    }

    @Test func eachLineIsToldInTurnForItsFullTime() {
        var t = timeline()
        t.stage(line: "second", at: 100.1)
        t.stage(line: "third", at: 100.2)
        t.update(at: 100.5)
        #expect(t.currentLine == "platform")
        t.update(at: 101.2)
        #expect(t.currentLine == "second")
        t.update(at: 102.3)
        #expect(t.currentLine == "second")
        t.update(at: 102.4)
        #expect(t.currentLine == "third")
    }

    @Test func whenTheGameRunsTheQueuedLinesAreNotTold() {
        var t = timeline()
        t.stage(line: "second", at: 100.1)
        t.gameRuns(at: 100.5)
        t.update(at: 105)
        #expect(t.currentLine == "platform")
    }

    @Test func theRevealWaitsForTheFirstFrameThenFillsTheBarThenOpens() {
        var t = timeline()
        t.gameRuns(at: 101)
        t.update(at: 101.5)
        #expect(t.phase == .awaitingFrame(since: 101))
        t.framePresented()
        t.update(at: 101.6)
        #expect(t.phase == .finishing(until: 101.85))
        #expect(abs(t.progress(at: 101.85) - 1) < 1e-9)
        t.update(at: 101.8)
        #expect(t.opening(at: 101.8) == 0)
        t.update(at: 101.85)
        #expect(t.phase == .opening(since: 101.85))
        #expect(abs(t.opening(at: 101.85 + 1.1) - 0.5) < 1e-9)
        t.update(at: 101.85 + 2.19)
        #expect(t.isActive)
        t.update(at: 101.85 + 2.2)
        #expect(t.phase == .done && !t.isActive)
        #expect(t.opening(at: 200) == 1)
    }

    @Test func aFrameThatNeverComesIsWaitedForThreeSeconds() {
        var t = timeline()
        t.gameRuns(at: 101)
        t.update(at: 103.9)
        #expect(t.phase == .awaitingFrame(since: 101))
        t.update(at: 104)
        #expect(t.phase == .finishing(until: 104.25))
    }

    @Test func reducedMotionOpensInHalfASecond() {
        var t = timeline(reduced: true)
        t.gameRuns(at: 101)
        t.framePresented()
        t.update(at: 101)
        t.update(at: 101.25)
        #expect(t.phase == .opening(since: 101.25))
        #expect(abs(t.opening(at: 101.5) - 0.5) < 1e-9)
        t.update(at: 101.75)
        #expect(t.phase == .done)
    }

    /// The renderer's arrival starts once, at the update that begins the exit, and lasts the exit's 2.2 s.
    @Test func theArrivalStartsWithTheExitAndLastsItsTime() {
        var t = timeline()
        var starts: [Double] = []
        func update(_ now: Double) {
            let previous = t.phase
            t.update(at: now)
            if let seconds = t.arrivalSeconds(since: previous) { starts.append(seconds) }
        }
        t.gameRuns(at: 101)
        update(101.1)
        t.framePresented()
        update(101.2)
        #expect(starts.isEmpty)
        update(101.5)
        #expect(t.phase == .opening(since: 101.5))
        #expect(starts == [2.2])
        update(102)
        update(101.5 + 2.2)
        #expect(t.phase == .done && starts == [2.2])
    }

    /// Reduced motion has no arrival: the picture is shown as it is while the plain fades run.
    @Test func reducedMotionHasNoArrival() {
        var t = timeline(reduced: true)
        t.gameRuns(at: 101)
        t.framePresented()
        for now in stride(from: 101.0, through: 102, by: 0.05) {
            let previous = t.phase
            t.update(at: now)
            #expect(t.arrivalSeconds(since: previous) == nil)
        }
        #expect(t.phase == .done)
    }

    @Test func stagesAfterTheGameRunsChangeNothing() {
        var t = timeline()
        t.gameRuns(at: 101)
        let before = t.progress(at: 102)
        t.stage(line: "late", at: 101.5)
        #expect(t.progress(at: 102) == before)
    }

    @Test func theInformationFadesDuringTheFirstThirtyFourPercentOfTheExit() {
        #expect(LaunchLook.infoAlpha(opening: 0) == 1)
        #expect(abs(LaunchLook.infoAlpha(opening: 0.17) - 0.5) < 1e-9)
        #expect(LaunchLook.infoAlpha(opening: 0.34) == 0)
        #expect(LaunchLook.infoAlpha(opening: 1) == 0)
        #expect(LaunchLook.infoAlpha(opening: .nan) == 1)
    }

    @Test func theNumbersAreAndroids() {
        #expect(LaunchLook.openingSeconds == 2.2 && LaunchLook.reducedOpeningSeconds == 0.5)
        #expect(LaunchLook.lineSeconds == 1.2 && LaunchLook.frameWaitSeconds == 3)
        #expect(LaunchLook.renderScale == 0.6)
        #expect(LaunchLook.accentGain == 1.5 && LaunchLook.accent2Gain == 1.3 && LaunchLook.accent3Gain == 0.5)
    }
}

@Suite struct LaunchTextTests {
    private let display = DisplayInfo(pixelWidth: 2796, pixelHeight: 1290, maxFramesPerSecond: 120)

    @Test func theParametersLineNamesResolutionCodecAndFrameRate() {
        var settings = StreamSettings()
        #expect(LaunchText.parameters(settings: settings, display: display) == "1920 × 884 · \(L("stream_loader_codec_auto")) · 60 FPS")
        settings.resolution = StreamResolution(width: 2560, height: 1440)
        settings.codec = .hevc
        settings.fps = 120
        #expect(LaunchText.parameters(settings: settings, display: display) == "2560 × 1440 · HEVC · 120 FPS")
        settings.codec = .av1
        #expect(LaunchText.parameters(settings: settings, display: display).contains("AV1"))
        settings.codec = .h264
        #expect(LaunchText.parameters(settings: settings, display: display).contains("H.264"))
        #expect(LaunchText.parameters(settings: settings, display: nil) == "")
    }

    @Test func thePercentageIsWholeAndClamped() {
        #expect(LaunchText.percent(0) == "0%")
        #expect(LaunchText.percent(0.376) == "38%")
        #expect(LaunchText.percent(1.4) == "100%")
        #expect(LaunchText.percent(-1) == "0%")
    }
}

@Suite struct ExitLookTests {
    @Test func theExitHandsOverAfterOneAndAHalfSecondsOrSevenHundredMillisecondsWithReducedMotion() {
        #expect(ExitLook.handoff(reduced: false) == 1.5)
        #expect(ExitLook.handoff(reduced: true) == 0.7)
    }

    @Test func theStreamBlursToFiftyAndZoomsToOneHundredTwelvePercent() {
        #expect(ExitLook.blurRadius(at: 0, reduced: false) == 0)
        #expect(ExitLook.blurRadius(at: 0.45, reduced: false) == 50)
        #expect(ExitLook.blurRadius(at: 9, reduced: false) == 50)
        #expect(ExitLook.scale(at: 0, reduced: false) == 1)
        #expect(abs(ExitLook.scale(at: 2.4, reduced: false) - 1.12) < 1e-9)
        // Fast at first, then easing out
        #expect(ExitLook.scale(at: 0.5, reduced: false) > 1.06)
    }

    @Test func reducedMotionOnlyFades() {
        #expect(ExitLook.blurRadius(at: 1, reduced: true) == 0)
        #expect(ExitLook.scale(at: 1, reduced: true) == 1)
        #expect(ExitLook.cover(at: 0.25, reduced: true) == 1)
        #expect(ExitLook.cover(at: 0.25, reduced: false) < 1)
        #expect(ExitLook.cover(at: 0.7, reduced: false) == 1)
    }

    @Test func theSceneFadesIntoTheFlatColorInTheLastMoments() {
        #expect(ExitLook.flat(at: 1.0, reduced: false) == 0)
        #expect(ExitLook.flat(at: 1.15, reduced: false) == 0)
        #expect(ExitLook.flat(at: 1.15 + 0.33, reduced: false) == 1)
        #expect(ExitLook.flat(at: 0.3, reduced: true) == 0)
        #expect(ExitLook.flat(at: 0.55, reduced: true) == 1)
        // The flat color is complete before the library comes back
        #expect(ExitLook.flat(at: ExitLook.handoff(reduced: false), reduced: false) == 1)
        #expect(ExitLook.flat(at: ExitLook.handoff(reduced: true), reduced: true) == 1)
    }
}

/// Records what the launch scene asks of the renderer.
private final class ArrivalRecorder: VideoRenderer, @unchecked Sendable {
    private let calls = Mutex<[String]>([])
    var recorded: [String] { calls.withLock { $0 } }
    var name: String { "recorder" }
    func enqueue(_ sample: CMSampleBuffer) -> Bool { true }
    func flush() {}
    func presentationCounters() async -> VideoPresentationCounters? { nil }
    @MainActor var hostLayer: CALayer { CALayer() }
    @MainActor func resize(to bounds: CGRect, scale: CGFloat) {}
    func startArrival(duration: Double) { calls.withLock { $0.append("start \(duration)") } }
    func cancelArrival() { calls.withLock { $0.append("cancel") } }
}

@MainActor @Suite struct LaunchDirectorArrivalTests {
    /// Waits on the real clock (the director ticks every 16 ms) until `done`, at most `seconds`.
    private func wait(upTo seconds: Double, until done: () -> Bool) async throws {
        let end = LaunchDirector.now() + seconds
        while !done(), LaunchDirector.now() < end { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// The director starts the renderer's arrival once, when the exit begins (0.25 s after the first frame), and leaves
    /// its end to the renderer's clock: a scene that ends normally cancels nothing.
    @Test func theExitStartsTheRenderersArrivalOnce() async throws {
        let renderer = ArrivalRecorder()
        let director = LaunchDirector(line: nil, reducedMotion: false, renderer: renderer)
        director.gameRuns()
        director.framePresented()
        try await wait(upTo: 10) { !director.isActive }
        #expect(!director.isActive)
        #expect(renderer.recorded == ["start 2.2"])
    }

    /// A scene stopped before its exit ended (the stream failed or is being left) ends the arrival with it.
    @Test func aSceneStoppedEarlyCancelsTheArrival() {
        let renderer = ArrivalRecorder()
        let director = LaunchDirector(line: nil, reducedMotion: false, renderer: renderer)
        director.stop()
        #expect(renderer.recorded == ["cancel"])
    }

    @Test func reducedMotionNeverStartsIt() async throws {
        let renderer = ArrivalRecorder()
        let director = LaunchDirector(line: nil, reducedMotion: true, renderer: renderer)
        director.gameRuns()
        director.framePresented()
        try await wait(upTo: 10) { !director.isActive }
        #expect(!director.isActive)
        #expect(renderer.recorded.isEmpty)
    }
}
