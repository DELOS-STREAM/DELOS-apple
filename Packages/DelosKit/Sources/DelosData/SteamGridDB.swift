import Foundation

/// The four SteamGridDB images of a game (`ArtKind` of DELOS for Android): the portrait cover, the wide cover of the
/// row's first tile, the hero (the game background) and the logo (the title above the row). The raw value names the
/// kind in stored matches, as Android's file names.
public enum ArtKind: String, CaseIterable, Codable, Sendable {
    case cover, wide, hero, logo
}

/// A game found on SteamGridDB.
public struct SteamGridDBGame: Equatable, Sendable {
    public let id: Int
    public let name: String
    public let year: Int?
}

/// One image on SteamGridDB, as far as the automatic download needs it: its id, the full-size URL and its size.
public struct SteamGridDBImage: Equatable, Sendable {
    public let id: Int
    public let url: URL
    public let width: Int
    public let height: Int
}

/// Why a SteamGridDB call failed (`SgdbFailure` of DELOS for Android).
public enum SteamGridDBError: Error, Equatable, Sendable {
    /// No API key was entered.
    case noKey
    /// SteamGridDB answered 401 or 403.
    case keyRejected
    /// Another HTTP status of the API.
    case apiHTTP(Int)
    /// A reply that is not the expected JSON (a captive portal's page, a changed API).
    case badReply
    /// An image download failed with this HTTP status.
    case downloadHTTP(Int)
    /// An image larger than the cache takes.
    case imageTooLarge
}

/// The SteamGridDB API (v2) with the user's own key (`SteamGridDbClient` of DELOS for Android). Only still images are
/// asked for (the dashboard does not play animated ones yet), never NSFW or humor images. [transport] performs one
/// request; the tests give it fixtures.
public struct SteamGridDB: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let base = URL(string: "https://www.steamgriddb.com/api/v2")!
    /// The covers' and wide covers' shapes the app lays out well (`ArtFilterRules.dimensions`).
    public static let coverDimensions = ["600x900", "660x930", "342x482"]
    public static let wideDimensions = ["920x430", "460x215"]

    let key: String
    let transport: Transport

    public init(key: String, transport: @escaping Transport = SteamGridDB.urlSession) {
        self.key = key
        self.transport = transport
    }

    /// URLSession with Android's time-outs (10 s to connect, 30 s to read).
    public static let urlSession: Transport = { request in
        var request = request
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SteamGridDBError.badReply }
        return (data, http)
    }

    // MARK: Requests

    /// The autocomplete search for [term] (a game's name from the PC, one path segment whatever it contains: "Fate/Grand
    /// Order" stays one segment). Nil for a name that cannot be a segment ("", ".", "..").
    public func searchRequest(_ term: String) -> URLRequest? {
        let name = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              let segment = name.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed)
        else { return nil }
        return request(path: "search/autocomplete/" + segment, query: [])
    }

    /// The still images of [kind] for the game [gameID], best rated first.
    public func imagesRequest(gameID: Int, kind: ArtKind) -> URLRequest {
        let path = switch kind {
        case .cover, .wide: "grids/game/\(gameID)"
        case .hero: "heroes/game/\(gameID)"
        case .logo: "logos/game/\(gameID)"
        }
        return request(path: path, query: Self.query(kind))
    }

    /// The query of an automatic still-image request (`ArtFilterRules.queries` with the type "static").
    static func query(_ kind: ArtKind) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "types", value: "static"),
            URLQueryItem(name: "nsfw", value: "false"),
            URLQueryItem(name: "humor", value: "false"),
            URLQueryItem(name: "mimes", value: kind == .logo ? "image/png,image/webp" : "image/png,image/jpeg,image/webp"),
        ]
        switch kind {
        case .cover: items.append(URLQueryItem(name: "dimensions", value: coverDimensions.joined(separator: ",")))
        case .wide: items.append(URLQueryItem(name: "dimensions", value: wideDimensions.joined(separator: ",")))
        case .hero, .logo: break
        }
        return items
    }

    /// RFC 3986 unreserved characters and the sub-delimiters a path segment may carry; "/" , "?" and "#" are encoded.
    private static let segmentAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@")

    private func request(path: String, query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = Self.base.path + "/" + path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: Calls

    public func search(_ term: String) async throws -> [SteamGridDBGame] {
        guard let request = searchRequest(term) else { return [] }
        return try Self.parseGames(try await call(request))
    }

    public func images(gameID: Int, kind: ArtKind) async throws -> [SteamGridDBImage] {
        try Self.parseImages(try await call(imagesRequest(gameID: gameID, kind: kind)))
    }

    /// The file at [url], at most [limit] bytes.
    public func download(_ url: URL, limit: Int64) async throws -> Data {
        let (data, response) = try await transport(URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else { throw SteamGridDBError.downloadHTTP(response.statusCode) }
        guard Int64(data.count) <= limit else { throw SteamGridDBError.imageTooLarge }
        return data
    }

    /// The reply of an API request: 401 and 403 reject the key, 404 is "nothing" (nil).
    private func call(_ request: URLRequest) async throws -> Data? {
        let (data, response) = try await transport(request)
        switch response.statusCode {
        case 401, 403: throw SteamGridDBError.keyRejected
        case 404: return nil
        case 200..<300: return data
        default: throw SteamGridDBError.apiHTTP(response.statusCode)
        }
    }

    // MARK: Replies

    /// The `data` list of a reply; nil when it has none. Anything but a JSON object, or a `data` that is not a list, is
    /// ``SteamGridDBError/badReply``.
    static func dataList(_ reply: Data?) throws -> [[String: Any]]? {
        guard let reply else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { throw SteamGridDBError.badReply }
        guard let data = object["data"], !(data is NSNull) else { return nil }
        guard let list = data as? [Any] else { throw SteamGridDBError.badReply }
        return list.compactMap { $0 as? [String: Any] }
    }

    /// The games of a search reply; `release_date` (epoch seconds) gives the year in the device's calendar.
    static func parseGames(_ reply: Data?) throws -> [SteamGridDBGame] {
        try dataList(reply)?.compactMap { entry in
            guard let id = number(entry["id"]), let name = entry["name"] as? String else { return nil }
            let year = number(entry["release_date"]).map {
                Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval($0)))
            }
            return SteamGridDBGame(id: id, name: name, year: year)
        } ?? []
    }

    /// The images of a list reply in its order; an entry without a usable URL, or a WebM (which the app cannot show), is
    /// left out.
    static func parseImages(_ reply: Data?) throws -> [SteamGridDBImage] {
        try dataList(reply)?.compactMap { entry in
            guard let id = number(entry["id"]), let text = entry["url"] as? String, let url = URL(string: text),
                  url.scheme == "https" || url.scheme == "http" else { return nil }
            if entry["mime"] as? String == "image/webm" || text.lowercased().hasSuffix(".webm") { return nil }
            return SteamGridDBImage(id: id, url: url, width: number(entry["width"]) ?? 0, height: number(entry["height"]) ?? 0)
        } ?? []
    }

    private static func number(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.intValue
    }
}
