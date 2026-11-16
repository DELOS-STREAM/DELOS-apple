import AVFAudio
import DelosCore

/// Plays the stream's audio: the core's Opus packets are decoded on the core's audio thread into an ``AudioRing``,
/// and an `AVAudioEngine` source node pulls them on its render thread. The ring holds at most 60 ms, so a burst from
/// the network cannot build up delay.
///
/// The core calls `setup`, `start`, `decodeAndPlay`, `stop` and `cleanup` one after another, never at the same time
/// (its audio thread, after the start on another thread has finished `setup`); the state they share is therefore
/// unsynchronized, and only the ring, which the render thread reads, has a lock.
public final class AudioOutput: AudioSampleSink, @unchecked Sendable {
    public var capabilities: AudioRendererCapabilities { [] }

    private final class Decoding {
        let decoder: OpusMultistreamDecoder
        var pcm: [Float]

        init(decoder: consuming OpusMultistreamDecoder, pcm: [Float]) {
            self.decoder = decoder
            self.pcm = pcm
        }
    }

    private var ring: AudioRing?
    private var decoding: Decoding?
    private var engine: AVAudioEngine?

    public init() {}

    public func setup(configuration: AudioConfiguration, opus: OpusMultistreamConfiguration) -> Bool {
        guard let decoder = try? OpusMultistreamDecoder(configuration: opus) else { return false }
        let channels = opus.channelCount
        let ring = AudioRing(channels: channels, capacityFrames: opus.sampleRate / 4, maxFrames: opus.sampleRate * 60 / 1000)
        self.ring = ring
        decoding = Decoding(decoder: decoder, pcm: [Float](repeating: 0, count: opus.samplesPerFrame * channels * 2))

        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)
        #endif
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(opus.sampleRate),
            channels: AVAudioChannelCount(channels), interleaved: true) else { return false }
        let engine = AVAudioEngine()
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, buffers -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard let first = list.first, let data = first.mData else { return noErr }
            let count = Int(frameCount) * channels
            ring.read(into: UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        self.engine = engine
        return true
    }

    public func start() {
        try? engine?.start()
    }

    public func stop() {
        engine?.stop()
    }

    public func cleanup() {
        engine = nil
        decoding = nil
        ring = nil
    }

    public func decodeAndPlay(_ packet: UnsafeRawBufferPointer?) {
        guard let ring, let decoding else { return }
        let frames = decoding.pcm.withUnsafeMutableBufferPointer { out in
            (try? decoding.decoder.decode(packet, into: out)) ?? 0
        }
        guard frames > 0 else { return }
        decoding.pcm.withUnsafeBufferPointer { ring.write(UnsafeBufferPointer(rebasing: $0.prefix(frames * ring.channels))) }
    }
}
