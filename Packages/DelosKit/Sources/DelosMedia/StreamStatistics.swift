import AVFoundation
import DelosCore
import Foundation
import Synchronization

/// A cumulative snapshot from a video renderer, not a count of enqueue calls. The three first counters both renderers
/// report; the rest only a renderer that decodes and presents itself (``MetalRenderer``) knows, and stay nil for the display
/// layer, whose system renderer does not expose them.
public struct VideoPresentationCounters: Sendable, Equatable {
    /// Frames the renderer accounted for: shown and dropped.
    public var totalFrames: Int
    /// Frames that were never shown.
    public var droppedFrames: Int
    /// Seconds the shown frames were late against the time they were due, summed.
    public var accumulatedDelaySeconds: Double
    /// Pictures decoded.
    public var decodedFrames: Int?
    /// Seconds the decoding of those pictures took, summed.
    public var accumulatedDecodeSeconds: Double?
    /// Display refreshes the renderer was asked for a picture at.
    public var refreshes: Int?
    /// Refreshes that showed the previous picture again, after the first picture was shown.
    public var repeatedRefreshes: Int?
    /// Frames waiting in the queue, summed over the refreshes.
    public var waitingSum: Int?
    /// Most frames that waited at a refresh since the previous reading.
    public var peakWaiting: Int?
    /// Frames whose drawing the GPU finished after the time of the refresh they were drawn for.
    public var lateRefreshes: Int?

    public init(
        totalFrames: Int, droppedFrames: Int, accumulatedDelaySeconds: Double, decodedFrames: Int? = nil,
        accumulatedDecodeSeconds: Double? = nil, refreshes: Int? = nil, repeatedRefreshes: Int? = nil,
        waitingSum: Int? = nil, peakWaiting: Int? = nil, lateRefreshes: Int? = nil
    ) {
        self.totalFrames = totalFrames
        self.droppedFrames = droppedFrames
        self.accumulatedDelaySeconds = accumulatedDelaySeconds
        self.decodedFrames = decodedFrames
        self.accumulatedDecodeSeconds = accumulatedDecodeSeconds
        self.refreshes = refreshes
        self.repeatedRefreshes = repeatedRefreshes
        self.waitingSum = waitingSum
        self.peakWaiting = peakWaiting
        self.lateRefreshes = lateRefreshes
    }
}

/// One measured window. Missing system/host readings stay nil; submission time is not decoding time.
public struct StreamStatistics: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var codec: String
    public var hdr: Bool
    public var incomingFPS: Double
    /// Pictures shown per second.
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
    /// The renderer's name for the Decoder row.
    public var renderer = ""
    /// Pictures per second the renderer decoded; for the display layer the frames it handled (shown and dropped), as it
    /// reports no decoding.
    public var decodedFPS: Double?
    /// Average time VideoToolbox took per picture; nil for the display layer.
    public var decodeMilliseconds: Double?
    /// Frames per second that were decoded but not shown.
    public var droppedFramesPerSecond: Double?
    /// Average and peak number of frames that waited in the queue at a refresh; nil for the display layer.
    public var queueWaitingAverage: Double?
    public var queueWaitingPeak: Int?
    /// Refreshes per second that showed the previous picture again.
    public var repeatedRefreshesPerSecond: Double?
    /// Frames per second the GPU finished drawing after the time of their refresh.
    public var lateRefreshesPerSecond: Double?
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
        var rendererName = ""
    }

    private let state = Mutex(State())

    public init() {}

    func configure(
        width: Int, height: Int, codec: String, renderer: String = "", now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        state.withLock {
            $0 = State(width: width, height: height, codec: codec, sampledAt: now, rendererName: renderer)
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
            var extra = RendererWindow()
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
                        extra = RendererWindow(renderer, since: previous, total: total, dropped: dropped, seconds: rendererSeconds)
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
                videoPackets: videoPackets, fecPackets: fecPackets, renderer: s.rendererName,
                decodedFPS: extra.decodedFPS, decodeMilliseconds: extra.decodeMilliseconds,
                droppedFramesPerSecond: extra.droppedFramesPerSecond, queueWaitingAverage: extra.queueWaitingAverage,
                queueWaitingPeak: extra.queueWaitingPeak, repeatedRefreshesPerSecond: extra.repeatedRefreshesPerSecond,
                lateRefreshesPerSecond: extra.lateRefreshesPerSecond)
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

/// What the renderer's counters say about one sampling window (the difference of two cumulative readings).
struct RendererWindow {
    var decodedFPS: Double?
    var decodeMilliseconds: Double?
    var droppedFramesPerSecond: Double?
    var queueWaitingAverage: Double?
    var queueWaitingPeak: Int?
    var repeatedRefreshesPerSecond: Double?
    var lateRefreshesPerSecond: Double?

    init() {}

    init(_ now: VideoPresentationCounters, since before: VideoPresentationCounters, total: Int, dropped: Int, seconds: Double) {
        droppedFramesPerSecond = Double(dropped) / seconds
        if let decoded = now.decodedFrames, let earlier = before.decodedFrames, decoded >= earlier {
            decodedFPS = Double(decoded - earlier) / seconds
            if let time = now.accumulatedDecodeSeconds, let earlierTime = before.accumulatedDecodeSeconds,
               decoded > earlier, time >= earlierTime {
                decodeMilliseconds = (time - earlierTime) * 1000 / Double(decoded - earlier)
            }
        } else if now.decodedFrames == nil {
            // The display layer reports no decoding: the frames it handled, shown and dropped
            decodedFPS = Double(total) / seconds
        }
        if let refreshes = now.refreshes, let earlier = before.refreshes, refreshes > earlier {
            if let sum = now.waitingSum, let earlierSum = before.waitingSum, sum >= earlierSum {
                queueWaitingAverage = Double(sum - earlierSum) / Double(refreshes - earlier)
                queueWaitingPeak = now.peakWaiting
            }
        }
        if let repeated = now.repeatedRefreshes, let earlier = before.repeatedRefreshes, repeated >= earlier {
            repeatedRefreshesPerSecond = Double(repeated - earlier) / seconds
        }
        if let late = now.lateRefreshes, let earlier = before.lateRefreshes, late >= earlier {
            lateRefreshesPerSecond = Double(late - earlier) / seconds
        }
    }
}

/// Core/renderer reads run off the main actor; only the immutable result crosses into the interface.
public actor StreamStatisticsSource {
    private let video: VideoStatistics
    private let renderer: any VideoRenderer
    private let session: StreamSession
    private let watchdog: WatchdogVideoRenderer

    public init(video: VideoStatistics, renderer: any VideoRenderer, session: StreamSession, watchdog: WatchdogVideoRenderer) {
        self.video = video
        self.renderer = renderer
        self.session = session
        self.watchdog = watchdog
    }

    public func sample() async -> StreamStatistics? {
        let presentation = await renderer.presentationCounters()
        guard !Task.isCancelled else { return nil }
        // Reuse this always-on stream sampler and its actual presentation reading; no second timer or metric query.
        watchdog.observe(presentation, now: DispatchTime.now().uptimeNanoseconds)
        let packets = session.videoStatistics()
        // Nil once the session stops; the session orders this read before the core's teardown.
        let roundTrip = await session.estimatedRoundTrip()
        return video.sample(
            renderer: presentation, roundTrip: roundTrip, videoPackets: packets.packets, fecPackets: packets.fecPackets)
    }
}
