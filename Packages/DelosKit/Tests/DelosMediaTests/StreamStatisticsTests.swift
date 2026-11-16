import DelosCore
import Testing
@testable import DelosMedia

@Suite struct StreamStatisticsTests {
    @Test func actualWindowDurationControlsFPSAndBitrate() throws {
        let collector = VideoStatistics()
        collector.configure(width: 1920, height: 1080, codec: "HEVC", now: 0)
        for frame in 100..<160 {
            collector.record(frameNumber: UInt32(frame), bytes: 10_000, hostLatencyTenths: 0, hdr: false)
        }
        let s = try #require(collector.sample(renderer: nil, roundTrip: nil, now: 2_500_000_000))
        #expect(s.incomingFPS == 24)
        #expect(s.bandwidthKiBPerSecond == 234.375)
        #expect(s.bandwidthKiBPerSecond * 1024 * 8 / 1_000_000 == 1.92)
        let idle = try #require(collector.sample(renderer: nil, roundTrip: nil, now: 3_500_000_000))
        #expect(idle.incomingFPS == 0)
        #expect(idle.bandwidthKiBPerSecond == 0)
        #expect(idle.lostFramesPercent == nil)
    }

    @Test func displayedFPSExcludesRendererDropsAndUsesPresentationDelay() throws {
        let collector = VideoStatistics()
        collector.configure(width: 1280, height: 720, codec: "H.264", now: 0)
        let first = try #require(collector.sample(
            renderer: .init(totalFrames: 120, droppedFrames: 20, accumulatedDelaySeconds: 0.5),
            roundTrip: nil, now: 1_000_000_000))
        #expect(first.renderingFPS == nil)
        let next = try #require(collector.sample(
            renderer: .init(totalFrames: 270, droppedFrames: 30, accumulatedDelaySeconds: 0.85),
            roundTrip: (.milliseconds(12), .milliseconds(3)), now: 3_500_000_000))
        #expect(next.renderingFPS == 56)
        #expect(abs(try #require(next.presentationDelayMilliseconds) - 2.5) < 0.000_001)
        #expect(next.networkMilliseconds == 12)
        #expect(next.networkVarianceMilliseconds == 3)
    }

    @Test func missingRendererReadingKeepsItsOwnSamplingInterval() throws {
        let collector = VideoStatistics()
        collector.configure(width: 1920, height: 1080, codec: "AV1", now: 0)
        _ = collector.sample(
            renderer: .init(totalFrames: 100, droppedFrames: 0, accumulatedDelaySeconds: 0),
            roundTrip: nil, now: 1_000_000_000)
        _ = collector.sample(renderer: nil, roundTrip: nil, now: 2_000_000_000)
        let next = try #require(collector.sample(
            renderer: .init(totalFrames: 200, droppedFrames: 0, accumulatedDelaySeconds: 0.2),
            roundTrip: nil, now: 3_000_000_000))
        #expect(next.renderingFPS == 50)
        #expect(next.presentationDelayMilliseconds == 2)
    }

    @Test func flushCounterResetDoesNotProduceNegativeOrHugeRates() throws {
        let collector = VideoStatistics()
        collector.configure(width: 1920, height: 1080, codec: "HEVC", now: 0)
        _ = collector.sample(
            renderer: .init(totalFrames: 100, droppedFrames: 5, accumulatedDelaySeconds: 1),
            roundTrip: nil, now: 1_000_000_000)
        let reset = try #require(collector.sample(
            renderer: .init(totalFrames: 20, droppedFrames: 0, accumulatedDelaySeconds: 0.1),
            roundTrip: nil, now: 2_000_000_000))
        #expect(reset.renderingFPS == nil)
        #expect(reset.presentationDelayMilliseconds == nil)
        let resumed = try #require(collector.sample(
            renderer: .init(totalFrames: 80, droppedFrames: 2, accumulatedDelaySeconds: 0.216),
            roundTrip: nil, now: 3_000_000_000))
        #expect(resumed.renderingFPS == 58)
        #expect(abs(try #require(resumed.presentationDelayMilliseconds) - 2) < 0.000_001)
    }

    @Test func lossUsesFrameGapsAcrossWrapAndIgnoresDuplicatesAndReordering() throws {
        let collector = VideoStatistics()
        collector.configure(width: 1920, height: 1080, codec: "HEVC", now: 0)
        for frame in [UInt32.max - 1, .max, 1, 1, .max] {
            collector.record(frameNumber: frame, bytes: 10, hostLatencyTenths: 0, hdr: false)
        }
        let wrapped = try #require(collector.sample(renderer: nil, roundTrip: nil, now: 1_000_000_000))
        #expect(wrapped.lostFramesPercent == 25)
        collector.record(frameNumber: 4, bytes: 10, hostLatencyTenths: 0, hdr: false)
        let next = try #require(collector.sample(renderer: nil, roundTrip: nil, now: 2_000_000_000))
        #expect(abs(try #require(next.lostFramesPercent) - 200.0 / 3) < 0.000_001)
    }

    @Test func absentHostTimingIsNotAZeroLatencyMeasurement() throws {
        let collector = VideoStatistics()
        collector.configure(width: 1920, height: 1080, codec: "HEVC", now: 0)
        collector.record(frameNumber: 40_000, bytes: 100, hostLatencyTenths: 0, hdr: true)
        let absent = try #require(collector.sample(renderer: nil, roundTrip: nil, now: 1_000_000_000))
        #expect(absent.hostAverageMilliseconds == nil)
        #expect(absent.lostFramesPercent == 0)
        #expect(absent.hdr)
        collector.record(frameNumber: 40_001, bytes: 100, hostLatencyTenths: 13, hdr: false)
        collector.record(frameNumber: 40_002, bytes: 100, hostLatencyTenths: 38, hdr: false)
        let measured = try #require(collector.sample(renderer: nil, roundTrip: nil, now: 2_000_000_000))
        #expect(measured.hostMinimumMilliseconds == 1.3)
        #expect(measured.hostMaximumMilliseconds == 3.8)
        #expect(abs(try #require(measured.hostAverageMilliseconds) - 2.55) < 0.000_001)
    }

    @Test func zeroElapsedSampleDoesNotConsumeCountersAndNewStreamResetsState() throws {
        let collector = VideoStatistics()
        collector.configure(width: 1920, height: 1080, codec: "HEVC", now: 10)
        collector.record(frameNumber: 50, bytes: 1024, hostLatencyTenths: 10, hdr: true)
        #expect(collector.sample(renderer: nil, roundTrip: nil, now: 10) == nil)
        let retained = try #require(collector.sample(renderer: nil, roundTrip: nil, now: 1_000_000_010))
        #expect(retained.incomingFPS == 1)
        #expect(retained.bandwidthKiBPerSecond == 1)
        collector.configure(width: 1280, height: 720, codec: "H.264", now: 2_000_000_000)
        collector.record(frameNumber: 10, bytes: 2048, hostLatencyTenths: 0, hdr: false)
        let fresh = try #require(collector.sample(renderer: nil, roundTrip: nil, now: 3_000_000_000))
        #expect(fresh.width == 1280)
        #expect(fresh.codec == "H.264")
        #expect(fresh.lostFramesPercent == 0)
        #expect(fresh.hostAverageMilliseconds == nil)
        #expect(!fresh.hdr)
    }
}
