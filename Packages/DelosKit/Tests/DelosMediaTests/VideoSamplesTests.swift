import CoreMedia
import Foundation
import Testing
@testable import DelosMedia

@Suite struct VideoSamplesTests {
    @Test func aFrameBeforeTheFirstKeyFrameAsksForOne() throws {
        let pictures = try Fixtures.pictures("frames.h264", codec: .h264)
        var samples = VideoSamples(codec: .h264)
        #expect(throws: VideoSamples.Failure.needsKeyFrame) { try samples.sample(for: pictures[1], keyFrame: false) }
    }

    @Test func theKeyFrameSetsTheFormatAndLaterFramesAreNotSync() throws {
        let pictures = try Fixtures.pictures("frames.h264", codec: .h264)
        #expect(pictures.count == 2)
        var samples = VideoSamples(codec: .h264)
        let first = try samples.sample(for: pictures[0], keyFrame: true)
        let second = try samples.sample(for: pictures[1], keyFrame: false)
        #expect(samples.format != nil)
        #expect(attachment(first, kCMSampleAttachmentKey_DisplayImmediately) == true)
        #expect(attachment(first, kCMSampleAttachmentKey_NotSync) == nil)
        #expect(attachment(second, kCMSampleAttachmentKey_NotSync) == true)
        // The sample holds the length-prefixed picture without the parameter sets
        #expect(CMSampleBufferGetTotalSampleSize(first) == AnnexB.lengthPrefixed(pictures[0], codec: .h264).count)
    }

    private func attachment(_ sample: CMSampleBuffer, _ key: CFString) -> Bool? {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]] else { return nil }
        return array.first?[key] as? Bool
    }
}
