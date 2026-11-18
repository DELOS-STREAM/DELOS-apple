import Foundation

/// What only this install knows and no pattern can recognise (`ScrubContext` of DELOS for Android, diag/LogScrubber.kt); the
/// caller reads it from the stored PC list, the profiles and the settings at the moment of the export, so a renamed PC is
/// covered too.
public struct ScrubContext: Sendable, Equatable {
    /// Names of the PCs (their own and the ones given in DELOS). They become `<pc-1>`, `<pc-2>`, ...
    public var pcNames: [String]
    /// Host names and addresses typed in or learned for the PCs. They become `<host>`.
    public var hostAddresses: [String]
    /// Names of people or devices: profile names, the device's own name. They become `<name>`.
    public var names: [String]
    /// Identifiers of this install: the client id, profile ids, PC ids. They become `<id>`.
    public var identifiers: [String]
    /// Keys and tokens, such as the SteamGridDB API key. They become `<secret>`.
    public var secrets: [String]

    public init(pcNames: [String] = [], hostAddresses: [String] = [], names: [String] = [], identifiers: [String] = [],
                secrets: [String] = []) {
        self.pcNames = pcNames
        self.hostAddresses = hostAddresses
        self.names = names
        self.identifiers = identifiers
        self.secrets = secrets
    }
}

/// Removes what must not leave the device from diagnostic text (docs/DIAGNOSTICS.md, `LogScrubber` of DELOS for Android):
/// IPv4/IPv6 and MAC addresses, PC and host names, the client id and other identifiers, URL queries, tokens and API keys,
/// user names in file paths, e-mail addresses, Wi-Fi names and serial numbers. It errs on the side of removing: a harmless
/// version string that looks like an address is replaced too. Addresses and names get a number (`<ip-1>`, `<pc-2>`), the
/// same for the same value within one scrubber, so the log stays readable.
public final class LogScrubber: @unchecked Sendable {
    // Mutable alias tables behind a lock: one scrubber is used by one export at a time
    private let lock = NSLock()
    private var ips: [String: Int] = [:]
    private var macs: [String: Int] = [:]
    private let pcNames: [String]
    private let literals: [(NSRegularExpression, (String) -> String)]

