/*
 * Search flow/payload adapted from howlongtobeatpy 1.0.24, HTMLRequests.py:
 * https://github.com/ScrappyCocco/HowLongToBeat-PythonAPI/tree/4275a452b9ccd230b7c2a82b8d1a5d851285eb14
 * MIT License — Copyright (c) 2018 Michele
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

import Foundation

/// Direct website client. Each lookup reads at most two search pages and five
/// detail pages. Every HTTP request, including discovery and initialization, is paced.
public actor HowLongToBeatClient {
    public struct SearchAuthorization: Sendable, Equatable {
        public let token: String
        public let key: String?
        public let value: String?
    }

    public struct SearchGame: Sendable, Equatable {
        public let id: Int64
        public let name: String
    }

    public struct SearchPage: Sendable, Equatable {
        public let games: [SearchGame]
        public let total: Int64
    }

    public struct DetailGame: Sendable, Equatable {
        public let name: String
        public let steamAppIDs: Set<Int64>
        public let completion: CompletionTime?
    }

    private static let base = "https://howlongtobeat.com"
    private static let discoveryBackoff: TimeInterval = 300
    private static let maxSearchPages = 2
    private static let maxDetails = 5

    private static let scriptSource = try! NSRegularExpression(
        pattern: #"<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let nextData = try! NSRegularExpression(
        pattern: #"<script\b[^>]*\bid\s*=\s*["']__NEXT_DATA__["'][^>]*>(.*?)</script\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let searchPost = try! NSRegularExpression(
        pattern: #"fetch\s*\(\s*["'](/api/[a-zA-Z0-9_/]*search[a-zA-Z0-9_/]*)[^"']*["']\s*,\s*\{[^}]*method:\s*["']POST["'][^}]*\}"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private let http: MetadataHTTP
    private let pacer: RequestPacer
    private let clock: @Sendable () -> TimeInterval

    private var searchPath: String?
    private var discoveryFailedAt: TimeInterval?
    private var discovery: Task<(String, SearchAuthorization), Error>?

    public init(http: MetadataHTTP = MetadataHTTP()) {
        self.http = http
        self.pacer = RequestPacer(intervalMilliseconds: 500)
        self.clock = { ProcessInfo.processInfo.systemUptime }
    }

    /// Internal injection avoids real delays and wall-clock-dependent backoff tests.
    init(
        http: MetadataHTTP,
        pacer: RequestPacer,
        clock: @escaping @Sendable () -> TimeInterval
    ) {
        self.http = http
        self.pacer = pacer
        self.clock = clock
    }

    public func lookup(
        name: String,
        steamAppIDs: [Int64]
    ) async throws -> CompletionTime? {
        try Task.checkCancellation()

        let title = Self.normalize(name)
        guard !title.isEmpty else { return nil }

        // Preserve the Android client's identity rules: only positive IDs participate.
        let steam = Set(steamAppIDs.filter { $0 > 0 })
        let (path, auth) = try await searchSession()

        var results: [SearchGame] = []
        var resultIndices: [Int64: Int] = [:]
        var page = 1

        while true {
            let payload = try Self.searchPayload(title: name, page: page, auth: auth)
            guard let source = try await request(path, payload: payload, auth: auth) else {
                throw MetadataError.malformedResponse
            }
            let response = try Self.parseSearchResponse(source, expectedPage: page)

            // Updating an existing ID does not change its original provider-order position.
            for game in response.games {
                if let index = resultIndices[game.id] {
                    results[index] = game
                } else {
                    resultIndices[game.id] = results.count
                    results.append(game)
                }
            }

            page += 1
            if page > Self.maxSearchPages || Int64(page) > response.total {
                break
            }
        }

        let baseTitle = Self.editionBase(title)
        let ranked = results.enumerated().sorted { lhs, rhs in
            let left = Self.closeness(Self.normalize(lhs.element.name), title)
            let right = Self.closeness(Self.normalize(rhs.element.name), title)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)

        let candidates: [SearchGame]
        if !steam.isEmpty {
            candidates = Array(ranked.prefix(Self.maxDetails))
        } else {
            let exact = ranked.filter { Self.normalize($0.name) == title }
            let eligible: [SearchGame]
            if !exact.isEmpty {
                eligible = exact
            } else if let baseTitle {
                eligible = ranked.filter { Self.normalize($0.name) == baseTitle }
            } else {
                eligible = []
            }
            candidates = Array(eligible.prefix(Self.maxDetails))
        }

        var details: [DetailGame] = []
        var failure: MetadataError?

        for candidate in candidates {
            try Task.checkCancellation()
            do {
                if let detail = try await detail(id: candidate.id) {
                    details.append(detail)
                }
            } catch let error as MetadataError {
                // Blocking and rate limiting stop immediately; unreadable individual
                // detail pages must not hide an otherwise verifiable candidate.
                if case .httpStatus = error {
                    throw error
                }
                failure = error
            }
        }

        try Task.checkCancellation()

        if details.isEmpty, let failure {
            throw failure
        }

        let matchingSteam = steam.isEmpty
            ? []
            : details.filter { !$0.steamAppIDs.isDisjoint(with: steam) }

        if matchingSteam.count > 1 { return nil }
        if let match = matchingSteam.first { return match.completion }

        let exact = details.filter {
            Self.normalize($0.name) == title
                && (steam.isEmpty || $0.steamAppIDs.isEmpty)
        }

        if !exact.isEmpty || !steam.isEmpty || baseTitle == nil {
            return exact.count == 1 ? exact[0].completion : nil
        }

        let baseMatches = details.filter { Self.normalize($0.name) == baseTitle }
        return baseMatches.count == 1 ? baseMatches[0].completion : nil
    }

    /// HLTB's literal normalization intentionally does not apply general fuzzy matching.
    public nonisolated static func normalize(_ title: String) -> String {
        title
            .replacingOccurrences(of: "™", with: "")
            .replacingOccurrences(of: "®", with: "")
            .precomposedStringWithCompatibilityMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(
                of: #"[^\p{L}\p{N}]+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    public nonisolated static func discoverScriptPaths(in html: String) -> [String] {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var paths: [String] = []
        var seen: Set<String> = []

        for match in scriptSource.matches(in: html, range: range) {
            guard let capture = Range(match.range(at: 1), in: html) else { continue }
            let path = String(html[capture])
            guard path.hasPrefix("/_next/static/chunks/"), path.hasSuffix(".js"),
                  seen.insert(path).inserted else {
                continue
            }
            paths.append(path)
        }
        return paths
    }

    public nonisolated static func discoverSearchPath(in source: String) -> String? {
        guard let path = capture(searchPost, in: source) else { return nil }
        return String(path.reversed().drop(while: { $0 == "/" }).reversed())
    }

    public nonisolated static func parseAuthorization(
        _ data: Data
    ) throws -> SearchAuthorization {
        let root = try object(data)
        let token = try text(root, "token")
        guard !isBlank(token) else { throw MetadataError.malformedResponse }

        let keyField = root.first { $0.key.range(of: "key", options: .caseInsensitive) != nil }
        let valueField = root.first { $0.key.range(of: "val", options: .caseInsensitive) != nil }

        guard (keyField == nil) == (valueField == nil) else {
            throw MetadataError.malformedResponse
        }

        let key: String?
        let value: String?
        if let keyField, let valueField {
            guard let parsedKey = keyField.value as? String,
                  let parsedValue = valueField.value as? String,
                  !isBlank(parsedKey) else {
                throw MetadataError.malformedResponse
            }
            key = parsedKey
            value = parsedValue
        } else {
            key = nil
            value = nil
        }

        return SearchAuthorization(token: token, key: key, value: value)
    }

    public nonisolated static func searchPayload(
        title: String,
        page: Int,
        auth: SearchAuthorization
    ) throws -> Data {
        var payload: [String: Any] = [
            "searchType": "games",
            "searchTerms": title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty },
            "searchPage": page,
            "size": 20,
            "searchOptions": [
                "games": [
                    "userId": 0,
                    "platform": "",
                    "sortCategory": "popular",
                    "rangeCategory": "main",
                    "rangeTime": ["min": 0, "max": 0],
                    "gameplay": [
                        "perspective": "",
                        "flow": "",
                        "genre": "",
                        "difficulty": ""
                    ],
                    "rangeYear": ["max": "", "min": ""],
                    "modifier": ""
                ],
                "users": ["sortCategory": "postcount"],
                "lists": ["sortCategory": "follows"],
                "filter": "",
                "sort": 0,
                "randomizer": 0
            ],
            "useCache": true
        ]

        if let key = auth.key, let value = auth.value {
            payload[key] = value
        }

        do {
            return try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw MetadataError.invalidRequest
        }
    }

    public nonisolated static func parseSearchResponse(
        _ data: Data,
        expectedPage: Int
    ) throws -> SearchPage {
        let root = try object(data)
        guard let games = root["data"] as? [Any],
              let current = try integer(root, "pageCurrent"),
              let total = try integer(root, "pageTotal"),
              current == Int64(expectedPage),
              total >= 0,
              games.isEmpty || total >= Int64(expectedPage) else {
            throw MetadataError.malformedResponse
        }

        let parsed = try games.map { value -> SearchGame in
            let game = try dictionary(value)
            guard let id = try integer(game, "game_id"), id > 0 else {
                throw MetadataError.malformedResponse
            }
            let name = try text(game, "game_name")
            guard !isBlank(name) else { throw MetadataError.malformedResponse }
            return SearchGame(id: id, name: name)
        }

        return SearchPage(games: parsed, total: total)
    }

    public nonisolated static func parseDetailPage(
        _ html: String,
        expectedID: Int64
    ) throws -> DetailGame? {
        guard let script = capture(nextData, in: html),
              let data = script.data(using: .utf8) else {
            throw MetadataError.malformedResponse
        }

        let root = try object(data)
        let props = try dictionary(root["props"])
        let page = try dictionary(props["pageProps"])

        if let notFound = page["notFound"] as? NSNumber,
           isBoolean(notFound), notFound.boolValue {
            return nil
        }

        let game = try dictionary(page["game"])
        let gameData = try dictionary(game["data"])
        guard let games = gameData["game"] as? [Any] else {
            throw MetadataError.malformedResponse
        }
        if games.isEmpty { return nil }
        guard games.count == 1 else { throw MetadataError.malformedResponse }

        let entry = try dictionary(games[0])
        guard try integer(entry, "game_id") == expectedID else {
            throw MetadataError.malformedResponse
        }

        let name = try text(entry, "game_name")
        guard !isBlank(name) else { throw MetadataError.malformedResponse }

        var steam: Set<Int64> = []
        if let id = try integer(entry, "profile_steam"), id > 0 {
            steam.insert(id)
        }
        if entry.keys.contains("profile_steam_alt"),
           let id = try integer(entry, "profile_steam_alt"), id > 0 {
            steam.insert(id)
        }

        let seconds = try integer(entry, "comp_all")
        let count = try integer(entry, "comp_all_count")
        guard seconds.map({ $0 >= 0 }) ?? true,
              count.map({ $0 >= 0 }) ?? true else {
            throw MetadataError.malformedResponse
        }

        let completion: CompletionTime?
        if let seconds, seconds > 0, let count, count > 0 {
            completion = CompletionTime(
                id: expectedID,
                name: name,
                seconds: seconds,
                url: "\(base)/game/\(expectedID)"
            )
        } else {
            completion = nil
        }

        return DetailGame(name: name, steamAppIDs: steam, completion: completion)
    }

    private func detail(id: Int64) async throws -> DetailGame? {
        guard let data = try await request("/game/\(id)", allowMissing: true) else {
            return nil
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw MetadataError.malformedResponse
        }
        return try Self.parseDetailPage(html, expectedID: id)
    }

    private func searchSession() async throws -> (String, SearchAuthorization) {
        if let searchPath {
            return (searchPath, try await searchAuthorization(path: searchPath))
        }

        if let discovery {
            return try await Self.awaitDiscovery(discovery)
        }

        if let failedAt = discoveryFailedAt,
           clock() - failedAt < Self.discoveryBackoff {
            throw MetadataError.unavailable
        }

        let task = Task<(String, SearchAuthorization), Error> {
            let path = try await self.discover()
            let auth = try await self.searchAuthorization(path: path)
            return (path, auth)
        }
        discovery = task

        do {
            let session = try await Self.awaitDiscovery(task)
            searchPath = session.0
            discoveryFailedAt = nil
            discovery = nil
            return session
        } catch {
            discovery = nil
            if !(error is CancellationError) {
                discoveryFailedAt = clock()
            }
            throw error
        }
    }

    private nonisolated static func awaitDiscovery(
        _ task: Task<(String, SearchAuthorization), Error>
    ) async throws -> (String, SearchAuthorization) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }

    private func discover() async throws -> String {
        guard let data = try await request("/"),
              let html = String(data: data, encoding: .utf8) else {
            throw MetadataError.malformedResponse
        }

        for script in Self.discoverScriptPaths(in: html) {
            guard let data = try await request(script),
                  let source = String(data: data, encoding: .utf8) else {
                throw MetadataError.malformedResponse
            }
            if let path = Self.discoverSearchPath(in: source) {
                return path
            }
        }

        throw MetadataError.malformedResponse
    }

    private func searchAuthorization(path: String) async throws -> SearchAuthorization {
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        guard let data = try await request("\(path)/init?t=\(milliseconds)") else {
            throw MetadataError.malformedResponse
        }
        return try Self.parseAuthorization(data)
    }

    private func request(
        _ path: String,
        payload: Data? = nil,
        auth: SearchAuthorization? = nil,
        allowMissing: Bool = false
    ) async throws -> Data? {
        try Task.checkCancellation()
        try await pacer.wait()
        try Task.checkCancellation()

        guard let url = URL(string: Self.base + path),
              url.scheme == "https",
              url.host == "howlongtobeat.com",
              url.user == nil,
              url.password == nil else {
            throw MetadataError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.setValue("Delos/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(Self.base + "/", forHTTPHeaderField: "Referer")
        request.setValue(Self.base, forHTTPHeaderField: "Origin")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        if let payload {
            request.httpMethod = "POST"
            request.httpBody = payload
            request.setValue(
                "application/json; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
        }
        if let auth {
            request.setValue(auth.token, forHTTPHeaderField: "x-auth-token")
            if let key = auth.key {
                request.setValue(key, forHTTPHeaderField: "x-hp-key")
            }
            if let value = auth.value {
                request.setValue(value, forHTTPHeaderField: "x-hp-val")
            }
        }

        do {
            let data = try await http.send(request)
            try Task.checkCancellation()
            return data
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            if let error = error as? MetadataError {
                if allowMissing, case .httpStatus(404) = error {
                    return nil
                }
                throw error
            }
            throw MetadataError.unavailable
        }
    }

    private nonisolated static func editionBase(_ title: String) -> String? {
        let base = title.replacingOccurrences(
            of: #"\s+(?:\S+\s+)?edition$"#,
            with: "",
            options: .regularExpression
        )
        return base != title && !base.isEmpty ? base : nil
    }

    private nonisolated static func closeness(_ name: String, _ title: String) -> Int {
        if name == title { return 0 }
        if !name.isEmpty && (name.contains(title) || title.contains(name)) { return 1 }
        return 2
    }

    private nonisolated static func capture(
        _ expression: NSRegularExpression,
        in source: String
    ) -> String? {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = expression.firstMatch(in: source, range: range),
              let capture = Range(match.range(at: 1), in: source) else {
            return nil
        }
        return String(source[capture])
    }

    private nonisolated static func object(_ data: Data) throws -> [String: Any] {
        do {
            return try dictionary(JSONSerialization.jsonObject(with: data))
        } catch {
            throw MetadataError.malformedResponse
        }
    }

    private nonisolated static func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let result = value as? [String: Any] else {
            throw MetadataError.malformedResponse
        }
        return result
    }

    private nonisolated static func text(
        _ object: [String: Any],
        _ field: String
    ) throws -> String {
        guard let value = object[field] as? String else {
            throw MetadataError.malformedResponse
        }
        return value
    }

    private nonisolated static func integer(
        _ object: [String: Any],
        _ field: String
    ) throws -> Int64? {
        guard let value = object[field] else {
            throw MetadataError.malformedResponse
        }
        if value is NSNull { return nil }

        let source: String
        if let string = value as? String {
            source = string
        } else if let number = value as? NSNumber, !isBoolean(number) {
            // Gson's toLongOrNull rejects decimals rather than truncating them.
            let type = String(cString: number.objCType)
            guard type != "f", type != "d" else {
                throw MetadataError.malformedResponse
            }
            source = number.stringValue
        } else {
            throw MetadataError.malformedResponse
        }

        guard let result = Int64(source) else {
            throw MetadataError.malformedResponse
        }
        return result
    }

    private nonisolated static func isBoolean(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        return type == "c" || type == "B"
    }

    private nonisolated static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
