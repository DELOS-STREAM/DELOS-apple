import AVFoundation
import DelosCore
import Foundation
import Synchronization

/// A cumulative snapshot from the system video renderer, not a count of enqueue calls.
public struct VideoPresentationCounters: Sendable, Equatable {
    public var totalFrames: Int
    public var droppedFrames: Int
    public var accumulatedDelaySeconds: Double

    public init(totalFrames: Int, droppedFrames: Int, accumulatedDelaySeconds: Double) {
        self.totalFrames = totalFrames
        self.droppedFrames = droppedFrames
        self.accumulatedDelaySeconds = accumulatedDelaySeconds
    }
}

/// One measured window. Missing system/host readings stay nil; submission time is not decoding time.
public struct StreamStatistics: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var codec: String
    public var hdr: Bool
    public var incomingFPS: Double
    public var renderingFPS: Double?
    public var bandwidthKiBPerSecond: Double
    /// Missing reassembled video frames, not RTP packet loss or renderer drops.
    public var lostFramesPercent: Double?
    public var networkMilliseconds: Double?
    public var networkVarianceMilliseconds: Double?
    public var hostMinimumMilliseconds: Double?
    public var hostMaximumMilliseconds: Double?
    public var hostAverageMilliseconds: Double?
    /// Average lateness against prescribed presentation time; not decode or input-to-display latency.
    public var presentationDelayMilliseconds: Double?
    public var videoPackets: UInt32
    public var fecPackets: UInt32
}

/// Scalar-only frame accounting on the core's video thread, sampled from a background actor.
public final class VideoStatistics: Sendable {
    private struct State: Sendable {
        var width = 0
        var height = 0
        var codec = ""
        var hdr = false
        var sampledAt: UInt64 = 0
        var frames: UInt64 = 0
        var bytes: UInt64 = 0
        var received: UInt64 = 0
        var lost: UInt64 = 0
        var previousFrame: UInt32?
        var hostCount = 0
        var hostSum = 0.0
        var hostMinimum = Double.greatestFiniteMagnitude
        var hostMaximum = 0.0
        var renderer: VideoPresentationCounters?
        var rendererSampledAt: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    func configure(width: Int, height: Int, codec: String, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        state.withLock {
            $0 = State(width: width, height: height, codec: codec, sampledAt: now)
        }
    }

    /// No allocation, formatting, wall clock or UI work per frame.
    func record(frameNumber: UInt32, bytes: Int, hostLatencyTenths: UInt16, hdr: Bool) {
        state.withLock { s in
            s.frames += 1
            s.bytes += UInt64(max(0, bytes))
            s.hdr = hdr
            if let previous = s.previousFrame {
                let advance = frameNumber &- previous
                // Duplicates/reordering do not create an enormous gap; UInt32 rollover is valid.
                if advance > 0, advance < 0x8000_0000 {
                    s.received += 1
                    s.lost += UInt64(advance - 1)
                    s.previousFrame = frameNumber
                }
            } else {
                s.received += 1
                s.previousFrame = frameNumber
            }
            if hostLatencyTenths > 0 {
                let milliseconds = Double(hostLatencyTenths) / 10
                s.hostCount += 1
                s.hostSum += milliseconds
                s.hostMinimum = min(s.hostMinimum, milliseconds)
                s.hostMaximum = max(s.hostMaximum, milliseconds)
            }
        }
    }

