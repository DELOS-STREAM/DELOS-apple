import CoreMedia
import CoreVideo
import Foundation
import Metal
import Synchronization
import Testing
import VideoToolbox
@testable import DelosMedia

/// Pixel buffers filled with known Y'CbCr codes.
enum PixelBuffers {
    /// A two-plane 4:2:0 buffer of `width` × `height`; `luma(x, y)` and `chroma(x, y)` (per 2 × 2 block) give the codes
    /// at the format's depth.
    static func make(
        width: Int, height: Int, format: OSType, luma: (Int, Int) -> Int, chroma: (Int, Int) -> (cb: Int, cr: Int)
    ) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &buffer) == kCVReturnSuccess)
        let pixelBuffer = try #require(buffer)
        let wide = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        func store(_ plane: Int, _ x: Int, _ y: Int, _ values: [Int]) {
            let row = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)! + y * CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            for (i, value) in values.enumerated() {
                if wide {
                    // The 10-bit code sits in the high bits of a 16-bit word
                    (row.assumingMemoryBound(to: UInt16.self) + x * values.count + i).pointee = UInt16(value << 6)
                } else {
                    (row.assumingMemoryBound(to: UInt8.self) + x * values.count + i).pointee = UInt8(value)
                }
            }
        }
        for y in 0..<height { for x in 0..<width { store(0, x, y, [luma(x, y)]) } }
        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                let c = chroma(x, y)
                store(1, x, y, [c.cb, c.cr])
            }
        }
        return pixelBuffer
    }
}

@Suite struct MetalFrameDrawerTests {
    /// Draws into an offscreen BGRA texture of `width` × `height`, returns its pixels.
    private func render(
        _ pixelBuffer: CVPixelBuffer, conversion: ColorConversion, width: Int, height: Int
    ) throws -> (pixel: (Int, Int) -> SIMD3<Double>, drawn: Bool) {
        let drawer = try #require(MetalFrameDrawer())
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        description.usage = [.renderTarget, .shaderRead]
        description.storageMode = .shared
        let target = try #require(drawer.device.makeTexture(descriptor: description))
        let commandBuffer = try #require(drawer.queue.makeCommandBuffer())
        let drawn = drawer.draw(pixelBuffer, conversion: conversion, into: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return ({ x, y in
            let i = (y * width + x) * 4
            return SIMD3(Double(bytes[i + 2]), Double(bytes[i + 1]), Double(bytes[i])) / 255
        }, drawn)
    }

    private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, tolerance: Double = 0.012) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.z - b.z) <= tolerance
    }

    @Test func theShaderAgreesWithTheCPUReferenceInLimitedRange() throws {
        // Left half BT.709 red, right half blue (codes of the limited range)
        let buffer = try PixelBuffers.make(
            width: 64, height: 64, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            luma: { x, _ in x < 32 ? 63 : 32 }, chroma: { x, _ in x < 16 ? (102, 240) : (240, 118) })
        let conversion = ColorConversion(matrix: .bt709, range: .limited)
        let (pixel, drawn) = try render(buffer, conversion: conversion, width: 64, height: 64)
        #expect(drawn)
        #expect(close(pixel(8, 20), conversion.rgb(y: 63, cb: 102, cr: 240)))
        #expect(close(pixel(56, 40), conversion.rgb(y: 32, cb: 240, cr: 118)))
        #expect(close(pixel(8, 20), SIMD3(1, 0, 0), tolerance: 0.03))
    }

    @Test func theShaderAgreesWithTheCPUReferenceInFullRangeAndBT601() throws {
        let buffer = try PixelBuffers.make(
            width: 32, height: 32, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            luma: { _, y in y < 16 ? 255 : 76 }, chroma: { _, y in y < 8 ? (128, 128) : (85, 255) })
        let conversion = ColorConversion(matrix: .bt601, range: .full)
        let (pixel, _) = try render(buffer, conversion: conversion, width: 32, height: 32)
        #expect(close(pixel(10, 4), SIMD3(repeating: 1)))
        #expect(close(pixel(10, 28), conversion.rgb(y: 76, cb: 85, cr: 255)))
        #expect(close(pixel(10, 28), SIMD3(1, 0, 0), tolerance: 0.03))
    }

    @Test func tenBitBuffersAreDrawnWithTheirOwnScale() throws {
        let buffer = try PixelBuffers.make(
            width: 32, height: 32, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            luma: { _, y in y < 16 ? 940 : 64 }, chroma: { _, _ in (512, 512) })
        let conversion = ColorConversion(matrix: .bt2020, range: .limited, transfer: .sdr, bitDepth: 10)
        let (pixel, _) = try render(buffer, conversion: conversion, width: 32, height: 32)
        #expect(close(pixel(10, 4), SIMD3(repeating: 1)))
        #expect(close(pixel(10, 28), .zero))
    }

    @Test func aWidePictureIsFittedIntoTheTargetOnBlack() throws {
        // 64 × 32 picture of white in a 64 × 64 target: the bars above and below are black
        let buffer = try PixelBuffers.make(
            width: 64, height: 32, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            luma: { _, _ in 235 }, chroma: { _, _ in (128, 128) })
        let (pixel, _) = try render(buffer, conversion: ColorConversion(), width: 64, height: 64)
        #expect(close(pixel(32, 4), .zero))
        #expect(close(pixel(32, 60), .zero))
        #expect(close(pixel(32, 32), SIMD3(repeating: 1)))
        #expect(close(pixel(2, 17), SIMD3(repeating: 1)))
    }

    @Test func theFittedViewportKeepsTheAspectRatioAndCenters() {
        let wide = MetalFrameDrawer.fittedViewport(video: (1920, 1080), target: (2752, 2064))
        #expect(wide.width == 2752 && wide.height == 1548 && wide.originX == 0 && wide.originY == 258)
        let tall = MetalFrameDrawer.fittedViewport(video: (1080, 1920), target: (1920, 1080))
        #expect(tall.height == 1080 && tall.width == 608 && tall.originX == 656)
        let same = MetalFrameDrawer.fittedViewport(video: (1280, 720), target: (1280, 720))
        #expect(same.originX == 0 && same.originY == 0 && same.width == 1280 && same.height == 720)
    }
}

