import CDelosCommon
import Foundation

/// The HDR metadata of the host's display and content (`SS_HDR_METADATA`, a Sunshine extension): what an HDR10 display
/// needs to map the picture. Valid while the host's HDR mode is active.
public struct HDRMetadata: Sendable, Equatable {
    /// A CIE 1931 chromaticity coordinate, normalized to 50,000.
    public struct Chromaticity: Sendable, Equatable {
        public var x: UInt16
        public var y: UInt16

        public init(x: UInt16, y: UInt16) {
            self.x = x
            self.y = y
        }
    }

    /// Red, green, blue (the order of the core).
    public var primaries: [Chromaticity]
    public var whitePoint: Chromaticity
    /// Nits.
    public var maxDisplayLuminance: UInt16
    /// 1/10000th of a nit.
    public var minDisplayLuminance: UInt16
    /// Nits; 0 when the host does not know the content.
    public var maxContentLightLevel: UInt16
    public var maxFrameAverageLightLevel: UInt16

    public init(
        primaries: [Chromaticity], whitePoint: Chromaticity, maxDisplayLuminance: UInt16, minDisplayLuminance: UInt16,
        maxContentLightLevel: UInt16, maxFrameAverageLightLevel: UInt16
    ) {
        precondition(primaries.count == 3)
        self.primaries = primaries
        self.whitePoint = whitePoint
        self.maxDisplayLuminance = maxDisplayLuminance
        self.minDisplayLuminance = minDisplayLuminance
        self.maxContentLightLevel = maxContentLightLevel
        self.maxFrameAverageLightLevel = maxFrameAverageLightLevel
    }

    init(_ raw: DelosHdrMetadata) {
        let x = raw.primaryX, y = raw.primaryY
        self.init(
            primaries: [Chromaticity(x: x.0, y: y.0), Chromaticity(x: x.1, y: y.1), Chromaticity(x: x.2, y: y.2)],
            whitePoint: Chromaticity(x: raw.whitePointX, y: raw.whitePointY),
            maxDisplayLuminance: raw.maxDisplayLuminance, minDisplayLuminance: raw.minDisplayLuminance,
            maxContentLightLevel: raw.maxContentLightLevel, maxFrameAverageLightLevel: raw.maxFrameAverageLightLevel)
    }

    /// The core's current metadata; nil when the host's HDR mode is off or the host sent none.
    public static func current() -> HDRMetadata? {
        var raw = DelosHdrMetadata()
        guard DelosCommonGetHdrMetadata(&raw) else { return nil }
        let metadata = HDRMetadata(raw)
        // A host without a display description sends zeros: nothing to tell the display
        return metadata.maxDisplayLuminance == 0 && metadata.primaries.allSatisfy { $0.x == 0 && $0.y == 0 } ? nil : metadata
    }

    /// The mastering display colour volume (SMPTE ST 2086) in the 24 bytes Apple wants
    /// (`kCMFormatDescriptionExtension_MasteringDisplayColorVolume`, `kCVImageBufferMasteringDisplayColorVolumeKey`),
    /// big-endian like the HEVC SEI: the primaries in green, blue, red order (x, y), the white point, the maximum
    /// luminance and the minimum, both in 1/10000th of a nit as 32-bit numbers.
    public var masteringDisplayColorVolume: Data {
        var data = Data(capacity: 24)
        func append(_ value: UInt16) { data.append(UInt8(value >> 8)); data.append(UInt8(value & 0xFF)) }
        func append(_ value: UInt32) { for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) } }
        for index in [1, 2, 0] {
            append(primaries[index].x)
            append(primaries[index].y)
        }
        append(whitePoint.x)
        append(whitePoint.y)
        append(UInt32(maxDisplayLuminance) * 10_000)
        append(UInt32(minDisplayLuminance))
        return data
    }

    /// The content light level (CTA-861.3) in 4 bytes, big-endian: the maximum content light level and the maximum
    /// frame-average light level in nits. Nil when the host sent neither.
    public var contentLightLevelInfo: Data? {
        guard maxContentLightLevel != 0 || maxFrameAverageLightLevel != 0 else { return nil }
        return Data([
            UInt8(maxContentLightLevel >> 8), UInt8(maxContentLightLevel & 0xFF),
            UInt8(maxFrameAverageLightLevel >> 8), UInt8(maxFrameAverageLightLevel & 0xFF),
        ])
    }
}
