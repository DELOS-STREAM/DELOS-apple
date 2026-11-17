import COpus
import DelosCore
import Foundation
import Testing
@testable import DelosMedia

@Suite struct OpusMultistreamDecoderTests {
    private static let sampleRate = 48000
    private static let frameSize = 240  // 5 ms, as hosts send it

    /// Interleaved stereo sweeps: 200 → 1200 Hz on the left, 1500 → 500 Hz on the right over 0.5 s. A sweep never
    /// repeats itself, so the codec delay has one clear match (a steady tone would match every period).
    private func sweeps(frames: Int) -> [Float] {
        let duration: Float = 0.5
        func sweep(from start: Float, to end: Float, at time: Float) -> Float {
            0.5 * sin(2 * .pi * (start * time + (end - start) / duration * time * time / 2))
        }
        return (0..<frames * Self.frameSize).flatMap { index -> [Float] in
            let time = Float(index) / Float(Self.sampleRate)
            return [sweep(from: 200, to: 1200, at: time), sweep(from: 1500, to: 500, at: time)]
        }
    }

    /// Encodes `pcm` (stereo) with libopus's multistream encoder into 5 ms packets.
    private func encode(_ pcm: [Float]) throws -> [[UInt8]] {
        var error: Int32 = 0
        var mapping: [UInt8] = [0, 1]
        let encoder = try #require(
            opus_multistream_encoder_create(
                Int32(Self.sampleRate), 2, 1, 1, &mapping, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &error))
        defer { opus_multistream_encoder_destroy(encoder) }
        try #require(error == OPUS_OK)