/// An elementary stream of one codec as pictures to decode: the fixtures' IDR frame and P frame, repeated (each pair
/// starts with the IDR frame again, so any number of frames decode).
struct ReplayStream {
    var codec: VideoCodec
    var samples: VideoSamples
    var pictures: [Data]

    init(fixture name: String, codec: VideoCodec) throws {
        self.codec = codec
        samples = VideoSamples(codec: codec)
        pictures = codec == .av1 ? try Self.temporalUnits(Fixtures.data(name)) : try Fixtures.pictures(name, codec: codec)
    }

    /// The sample for frame `index`: even frames are key frames, odd ones the fixture's P frame. `hostTimeUs`: the
    /// host's time of the frame (``VideoSamples/sample(for:keyFrame:hostTimeUs:)``).
    mutating func sample(_ index: Int, hostTimeUs: UInt64? = nil) throws -> CMSampleBuffer {
        let key = index % 2 == 0
        return try pictures[index % 2].withUnsafeBytes { try samples.sample(for: $0, keyFrame: key, hostTimeUs: hostTimeUs) }
    }

    /// Splits low-overhead OBUs into temporal units at the temporal delimiters.
    static func temporalUnits(_ data: Data) throws -> [Data] {
        var units: [Data] = []
        for obu in try AV1.obus(data) {
            if obu.type == 2 || units.isEmpty { units.append(Data()) }
            units[units.count - 1].append(obu.bytes)
        }
        return units
    }

    /// Whether VideoToolbox decodes the codec on this machine.
    static func isDecodable(_ codec: VideoCodec) -> Bool {
        codec != .av1 || VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }

    static let fixtures: [(String, VideoCodec)] = [("frames.h264", .h264), ("frames.hevc", .hevc), ("frames.obu", .av1)]
}

@Suite struct VideoDecoderTests {
    @Test(arguments: ReplayStream.fixtures)
    func decodesTheFixturesIntoDrawablePixelBuffers(name: String, codec: VideoCodec) throws {
        guard ReplayStream.isDecodable(codec) else { return }
        var stream = try ReplayStream(fixture: name, codec: codec)
        let frames = Mutex<[DecodedFrame]>([])
        let failures = Mutex(0)
        let decoder = VideoDecoder(onFrame: { frame in frames.withLock { $0.append(frame) } }, onFailure: { _ in failures.withLock { $0 += 1 } })
        defer { decoder.invalidate() }
        for index in 0..<6 {
            #expect(decoder.decode(try stream.sample(index)))
        }
        decoder.finishFrames()
        let decoded = frames.withLock { $0 }
        #expect(failures.withLock { $0 } == 0)
        #expect(decoded.count == 6)
        for frame in decoded {
            #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 64)
            #expect(CVPixelBufferGetHeight(frame.pixelBuffer) == 64)
            #expect(ColorConversion(pixelBuffer: frame.pixelBuffer) != nil)
            #expect(frame.decodeSeconds > 0)
        }
    }
}
