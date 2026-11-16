import Foundation

public struct PCGamingWikiClient: Sendable {
    private let state: State

    public init(baseURL: String, http: MetadataHTTP = MetadataHTTP()) {
        state = State(baseURL: baseURL, http: http)
    }

    public func lookup(steamAppIDs: [Int64], name: String) async throws -> HDREvidence {
        try await state.lookup(steamAppIDs: steamAppIDs, name: name)
    }

    private actor State {
        private struct Cached {
            let inserted: ContinuousClock.Instant
            let evidence: HDREvidence
        }

        private let baseURL: String
        private let http: MetadataHTTP
        private let pacer = RequestPacer(intervalMilliseconds: 1050)
        private let clock = ContinuousClock()
        private var cache: [String: Cached] = [:]
        private var insertionOrder: [String] = []
        private var inFlight: [String: Task<HDREvidence, Error>] = [:]

        init(baseURL: String, http: MetadataHTTP) {
            self.baseURL = baseURL
            self.http = http
        }

        func lookup(steamAppIDs: [Int64], name: String) async throws -> HDREvidence {
            guard steamAppIDs.allSatisfy({ $0 > 0 }) else {
                throw MetadataError.invalidRequest
            }
            let ids = Array(
                Set(steamAppIDs.filter { $0 <= MetadataProxy.maxSteamAppID })
                    .sorted()
                    .prefix(20)
            )
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if ids.isEmpty && trimmedName.isEmpty { return HDREvidence() }

            let key = ids.isEmpty
                ? "title:\(trimmedName)"
                : "steam:\(ids.map(String.init).joined(separator: ","))"

            if let cached = cache[key],
               cached.inserted.duration(to: clock.now) < .seconds(6 * 60 * 60) {
                return cached.evidence
            }
            if let task = inFlight[key] {
                return try await Self.value(task)
            }

            let task = Task {
                try await self.resolve(ids: ids, name: name)
            }
            inFlight[key] = task

            do {
                let evidence = try await Self.value(task)
                inFlight[key] = nil
                // Android uses insertion order rather than an access-order LRU.
                if cache.count >= 128, let oldest = insertionOrder.first {
                    cache[oldest] = nil
                    insertionOrder.removeFirst()
                }
                if cache[key] == nil { insertionOrder.append(key) }
                cache[key] = Cached(inserted: clock.now, evidence: evidence)
                return evidence
            } catch {
                inFlight[key] = nil
                throw error
            }
        }

        private nonisolated static func value(_ task: Task<HDREvidence, Error>) async throws -> HDREvidence {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let result = try await task.value
                try Task.checkCancellation()
                return result
            } onCancel: { task.cancel() }
        }

        private func resolve(ids: [Int64], name: String) async throws -> HDREvidence {
            var pages: [String]
            if ids.isEmpty {
                pages = try await pagesByTitle(name, withoutSteamID: false)
            } else {
                pages = try await wikiPages(
                    selector: "steam",
                    value: ids.map(String.init).joined(separator: ","),
                    withoutSteamID: false
                )
            }
            if pages.isEmpty && !ids.isEmpty &&
                !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages = try await pagesByTitle(name, withoutSteamID: true)
            }
            guard !pages.isEmpty, pages.count <= 3 else { return HDREvidence() }

