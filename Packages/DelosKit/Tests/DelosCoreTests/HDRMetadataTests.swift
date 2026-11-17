import Foundation
import Testing
@testable import DelosCore

@Suite struct HDRMetadataTests {
    /// Rec. 2020 primaries and D65 white in the core's units (50,000 = 1.0), a 1000-nit display at 0.005 nit.
    static let rec2020 = HDRMetadata(
        primaries: [.init(x: 35400, y: 14600), .init(x: 8500, y: 39850), .init(x: 6550, y: 2300)],
        whitePoint: .init(x: 15635, y: 16450), maxDisplayLuminance: 1000, minDisplayLuminance: 50,
        maxContentLightLevel: 1200, maxFrameAverageLightLevel: 400)

    @Test func masteringBlobIs24BytesBigEndianInGreenBlueRedOrder() {
        let blob = [UInt8](Self.rec2020.masteringDisplayColorVolume)
        #expect(blob.count == 24)
        func word(_ i: Int) -> Int { Int(blob[2 * i]) * 256 + Int(blob[2 * i + 1]) }
        func pair(_ i: Int) -> [Int] { [word(i), word(i + 1)] }
        // The core sends red, green, blue; the SEI order Apple reads is green, blue, red
        #expect(pair(0) == [8500, 39850])
        #expect(pair(2) == [6550, 2300])
        #expect(pair(4) == [35400, 14600])
        #expect(pair(6) == [15635, 16450])
        // Luminances as 32-bit numbers in 1/10000th of a nit: 1000 nits and 0.005 nit
        #expect(Array(blob[16..<20]) == [0x00, 0x98, 0x96, 0x80])
        #expect(Array(blob[20..<24]) == [0, 0, 0, 50])
    }

    @Test func contentLightLevelIs4BytesBigEndian() {
        #expect(Self.rec2020.contentLightLevelInfo == Data([0x04, 0xB0, 0x01, 0x90]))
    }

    @Test func aHostWithoutContentValuesSendsNoContentLightLevel() {
        var metadata = Self.rec2020
        metadata.maxContentLightLevel = 0
        metadata.maxFrameAverageLightLevel = 0
        #expect(metadata.contentLightLevelInfo == nil)
    }

    @Test func theCoreHasNoMetadataBeforeAHostSendsOne() {
        #expect(HDRMetadata.current() == nil)
    }
}
