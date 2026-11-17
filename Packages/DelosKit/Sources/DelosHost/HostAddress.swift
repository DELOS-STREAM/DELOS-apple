import Foundation
import Network

/// A host name or IP address and a TCP port. IPv6 addresses are kept without brackets.
public struct HostAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The GameStream HTTP port, used when the user types none.
    public static let defaultHTTPPort = 47989
    /// The GameStream HTTPS port, used when `serverinfo` names none.
    public static let defaultHTTPSPort = 47984

    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        precondition((1...65535).contains(port), "a port is 1...65535")
        self.host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        self.port = port
    }

    public var isIPv6: Bool { host.contains(":") }

    /// `host:port`, with brackets around an IPv6 address.
    public var description: String { "\(urlHost):\(port)" }

    /// The host as it is written in a URL or an HTTP `Host` header.
    var urlHost: String { isIPv6 ? "[\(host)]" : host }

    /// What the user typed in "Add a PC manually", as a host and the port they typed (nil: none, use the default).
    public struct Typed: Equatable, Sendable {
        public let host: String
        public let port: Int?

        public func address(defaultPort: Int = HostAddress.defaultHTTPPort) -> HostAddress {
            HostAddress(host: host, port: port ?? defaultPort)
        }
    }

    /// Accepted (the contract of DELOS for Android, `PcSetup.parseAddress`): `192.168.1.20`, `192.168.1.20:47989`,
    /// `desk.local`, `desk.local:47989`, `[2001:db8::1]`, `[2001:db8::1]:47989`, and an IPv6 address without brackets
    /// (`2001:db8::1`, `::1`), which cannot carry a port. Surrounding white space is ignored. Nil when no host can be
    /// read, the port is not 1...65535, or the text contains characters no host name has.
    public static func parse(_ input: String) -> Typed? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let inside = String(text[text.index(after: text.startIndex)..<close])
            guard isIPv6Literal(inside) else { return nil }
            let after = text[text.index(after: close)...]
            if after.isEmpty { return Typed(host: inside, port: nil) }
            guard after.first == ":", let port = port(String(after.dropFirst())) else { return nil }
            return Typed(host: inside, port: port)
        }

        // Two or more colons outside brackets are an IPv6 address: its last group is not a port.
        if text.filter({ $0 == ":" }).count >= 2 {
            return isIPv6Literal(text) ? Typed(host: text, port: nil) : nil
        }

        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        let host = String(parts[0])
        guard isHostName(host) else { return nil }
        if parts.count == 1 { return Typed(host: host, port: nil) }
        guard let port = port(String(parts[1])) else { return nil }
        return Typed(host: host, port: port)
    }

    /// Whether [text] is exactly one host name or IP literal, without a port, brackets, white space or control
    /// characters: what an address from the network may be before it is stored, used in a header or sent a packet.
    public static func isValidHost(_ text: String) -> Bool {
        guard let typed = parse(text), typed.port == nil else { return false }
        return typed.host == text
    }

    /// An IPv6 address the system can read, or one written with hexadecimal digits, colons and dots only. The second
    /// case keeps the Android contract (`2001:db8:0:0:0:0:0:47989` is taken as typed); a wrong address then fails
    /// when the client connects.
    private static func isIPv6Literal(_ text: String) -> Bool {
        IPv6Address(text) != nil || (!text.isEmpty && text.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." })
    }

    private static func port(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isASCII), let value = Int(text), (1...65535).contains(value) else {
            return nil
        }
        return value
    }

    /// Letters, digits, hyphens, underscores and dots; no empty label (also covers IPv4 literals).
    private static func isHostName(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 253 else { return false }
        let allowed = text.unicodeScalars.allSatisfy {
            ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "-" || $0 == "_" || $0 == "."
        }
        return allowed && !text.split(separator: ".", omittingEmptySubsequences: false).contains { $0.isEmpty }
    }
}

/// The host's `uniqueid`: it keys stored records and names cache directories, so only values that cannot leave a
/// directory are accepted (rule S-02 of DELOS for Android, `HostIds.isValidUuid`).
public enum HostID {
    /// Hosts send a UUID (36 characters) or a hexadecimal string; nothing legitimate is longer.
    public static let maxLength = 64

    /// True for 1...64 ASCII letters, digits and hyphens.
    public static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= maxLength && id.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || $0 == UInt8(ascii: "-")
        }
    }
}
