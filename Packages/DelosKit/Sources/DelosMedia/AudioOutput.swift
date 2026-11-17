import AVFAudio
import DelosCore
import Foundation

/// Plays the stream's audio: the core's Opus packets are decoded on the core's audio thread into an ``AudioRing``,
/// and an `AVAudioEngine` source node pulls them on its render thread. The ring holds at most 60 ms, so a burst from
/// the network cannot build up delay.
///
/// The core calls `setup`, `start`, `decodeAndPlay`, `stop` and `cleanup` one after another, never at the same time
/// (its audio thread, after the start on another thread has finished `setup`); the state they share is therefore
/// unsynchronized. The ring, which the render thread reads, has no lock either: one writer and one reader share it
/// through atomic positions, so the render thread never waits for the decoder.
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
    private var restarter: AudioRestarter?
    private var observers: [any NSObjectProtocol] = []
    /// The notifications arrive here, one after another, never on the core's threads.
    private let notifications: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "io.github.meitoncz.delos.audio.restart"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

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
        // The engine's mixer takes the standard format only (non-interleaved float): an interleaved format made
        // AVAudioEngine.connect raise an exception and the app crash at the stream start (owner's iPad, 2026-11-16).
        // The ring stays interleaved, as the decoder writes it; the render block splits it into the channels.
        guard let format = Self.format(sampleRate: Double(opus.sampleRate), channels: channels) else { return false }
        let source = AVAudioSourceNode(format: format, renderBlock: Self.renderBlock(ring: ring))
        let engine = AVAudioEngine()
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        self.engine = engine
        observe(engine)
        return true
    }

    /// Starts the engine again when the system stopped it (route or device change, interruption).
    private func observe(_ engine: AVAudioEngine) {
        let restarter = AudioRestarter(isRunning: { engine.isRunning }, restart: { (try? engine.start()) != nil })
        self.restarter = restarter
        let center = NotificationCenter.default
        func watch(_ name: Notification.Name, object: Any?, _ event: @escaping @Sendable (Notification) -> AudioRestarter.Event?) {
            observers.append(center.addObserver(forName: name, object: object, queue: notifications) { notification in
                if let event = event(notification) { restarter.handle(event) }
            })
        }
        watch(.AVAudioEngineConfigurationChange, object: engine) { _ in .configurationChange }
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        watch(AVAudioSession.routeChangeNotification, object: session) { _ in .routeChange }
        watch(AVAudioSession.interruptionNotification, object: session) { notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            switch raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
            case .began: return .interruptionBegan
            case .ended:
                // The session was deactivated by the interruption: activate it again before the engine starts
                try? session.setActive(true)
                return .interruptionEnded
            default: return nil
            }
        }
        #endif
    }

    /// The standard format for the stream's channels. Surround needs a channel layout: the host sends Windows' order
    /// (front left, front right, center, LFE, then the back and side pairs), which is WAVE's.
    static func format(sampleRate: Double, channels: Int) -> AVAudioFormat? {
        let tag: AudioChannelLayoutTag
        switch channels {
        case 1, 2: return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
        case 6: tag = kAudioChannelLayoutTag_WAVE_5_1_A
        case 8: tag = kAudioChannelLayoutTag_WAVE_7_1
        default: return nil
        }
        guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }

    /// The render block: reads interleaved samples from the ring into a scratch buffer made once, then writes each
    /// channel into its own buffer of the list. No allocation on the render thread up to `maxFrames` per call.
    static func renderBlock(ring: AudioRing, maxFrames: Int = 4096) -> AVAudioSourceNodeRenderBlock {
        let channels = ring.channels
        let scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: maxFrames * channels)
        let holder = ScratchHolder(scratch)
        return { _, _, frameCount, buffers -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            let frames = min(Int(frameCount), maxFrames)
            let interleaved = UnsafeMutableBufferPointer(rebasing: holder.buffer[0..<(frames * channels)])
            ring.read(into: interleaved)
            for (channel, buffer) in list.enumerated() where channel < channels {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<frames { data[frame] = interleaved[frame * channels + channel] }
                for frame in frames..<Int(frameCount) { data[frame] = 0 }
            }
            return noErr
        }
    }

    /// Owns the render block's scratch buffer and frees it with the block.
    private final class ScratchHolder: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<Float>
        init(_ buffer: UnsafeMutableBufferPointer<Float>) { self.buffer = buffer }
        deinit { buffer.deallocate() }
    }

    public func start() {
        restarter?.setWanted(true)
        try? engine?.start()
    }

    public func stop() {
        restarter?.setWanted(false)
        engine?.stop()
    }

    public func cleanup() {
        restarter?.setWanted(false)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        restarter = nil
        engine?.stop()
        #if !os(macOS)
        // Give the sound back to what played before the stream
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
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