    public init(context: ScrubContext = ScrubContext()) {
        var seen = Set<String>()
        let pcs = context.pcNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= Self.minName && seen.insert($0.lowercased()).inserted }
        pcNames = pcs
        var literals: [(NSRegularExpression, (String) -> String)] = []
        func add(_ values: [String], _ minLength: Int, _ replacement: @escaping (String) -> String) {
            if let pattern = Self.literalPattern(values, minLength) { literals.append((pattern, replacement)) }
        }
        add(context.secrets, Self.minSecret) { _ in "<secret>" }
        add(context.identifiers, Self.minSecret) { _ in "<id>" }
        add(pcs, Self.minName) { found in "<pc-\((pcs.firstIndex { $0.caseInsensitiveCompare(found) == .orderedSame } ?? 0) + 1)>" }
        add(context.hostAddresses, Self.minName) { _ in "<host>" }
        add(context.names, Self.minName) { _ in "<name>" }
        self.literals = literals
    }

    /// [text] without personal data.
    public func scrub(_ text: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        var out = text
        out = Self.replace(Self.url, out) { m, _ in scrubURL(m[0]) }
        out = Self.replace(Self.ssid, out) { m, _ in "\(m[1])\(m[2])<redacted>" }
        for (pattern, replacement) in literals { out = Self.replace(pattern, out) { m, _ in replacement(m[0]) } }
        out = Self.replace(Self.keyValue, out) { m, _ in "\(m[1])\(m[2])<redacted>" }
        out = Self.replace(Self.bearer, out) { m, _ in "\(m[1]) <redacted>" }
        out = Self.replace(Self.quotedHost, out) { m, _ in "\(m[1])<host>\(m[3])" }
        out = Self.replace(Self.unknownHost, out) { m, _ in "\(m[1])<host>" }
        out = Self.replace(Self.unableToResolve, out) { m, _ in "\(m[1])<host>\(m[3])" }
        out = Self.replace(Self.mac, out) { m, _ in
            let key = m[0].lowercased().replacingOccurrences(of: "-", with: ":")
            if macs[key] == nil { macs[key] = macs.count + 1 }
            return "<mac-\(macs[key]!)>"
        }
        out = Self.replace(Self.ipv6Candidate, out) { m, _ in
            let whole = m[0]
            let trimmedDot = Self.trimEnd(whole, ["."])
            let trimmedBoth = Self.trimEnd(whole, [".", ":"])
            guard let address = [whole, trimmedDot, trimmedBoth].first(where: Self.isIPv6) else { return whole }
            return ipAlias(address) + whole.dropFirst(address.count)
        }
        out = Self.replace(Self.ipv4, out) { m, _ in Self.isIPv4(m[0]) ? ipAlias(m[0]) : m[0] }
        out = Self.replace(Self.uuid, out) { _, _ in "<uuid>" }
        out = Self.replace(Self.longHex, out) { _, _ in "<hex>" }
        out = Self.replace(Self.longToken, out) { _, _ in "<token>" }
        out = Self.replace(Self.userPath, out) { m, _ in "\(m[1])<user>" }
        out = Self.replace(Self.volumePath, out) { m, _ in "\(m[1])<volume>" }
        out = Self.replace(Self.email, out) { _, _ in "<email>" }
        out = Self.replace(Self.localHost, out) { _, _ in "<host>" }
        return out
    }

    private func ipAlias(_ address: String) -> String {
        let key = address.lowercased()
        if ips[key] == nil { ips[key] = ips.count + 1 }
        return "<ip-\(ips[key]!)>"
    }

    private func scrubURL(_ raw: String) -> String {
        // Trailing sentence punctuation is not part of the address
        let trimmed = Self.trimEnd(raw, [".", ",", ";", ":", "!"])
        let tail = String(raw.dropFirst(trimmed.count))
        guard let schemeEnd = trimmed.range(of: "://") else { return raw }
        let scheme = trimmed[..<schemeEnd.lowerBound]
        let rest = trimmed[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authorityFull = rest[..<authorityEnd]
        let authority = authorityFull.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        var remainder = String(rest[authorityEnd...])
        if let hash = remainder.firstIndex(of: "#") { remainder = String(remainder[..<hash]) }
        let query: String
        let path: String
        if let mark = remainder.firstIndex(of: "?") {
            query = String(remainder[remainder.index(after: mark)...])
            path = String(remainder[..<mark])
        } else {
            query = ""
            path = remainder
        }
        let (host, port) = Self.splitHostPort(authority)
        var cleanQuery = ""
        if !query.isEmpty {
            cleanQuery = "?" + query.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
                guard let equals = pair.firstIndex(of: "=") else { return String(pair) }
                let key = pair[..<equals]
                let value = String(pair[pair.index(after: equals)...])
                return "\(key)=\(Self.matchesWhole(Self.safeQueryValue, value) ? value : "<redacted>")"
            }.joined(separator: "&")
        }
        return "\(scheme)://\(urlHost(host))\(port.isEmpty ? "" : ":\(port)")\(path)\(cleanQuery)\(tail)"
    }

    private func urlHost(_ host: String) -> String {
        var bare = host
        if bare.hasPrefix("[") { bare.removeFirst() }
        if bare.hasSuffix("]") { bare.removeLast() }
        if bare.isEmpty { return "" }
        if Self.isIPv4(bare) || Self.isIPv6(bare) { return ipAlias(bare) }
        if let index = pcNames.firstIndex(where: { $0.caseInsensitiveCompare(bare) == .orderedSame }) { return "<pc-\(index + 1)>" }
        let lower = bare.lowercased()
        if Self.publicHosts.contains(where: { lower == $0 || lower.hasSuffix(".\($0)") }) { return bare }
        return "<host>"
    }

    // MARK: Rules

    static let minName = 3
    static let minSecret = 4

    /// Public services the app talks to; their address in a URL says nothing about the user.
    static let publicHosts = ["github.com", "steamgriddb.com", "igdb.com", "steampowered.com", "howlongtobeat.com", "pcgamingwiki.com"]

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are constants; a broken one is a programming error found by the tests
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// A name is a whole word: "Home" in the PC list does not turn "homepage" into "<name>page".
    static func literalPattern(_ values: [String], _ minLength: Int) -> NSRegularExpression? {
        var seen = Set<String>()
        let parts = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= minLength && seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
        guard !parts.isEmpty else { return nil }
        let alternatives = parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return regex("(?<![\\p{L}\\p{N}])(?:\(alternatives))(?![\\p{L}\\p{N}])", .caseInsensitive)
    }

    static let url = regex(#"(?i)\b[a-z][a-z0-9+.-]{1,12}://[^\s"'<>\])]+"#)
    static let bearer = regex(#"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+"#)
    static let ssid = regex(#"(?i)\b(b?ssid)(\s*[=:]\s*)("[^"]*"|[^\r\n,;]*)"#)
    static let keyValue = regex(
        #"(?i)(?<![A-Za-z0-9])(unique_?id|uuid|device_?name|client_?id|device_?id|android_?id|vendor_?id|serial(?:_?no|_?number)?|ro\.serialno|imei|hostname|host_name|pc_?name|computer_?name|user_?name|password|passwd|pwd|pin|(?:access_|refresh_|id_)?token|api[_-]?key|x-api-key|(?:client_)?secret|authorization|auth|salt|cookie|session_?id|rikey(?:id)?|client_?cert|private_?key)(\s*[=:]\s*)((?:Bearer\s+|Basic\s+)?(?:"[^"]*"|'[^']*'|[^\s,;&)}\]]+))"#)
    static let quotedHost = regex(#"(?i)(\bhost\s+")([^"]*)(")"#)
    static let unknownHost = regex(#"(UnknownHostException:\s*)(\S+)"#)
    /// The quoted-host rule for "Unable to resolve host "x"" (a host name inside a resolver's error text).
    static let unableToResolve = regex(#"(?i)(\bresolve host\s+")([^"]*)(")"#)
    static let mac = regex(#"(?i)(?<![0-9a-f:-])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f]|[:-][0-9a-f])"#)
    static let ipv4 = regex(#"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?!\d|\.\d)"#)
    static let ipv6Candidate = regex(#"(?<![0-9A-Za-z_:.])[0-9A-Fa-f:]*:[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*(?:%[A-Za-z0-9_.-]+)?"#)
    static let uuid = regex(#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#)
    static let longHex = regex(#"(?i)\b[0-9a-f]{16,}\b"#)
    static let longToken = regex(#"\b(?=[A-Za-z0-9_-]{32,}\b)(?=[A-Za-z0-9_-]*\d)(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{32,}\b"#)
    static let userPath = regex(#"(?i)(/Users/|/home/|[A-Za-z]:[\\/]+Users[\\/]+)([^/\\\s:"']+)"#)
    static let volumePath = regex(#"(/Volumes/|/storage/|/mnt/media_rw/)(?!emulated\b|self\b)([^/\s:"']+)"#)
    static let email = regex(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#)
    static let localHost = regex(
        #"(?i)\b[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9_-]+)*\.(?:local|lan|home|internal|localdomain|home\.arpa|ts\.net|duckdns\.org|dyndns\.[a-z]+|no-ip\.[a-z]+|myfritz\.net|ddns\.net)\b"#)
    /// Query values that carry no identity: small numbers, resolutions and booleans. Anchored at both ends: Kotlin's `matches`
    /// tries every alternative against the whole value, an anchored first match would stop at the first one ("1920" of a size).
    static let safeQueryValue = regex(#"(?i)^(?:\d{1,6}|\d{2,5}x\d{2,5}(?:x\d{1,3})?|true|false)$"#)

    /// Every match of [pattern] in [text] replaced by [transform] of its groups (group 0 the whole match; "" for a group that
    /// did not take part), left to right like Kotlin's `Regex.replace`.
    static func replace(_ pattern: NSRegularExpression, _ text: String, _ transform: ([String], NSRange) -> String) -> String {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var last = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            out += transform(groups, match.range)
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func matchesWhole(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        let length = (text as NSString).length
        guard let match = pattern.firstMatch(in: text, options: [.anchored], range: NSRange(location: 0, length: length)) else { return false }
        return match.range.length == length
    }

    static func trimEnd(_ text: String, _ characters: Set<Character>) -> String {
        var out = Substring(text)
        while let last = out.last, characters.contains(last) { out = out.dropLast() }
        return String(out)
    }

    static func splitHostPort(_ authority: String) -> (String, String) {
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            let host = String(authority[...close])
            var port = String(authority[authority.index(after: close)...])
            if port.hasPrefix(":") { port.removeFirst() }
            return (host, port)
        }
        // A bare IPv6 address in a URL has no port; otherwise the last colon separates it
        if authority.filter({ $0 == ":" }).count > 1 { return (authority, "") }
        guard let colon = authority.lastIndex(of: ":") else { return (authority, "") }
        return (String(authority[..<colon]), String(authority[authority.index(after: colon)...]))
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCIIDigit) && (Int(part) ?? 256) <= 255
        }
    }

    /// A textual IPv6 address with optional zone and IPv4 tail: eight groups, or fewer around one `::`.
    static func isIPv6(_ candidate: String) -> Bool {
        let address = candidate.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard address.filter({ $0 == ":" }).count >= 2, !address.contains(":::") else { return false }
        let halves = address.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
        let groups = halves.flatMap { $0.isEmpty ? [] : $0.components(separatedBy: ":") }
        var count = 0
        for (index, group) in groups.enumerated() {
            if (1...4).contains(group.count) && group.allSatisfy(\.isHexDigit) {
                count += 1
            } else if index == groups.count - 1 && isIPv4(group) {
                count += 2
            } else {
                return false
            }
        }
        return count > 0 && (halves.count == 2 ? count <= 7 : count == 8)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
