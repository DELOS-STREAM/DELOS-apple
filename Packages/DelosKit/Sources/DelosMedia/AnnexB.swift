/// H.264 and HEVC frames as the host sends them: NAL units separated by Annex B start codes (`00 00 01` or
/// `00 00 00 01`). The frame is read in place: the units are ranges of its bytes, and only the sample's own block gets
/// a copy of them.
public enum AnnexB {
    /// Calls `body` with where each NAL unit of `bytes` is, without its start code. Empty units are left out.
    public static func forEachUnit(in bytes: UnsafeRawBufferPointer, _ body: (Range<Int>) throws -> Void) rethrows {
        var unitStart: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let code = i > 0 && bytes[i - 1] == 0 ? i - 1 : i
                if let unitStart, unitStart < code { try body(unitStart..<code) }
                unitStart = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if let unitStart, unitStart < bytes.count { try body(unitStart..<bytes.count) }
    }

    /// The NAL unit type in a unit's first byte: bits 1...5 for H.264, bits 1...6 for HEVC.
    public static func type(_ header: UInt8, codec: VideoCodec) -> UInt8 {
        codec == .hevc ? (header >> 1) & 0x3F : header & 0x1F
    }

    /// The parameter sets of a frame in the order the format description takes them: SPS and PPS for H.264, VPS, SPS
    /// and PPS for HEVC (the first of each type); nil when one is missing.
    static func parameterSets(_ units: [Range<Int>], in frame: UnsafeRawBufferPointer, codec: VideoCodec) -> [Range<Int>]? {
        let types: [UInt8] = codec == .hevc ? [32, 33, 34] : [7, 8]
        var sets: [Range<Int>] = []
        for wanted in types {
            guard let unit = units.first(where: { type(frame[$0.lowerBound], codec: codec) == wanted }) else { return nil }
            sets.append(unit)
        }
        return sets
    }

    /// The size of the frame in the length-prefixed form VideoToolbox decodes: each unit after its 4-byte big-endian
    /// length, without the parameter sets, which travel in the format description.
    static func lengthPrefixedCount(_ units: [Range<Int>], in frame: UnsafeRawBufferPointer, codec: VideoCodec) -> Int {
        var count = 0
        for unit in units where !isParameterSet(frame[unit.lowerBound], codec: codec) {
            count += 4 + unit.count
        }
        return count
    }

    /// Writes that form into `destination`, which holds exactly ``lengthPrefixedCount(_:in:codec:)`` bytes.
    static func writeLengthPrefixed(
        _ units: [Range<Int>], from frame: UnsafeRawBufferPointer, codec: VideoCodec,
        into destination: UnsafeMutableRawBufferPointer
    ) {
        var offset = 0
        for unit in units where !isParameterSet(frame[unit.lowerBound], codec: codec) {
            destination.storeBytes(of: UInt32(unit.count).bigEndian, toByteOffset: offset, as: UInt32.self)
            UnsafeMutableRawBufferPointer(rebasing: destination[(offset + 4)..<(offset + 4 + unit.count)])
                .copyMemory(from: UnsafeRawBufferPointer(rebasing: frame[unit]))
            offset += 4 + unit.count
        }
    }

    static func isParameterSet(_ header: UInt8, codec: VideoCodec) -> Bool {
        let kind = type(header, codec: codec)
        switch codec {
        case .h264: return kind == 7 || kind == 8
        case .hevc: return kind >= 32 && kind <= 34
        case .av1: return false
        }
    }
}
