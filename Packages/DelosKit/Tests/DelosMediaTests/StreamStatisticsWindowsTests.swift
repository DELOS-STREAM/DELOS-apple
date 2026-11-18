import DelosCore
import Darwin
import Foundation
import Synchronization
import Testing
@testable import DelosMedia

/// 1 % low, the render latency's average / p95 / maximum, the Sharpen only cost and their rows (Android FrameTimesTest,
/// LatencyStagesTest, StreamStats.kt).
@Suite struct StreamStatisticsWindowsTests {
    @Test func theSlowestOnePercentSetsTheLow() {
        var times = FrameTimes()
        var now = 0.000001
        times.add(now)
        // 990 frames at 8 ms and 10 hitches of 50 ms: the slowest 1 % are the hitches
        for i in 0..<1000 {
            now += i % 100 == 0 ? 0.050 : 0.008
            times.add(now)
        }
        #expect(abs((times.onePercentLowFPS ?? 0) - 20) < 0.01)
    }

    @Test func stillPicturesAndFewFramesAreNoHitch() {
        var times = FrameTimes()
        #expect(times.onePercentLowFPS == nil)
        var now = 0.000001
        times.add(now)
        for i in 0..<200 {
            now += i == 100 ? 3 : 0.010
            times.add(now)
        }
        #expect(abs((times.onePercentLowFPS ?? 0) - 100) < 0.01)
    }

    @Test func theStageSummaryIsAverageNearestRankP95AndMaximum() {
        var stage = StageWindow()
        #expect(stage.summarize() == nil)
        for ms in 1...100 { stage.record(Double(ms) / 1000) }
        stage.record(-1)
        let summary = stage.summarize()
        #expect(summary?.count == 100)
        #expect(summary.map { abs($0.averageMilliseconds - 50.5) < 1e-9 } == true)
        #expect(summary.map { abs($0.p95Milliseconds - 95) < 1e-9 } == true)
        #expect(summary.map { abs($0.maximumMilliseconds - 100) < 1e-9 } == true)
        // The window starts empty again
        #expect(stage.summarize() == nil)
        #expect(StageWindow.percentileIndex(size: 1, fraction: 0.95) == 0)
        #expect(StageWindow.percentileIndex(size: 20, fraction: 0.95) == 18)
    }

    @Test func theSharpenMeterReportsThePassAndThePreparation() {
        var meter = SharpenMeter()
        #expect(meter.summarize() == nil)
        meter.record(passSeconds: 0.001, prepareSeconds: 0.0005)
        meter.record(passSeconds: 0.003, prepareSeconds: nil)
        let cost = meter.summarize()
        #expect(cost?.samples == 2)
        #expect(cost.map { abs($0.passAverageMilliseconds - 2) < 1e-9 && abs($0.passMaximumMilliseconds - 3) < 1e-9 } == true)
        #expect(cost.map { abs(($0.prepareAverageMilliseconds ?? 0) - 0.5) < 1e-9 } == true)
    }

    @Test func theRowsReadAsAndroidsPanel() {
        var stats = sampled()
        stats.renderLatency = StageSummary(count: 60, averageMilliseconds: 12.34, p95Milliseconds: 15.06, maximumMilliseconds: 21)
        stats.onePercentLowFPS = 57.94
        stats.upscalingMilliseconds = 1.234
        stats.sharpen = SharpenCost(
            gpuTimed: true, passAverageMilliseconds: 0.42, passMaximumMilliseconds: 0.9, prepareAverageMilliseconds: 0.31,
            prepareMaximumMilliseconds: 0.5, prepareName: "conversion", samples: 60)
        stats.gpuBusySkippedPerSecond = 12
        #expect(stats.renderLatencyText == "12.3 / 15.1 / 21.0 ms avg/p95/max")
        #expect(stats.onePercentLowText == "57.9 FPS")
        #expect(stats.upscalingText == "1.23 ms")
        #expect(stats.sharpenPassText == "0.42 ms avg / 0.90 max · conversion 0.31 ms")
        #expect(stats.frameQueueText?.hasSuffix("12.0 GPU busy /s") == true)
        stats.upscalingMilliseconds = 0
        #expect(stats.upscalingText == nil)
    }

    @Test func theRendererWindowsReachTheStatistics() {
        let video = VideoStatistics()
        video.configure(width: 1920, height: 1080, codec: "HEVC", now: 0)
        var counters = VideoPresentationCounters(totalFrames: 0, droppedFrames: 0, accumulatedDelaySeconds: 0)
        counters.gpuBusySkipped = 0
        _ = video.sample(renderer: counters, roundTrip: nil, now: 1_000_000_000)
        counters.totalFrames = 60
        counters.onePercentLowFPS = 55
        counters.renderLatency = StageSummary(count: 60, averageMilliseconds: 10, p95Milliseconds: 12, maximumMilliseconds: 14)
        counters.scaleDescription = "Upscaled to: 2560 × 1440"
        counters.upscalingMilliseconds = 2
        counters.gpuBusySkipped = 6
        counters.vrr = true
        let stats = video.sample(renderer: counters, roundTrip: nil, now: 2_000_000_000)
        #expect(stats?.onePercentLowFPS == 55)
        #expect(stats?.renderLatency?.p95Milliseconds == 12)
        #expect(stats?.scaleDescription == "Upscaled to: 2560 × 1440")
        #expect(stats?.upscalingMilliseconds == 2)
        #expect(stats?.gpuBusySkippedPerSecond == 6)
        #expect(stats?.vrr == true)
    }

    private func sampled() -> StreamStatistics {
        let video = VideoStatistics()
        video.configure(width: 1920, height: 1080, codec: "HEVC", now: 0)
        return video.sample(renderer: nil, roundTrip: nil, now: 1_000_000_000)!
    }
}

/// Reference frame invalidation and the receive thread's quality of service (Android MediaCodecHelper, latency_threads.c).
@Suite struct VideoOutputCapabilityTests {
    @Test func hevcAndAV1AskForReferenceFrameInvalidationLikeAndroid() async {
        let renderer = await DisplayLayerRenderer()
        let output = VideoOutput(renderer: renderer, supportedFormats: .h264)
        #expect(output.capabilities.contains(.directSubmit))
        #expect(output.capabilities.contains(.referenceFrameInvalidationHEVC))
        #expect(output.capabilities.contains(.referenceFrameInvalidationAV1))
        #expect(!output.capabilities.contains(.referenceFrameInvalidationAVC))
    }

    @Test func theReceiveThreadRunsUserInteractive() {
        // The core's receive thread is a plain thread (not one of a dispatch pool), as this one
        let qos = Mutex(QOS_CLASS_UNSPECIFIED)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            VideoOutput.raiseCurrentThread()
            qos.withLock { $0 = qos_class_self() }
            done.signal()
        }
        thread.qualityOfService = .utility
        thread.start()
        done.wait()
        #expect(qos.withLock { $0 } == QOS_CLASS_USER_INTERACTIVE)
    }
}
