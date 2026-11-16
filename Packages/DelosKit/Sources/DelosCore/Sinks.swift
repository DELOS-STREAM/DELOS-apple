// The receivers of the core's video decode units and audio packets. The core calls them on its own threads.
import CDelosCommon

/// What a video decoder tells the core about itself (`CAPABILITY_*` of DECODER_RENDERER_CALLBACKS).
public struct VideoDecoderCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    /// Decode units are submitted on the receive thread instead of the core's decoder thread.
    public static let directSubmit = VideoDecoderCapabilities(rawValue: CAPABILITY_DIRECT_SUBMIT)
    public static let referenceFrameInvalidationAVC = VideoDecoderCapabilities(
        rawValue: CAPABILITY_REFERENCE_FRAME_INVALIDATION_AVC)
    public static let referenceFrameInvalidationHEVC = VideoDecoderCapabilities(
        rawValue: CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC)
    public static let referenceFrameInvalidationAV1 = VideoDecoderCapabilities(
        rawValue: CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1)
}

/// What an audio renderer tells the core about itself.
public struct AudioRendererCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    /// Ask the host for fewer, longer audio packets because decoding is slow.
    public static let slowOpusDecoder = AudioRendererCapabilities(rawValue: CAPABILITY_SLOW_OPUS_DECODER)
    /// The renderer accepts packets of any duration.
    public static let arbitraryAudioDuration = AudioRendererCapabilities(
        rawValue: CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION)
}

/// The decoder's answer to one decode unit.
public enum DecodeResult: Sendable {
    case ok
    /// The unit could not be decoded; the core asks the host for a new IDR frame.
    case needIDRFrame

    var cValue: Int32 {
        switch self {
        case .ok: DR_OK
        case .needIDRFrame: DR_NEED_IDR
        }
    }
}

/// The kind of one buffer of a decode unit.
public enum DecodeBufferType: Sendable, Hashable {
    case pictureData
    case sps
    case pps
    case vps
    /// A type a newer core added.
    case other(Int32)

    init(_ value: Int32) {
        switch value {
        case BUFFER_TYPE_PICDATA: self = .pictureData
        case BUFFER_TYPE_SPS: self = .sps
        case BUFFER_TYPE_PPS: self = .pps
        case BUFFER_TYPE_VPS: self = .vps
        default: self = .other(value)
        }
    }
}

/// One video frame as the core reassembled it: a chain of buffers (parameter sets first, then picture data).
///
/// The memory belongs to the core and is valid only during `VideoDecodeUnitSink.submit(_:)`; the type is
/// non-copyable and passed `borrowing`, so it cannot outlive the call.
public struct DecodeUnit: ~Copyable {
    private let unit: UnsafePointer<DECODE_UNIT>

    init(_ unit: UnsafePointer<DECODE_UNIT>) {
        self.unit = unit
    }

    public var frameNumber: Int { Int(unit.pointee.frameNumber) }
    public var isIDRFrame: Bool { unit.pointee.frameType == FRAME_TYPE_IDR }
    /// The host's processing time in units of 0.1 ms; 0 when the host does not report it.
    public var hostProcessingLatencyTenthsOfMs: UInt16 { unit.pointee.frameHostProcessingLatency }
    /// When the first packet of the frame arrived, in the core's microsecond clock (`LiGetMicroseconds`).
    public var receiveTimeUs: UInt64 { unit.pointee.receiveTimeUs }
    /// When the frame was complete and queued for the decoder, in the same clock.
    public var enqueueTimeUs: UInt64 { unit.pointee.enqueueTimeUs }
    /// The host's presentation time of the frame.
    public var presentationTimeUs: UInt64 { unit.pointee.presentationTimeUs }
    public var rtpTimestamp: UInt32 { unit.pointee.rtpTimestamp }
    /// The sum of the lengths of all buffers.
    public var fullLength: Int { Int(unit.pointee.fullLength) }
    public var hdrActive: Bool { unit.pointee.hdrActive }
    public var colorSpace: ColorSpace? { ColorSpace(rawValue: Int32(unit.pointee.colorspace)) }
    /// PyroWave only: the number of packets the frame cannot lose.
    public var pyroWaveCriticalPackets: UInt16 { unit.pointee.pyrowaveCriticalPackets }

    /// Calls `body` for each buffer in order.
    public func forEachBuffer(_ body: (DecodeBufferType, UnsafeRawBufferPointer) throws -> Void) rethrows {
        var entry = unit.pointee.bufferList
        while let current = entry {
            try body(
                DecodeBufferType(current.pointee.bufferType),
                UnsafeRawBufferPointer(start: current.pointee.data, count: Int(current.pointee.length)))
            entry = current.pointee.next
        }
    }
}

/// Receives the video stream. All methods are called on the core's threads.
public protocol VideoDecodeUnitSink: Sendable {
    var capabilities: VideoDecoderCapabilities { get }
    /// Called once the host has chosen the format; return false to fail the stream start.
    func setup(format: VideoFormats, width: Int, height: Int, frameRate: Int) -> Bool
    func start()
    func stop()
    func cleanup()
    /// One frame; see `DecodeUnit` for the lifetime of its memory.
    func submit(_ unit: borrowing DecodeUnit) -> DecodeResult
}

/// The layout of the host's Opus multistream packets (OPUS_MULTISTREAM_CONFIGURATION).
public struct OpusMultistreamConfiguration: Sendable, Equatable {
    public var sampleRate: Int
    public var channelCount: Int
    public var streams: Int
    public var coupledStreams: Int
    public var samplesPerFrame: Int
    /// Output channel → decoded channel, `channelCount` entries.
    public var mapping: [UInt8]

    public init(
        sampleRate: Int, channelCount: Int, streams: Int, coupledStreams: Int, samplesPerFrame: Int, mapping: [UInt8]
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.streams = streams
        self.coupledStreams = coupledStreams
        self.samplesPerFrame = samplesPerFrame
        self.mapping = mapping
    }

    init(_ config: OPUS_MULTISTREAM_CONFIGURATION) {
        let channels = Int(config.channelCount)
        let mapping = withUnsafeBytes(of: config.mapping) { Array($0.prefix(channels)) }
        self.init(
            sampleRate: Int(config.sampleRate), channelCount: channels, streams: Int(config.streams),
            coupledStreams: Int(config.coupledStreams), samplesPerFrame: Int(config.samplesPerFrame),
            mapping: mapping)
    }
}

/// Receives the audio stream. All methods are called on the core's threads.
public protocol AudioSampleSink: Sendable {
    var capabilities: AudioRendererCapabilities { get }
    /// Called before the stream starts; return false to fail the stream start.
    func setup(configuration: AudioConfiguration, opus: OpusMultistreamConfiguration) -> Bool
    func start()
    func stop()
    func cleanup()
    /// One Opus packet, valid only during the call; nil when a packet was lost and the decoder should conceal it.
    func decodeAndPlay(_ packet: UnsafeRawBufferPointer?)
}
