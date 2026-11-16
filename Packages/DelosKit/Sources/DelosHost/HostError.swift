import Foundation

/// Why a request to a host, or the handling of its answer, failed.
public enum HostError: Error, Equatable, Sendable {
    /// No connection could be made (refused, no route, name not resolved).
    case unreachable(String)
    /// The host did not answer within the request's time limit.
    case timedOut
    /// Over HTTPS the host presented a certificate other than the pinned one.
    case certificateMismatch
    /// The HTTP status line was not 200.
    case httpStatus(Int)
    /// The XML answer carried a `status_code` other than 200.
    case hostStatus(code: Int, message: String?)
    /// The answer could not be read: truncated, not XML, a mandatory field missing or malformed.
    case malformedResponse(String)
    /// The host's `uniqueid` is missing or could leave a directory (rule S-02 of DELOS for Android).
    case invalidHostID
    /// The answer came from another host than the record it was meant to update.
    case differentHost
    /// The answer was longer than the request allows.
    case responseTooLarge
    /// The host refused to launch, resume or quit.
    case refused
    /// The client identity could not be created or used.
    case identity(String)
}

enum Hex {
    private static let digits = Array("0123456789ABCDEF".utf8)

    /// Upper-case hexadecimal, as GameStream hosts send and expect.
    static func encode(_ bytes: some Sequence<UInt8>) -> String {
        var out = [UInt8]()
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Nil for an odd length or a character that is not a hexadecimal digit.
    static func decode(_ text: String) -> Data? {
        let chars = Array(text.utf8)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = value(chars[index]), let low = value(chars[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    private static func value(_ char: UInt8) -> UInt8? {
        switch char {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): char - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): char - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): char - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
