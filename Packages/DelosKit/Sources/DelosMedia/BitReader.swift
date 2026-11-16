import Foundation

/// Reads a byte buffer bit by bit, most significant bit first (the order of H.26x and AV1 syntax elements).
struct BitReader {
    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count * 8 - position }

    enum Failure: Error { case endOfData }

    mutating func bit() throws -> UInt32 {
        guard position < bytes.count * 8 else { throw Failure.endOfData }
        let value = (bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
        position += 1
        return UInt32(value)
    }

    mutating func flag() throws -> Bool { try bit() == 1 }

    /// `count` bits (at most 32) as an unsigned number.
    mutating func bits(_ count: Int) throws -> UInt32 {
        precondition(count <= 32)
        var value: UInt32 = 0
        for _ in 0..<count { value = value << 1 | (try bit()) }
        return value
    }

    /// AV1's `uvlc()`: an unsigned variable-length code.
    mutating func uvlc() throws -> UInt32 {
        var leadingZeros = 0
        while try !flag() {
            leadingZeros += 1
            if leadingZeros >= 32 { return UInt32.max }
        }
        return try leadingZeros == 0 ? 0 : bits(leadingZeros) + (UInt32(1) << leadingZeros) - 1
    }
}
