import DelosCore
import Testing
@testable import DelosMedia

@Suite struct DecoderSupportTests {
    @Test func h264AlwaysAndOnly8BitFormats() {
        #expect(DecoderSupport.formats(hevc: false, av1: false) == .h264)
        #expect(DecoderSupport.formats(hevc: true, av1: false) == [.h264, .hevc])
        #expect(DecoderSupport.formats(hevc: true, av1: true) == [.h264, .hevc, .av1Main8])
        // No 10-bit or 4:4:4 format is offered before HDR is supported
        let all = DecoderSupport.formats(hevc: true, av1: true)
        #expect(all.isDisjoint(with: .tenBit))
        #expect(all.isDisjoint(with: .yuv444))
    }

    @Test func thisMacDecodesH264AndHEVC() {
        // Apple silicon decodes HEVC in hardware
        #expect(DecoderSupport.device.isSuperset(of: [.h264, .hevc]))
    }
}
