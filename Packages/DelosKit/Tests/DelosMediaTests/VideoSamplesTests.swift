import CDelosCommon
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import DelosCore
@testable import DelosMedia

@Suite struct VideoSamplesTests {
    @Test func aFrameBeforeTheFirstKeyFrameAsksForOne() throws {
        let pictures = try Fixtures.pictures("frames.h264", codec: .h264)
        var samples = VideoSamples(codec: .h264)
        #expect(throws: VideoSamples.Failure.needsKeyFrame) { try sample(&samples, pictures[1], keyFrame: false) }
    }

    @Test func theKeyFrameSetsTheFormatAndLaterFramesAreNotSync() throws {
        let pictures = try Fixtures.pictures("frames.h264", codec: .h264)
        #expect(pictures.count == 2)
        var samples = VideoSamples(codec: .h264)
        let first = try sample(&samples, pictures[0], keyFrame: true)
        let second = try sample(&samples, pictures[1], keyFrame: false)
        #expect(samples.format != nil)
        #expect(attachment(first, kCMSampleAttachmentKey_DisplayImmediately) == true)
        #expect(attachment(first, kCMSampleAttachmentKey_NotSync) == nil)
        #expect(attachment(second, kCMSampleAttachmentKey_NotSync) == true)
        // The sample holds the length-prefixed picture without the parameter sets
        #expect(sampleBytes(first) == lengthPrefixed(pictures[0]))
        #expect(sampleBytes(second) == lengthPrefixed(pictures[1]))
    }

    @Test func aKeyFrameWithTheSameParameterSetsKeepsTheFormat() throws {
        let pictures = try Fixtures.pictures("frames.h264", codec: .h264)
        var samples = VideoSamples(codec: .h264)
        _ = try sample(&samples, pictures[0], keyFrame: true)
        let format = try #require(samples.format)
        _ = try sample(&samples, pictures[0], keyFrame: true)
        #expect(samples.format === format)
    }

    private func sample(_ samples: inout VideoSamples, _ frame: Data, keyFrame: Bool) throws -> CMSampleBuffer {
        try frame.withUnsafeBytes { try samples.sample(for: $0, keyFrame: keyFrame) }
    }

    /// Written apart from `AnnexB`: every unit that is not an SPS or a PPS, after its 4-byte big-endian length.
    private func lengthPrefixed(_ frame: Data) -> [UInt8] {
        Fixtures.units(frame).filter { ![7, 8].contains($0.first! & 0x1F) }.flatMap { unit in
            [UInt8(unit.count >> 24 & 0xFF), UInt8(unit.count >> 16 & 0xFF), UInt8(unit.count >> 8 & 0xFF),
             UInt8(unit.count & 0xFF)] + unit
        }
    }

    private func attachment(_ sample: CMSampleBuffer, _ key: CFString) -> Bool? {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]] else { return nil }
        return array.first?[key] as? Bool
    }
}

/// The core's frames reach `VideoOutput` as a chain of buffers cut where its packets ended.
@Suite struct VideoOutputSubmitTests {
    @Test func aFrameCutAcrossTheCoresBuffersIsJoinedIntoOneSample() throws {
        let pictures = try Fixtures.pictures("frames.h264", codec: .h264).map { [UInt8]($0) }
        let renderer = RecordingRenderer()
        let output = VideoOutput(renderer: renderer, supportedFormats: .h264)
        #expect(output.setup(format: .h264, width: 64, height: 64, frameRate: 60))

        #expect(submit(pictures[1], idr: false, to: output, cutAt: [7]) == .needIDRFrame)
        // Cuts through a start code, the parameter sets and the slice
        let size = pictures[0].count
        #expect(submit(pictures[0], idr: true, to: output, cutAt: [2, 9, 18, size / 2, size - 1]) == .ok)
        #expect(submit(pictures[1], idr: false, to: output, cutAt: [1, pictures[1].count / 3]) == .ok)

        var whole = VideoSamples(codec: .h264)
        let expected = try pictures.enumerated().map { index, picture in
            try picture.withUnsafeBytes { try sampleBytes(whole.sample(for: $0, keyFrame: index == 0)) }
        }
        #expect(renderer.received.withLock { $0 } == expected)
    }

    private func submit(_ frame: [UInt8], idr: Bool, to output: VideoOutput, cutAt cuts: [Int]) -> DecodeResult {
        var bytes = frame.map { CChar(bitPattern: $0) }
        let bounds = [0] + cuts + [frame.count]
        let entries = UnsafeMutablePointer<LENTRY>.allocate(capacity: bounds.count - 1)
        defer { entries.deallocate() }
        return bytes.withUnsafeMutableBufferPointer { buffer in
            for k in 0..<(bounds.count - 1) {
                (entries + k).initialize(to: LENTRY(
                    next: k + 2 < bounds.count ? entries + k + 1 : nil, data: buffer.baseAddress! + bounds[k],
                    length: Int32(bounds[k + 1] - bounds[k]), bufferType: BUFFER_TYPE_PICDATA))
            }
            var unit = DECODE_UNIT()
            unit.frameNumber = 1
            unit.frameType = idr ? FRAME_TYPE_IDR : FRAME_TYPE_PFRAME
            unit.fullLength = Int32(frame.count)
            unit.bufferList = entries
            return withUnsafePointer(to: &unit) { output.submit(DecodeUnit($0)) }
        }
    }
}

/// Keeps the bytes of each sample it is given.
private final class RecordingRenderer: VideoRenderer {
    let received = Mutex<[[UInt8]]>([])

    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        let bytes = sampleBytes(sample)
        received.withLock { $0.append(bytes) }
        return true
    }

    func flush() {}
}

private func sampleBytes(_ sample: CMSampleBuffer) -> [UInt8] {
    guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
    var out = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
    _ = out.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
    }
    return out
}
