import CDelosCommon
import CoreMedia
import CoreVideo
@testable import DelosCore
import Foundation
import QuartzCore
import Synchronization
import Testing
import VideoToolbox
@testable import DelosMedia

/// What a fake HDR host changes in the pictures: 10-bit decoder output, metadata on formats and pictures, EDR layers.
@Suite struct HDRStreamTests {
    // MARK: Hardware probe

    @Test func theMain10ParameterSetsMakeAFormatThatSaysTenBits() throws {
        let format = try #require(HardwareProbe.Streams.hevcMain10Description)
        #expect(VideoFormat.bitDepth(of: format) == 10)
        let size = CMVideoFormatDescriptionGetDimensions(format)
        #expect(size.width == 256 && size.height == 256)
    }

    @Test func the8BitFixtureSaysEightBits() throws {
        let pictures = try Fixtures.pictures("frames.hevc", codec: .hevc)
        var samples = VideoSamples(codec: .hevc)
        _ = try pictures[0].withUnsafeBytes { try samples.sample(for: $0, keyFrame: true) }
        #expect(VideoFormat.bitDepth(of: try #require(samples.format)) == 8)
    }

    @Test func theGeneratedAV1HeaderParsesAsMain10() throws {
        let obu = HardwareProbe.Streams.av1Main10SequenceHeaderOBU()
        let parsed = try #require(try AV1.obus(Data(obu)).first)
        #expect(parsed.type == AV1.sequenceHeaderType)
        let header = try AV1.parseSequenceHeader(parsed.payload)
        #expect(header.profile == 0 && header.bitDepth == 10)
        #expect(header.maxWidth == 256 && header.maxHeight == 256)
        #expect(header.colorPrimaries == 9 && header.transferCharacteristics == 16 && header.matrixCoefficients == 9)
        let format = try #require(HardwareProbe.Streams.av1Main10Description)
        #expect(VideoFormat.bitDepth(of: format) == 10)
    }

    @Test func theBitWriterMakesExpGolombCodesAndEmulationPrevention() {
        var w = BitWriter()
        w.ue(0); w.ue(1); w.ue(2); w.ue(3)
        w.trailing()
        // 1 010 011 00100 then the stop bit, padded: 1010 0110 0100 1000
        #expect(w.bytes == [0b1010_0110, 0b0100_1000])
        var zeros = BitWriter()
        zeros.bits(0, 16); zeros.bits(1, 8)
        #expect(zeros.rbsp() == [0, 0, 3, 1])
    }

    @Test func theProbeIsNotOfferedWithoutAHardwareSession() {
        #expect(!HardwareProbe.hardwareSession(for: nil))
        // Apple silicon decodes HEVC Main10 in hardware, and the probe agrees with what a session of the generated stream says
        #expect(HardwareProbe.hevcMain10 == HardwareProbe.hardwareSession(for: HardwareProbe.Streams.hevcMain10Description))
        #if os(macOS) && arch(arm64)
        #expect(HardwareProbe.hevcMain10)
        #endif
    }

    @Test func tenBitProfilesAreOfferedOnlyWhereTheCodecIs() {
        let all = DecoderSupport.formats(hevc: true, av1: true, hevcMain10: true, av1Main10: true)
        #expect(all == [.h264, .hevc, .av1Main8, .hevcMain10, .av1Main10])
        // A Main10 profile without its codec's hardware is not offered
        #expect(DecoderSupport.formats(hevc: false, av1: true, hevcMain10: true, av1Main10: true) == [.h264, .av1Main8, .av1Main10])
        #expect(DecoderSupport.formats(hevc: true, av1: false, hevcMain10: false, av1Main10: true) == [.h264, .hevc])
    }

    @Test func displaysAboveStandardWhiteOrWithAnHDRModeShowHDR() {
        #expect(HDRDisplay.supports(potentialHeadroom: 2, hdrModes: false))
        #expect(HDRDisplay.supports(potentialHeadroom: 1, hdrModes: true))
        #expect(!HDRDisplay.supports(potentialHeadroom: 1, hdrModes: false))
        #expect(!HDRDisplay.supports(potentialHeadroom: nil, hdrModes: false))
    }

    // MARK: Decoder output

    @Test func aTenBitStreamAsksVideoToolboxForTenBitOutputAndAnEightBitOneForEightBit() {
        #expect(VideoDecoder.outputFormats(tenBit: true) == [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange])
        #expect(VideoDecoder.outputFormats(tenBit: false) == [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        #expect(VideoDecoder.outputFormats(tenBit: true).allSatisfy(ColorConversion.pixelFormats.contains))
    }

