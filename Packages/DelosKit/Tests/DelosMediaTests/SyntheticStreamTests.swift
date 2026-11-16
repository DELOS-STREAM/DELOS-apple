import CoreMedia
import CoreVideo
import Foundation
import Metal
import Synchronization
import Testing
import VideoToolbox
@testable import DelosMedia

/// Compressed streams of full-size pictures, made by the Mac's own hardware encoder (VideoToolbox has no AV1 encoder, so
/// AV1 stays on the 64 × 64 fixtures): the replay with the real picture sizes of a 1080p or 4K stream. Decoding and
/// drawing really run, so the Mac's decode and GPU time per picture are measured (printed, not asserted: they depend
/// on the machine); what is asserted is that every picture decodes and draws.
enum SyntheticStream {
    /// `count` frames, a key frame first and then every 60th, no B-frames, in the encoder's output order.
    static func encode(codec: CMVideoCodecType, width: Int, height: Int, count: Int) throws -> [CMSampleBuffer] {
        let frames = Collected()
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw EncodeFailure.session(status) }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: (width * height * 8) as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        let patterns = try (0..<4).map { try pattern(width: width, height: height, shift: $0 * 16) }
        for i in 0..<count {
            let time = CMTime(value: CMTimeValue(i), timescale: 120)
            let encoded = VTCompressionSessionEncodeFrame(
                session, imageBuffer: patterns[i % 4], presentationTimeStamp: time, duration: .invalid, frameProperties: nil,
                infoFlagsOut: nil
            ) { status, _, sample in
                if status == noErr, let sample { frames.add(sample) }
            }
            guard encoded == noErr else { throw EncodeFailure.frame(encoded) }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return frames.take()
    }

    /// Samples collected from the encoder's thread.
    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [CMSampleBuffer] = []

        func add(_ sample: CMSampleBuffer) {
            lock.lock()
            samples.append(sample)
            lock.unlock()
        }

        func take() -> [CMSampleBuffer] {
            lock.lock()
            defer { lock.unlock() }
            return samples
        }
    }

    enum EncodeFailure: Error {
        case session(OSStatus)
        case frame(OSStatus)
    }

    /// A buffer of diagonal stripes, so the encoder has something to compress; `shift` moves them.
    static func pattern(width: Int, height: Int, shift: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        guard CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { throw EncodeFailure.frame(-1) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<height {
            for x in 0..<width { luma[y * lumaRow + x] = UInt8(truncatingIfNeeded: 16 + ((x + y + shift) / 4) % 200) }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                chroma[y * chromaRow + 2 * x] = UInt8(truncatingIfNeeded: 64 + (x + shift) % 128)
                chroma[y * chromaRow + 2 * x + 1] = UInt8(truncatingIfNeeded: 64 + (y + shift) % 128)
            }
        }
        return buffer
    }
}

@Suite struct SyntheticStreamTests {
    @Test(arguments: [
        (kCMVideoCodecType_H264, "H.264", 1920, 1080, 120), (kCMVideoCodecType_HEVC, "HEVC", 1920, 1080, 120),
        (kCMVideoCodecType_H264, "H.264", 3840, 2160, 60), (kCMVideoCodecType_HEVC, "HEVC", 3840, 2160, 60),
    ])
    func fullSizePicturesDecodeAndDrawThroughThePipeline(
        codec: CMVideoCodecType, name: String, width: Int, height: Int, count: Int
    ) throws {
        let samples = try SyntheticStream.encode(codec: codec, width: width, height: height, count: count)
        #expect(samples.count == count)
        let decoded = Mutex<[DecodedFrame]>([])
        let failures = Mutex(0)
        let decoder = VideoDecoder(onFrame: { frame in decoded.withLock { $0.append(frame) } }, onFailure: { _ in failures.withLock { $0 += 1 } })
        defer { decoder.invalidate() }
        // The pictures decode one after the other as fast as VideoToolbox gives them back
        let started = DispatchTime.now().uptimeNanoseconds
        for sample in samples { #expect(decoder.decode(sample)) }
        decoder.finishFrames()
        let wall = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        #expect(failures.withLock { $0 } == 0)
        let frames = decoded.withLock { $0 }
        #expect(frames.count == count)
        #expect(frames.allSatisfy { CVPixelBufferGetWidth($0.pixelBuffer) == width && CVPixelBufferGetHeight($0.pixelBuffer) == height })
        let times = frames.map(\.decodeSeconds).sorted()

        // Every picture drawn into a drawable-sized texture; the GPU's own start and end times give the drawing time
        let drawer = try #require(MetalFrameDrawer())
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        description.usage = [.renderTarget, .shaderRead]
        let target = try #require(drawer.device.makeTexture(descriptor: description))
        var gpu: [Double] = []
        for frame in frames {
            let commandBuffer = try #require(drawer.queue.makeCommandBuffer())
            let conversion = try #require(ColorConversion(pixelBuffer: frame.pixelBuffer))
            #expect(drawer.draw(frame.pixelBuffer, conversion: conversion, into: target, commandBuffer: commandBuffer))
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            gpu.append(commandBuffer.gpuEndTime - commandBuffer.gpuStartTime)
        }
        gpu.sort()
        func ms(_ values: [Double], _ fraction: Double) -> Double { values[min(values.count - 1, Int(Double(values.count) * fraction))] * 1000 }
        print(String(
            format: "SYNTHETIC %@ %dx%d, %d pictures: decode median %.2f ms, p95 %.2f ms, max %.2f ms (%.0f pictures/s in a row); draw GPU median %.2f ms, p95 %.2f ms, max %.2f ms",
            name, width, height, count, ms(times, 0.5), ms(times, 0.95), ms(times, 1), Double(count) / wall, ms(gpu, 0.5), ms(gpu, 0.95),
            ms(gpu, 1)))
    }
}
