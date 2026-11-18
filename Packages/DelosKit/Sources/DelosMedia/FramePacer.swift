import Foundation

/// Android's pacing choices with an honest display-layer mapping. Warp requests oversampling at the host, not generated frames.
public enum FramePacing: String, CaseIterable, Codable, Sendable {
    /// Each frame is shown as soon as it is decoded (`latency`). Lowest delay; the network's jitter shows as uneven
    /// motion.
    case latency
    /// Frames are spaced evenly with up to one frame of buffer (`balanced`).
    case balanced
    /// Balanced presentation with Android's host FPS cap just below the display refresh rate.
    case capFPS = "cap-fps"
    /// Frames are spaced evenly with up to two frames of buffer (`smoothness`): steadier, one frame more delay.
    case smoothness
    /// Lowest-latency presentation with twice/four times the configured host FPS.
    case warp
    case warp2

    /// The frames of buffer that absorb the network's jitter; 0 shows frames at once.
    var bufferFrames: Double {
        switch self {
        case .latency, .warp, .warp2: 0
        case .balanced, .capFPS: 1
        case .smoothness: 2
        }
    }
}

/// Gives each frame the time it is shown at, so frames that arrive unevenly (the network bunches packets) still reach
/// the screen one refresh apart. A frame is shown at its arrival plus the buffer, but never sooner than nine tenths of a
/// frame after the previous one; the slack lets the pacer follow the host's clock, which runs a little faster or slower
/// than the device's. When frames pile up beyond the buffer (the stream stalled and caught up), the schedule starts
/// again from the newest frame instead of carrying the delay along.
///
/// The display layer shows a frame at the first refresh at or after its time, through a timebase on the host clock.
public struct FramePacer: Sendable {
    public let pacing: FramePacing
    /// Seconds per frame of the stream.
    public private(set) var interval: Double
    private var last: Double?

    public init(pacing: FramePacing, fps: Int) {
        self.pacing = pacing
        interval = 1 / Double(max(fps, 1))
    }

    /// Paces at [fps] from now on: the rate the host was told once the display's refresh rate is known (Cap FPS).
    public mutating func retime(fps: Int) {
        interval = 1 / Double(max(fps, 1))
    }

    /// When the frame that arrived at `arrival` (seconds, host clock) is shown; nil: at once.
    public mutating func presentationTime(arrival: Double) -> Double? {
        guard pacing.bufferFrames > 0 else { return nil }
        let buffer = pacing.bufferFrames * interval
        var time = max(arrival + buffer, (last ?? -.infinity) + 0.9 * interval)
        if time > arrival + buffer + 2 * interval { time = arrival + buffer }
        last = time
        return time
    }

    /// Forget the schedule (a new stream, or after the renderer was flushed).
    public mutating func reset() {
        last = nil
    }
}