    @Test func aSessionOfOneDepthIsReplacedWhenTheStreamChangesDepth() throws {
        let eight = try eightBitHEVCSample()
        let ten = try #require(HardwareProbe.Streams.hevcMain10Description)
        let decoder = VideoDecoder(onFrame: { _ in }, onFailure: { _ in })
        _ = decoder.decode(eight)
        #expect(decoder.sessionDepth == false)
        guard HardwareProbe.hevcMain10 else { return }
        // A 10-bit format arrives (the stream restarted as HDR): the session is made again for it
        try decoder.prepare(for: ten)
        #expect(decoder.sessionDepth == true)
        decoder.invalidate()
        #expect(decoder.sessionDepth == nil)
    }

    private func eightBitHEVCSample() throws -> CMSampleBuffer {
        let pictures = try Fixtures.pictures("frames.hevc", codec: .hevc)
        var samples = VideoSamples(codec: .hevc)
        return try pictures[0].withUnsafeBytes { try samples.sample(for: $0, keyFrame: true) }
    }

    // MARK: Metadata

    private static let metadata = HDRMetadata(
        primaries: [.init(x: 35400, y: 14600), .init(x: 8500, y: 39850), .init(x: 6550, y: 2300)],
        whitePoint: .init(x: 15635, y: 16450), maxDisplayLuminance: 1000, minDisplayLuminance: 50,
        maxContentLightLevel: 1200, maxFrameAverageLightLevel: 400)

    @Test func theFormatDescriptionCarriesTheMetadataTheHostSent() throws {
        let pictures = try Fixtures.pictures("frames.hevc", codec: .hevc)
        var samples = VideoSamples(codec: .hevc)
        _ = try pictures[0].withUnsafeBytes { try samples.sample(for: $0, keyFrame: true) }
        let plain = try #require(samples.format)
        #expect(extensionData(plain, kCMFormatDescriptionExtension_MasteringDisplayColorVolume) == nil)

        samples.setHDRMetadata(Self.metadata)
        let format = try #require(samples.format)
        #expect(format !== plain)
        #expect(extensionData(format, kCMFormatDescriptionExtension_MasteringDisplayColorVolume) == Self.metadata.masteringDisplayColorVolume)
        #expect(extensionData(format, kCMFormatDescriptionExtension_ContentLightLevelInfo) == Self.metadata.contentLightLevelInfo)
        // The next key frame with the same parameter sets keeps it
        _ = try pictures[0].withUnsafeBytes { try samples.sample(for: $0, keyFrame: true) }
        #expect(samples.format === format)
        // HDR off again: the description loses it
        samples.setHDRMetadata(nil)
        #expect(extensionData(try #require(samples.format), kCMFormatDescriptionExtension_MasteringDisplayColorVolume) == nil)
    }

    @Test func metadataSetBeforeTheFirstKeyFrameIsInItsFormat() throws {
        let frame = try Fixtures.data("frames-10bit.obu")
        var samples = VideoSamples(codec: .av1)
        samples.setHDRMetadata(Self.metadata)
        _ = try frame.withUnsafeBytes { try samples.sample(for: $0, keyFrame: true) }
        let format = try #require(samples.format)
        #expect(extensionData(format, kCMFormatDescriptionExtension_MasteringDisplayColorVolume) == Self.metadata.masteringDisplayColorVolume)
        #expect(VideoFormat.bitDepth(of: format) == 10)
    }

    @Test func aPictureGetsTheFormatsMetadataAsAttachmentsWithoutOverwritingItsOwn() throws {
        var samples = VideoSamples(codec: .hevc)
        samples.setHDRMetadata(Self.metadata)
        let pictures = try Fixtures.pictures("frames.hevc", codec: .hevc)
        _ = try pictures[0].withUnsafeBytes { try samples.sample(for: $0, keyFrame: true) }
        let attachments = VideoDecoder.hdrAttachments(of: try #require(samples.format))
        let buffer = try PixelBuffers.make(
            width: 2, height: 2, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, luma: { _, _ in 64 }, chroma: { _, _ in (512, 512) })
        VideoDecoder.attach(attachments, to: buffer)
        let info = try #require(HDRPictureInfo(pixelBuffer: buffer))
        #expect(info.masteringDisplayColorVolume == Self.metadata.masteringDisplayColorVolume)
        #expect(info.contentLightLevelInfo == Self.metadata.contentLightLevelInfo)
        // Attachments VideoToolbox put on the picture stay
        let own = Data(repeating: 7, count: 4)
        CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, own as CFData, .shouldPropagate)
        VideoDecoder.attach(attachments, to: buffer)
        #expect(HDRPictureInfo(pixelBuffer: buffer)?.contentLightLevelInfo == own)
    }

    @Test func aPictureWithoutMetadataHasNoInfo() throws {
        let buffer = try PixelBuffers.make(
            width: 2, height: 2, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, luma: { _, _ in 64 }, chroma: { _, _ in (128, 128) })
        #expect(HDRPictureInfo(pixelBuffer: buffer) == nil)
    }

    private func extensionData(_ format: CMFormatDescription, _ key: CFString) -> Data? {
        CMFormatDescriptionGetExtension(format, extensionKey: key) as? Data
    }

