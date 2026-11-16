import Foundation

/// MetadataPolicy.kt: provider errors are not negative matches; each provider has its own retry window.
public enum MetadataPolicy {
    public static let maximumAge: Int64 = 7 * 24 * 60 * 60 * 1000
    public static let absentMaximumAge: Int64 = 6 * 60 * 60 * 1000
    public static let failureBackoff: Int64 = 30 * 60 * 1000

    public static func isFresh(_ time: Int64, maximumAge: Int64, now: Int64) -> Bool {
        time > 0 && time <= now && now - time < maximumAge
    }
    public static func isBackedOff(_ time: Int64, now: Int64) -> Bool {
        isFresh(time, maximumAge: failureBackoff, now: now)
    }
    public static func refreshDue(_ data: GameMetadata?, now: Int64) -> Bool {
        guard let data else { return true }
        let failures = [data.igdbFailedAt, data.pcgwFailedAt, data.hltbFailedAt, data.steamFailedAt].filter { $0 > 0 }
        if data.candidate == nil {
            return failures.isEmpty ? !isFresh(data.updatedAt, maximumAge: absentMaximumAge, now: now)
                : failures.contains { !isBackedOff($0, now: now) }
        }
        if isFresh(data.updatedAt, maximumAge: maximumAge, now: now) { return false }
        return failures.isEmpty || failures.contains { !isBackedOff($0, now: now) }
    }

    private static let suffixes = [
        "game of the year edition", "game of the year", "goty edition", "goty", "directors cut",
        "definitive edition", "complete edition", "deluxe edition", "ultimate edition", "enhanced edition",
        "special edition", "gold edition", "anniversary edition", "standard edition", "collectors edition",
        "legendary edition", "premium edition", "digital edition", "limited edition", "remastered",
    ].map { $0.split(separator: " ").map(String.init) }.sorted { $0.count > $1.count }
    private static let separators = try! NSRegularExpression(pattern: "[^\\p{L}\\p{N}]+")
    private static let bracketed = try! NSRegularExpression(pattern: "[(\\[][^)\\]]*[)\\]]")
    private static let apostrophes = try! NSRegularExpression(pattern: "['‘’`´]")
    private static let roman = try! NSRegularExpression(pattern: "^(?:x{1,2}(?:ix|iv|v?i{0,3})|ix|iv|v?i{1,3})$")
    private static let year = try! NSRegularExpression(pattern: "[(\\[]\\s*((?:19|20)\\d{2})\\s*[)\\]]")
    private static let symbols = try! NSRegularExpression(pattern: "[\\p{So}\\p{Cf}]")
    private static let whitespace = try! NSRegularExpression(pattern: "\\s+")

    private static func replace(_ text: String, _ regex: NSRegularExpression, with replacement: String = "") -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
    private static func plain(_ text: String) -> String {
        let stripped = text.replacingOccurrences(of: "™", with: "").replacingOccurrences(of: "®", with: "")
            .replacingOccurrences(of: "©", with: "").decomposedStringWithCanonicalMapping
        let scalars = stripped.unicodeScalars.filter { !CharacterSet.nonBaseCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars)).lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
    public static func literalKey(_ name: String) -> String { replace(plain(name), separators) }
    public static func searchTerm(_ name: String) -> String {
        replace(replace(name, symbols), whitespace, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func matchKey(_ name: String) -> String {
        let words = replace(replace(plain(name), bracketed, with: " ").replacingOccurrences(of: "&", with: " and "), apostrophes)
        var tokens = replace(words, separators, with: " ").split(separator: " ").map(String.init).filter { $0 != "and" }
        if tokens.count > 1, tokens.first == "the" { tokens.removeFirst() }
        while let suffix = suffixes.first(where: { tokens.count > $0.count && tokens.suffix($0.count).elementsEqual($0) }) {
            tokens.removeLast(suffix.count)
            if tokens.count > 1, tokens.last == "the" { tokens.removeLast() }
        }
        return tokens.map { token in
            guard token.count >= 2, roman.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil else { return token }
            let digits = token.map { $0 == "i" ? 1 : $0 == "v" ? 5 : 10 }
            return String(digits.indices.reduce(0) { total, i in
                total + (i + 1 < digits.count && digits[i] < digits[i + 1] ? -digits[i] : digits[i])
            })
        }.joined()
    }
    public static func chooseMatch(hostName: String, candidates: [MetadataCandidate]) -> MetadataCandidate? {
        let key = matchKey(hostName)
        guard !key.isEmpty else { return nil }
        var pool = candidates.filter { matchKey($0.name) == key }
        if pool.isEmpty {
            let host = replace(replace(plain(hostName), bracketed, with: " "), whitespace, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = candidates.filter { candidate in
                let name = replace(plain(candidate.name), whitespace, with: " ")
                guard candidate.isPC || !candidate.steamAppIDs.isEmpty, name.hasPrefix(host) else { return false }
                let tail = name.dropFirst(host.count)
                return [":", " - ", " – ", " — "].contains { tail.hasPrefix($0) }
            }
            return matches.count == 1 ? matches[0] : nil
        }
        if pool.count == 1 { return pool[0] }
        func narrow(_ predicate: (MetadataCandidate) -> Bool) -> MetadataCandidate? {
            let smaller = pool.filter(predicate)
            if !smaller.isEmpty { pool = smaller }
            return pool.count == 1 ? pool[0] : nil
        }
        let literal = literalKey(hostName)
        if let value = narrow({ literalKey($0.name) == literal }) { return value }
        if let match = year.firstMatch(in: hostName, range: NSRange(hostName.startIndex..., in: hostName)),
           let range = Range(match.range(at: 1), in: hostName), let hostYear = Int(hostName[range]),
           let value = narrow({ $0.year == hostYear }) { return value }
        if let value = narrow({ !$0.steamAppIDs.isEmpty }) { return value }
        if let value = narrow({ $0.isPC }) { return value }
        if let newest = pool.compactMap(\.year).max(), let value = narrow({ $0.year == newest }) { return value }
        let ranked = pool.sorted { $0.ratingCount > $1.ratingCount }
        return ranked[0].ratingCount > 0 && ranked[0].ratingCount / 3 >= ranked[1].ratingCount ? ranked[0] : nil
    }
}
