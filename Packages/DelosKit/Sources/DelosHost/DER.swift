import Foundation

/// The few DER (ITU-T X.690) structures the client identity needs: the self-signed certificate, the in-memory PKCS #12
/// container and reading the signature out of a certificate. Not a general ASN.1 library.
enum DER {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes = [UInt8]()
        var rest = count
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func sequence(_ parts: [UInt8]...) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func set(_ parts: [UInt8]...) -> [UInt8] { tlv(0x31, parts.flatMap { $0 }) }
    static let null: [UInt8] = [0x05, 0x00]
    static func octetString(_ bytes: some Sequence<UInt8>) -> [UInt8] { tlv(0x04, Array(bytes)) }
    /// A BIT STRING of whole bytes (no unused bits).
    static func bitString(_ bytes: some Sequence<UInt8>) -> [UInt8] { tlv(0x03, [0] + Array(bytes)) }
    static func utf8String(_ text: String) -> [UInt8] { tlv(0x0C, Array(text.utf8)) }
    /// `[n] EXPLICIT` (constructed, context-specific).
    static func explicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | number, content) }

    /// A non-negative INTEGER from big-endian magnitude bytes.
    static func integer(unsigned magnitude: [UInt8]) -> [UInt8] {
        var bytes = Array(magnitude.drop { $0 == 0 })
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    static func integer(_ value: Int) -> [UInt8] {
        precondition(value >= 0, "only non-negative integers are encoded")
        return integer(unsigned: withUnsafeBytes(of: UInt64(value).bigEndian) { Array($0) })
    }

    static func objectIdentifier(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").map { UInt64($0)! }
        var body = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk = [UInt8(arc & 0x7F)]
            var rest = arc >> 7
            while rest > 0 {
                chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
                rest >>= 7
            }
            body += chunk
        }
        return tlv(0x06, body)
    }

    /// UTCTime before 2050, GeneralizedTime from 2050 on (RFC 5280, 4.1.2.5).
    static func time(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = parts.year!
        let rest = [parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!]
            .map { String(format: "%02d", $0) }.joined()
        if year < 2050 {
            return tlv(0x17, Array((String(format: "%02d", year % 100) + rest + "Z").utf8))
        }
        return tlv(0x18, Array((String(format: "%04d", year) + rest + "Z").utf8))
    }

    /// One element: its tag, its content and what follows it.
    struct Element {
        let tag: UInt8
        let content: ArraySlice<UInt8>
        let rest: ArraySlice<UInt8>
    }

    /// Reads one definite-length element from the start of `bytes`; nil when the encoding is cut or invalid.
    static func read(_ bytes: ArraySlice<UInt8>) -> Element? {
        var index = bytes.startIndex
        guard index < bytes.endIndex else { return nil }
        let tag = bytes[index]
        index += 1
        guard index < bytes.endIndex else { return nil }
        let first = bytes[index]
        index += 1
        var count = 0
        if first < 0x80 {
            count = Int(first)
        } else {
            let octets = Int(first & 0x7F)
            guard octets > 0, octets <= 4, bytes.endIndex - index >= octets else { return nil }
            for _ in 0..<octets {
                count = count << 8 | Int(bytes[index])
                index += 1
            }
        }
        guard bytes.endIndex - index >= count else { return nil }
        return Element(tag: tag, content: bytes[index..<index + count], rest: bytes[(index + count)...])
    }

    /// The signature value of an X.509 certificate (the bytes of its last BIT STRING): what the pairing hashes
    /// include as "the certificate's signature".
    static func certificateSignature(_ certificate: Data) -> Data? {
        guard let outer = read(ArraySlice(certificate)), outer.tag == 0x30,
              let tbs = read(outer.content), tbs.tag == 0x30,
              let algorithm = read(tbs.rest), algorithm.tag == 0x30,
              let signature = read(algorithm.rest), signature.tag == 0x03,
              signature.content.first == 0
        else { return nil }
        return Data(signature.content.dropFirst())
    }
}