        var packets: [[UInt8]] = []
        for start in stride(from: 0, to: pcm.count, by: 2 * Self.frameSize) {
            var packet = [UInt8](repeating: 0, count: 1500)
            let length = pcm.withUnsafeBufferPointer { samples in
                opus_multistream_encode_float(
                    encoder, samples.baseAddress! + start, Int32(Self.frameSize), &packet, Int32(packet.count))
            }
            try #require(length > 0)
            packets.append(Array(packet.prefix(Int(length))))
        }
        return packets
    }

    private let stereo = OpusMultistreamConfiguration(
        sampleRate: 48000, channelCount: 2, streams: 1, coupledStreams: 1, samplesPerFrame: 240, mapping: [0, 1])

    @Test func decodesWhatTheEncoderMade() throws {
        let input = sweeps(frames: 100)
        let packets = try encode(input)
        let decoder = try OpusMultistreamDecoder(configuration: stereo)

        var output: [Float] = []
        var frame = [Float](repeating: 0, count: 2 * Self.frameSize)
        for packet in packets {
            let samples = try packet.withUnsafeBytes { bytes in
                try frame.withUnsafeMutableBufferPointer { try decoder.decode(bytes, into: $0) }
            }
            #expect(samples == Self.frameSize)
            output += frame
        }

        // The codec delays the signal; find the delay on the left channel, then compare both channels
        let left = stride(from: 0, to: input.count, by: 2).map { input[$0] }
        let decodedLeft = stride(from: 0, to: output.count, by: 2).map { output[$0] }
        let right = stride(from: 1, to: input.count, by: 2).map { input[$0] }
        let decodedRight = stride(from: 1, to: output.count, by: 2).map { output[$0] }
        let delay = (0..<Self.maximumDelay).min {
            error(left, decodedLeft, delay: $0) < error(left, decodedLeft, delay: $1)
        }!
        // The restricted low-delay mode's look-ahead: 2.5 ms
        #expect(delay == 120)
        #expect(signalToNoise(left, decodedLeft, delay: delay) > 15)
        #expect(signalToNoise(right, decodedRight, delay: delay) > 15)
        // The channels stay apart
        #expect(signalToNoise(right, decodedLeft, delay: delay) < 0)
    }

    @Test func aLostPacketIsConcealedWithOneFrame() throws {
        let packets = try encode(sweeps(frames: 10))
        let decoder = try OpusMultistreamDecoder(configuration: stereo)
        var frame = [Float](repeating: 0, count: 4 * Self.frameSize)
        for packet in packets.prefix(5) {
            _ = try packet.withUnsafeBytes { bytes in
                try frame.withUnsafeMutableBufferPointer { try decoder.decode(bytes, into: $0) }
            }
        }
        let concealed = try frame.withUnsafeMutableBufferPointer { try decoder.decode(nil, into: $0) }
        #expect(concealed == Self.frameSize)
    }

    @Test func surroundLayoutsAreAccepted() throws {
        // The host's 5.1 layout: four streams, two of them coupled
        let surround = OpusMultistreamConfiguration(
            sampleRate: 48000, channelCount: 6, streams: 4, coupledStreams: 2, samplesPerFrame: 240,
            mapping: [0, 4, 1, 5, 2, 3])
        let decoder = try OpusMultistreamDecoder(configuration: surround)
        var frame = [Float](repeating: 1, count: 6 * Self.frameSize)
        let samples = try frame.withUnsafeMutableBufferPointer { try decoder.decode(nil, into: $0) }
        #expect(samples == Self.frameSize)
    }

    /// 5.1 and 7.1 as the host sends them (several streams, some coupled): every channel comes out in its own place.
    /// Each channel carries a tone of its own; after the codec's 2.5 ms delay a channel matches its input and no other.
    @Test(arguments: [
        (6, 4, 2, [UInt8]([0, 4, 1, 5, 2, 3])),
        (8, 5, 3, [UInt8]([0, 6, 1, 7, 2, 3, 4, 5])),
    ])
    func surroundChannelsStayInTheirPlaces(channels: Int, streams: Int, coupled: Int, mapping: [UInt8]) throws {
        let frames = 100
        let count = frames * Self.frameSize
        let tones = (0..<channels).map { channel in
            (0..<count).map { index in 0.4 * sin(2 * Float.pi * Float(400 + 250 * channel) * Float(index) / 48000) }
        }
        let input = (0..<count).flatMap { index in tones.map { $0[index] } }

        var error: Int32 = 0
        var encoderMapping = mapping
        let encoder = try #require(
            opus_multistream_encoder_create(
                48000, Int32(channels), Int32(streams), Int32(coupled), &encoderMapping, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &error))
        defer { opus_multistream_encoder_destroy(encoder) }
        try #require(error == OPUS_OK)

        let decoder = try OpusMultistreamDecoder(configuration: OpusMultistreamConfiguration(
            sampleRate: 48000, channelCount: channels, streams: streams, coupledStreams: coupled, samplesPerFrame: 240, mapping: mapping))
        var output: [Float] = []
        var frame = [Float](repeating: 0, count: channels * Self.frameSize)
        for start in stride(from: 0, to: input.count, by: channels * Self.frameSize) {
            var packet = [UInt8](repeating: 0, count: 4000)
            let length = input.withUnsafeBufferPointer {
                opus_multistream_encode_float(encoder, $0.baseAddress! + start, Int32(Self.frameSize), &packet, Int32(packet.count))
            }
            try #require(length > 0)
            let samples = try packet.prefix(Int(length)).withUnsafeBytes { bytes in
                try frame.withUnsafeMutableBufferPointer { try decoder.decode(bytes, into: $0) }
            }
            #expect(samples == Self.frameSize)
            output += frame
        }

        let decoded = (0..<channels).map { channel in stride(from: channel, to: output.count, by: channels).map { output[$0] } }
        for channel in 0..<channels {
            #expect(signalToNoise(tones[channel], decoded[channel], delay: 120) > 10, "channel \(channel)")
            #expect(signalToNoise(tones[(channel + 1) % channels], decoded[channel], delay: 120) < 0, "channel \(channel)")
        }
    }

    @Test func invalidLayoutsAreRejected() {
        let moreCoupledThanStreams = OpusMultistreamConfiguration(
            sampleRate: 48000, channelCount: 2, streams: 1, coupledStreams: 2, samplesPerFrame: 240, mapping: [0, 1])
        #expect(throws: OpusError(code: OPUS_BAD_ARG)) {
            _ = try OpusMultistreamDecoder(configuration: moreCoupledThanStreams)
        }

        let shortMapping = OpusMultistreamConfiguration(
            sampleRate: 48000, channelCount: 2, streams: 1, coupledStreams: 1, samplesPerFrame: 240, mapping: [0])
        #expect(throws: OpusError(code: OPUS_BAD_ARG)) { _ = try OpusMultistreamDecoder(configuration: shortMapping) }
    }

    @Test func aCorruptPacketIsAnError() throws {
        let decoder = try OpusMultistreamDecoder(configuration: stereo)
        var frame = [Float](repeating: 0, count: 2 * Self.frameSize)
        // TOC byte of a code-3 packet that declares 0 frames: invalid
        let corrupt: [UInt8] = [0x03, 0x00]
        #expect(throws: OpusError(code: OPUS_INVALID_PACKET)) {
            _ = try corrupt.withUnsafeBytes { bytes in
                try frame.withUnsafeMutableBufferPointer { try decoder.decode(bytes, into: $0) }
            }
        }
    }

    private static let maximumDelay = 480

    /// The squared error over a fixed window that skips the first 100 ms (the encoder settles) and leaves room for
    /// every delay that is searched.
    private func error(_ reference: [Float], _ decoded: [Float], delay: Int) -> Float {
        (4800..<reference.count - Self.maximumDelay).reduce(0) { sum, index in
            let difference = reference[index] - decoded[index + delay]
            return sum + difference * difference
        }
    }

    private func signalToNoise(_ reference: [Float], _ decoded: [Float], delay: Int) -> Float {
        let signal = (4800..<reference.count - Self.maximumDelay).reduce(Float(0)) {
            $0 + reference[$1] * reference[$1]
        }
        return 10 * log10(signal / error(reference, decoded, delay: delay))
    }
}