    // MARK: Layers

    @MainActor @Test func theMetalLayerGetsHDR10MetadataForPQAndHLGDescriptionForHLG() throws {
        #if !os(tvOS)
        let layer = CAMetalLayer()
        let info = HDRPictureInfo(
            masteringDisplayColorVolume: Self.metadata.masteringDisplayColorVolume, contentLightLevelInfo: Self.metadata.contentLightLevelInfo)
        let pq = ColorConversion(matrix: .bt2020, range: .limited, transfer: .pq, bitDepth: 10)
        LayerRetagger.configure(layer, conversion: pq, hdr: info)
        #expect(layer.edrMetadata != nil)
        LayerRetagger.configure(layer, conversion: ColorConversion(matrix: .bt2020, range: .limited, transfer: .hlg, bitDepth: 10), hdr: nil)
        #expect(layer.edrMetadata != nil)
        LayerRetagger.configure(layer, conversion: pq, hdr: nil)
        #expect(layer.edrMetadata == nil)
        LayerRetagger.configure(layer, conversion: ColorConversion(), hdr: info)
        #expect(layer.edrMetadata == nil)
        #endif
    }

    @MainActor @Test func theDisplayLayerAsksForExtendedRangeOnlyWhileTheStreamIsHDR() async throws {
        #if !os(tvOS)
        let renderer = DisplayLayerRenderer()
        #expect(!renderer.layer.wantsExtendedDynamicRangeContent)
        renderer.setHDR(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(renderer.layer.wantsExtendedDynamicRangeContent)
        renderer.setHDR(false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!renderer.layer.wantsExtendedDynamicRangeContent)
        #endif
    }

    // MARK: VideoOutput

    @Test func keyFramesCarryTheHostsMetadataWhileItsHDRModeIsOnAndTheRendererLearnsOfTenBitFormats() throws {
        let pictures = try Fixtures.pictures("frames.hevc", codec: .hevc).map { [UInt8]($0) }
        let renderer = RecordingHDRRenderer()
        let output = VideoOutput(renderer: renderer, supportedFormats: .hevcMain10, hdrMetadata: { Self.metadata })
        #expect(output.setup(format: .hevcMain10, width: 64, height: 64, frameRate: 60))
        #expect(renderer.hdr.withLock { $0 } == [true])

        #expect(submit(pictures[0], idr: true, hdr: false, to: output) == .ok)
        #expect(submit(pictures[0], idr: true, hdr: true, to: output) == .ok)
        output.cleanup()
        let formats = renderer.formats.withLock { $0 }
        #expect(formats.count == 2)
        #expect(extensionData(formats[0], kCMFormatDescriptionExtension_MasteringDisplayColorVolume) == nil)
        #expect(extensionData(formats[1], kCMFormatDescriptionExtension_MasteringDisplayColorVolume) == Self.metadata.masteringDisplayColorVolume)
        #expect(renderer.hdr.withLock { $0 } == [true, false])
    }

    @Test func aHostInSDRModeLeavesAnEightBitStreamAlone() throws {
        let renderer = RecordingHDRRenderer()
        let output = VideoOutput(renderer: renderer, supportedFormats: .hevc, hdrMetadata: { Self.metadata })
        #expect(output.setup(format: .hevc, width: 64, height: 64, frameRate: 60))
        #expect(renderer.hdr.withLock { $0 } == [false])
    }

    private func submit(_ frame: [UInt8], idr: Bool, hdr: Bool, to output: VideoOutput) -> DecodeResult {
        var bytes = frame.map { CChar(bitPattern: $0) }
        return bytes.withUnsafeMutableBufferPointer { buffer in
            var entry = LENTRY(next: nil, data: buffer.baseAddress!, length: Int32(frame.count), bufferType: BUFFER_TYPE_PICDATA)
            return withUnsafeMutablePointer(to: &entry) { pointer in
                var unit = DECODE_UNIT()
                unit.frameNumber = 1
                unit.frameType = idr ? FRAME_TYPE_IDR : FRAME_TYPE_PFRAME
                unit.fullLength = Int32(frame.count)
                unit.hdrActive = hdr
                unit.bufferList = pointer
                return withUnsafePointer(to: &unit) { output.submit(DecodeUnit($0)) }
            }
        }
    }
}

private final class RecordingHDRRenderer: VideoRenderer {
    let formats = Mutex<[CMFormatDescription]>([])
    let hdr = Mutex<[Bool]>([])

    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        if let format = CMSampleBufferGetFormatDescription(sample) { formats.withLock { $0.append(format) } }
        return true
    }

    func setHDR(_ active: Bool) { hdr.withLock { $0.append(active) } }
    func flush() {}
    var name: String { "Recording" }
    func presentationCounters() async -> VideoPresentationCounters? { nil }
    @MainActor var hostLayer: CALayer { CALayer() }
    @MainActor func resize(to bounds: CGRect, scale: CGFloat) {}
}
