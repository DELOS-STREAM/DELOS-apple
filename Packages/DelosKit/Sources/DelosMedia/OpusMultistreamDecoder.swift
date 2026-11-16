// Decodes the host's audio: Opus multistream packets (libopus, built from source as COpus).
import COpus
import DelosCore

/// An error code of libopus (`OPUS_*` < 0).
public struct OpusError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: Int32

    public var description: String { String(cString: opus_strerror(code)) }
}

/// Decodes the Opus multistream packets of one stream to interleaved 32-bit float PCM.
///
/// Not thread-safe: one decoder belongs to the thread that receives the audio packets.
public struct OpusMultistreamDecoder: ~Copyable {
    public let configuration: OpusMultistreamConfiguration
    private let decoder: OpaquePointer

    /// A decoder for the layout the core reports in `AudioSampleSink.setup(configuration:opus:)`.
    public init(configuration: OpusMultistreamConfiguration) throws(OpusError) {
        guard configuration.channelCount > 0, configuration.mapping.count == configuration.channelCount else {
            throw OpusError(code: OPUS_BAD_ARG)
        }
        var error: Int32 = OPUS_OK
        let decoder = configuration.mapping.withUnsafeBufferPointer { mapping in
            opus_multistream_decoder_create(
                Int32(clamping: configuration.sampleRate), Int32(clamping: configuration.channelCount),
                Int32(clamping: configuration.streams), Int32(clamping: configuration.coupledStreams),
                mapping.baseAddress!, &error)
        }
        guard let decoder, error == OPUS_OK else { throw OpusError(code: error) }
        self.configuration = configuration
        self.decoder = decoder
    }

    deinit {
        opus_multistream_decoder_destroy(decoder)
    }

    /// Decodes one packet into `output` (interleaved, `channelCount` values per sample) and returns the number of
    /// samples per channel. A nil packet conceals one lost frame of `samplesPerFrame` samples.
    public func decode(
        _ packet: UnsafeRawBufferPointer?, into output: UnsafeMutableBufferPointer<Float>
    ) throws(OpusError) -> Int {
        let frameCapacity = output.count / configuration.channelCount
        guard let pcm = output.baseAddress, frameCapacity > 0 else { throw OpusError(code: OPUS_BUFFER_TOO_SMALL) }
        let data = packet?.baseAddress?.assumingMemoryBound(to: UInt8.self)
        let length = packet.map { Int32(clamping: $0.count) } ?? 0
        let frameSize = packet == nil ? min(configuration.samplesPerFrame, frameCapacity) : frameCapacity
        let samples = opus_multistream_decode_float(decoder, data, length, pcm, Int32(clamping: frameSize), 0)
        guard samples >= 0 else { throw OpusError(code: samples) }
        return Int(samples)
    }
}
