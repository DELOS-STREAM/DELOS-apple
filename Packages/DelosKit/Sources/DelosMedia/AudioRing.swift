import Synchronization

/// The queue between the core's audio thread (which decodes and writes) and the audio engine's render thread (which
/// reads): interleaved float samples in a fixed ring with one writer and one reader and no lock, so the render thread
/// never waits for the decoder. Each side moves only its own position (the samples written, or read, so far) and
/// publishes it after the samples it covers; the other side's position tells how far it may go.
///
/// Latency stays bounded: before it reads, the reader skips the oldest samples beyond ``maxFrames`` (the network
/// delivered a burst, or the device fell behind). When the ring is full because nothing reads (the engine stopped), a
/// write keeps the frames that fit and drops the rest of its block. When the ring runs dry, the render thread gets
/// silence.
public final class AudioRing: @unchecked Sendable {
    public let channels: Int
    /// The most frames kept; more are skipped from the oldest end.
    public let maxFrames: Int

    /// Written only by the writer in front of `written`, read only by the reader between `read` and `written`.
    private let storage: UnsafeMutableBufferPointer<Float>
    /// Samples written so far; stored only by the writer.
    private let written = Atomic<Int>(0)
    /// Samples read or skipped so far; stored only by the reader.
    private let read = Atomic<Int>(0)

    public init(channels: Int, capacityFrames: Int, maxFrames: Int) {
        precondition(channels > 0 && capacityFrames >= maxFrames && maxFrames > 0)
        self.channels = channels
        self.maxFrames = maxFrames
        storage = .allocate(capacity: capacityFrames * channels)
        storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }

    /// Frames waiting to be played.
    public var queuedFrames: Int {
        let read = self.read.load(ordering: .acquiring)
        let written = self.written.load(ordering: .acquiring)
        return min(written - read, maxFrames * channels) / channels
    }

    /// Appends interleaved samples (a multiple of `channels` values). Only one thread writes.
    public func write(_ samples: UnsafeBufferPointer<Float>) {
        guard let source = samples.baseAddress else { return }
        let capacity = storage.count
        let written = self.written.load(ordering: .relaxed)
        let free = capacity - (written - self.read.load(ordering: .acquiring))
        let count = min(samples.count, free - free % channels)
        guard count > 0 else { return }
        let start = written % capacity
        let first = min(count, capacity - start)
        (storage.baseAddress! + start).update(from: source, count: first)
        storage.baseAddress!.update(from: source + first, count: count - first)
        self.written.store(written + count, ordering: .releasing)
    }

    /// Fills `output` (interleaved) with the oldest samples, in whole frames, and returns how many values were real;
    /// the rest is silence. Only one thread reads; it neither waits nor allocates.
    @discardableResult
    public func read(into output: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let destination = output.baseAddress else { return 0 }
        let capacity = storage.count
        let written = self.written.load(ordering: .acquiring)
        var read = self.read.load(ordering: .relaxed)
        read = max(read, written - maxFrames * channels)
        let count = min(output.count - output.count % channels, written - read)
        let start = read % capacity
        let first = min(count, capacity - start)
        destination.update(from: storage.baseAddress! + start, count: first)
        (destination + first).update(from: storage.baseAddress!, count: count - first)
        (destination + count).update(repeating: 0, count: output.count - count)
        self.read.store(read + count, ordering: .releasing)
        return count
    }
}
