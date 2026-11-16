import AVFoundation
import Metal
import QuartzCore
import Testing
@testable import DelosMedia

@Suite struct RendererStatisticsTests {
    private func collector(renderer: String) -> VideoStatistics {
        let collector = VideoStatistics()
        collector.configure(width: 2752, height: 2064, codec: "AV1", renderer: renderer, now: 0)
        return collector
    }

    @Test func theMetalRendererReportsDecodedDisplayedAndDroppedFramesPerSecond() throws {
        let c = collector(renderer: "VideoToolbox + Metal")
        _ = c.sample(
            renderer: .init(
                totalFrames: 0, droppedFrames: 0, accumulatedDelaySeconds: 0, decodedFrames: 0, accumulatedDecodeSeconds: 0,
                refreshes: 0, repeatedRefreshes: 0, waitingSum: 0, peakWaiting: 0, lateRefreshes: 0),
            roundTrip: nil, now: 1_000_000_000)
        // Two seconds later: 240 decoded in 480 ms of decoding, 228 shown, 12 dropped, 240 refreshes of which 6 repeated,
        // 120 frames waited in total, and 3 were presented late
        let s = try #require(c.sample(
            renderer: .init(
                totalFrames: 240, droppedFrames: 12, accumulatedDelaySeconds: 0.456, decodedFrames: 240,
                accumulatedDecodeSeconds: 0.48, refreshes: 240, repeatedRefreshes: 6, waitingSum: 120, peakWaiting: 2,
                lateRefreshes: 3),
            roundTrip: nil, now: 3_000_000_000))
        #expect(s.renderer == "VideoToolbox + Metal")
        #expect(s.renderingFPS == 114)
        #expect(s.decodedFPS == 120)
        #expect(try #require(s.decodeMilliseconds) == 2)
        #expect(s.droppedFramesPerSecond == 6)
        #expect(s.queueWaitingAverage == 0.5)
        #expect(s.queueWaitingPeak == 2)
        #expect(s.repeatedRefreshesPerSecond == 3)
        #expect(s.lateRefreshesPerSecond == 1.5)
        #expect(abs(try #require(s.presentationDelayMilliseconds) - 2) < 1e-9)
        #expect(s.decodingText == "2.00 ms · 120.0 FPS")
        #expect(s.frameQueueText == "0.5 avg / 2 max waiting · 6.0 skipped /s · 3.0 repeated /s · 1.5 late /s")
    }

    @Test func theDisplayLayerReportsOnlyWhatTheSystemCounts() throws {
        let c = collector(renderer: "AVSampleBufferDisplayLayer")
        _ = c.sample(renderer: .init(totalFrames: 0, droppedFrames: 0, accumulatedDelaySeconds: 0), roundTrip: nil, now: 1_000_000_000)
        let s = try #require(c.sample(
            renderer: .init(totalFrames: 240, droppedFrames: 40, accumulatedDelaySeconds: 0.4),
            roundTrip: nil, now: 3_000_000_000))
        #expect(s.renderer == "AVSampleBufferDisplayLayer")
        #expect(s.renderingFPS == 100)
        // Frames handled, shown and dropped: the system reports no decoding
        #expect(s.decodedFPS == 120)
        #expect(s.droppedFramesPerSecond == 20)
        #expect(s.decodeMilliseconds == nil)
        #expect(s.queueWaitingAverage == nil)
        #expect(s.lateRefreshesPerSecond == nil)
        #expect(s.decodingText == nil)
        #expect(s.frameQueueText == "20.0 skipped /s")
    }

    @Test func aRendererWithoutCountersLeavesTheReadingsEmpty() throws {
        let c = collector(renderer: "AVSampleBufferDisplayLayer")
        let s = try #require(c.sample(renderer: nil, roundTrip: nil, now: 1_000_000_000))
        #expect(s.decodedFPS == nil && s.droppedFramesPerSecond == nil && s.frameQueueText == nil)
    }

    @Test func aResetOfTheDecodeCounterDoesNotGiveNegativeRates() throws {
        let c = collector(renderer: "VideoToolbox + Metal")
        _ = c.sample(
            renderer: .init(totalFrames: 100, droppedFrames: 0, accumulatedDelaySeconds: 0, decodedFrames: 100, accumulatedDecodeSeconds: 0.2),
            roundTrip: nil, now: 1_000_000_000)
        let s = try #require(c.sample(
            renderer: .init(totalFrames: 200, droppedFrames: 0, accumulatedDelaySeconds: 0, decodedFrames: 10, accumulatedDecodeSeconds: 0.02),
            roundTrip: nil, now: 2_000_000_000))
        #expect(s.decodedFPS == nil)
        #expect(s.decodeMilliseconds == nil)
    }
}

@Suite struct RendererChoiceTests {
    @Test func theSwitchValuesAreCaseInsensitiveAndUnknownOnesAreIgnored() {
        #expect(RendererChoice(switchValue: "metal") == .metal)
        #expect(RendererChoice(switchValue: "Layer") == .layer)
        #expect(RendererChoice(switchValue: "opengl") == nil)
        #expect(RendererChoice(switchValue: nil) == nil)
    }

    @Test @MainActor func theLayerChoiceMakesTheDisplayLayerRendererAndMetalMakesTheMetalOne() throws {
        let layer = RendererChoice.layer.makeRenderer(pacing: .balanced, fps: 120)
        #expect(layer is DisplayLayerRenderer)
        #expect(layer.name == "AVSampleBufferDisplayLayer")
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let metal = RendererChoice.metal.makeRenderer(pacing: .balanced, fps: 120)
        #expect(metal is MetalRenderer)
        #expect(metal.hostLayer is CAMetalLayer)
    }

    @Test @MainActor func theMetalLayerFollowsTheViewsSizeInPixels() throws {
        guard let renderer = MetalRenderer(pacing: .balanced, fps: 120) else { return }
        renderer.resize(to: CGRect(x: 0, y: 0, width: 1376, height: 1032), scale: 2)
        let layer = try #require(renderer.hostLayer as? CAMetalLayer)
        #expect(layer.frame.size == CGSize(width: 1376, height: 1032))
        #expect(layer.drawableSize == CGSize(width: 2752, height: 2064))
        #expect(layer.pixelFormat == .bgra8Unorm)
        // An empty size (the view before its layout) leaves the last good one
        renderer.resize(to: .zero, scale: 2)
        #expect(layer.drawableSize == CGSize(width: 2752, height: 2064))
    }
}