    func sample(
        renderer: VideoPresentationCounters?, roundTrip: (rtt: Duration, variance: Duration)?,
        videoPackets: UInt32 = 0, fecPackets: UInt32 = 0, now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> StreamStatistics? {
        state.withLock { s in
            guard s.width > 0, now > s.sampledAt else { return nil }
            let seconds = Double(now - s.sampledAt) / 1_000_000_000
            var renderingFPS: Double?
            var presentationDelay: Double?
            if let renderer {
                if let previous = s.renderer, now > s.rendererSampledAt,
                   renderer.totalFrames >= previous.totalFrames,
                   renderer.droppedFrames >= previous.droppedFrames,
                   renderer.accumulatedDelaySeconds >= previous.accumulatedDelaySeconds {
                    let total = renderer.totalFrames - previous.totalFrames
                    let dropped = renderer.droppedFrames - previous.droppedFrames
                    if total >= dropped {
                        let displayed = total - dropped
                        let rendererSeconds = Double(now - s.rendererSampledAt) / 1_000_000_000
                        renderingFPS = Double(displayed) / rendererSeconds
                        if displayed > 0 {
                            presentationDelay = (renderer.accumulatedDelaySeconds - previous.accumulatedDelaySeconds)
                                * 1000 / Double(displayed)
                        }
                    }
                }
                // First reading, reset/flush or missing readings: establish a fresh cumulative baseline.
                s.renderer = renderer
                s.rendererSampledAt = now
            }
            let expected = s.received + s.lost
            let result = StreamStatistics(
                width: s.width, height: s.height, codec: s.codec, hdr: s.hdr,
                incomingFPS: Double(s.frames) / seconds, renderingFPS: renderingFPS,
                bandwidthKiBPerSecond: Double(s.bytes) / 1024 / seconds,
                lostFramesPercent: expected > 0 ? Double(s.lost) * 100 / Double(expected) : nil,
                networkMilliseconds: roundTrip.map { Self.milliseconds($0.rtt) },
                networkVarianceMilliseconds: roundTrip.map { Self.milliseconds($0.variance) },
                hostMinimumMilliseconds: s.hostCount > 0 ? s.hostMinimum : nil,
                hostMaximumMilliseconds: s.hostCount > 0 ? s.hostMaximum : nil,
                hostAverageMilliseconds: s.hostCount > 0 ? s.hostSum / Double(s.hostCount) : nil,
                presentationDelayMilliseconds: presentationDelay,
                videoPackets: videoPackets, fecPackets: fecPackets)
            s.sampledAt = now
            s.frames = 0; s.bytes = 0; s.received = 0; s.lost = 0
            s.hostCount = 0; s.hostSum = 0; s.hostMinimum = .greatestFiniteMagnitude; s.hostMaximum = 0
            return result
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1_000_000_000_000_000
    }
}

/// Capture the layer's main-actor getter once; query its thread-safe renderer off the main thread.
private final class VideoPresentationReader: Sendable {
    private nonisolated(unsafe) let renderer: AVSampleBufferVideoRenderer

    @MainActor
    init(_ display: DisplayLayerRenderer) {
        renderer = display.layer.sampleBufferRenderer
    }

    func presentationCounters() async -> VideoPresentationCounters? {
        await withCheckedContinuation { continuation in
            renderer.loadVideoPerformanceMetrics { metrics in
                continuation.resume(returning: metrics.map {
                    VideoPresentationCounters(
                        totalFrames: $0.totalNumberOfFrames, droppedFrames: $0.numberOfDroppedFrames,
                        accumulatedDelaySeconds: $0.totalAccumulatedFrameDelay)
                })
            }
        }
    }
}

/// Core/renderer reads run off the main actor; only the immutable result crosses into the interface.
public actor StreamStatisticsSource {
    private let video: VideoStatistics
    private let renderer: VideoPresentationReader?
    private let session: StreamSession

    @MainActor
    public init(video: VideoStatistics, renderer: any VideoRenderer, session: StreamSession) {
        self.video = video
        if let display = renderer as? DisplayLayerRenderer {
            self.renderer = VideoPresentationReader(display)
        } else {
            self.renderer = nil
        }
        self.session = session
    }

    public func sample() async -> StreamStatistics? {
        let presentation = await renderer?.presentationCounters()
        guard !Task.isCancelled else { return nil }
        let packets = session.videoStatistics()
        return video.sample(
            renderer: presentation, roundTrip: session.estimatedRoundTrip(),
            videoPackets: packets.packets, fecPackets: packets.fecPackets)
    }
}
