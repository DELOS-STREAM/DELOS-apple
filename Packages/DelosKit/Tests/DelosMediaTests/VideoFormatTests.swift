import CoreMedia
import Foundation
import Testing
import VideoToolbox
@testable import DelosMedia

@Suite struct AnnexBTests {
    @Test func splitsOnThreeAndFourByteStartCodes() {
        let data = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5])
        #expect(Fixtures.units(data) == [Data([0x67, 1, 2]), Data([0x68, 3]), Data([0x65, 4, 5])])
    }

    @Test func bytesBeforeTheFirstStartCodeAndEmptyUnitsAreNoUnits() {
        let data = Data([9, 9, 0, 0, 1, 0, 0, 0, 1, 0x65, 4])
        #expect(Fixtures.units(data) == [Data([0x65, 4])])
    }

    @Test func lengthPrefixingDropsTheParameterSets() {
        let data: [UInt8] = [0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 2, 0, 0, 1, 0x65, 9, 9, 0, 0, 1, 0x41, 7]
        let out = data.withUnsafeBytes { frame in
            var units: [Range<Int>] = []
            AnnexB.forEachUnit(in: frame) { units.append($0) }
            #expect(AnnexB.parameterSets(units, in: frame, codec: .h264) == [4..<6, 9..<11])
            var out = [UInt8](repeating: 0xEE, count: AnnexB.lengthPrefixedCount(units, in: frame, codec: .h264))
            out.withUnsafeMutableBytes { AnnexB.writeLengthPrefixed(units, from: frame, codec: .h264, into: $0) }
            return out
        }
        #expect(out == [0, 0, 0, 3, 0x65, 9, 9, 0, 0, 0, 2, 0x41, 7])
    }
}

@Suite struct AV1Tests {
    @Test func readsTheSequenceHeaderOfAn8BitStream() throws {
        let obu = try #require(try AV1.obus(Fixtures.data("frames.obu")).first { $0.type == AV1.sequenceHeaderType })
        let header = try AV1.parseSequenceHeader(obu.payload)
        #expect(header.profile == 0)
        #expect(header.bitDepth == 8)
        #expect(header.maxWidth == 64 && header.maxHeight == 64)
        #expect(header.subsamplingX && header.subsamplingY)
        #expect(header.monochrome == false)
    }

    @Test func readsTheBitDepthOfA10BitStream() throws {
        let obu = try #require(try AV1.obus(Fixtures.data("frames-10bit.obu")).first { $0.type == AV1.sequenceHeaderType })
        #expect(try AV1.parseSequenceHeader(obu.payload).bitDepth == 10)
    }

    @Test func aTruncatedOBUIsRejected() {
        #expect(throws: AV1.Failure.truncated) { try AV1.obus(Data([0x0A, 0x05, 0x00])) }
    }

    @Test func theConfigurationRecordCarriesProfileLevelAndChroma() {
        var header = AV1.SequenceHeader()
        header.profile = 0
        header.level = 8
        header.bitDepth = 10
        let record = AV1.configurationRecord(header, sequenceHeaderOBU: Data([0x0A, 0x00]))
        #expect([UInt8](record) == [0x81, 0x08, 0b0100_1100, 0x00, 0x0A, 0x00])
    }
}

/// Decodes the first frame of each fixture with VideoToolbox: the format description and the sample `VideoSamples`
/// makes are what the decoder accepts, end to end.
@Suite struct DecodeTests {
    @Test(arguments: [("frames.h264", VideoCodec.h264), ("frames.hevc", .hevc), ("frames.obu", .av1), ("frames-10bit.obu", .av1)])
    func theFirstFrameDecodes(name: String, codec: VideoCodec) throws {
        if codec == .av1, !VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) { return }
        let frame = codec == .av1 ? try Fixtures.data(name) : try Fixtures.pictures(name, codec: codec)[0]
        var samples = VideoSamples(codec: codec)
        let sample = try frame.withUnsafeBytes { try samples.sample(for: $0, keyFrame: true) }
        let format = try #require(samples.format)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        #expect(dimensions.width == 64 && dimensions.height == 64)
        #expect(try decodedWidth(format: format, sample: sample) == 64)
    }

    private func decodedWidth(format: CMVideoFormatDescription, sample: CMSampleBuffer) throws -> Int {
        var session: VTDecompressionSession?
        #expect(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                             imageBufferAttributes: nil, outputCallback: nil,
                                             decompressionSessionOut: &session) == noErr)
        let decoder = try #require(session)
        defer { VTDecompressionSessionInvalidate(decoder) }
        nonisolated(unsafe) var width = 0
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [],
                                                       infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr, let image { width = CVPixelBufferGetWidth(image) }
        }
        #expect(status == noErr)
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        return width
    }
}
