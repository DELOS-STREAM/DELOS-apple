import Foundation

/// H.264 and HEVC frames as the host sends them: NAL units separated by Annex B start codes (`00 00 01` or
/// `00 00 00 01`). The frame is read in place: the units are ranges of its bytes, and only the sample's own block gets
/// a copy of them.
public enum AnnexB {
    /// Calls `body` with where each NAL unit of `bytes` is, without its start code. Empty units are left out.
    ///
    /// The core's receive thread runs this over every frame, so the `01` bytes are found with `memchr` (vectorized) and
    /// only they are looked at: a byte-by-byte loop cost 5 ns a byte in a debug build, 1 ms a 200 KB frame.
    public static func forEachUnit(in bytes: UnsafeRawBufferPointer, _ body: (Range<Int>) throws -> Void) rethrows {
        guard let base = bytes.baseAddress, bytes.count >= 3 else { return }
        var unitStart: Int?
        // Where the next start code's `01` may be: a start code needs two zeros before it
        var next = 2
        while next < bytes.count, let found = memchr(base + next, 1, bytes.count - next) {
            let one = base.distance(to: UnsafeRawPointer(found))
            guard bytes[one - 1] == 0, bytes[one - 2] == 0 else {
                next = one + 1
                continue
            }
            let start = one - 2
            let code = start > 0 && bytes[start - 1] == 0 ? start - 1 : start
            if let unitStart, unitStart < code { try body(unitStart..<code) }
            unitStart = one + 1
            next = one + 3
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
