import Synchronization

/// The queue between the core's audio thread (which decodes) and the audio engine's render thread (which plays):
/// interleaved float samples in a fixed ring. When the queue grows past ``maxFrames`` (the network delivered a burst,
/// or the device fell behind), the oldest samples are dropped so latency stays bounded; when it runs dry, the render
/// thread gets silence.
public final class AudioRing: Sendable {
    public let channels: Int
    /// The most frames kept; more are dropped from the oldest end.
    public let maxFrames: Int

    private struct State {
        var buffer: [Float]
        var read = 0
        var count = 0
    }

    private let state: Mutex<State>

    public init(channels: Int, capacityFrames: Int, maxFrames: Int) {
        precondition(channels > 0 && capacityFrames >= maxFrames && maxFrames > 0)
        self.channels = channels
        self.maxFrames = maxFrames
        state = Mutex(State(buffer: [Float](repeating: 0, count: capacityFrames * channels)))
    }

    /// Frames waiting to be played.
    public var queuedFrames: Int { state.withLock { $0.count / channels } }

    /// Appends interleaved samples (a multiple of `channels` values).
    public func write(_ samples: UnsafeBufferPointer<Float>) {
        state.withLock { s in
            let capacity = s.buffer.count
            for value in samples {
                let write = (s.read + s.count) % capacity
                s.buffer[write] = value
                if s.count < capacity { s.count += 1 } else { s.read = (s.read + 1) % capacity }
            }
            let excess = s.count - maxFrames * channels
            if excess > 0 {
                s.read = (s.read + excess) % capacity
                s.count -= excess
            }
        }
    }

    /// Fills `output` (interleaved) with the oldest samples and returns how many values were real; the rest is silence.
    @discardableResult
    public func read(into output: UnsafeMutableBufferPointer<Float>) -> Int {
        state.withLock { s in
            let capacity = s.buffer.count
            let n = min(output.count, s.count)
            for i in 0..<n { output[i] = s.buffer[(s.read + i) % capacity] }
            for i in n..<output.count { output[i] = 0 }
            s.read = (s.read + n) % capacity
            s.count -= n
            return n
        }
    }
}