            var results: [HDREvidence] = []
            for page in pages {
                let data = try await api(
                    path: "v1/pcgw/page",
                    parameter: "title",
                    value: page
                )
                let source = try PCGamingWikiClient.parsePage(data)
                results.append(PCGamingWikiClient.parseVideo(source, page: page))
            }
            let first = results[0]
            if results.count == 1 ||
                (first.support != .unknown && results.allSatisfy({ $0.support == first.support })) {
                return first
            }
            return HDREvidence()
        }

        private func pagesByTitle(_ title: String, withoutSteamID: Bool) async throws -> [String] {
            guard let name = MetadataProxy.title(
                title.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "_", with: " ")
            ) else { return [] }

            let exact = try await resolveTitle(name, withoutSteamID: withoutSteamID)
            if !exact.isEmpty { return exact }

            let searchData = try await api(
                path: "v1/pcgw/search",
                parameter: "q",
                value: name
            )
            let key = MetadataPolicy.literalKey(name)
            let similar = try PCGamingWikiClient.parseSearchTitles(searchData)
                .filter { $0 != name && MetadataPolicy.literalKey($0) == key }
                .prefix(2)
            for title in similar {
                let resolved = try await resolveTitle(title, withoutSteamID: withoutSteamID)
                if !resolved.isEmpty { return resolved }
            }
            return []
        }

        private func resolveTitle(_ page: String, withoutSteamID: Bool) async throws -> [String] {
            guard MetadataProxy.title(page) != nil else { return [] }
            let exact = try await wikiPages(
                selector: "page",
                value: page,
                withoutSteamID: withoutSteamID
            )
            if !exact.isEmpty { return exact }

            let redirectData = try await api(
                path: "v1/pcgw/redirect",
                parameter: "title",
                value: page
            )
            guard let target = try PCGamingWikiClient.parseRedirectTarget(redirectData),
                  MetadataProxy.title(target) != nil else { return [] }
            return try await wikiPages(
                selector: "page",
                value: target,
                withoutSteamID: withoutSteamID
            )
        }

        private func wikiPages(
            selector: String,
            value: String,
            withoutSteamID: Bool
        ) async throws -> [String] {
            let data = try await api(
                path: "v1/pcgw/cargo",
                parameter: selector,
                value: value
            )
            return try PCGamingWikiClient.parseCargoPages(data, withoutSteamID: withoutSteamID)
        }

        private func api(path: String, parameter: String, value: String) async throws -> Data {
            guard let url = MetadataProxy.url(
                baseURL: baseURL,
                path: path,
                parameters: [URLQueryItem(name: parameter, value: value)]
            ) else {
                throw MetadataError.unavailable
            }
            try await pacer.wait()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return try await http.send(request)
        }
    }

    /// Reject API errors without retaining upstream text or submitted parameters.
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any],
              object["error"] == nil,
              object["errors"] == nil else {
            throw MetadataError.malformedResponse
        }
        return object
    }

    public static func parseCargoPages(
        _ data: Data,
        withoutSteamID: Bool = false
    ) throws -> [String] {
        let object = try object(data)
        guard let rows = object["cargoquery"] as? [[String: Any]] else {
            throw MetadataError.malformedResponse
        }
        var pages: [String] = []
        var seen: Set<String> = []
        for row in rows {
            guard let title = row["title"] as? [String: Any] else {
                throw MetadataError.malformedResponse
            }
            if withoutSteamID {
                // Gson treats missing/non-primitive Steam values as blank here.
                let steam: String
                if let string = title["Steam"] as? String {
                    steam = string
                } else if let number = title["Steam"] as? NSNumber {
                    steam = number.stringValue
                } else {
                    steam = ""
                }
                if !steam.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
            }
            guard let page = title["Page"] as? String else {
                throw MetadataError.malformedResponse
            }
            if seen.insert(page).inserted { pages.append(page) }
        }
        return pages
    }

    public static func parseRedirectTarget(_ data: Data) throws -> String? {
        let object = try object(data)
        guard let value = object["query"] else { return nil }
        guard let query = value as? [String: Any] else {
            throw MetadataError.malformedResponse
        }
        guard let value = query["redirects"] else { return nil }
        guard let redirects = value as? [[String: Any]] else {
            throw MetadataError.malformedResponse
        }
        guard let last = redirects.last else { return nil }
        guard let value = last["to"] else { return nil }
        guard let target = value as? String else {
            throw MetadataError.malformedResponse
        }
        return target
    }

    public static func parseSearchTitles(_ data: Data) throws -> [String] {
        let object = try object(data)
        guard let value = object["query"] else { return [] }
        guard let query = value as? [String: Any] else {
            throw MetadataError.malformedResponse
        }
        guard let value = query["search"] else { return [] }
        guard let rows = value as? [[String: Any]] else {
            throw MetadataError.malformedResponse
        }
        return try rows.map {
            guard let title = $0["title"] as? String else {
                throw MetadataError.malformedResponse
            }
            return title
        }
    }

    public static func parsePage(_ data: Data) throws -> String {
        let object = try object(data)
        guard let parse = object["parse"] as? [String: Any],
              let wikitext = parse["wikitext"] as? [String: Any],
              let source = wikitext["*"] as? String else {
            throw MetadataError.malformedResponse
        }
        return source
    }

    private static let comments = try! NSRegularExpression(
        pattern: #"<!--.*?-->"#,
        options: .dotMatchesLineSeparators
    )
    private static let videoStart = try! NSRegularExpression(
        pattern: #"\{\{\s*(?:Template:)?Video\s*(?=[|}])"#,
        options: .caseInsensitive
    )
    private static let retrofitOnly = try! NSRegularExpression(
        pattern: #"\b(?:only|requires?|required|must|via|using|through)\b[^.]{0,60}\b(?:special\s*k|reshade|auto\s*hdr|rtx\s*hdr|mod|retrofit)\b|\b(?:use|enable|with)\s+(?:special\s*k|reshade|auto\s*hdr|rtx\s*hdr)\b|\b(?:no|not|without)\s+native\b|\bnot supported natively"#,
        options: .caseInsensitive
    )
    private static let limitedSupport = try! NSRegularExpression(
        pattern: #"\bconsoles?\b|\bxbox\b|playstation|\bps[345]\b|nintendo\s+switch|\bswitch\s+(?:version|edition)\b|\bnot supported\b|\bunsupported\b|\b(?:specific|certain|some|particular|newer|older|later|earlier)\s+(?:versions?|editions?|builds?)\b|\b(?:enhanced|special|deluxe|ultimate|gold|definitive|complete|anniversary|remastered?)\s+editions?\b|\bonly\b[^.]{0,40}\b(?:versions?|editions?)\b"#,
        options: .caseInsensitive
    )
    private static let notWorking = try! NSRegularExpression(
        pattern: #"\bhdr\b[^.]{0,30}\b(?:is|are|was|currently|now|still)\s+(?:\w+\s+)?broken\b|^\s*broken\b|currently disabled|disabled in (?:a |the )?(?:recent|latest|current|last)\b|\bhdr\b[^.]{0,30}\b(?:does not|doesn't|do not|don't|cannot|can't|will not|won't)\s+work\b(?!\s+(?:well|properly|correctly))|\bno longer\s+(?:works?|available|supported|present)\b|\bsimulated\s+hdr\b|\bfake\s+hdr\b"#,
        options: .caseInsensitive
    )
    private static let references = try! NSRegularExpression(
        pattern: #"<ref\b[^>]*?/>|<ref\b[^>]*>.*?</ref\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let htmlTags = try! NSRegularExpression(pattern: #"</?[a-zA-Z][^>]*>"#)
    private static let innerTemplate = try! NSRegularExpression(pattern: #"\{\{([^{}]*)\}\}"#)
    private static let wikiLink = try! NSRegularExpression(
        pattern: #"\[\[([^\]|]*)(?:\|([^\]]*))?\]\]"#
    )
    private static let namespaceTarget = try! NSRegularExpression(
        pattern: #"\s*(?:file|image|category|media):.*"#,
        options: .caseInsensitive
    )
    private static let externalLink = try! NSRegularExpression(
        pattern: #"\[(?:https?:)?//[^\s\]]+(?:\s+([^\]]*))?\]"#,
        options: .caseInsensitive
    )
    private static let bareURL = try! NSRegularExpression(
        pattern: #"(?:https?://|www\.)\S+"#,
        options: .caseInsensitive
    )
    private static let entity = try! NSRegularExpression(pattern: #"&(?:[a-zA-Z]+|#\d+);"#)
    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)

    private static func contains(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replace(
        _ regex: NSRegularExpression,
        in text: String,
        with replacement: String
    ) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }

    private static func transform(
        _ regex: NSRegularExpression,
        in text: String,
        replacement: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        var output = ""
        var end = 0
        for match in matches {
            output += source.substring(with: NSRange(location: end, length: match.range.location - end))
            output += replacement(match, source)
            end = NSMaxRange(match.range)
        }
        output += source.substring(from: end)
        return output
    }

    private static func group(_ index: Int, _ match: NSTextCheckingResult, _ source: NSString) -> String {
        let range = match.range(at: index)
        return range.location == NSNotFound ? "" : source.substring(with: range)
    }

    public static func plainText(_ wikitext: String) -> String {
        var text = replace(references, in: wikitext, with: " ")
        text = replace(htmlTags, in: text, with: " ")
        while true {
            let before = text
            text = transform(innerTemplate, in: text) { match, source in
                group(1, match, source)
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .dropFirst()
                    .filter { !$0.contains("=") }
                    .joined(separator: " ")
            }
            if text == before { break }
        }
        text = transform(wikiLink, in: text) { match, source in
            let target = group(1, match, source)
            let label = group(2, match, source)
            let targetRange = NSRange(target.startIndex..., in: target)
            let namespace = namespaceTarget.firstMatch(in: target, range: targetRange)
            let discardTarget = target.hasPrefix("#") || namespace?.range == targetRange
            return ((discardTarget ? "" : target) + " " + label)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = transform(externalLink, in: text) { match, source in
            group(1, match, source)
        }
        text = replace(bareURL, in: text, with: " ")
        text = text.replacingOccurrences(of: "'''", with: "")
            .replacingOccurrences(of: "''", with: "")
        text = replace(entity, in: text, with: " ")
        return replace(whitespace, in: text, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads only Video's own fields; nested templates, links and references keep their pipes.
    public static func parseVideo(_ wikitext: String, page: String) -> HDREvidence {
        let clean = replace(comments, in: wikitext, with: "")
        let text = clean as NSString
        guard let start = videoStart.firstMatch(
            in: clean,
            range: NSRange(location: 0, length: text.length)
        ) else {
            return HDREvidence(support: .unknown, page: page)
        }

        func starts(_ token: String, at index: Int, insensitive: Bool = false) -> Bool {
            let length = (token as NSString).length
            guard index >= 0, index + length <= text.length else { return false }
            return text.compare(
                token,
                options: insensitive ? .caseInsensitive : [],
                range: NSRange(location: index, length: length)
            ) == .orderedSame
        }

        func startsReference(at index: Int) -> Bool {
            guard starts("<ref", at: index, insensitive: true) else { return false }
            let next = index + 4
            guard next < text.length else { return true }
            let unit = text.character(at: next)
            return unit == 62 || unit == 47 ||
                UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } == true
        }

        var parts: [String] = []
        var partStart = NSMaxRange(start.range)
        var index = partStart
        var templates = 1
        var links = 0

        while index < text.length - 1 {
            if startsReference(at: index) {
                let tail = NSRange(location: index, length: text.length - index)
                let tagEnd = text.range(of: ">", range: tail)
                var close = NSRange(location: NSNotFound, length: 0)
                if tagEnd.location != NSNotFound,
                   tagEnd.location > 0,
                   text.character(at: tagEnd.location - 1) != 47 {
                    close = text.range(
                        of: "</ref",
                        options: .caseInsensitive,
                        range: NSRange(
                            location: tagEnd.location,
                            length: text.length - tagEnd.location
                        )
                    )
                }
                index = close.location == NSNotFound ? index + 4 : close.location + 5
                continue
            }
            if starts("{{", at: index) {
                templates += 1
                index += 2
                continue
            }
            if starts("}}", at: index) {
                templates -= 1
                if templates == 0 {
                    parts.append(text.substring(
                        with: NSRange(location: partStart, length: index - partStart)
                    ))
                    break
                }
                index += 2
                continue
            }
            if starts("[[", at: index) {
                links += 1
                index += 2
                continue
            }
            if starts("]]", at: index) {
                if links > 0 { links -= 1 }
                index += 2
                continue
            }
            if text.character(at: index) == 124 && templates == 1 && links == 0 {
                parts.append(text.substring(
                    with: NSRange(location: partStart, length: index - partStart)
                ))
                partStart = index + 1
            }
            index += 1
        }

        guard templates == 0 else {
            return HDREvidence(support: .unknown, page: page)
        }
        var fields: [String: String] = [:]
        for part in parts {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = part[..<equals]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: " ")
            fields[key] = String(part[part.index(after: equals)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let value = fields["hdr"]?.lowercased()
        let notes = fields["hdr notes"].flatMap { $0.isEmpty ? nil : $0 }
        let support: NativeHDR
        if value == "false" || value == "hackable" {
            support = .sdr
        } else if !["true", "always on", "alwayson", "limited"].contains(value ?? "") {
            support = .unknown
        } else if let notes {
            let prose = plainText(notes)
            support = contains(retrofitOnly, prose) ||
                contains(limitedSupport, prose) ||
                contains(notWorking, prose) ? .unknown : .hdr
        } else {
            support = .hdr
        }
        return HDREvidence(support: support, page: page, notes: notes)
    }
}
