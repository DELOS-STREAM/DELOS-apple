import Foundation

public struct IGDBMetadataClient: Sendable {
    private let baseURL: String
    private let http: MetadataHTTP
    private let pacer: RequestPacer

    public init(baseURL: String, http: MetadataHTTP = MetadataHTTP()) {
        self.baseURL = baseURL
        self.http = http
        self.pacer = RequestPacer(intervalMilliseconds: 260)
    }

    public func search(_ query: String) async throws -> [MetadataCandidate] {
        let term = MetadataProxy.term(MetadataPolicy.searchTerm(query))
        guard !term.isEmpty else { return [] }
        return Self.preferPC(try await games(parameter: "search", value: term))
    }

    public func game(_ id: Int64) async throws -> MetadataCandidate? {
        guard id > 0 else { throw MetadataError.invalidRequest }
        return try await games(parameter: "id", value: String(id)).first
    }

    /// The overview's details of game [id] (`/v1/igdb/game-details`); nil when the Worker knows no such game (404).
    public func details(_ id: Int64) async throws -> GameDetails? {
        guard id > 0 else { throw MetadataError.invalidRequest }
        guard let url = MetadataProxy.url(baseURL: baseURL, path: "v1/igdb/game-details",
                                          parameters: [URLQueryItem(name: "id", value: String(id))]) else {
            throw MetadataError.unavailable
        }
        try await pacer.wait()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            return try GameDetails.parse(await http.send(request))
        } catch MetadataError.httpStatus(404) {
            return nil
        }
    }

    private func games(parameter: String, value: String) async throws -> [MetadataCandidate] {
        guard let url = MetadataProxy.url(
            baseURL: baseURL,
            path: "v1/igdb/games",
            parameters: [URLQueryItem(name: parameter, value: value)]
        ) else {
            throw MetadataError.unavailable
        }
        try await pacer.wait()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try Self.parseGames(await http.send(request))
    }

    /// Stable buckets: PC/Steam, unknown platforms, then console-only.
    public static func preferPC(_ candidates: [MetadataCandidate]) -> [MetadataCandidate] {
        var preferred: [MetadataCandidate] = []
        var unknown: [MetadataCandidate] = []
        var console: [MetadataCandidate] = []
        for candidate in candidates {
            if candidate.isPC || !candidate.steamAppIDs.isEmpty {
                preferred.append(candidate)
            } else if candidate.platformIDs.isEmpty {
                unknown.append(candidate)
            } else {
                console.append(candidate)
            }
        }
        return preferred + unknown + console
    }

    public static func parseGames(_ data: Data) throws -> [MetadataCandidate] {
        do {
            let games = try JSONDecoder().decode([Game].self, from: data)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return games.map { game in
                var seenSteam: Set<Int64> = []
                let steam = game.externalGames.compactMap { entry -> Int64? in
                    guard entry.source == 1,
                          let uid = entry.uid,
                          let id = Int64(uid),
                          id > 0,
                          seenSteam.insert(id).inserted else { return nil }
                    return id
                }
                var seenPlatforms: Set<Int> = []
                let platforms = game.platforms.filter { seenPlatforms.insert($0).inserted }
                let year = game.releaseDate.map {
                    calendar.component(.year, from: Date(timeIntervalSince1970: Double($0)))
                }
                return MetadataCandidate(
                    id: game.id,
                    name: game.name,
                    year: year,
                    steamAppIDs: steam,
                    genres: game.genres.map { GameGenre(id: $0.id, name: $0.name) },
                    summary: game.summary,
                    platformIDs: platforms,
                    ratingCount: max(game.ratingCount, game.totalRatingCount),
                    themes: game.themes.map { GameGenre(id: $0.id, name: $0.name) }
                )
            }
        } catch {
            throw MetadataError.malformedResponse
        }
    }

    private struct Genre: Decodable {
        let id: Int
        let name: String
    }

    private struct ExternalGame: Decodable {
        let source: Int?
        let uid: String?

        enum CodingKeys: String, CodingKey {
            case source = "external_game_source"
            case uid
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            source = try container.decodeIfPresent(Int.self, forKey: .source)
            let missingUID = try !container.contains(.uid) || container.decodeNil(forKey: .uid)
            if missingUID {
                uid = nil
            } else if let string = try? container.decode(String.self, forKey: .uid) {
                uid = string
            } else {
                // Gson's primitive asString also accepts numeric Steam aliases.
                uid = String(try container.decode(Int64.self, forKey: .uid))
            }
        }
    }

    private struct Game: Decodable {
        let id: Int64
        let name: String
        let releaseDate: Int64?
        let externalGames: [ExternalGame]
        let genres: [Genre]
        let themes: [Genre]
        let summary: String?
        let platforms: [Int]
        let ratingCount: Int
        let totalRatingCount: Int

        enum CodingKeys: String, CodingKey {
            case id, name, genres, themes, summary, platforms
            case releaseDate = "first_release_date"
            case externalGames = "external_games"
            case ratingCount = "rating_count"
            case totalRatingCount = "total_rating_count"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int64.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            releaseDate = try container.decodeIfPresent(Int64.self, forKey: .releaseDate)
            externalGames = try container.decodeIfPresent([ExternalGame].self, forKey: .externalGames) ?? []
            genres = try container.decodeIfPresent([Genre].self, forKey: .genres) ?? []
            themes = try container.decodeIfPresent([Genre].self, forKey: .themes) ?? []
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
            platforms = try container.decodeIfPresent([Int].self, forKey: .platforms) ?? []
            ratingCount = try container.decodeIfPresent(Int.self, forKey: .ratingCount) ?? 0
            totalRatingCount = try container.decodeIfPresent(Int.self, forKey: .totalRatingCount) ?? 0
        }
    }
}
