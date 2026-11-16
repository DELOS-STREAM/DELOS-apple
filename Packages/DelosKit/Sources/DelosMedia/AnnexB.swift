import Foundation

/// H.264 and HEVC frames as the host sends them: NAL units separated by Annex B start codes (`00 00 01` or
/// `00 00 00 01`).
public enum AnnexB {
    /// The NAL units of a frame, without their start codes.
    public static func units(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let code = i > 0 && bytes[i - 1] == 0 ? i - 1 : i
                starts.append((code, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        return starts.indices.map { k in
            let end = k + 1 < starts.count ? starts[k + 1].code : bytes.count
            return Data(bytes[starts[k].payload..<end])
        }
    }

    /// The NAL unit type: bits 1...5 of the first byte for H.264, bits 1...6 for HEVC.
    public static func type(of unit: Data, codec: VideoCodec) -> UInt8? {
        guard let first = unit.first else { return nil }
        return codec == .hevc ? (first >> 1) & 0x3F : first & 0x1F
    }

    /// The frame in the length-prefixed form VideoToolbox decodes (each unit after its 4-byte big-endian length),
    /// without the parameter sets, which travel in the format description.
    public static func lengthPrefixed(_ data: Data, codec: VideoCodec) -> Data {
        var out = Data(capacity: data.count + 16)
        for unit in units(data) where !isParameterSet(unit, codec: codec) {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(unit)
        }
        return out
    }

    static func isParameterSet(_ unit: Data, codec: VideoCodec) -> Bool {
        guard let type = type(of: unit, codec: codec) else { return false }
        switch codec {
        case .h264: return type == 7 || type == 8
        case .hevc: return type == 32 || type == 33 || type == 34
        case .av1: return false
        }
    }
}
