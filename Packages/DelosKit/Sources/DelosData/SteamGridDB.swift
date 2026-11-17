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

    public init(id: Int, name: String, year: Int? = nil) {
        self.id = id
        self.name = name
        self.year = year
    }
}

/// One image on SteamGridDB: the full-size URL, the [thumb] the choices show and what the API tells about it (0 or nil
/// when it does not): the [style], [score], the [author]'s name, the upload [date] (epoch seconds) and [mime].
public struct SteamGridDBImage: Equatable, Hashable, Sendable {
    public let id: Int
    public let url: URL
    public let width: Int
    public let height: Int
    public let thumb: URL
    public let style: String?
    public let score: Int
    public let author: String?
    public let date: Int?
    public let mime: String?

    public init(
        id: Int, url: URL, width: Int = 0, height: Int = 0, thumb: URL? = nil, style: String? = nil, score: Int = 0,
        author: String? = nil, date: Int? = nil, mime: String? = nil
    ) {
        self.id = id
        self.url = url
        self.width = width
        self.height = height
        self.thumb = thumb ?? url
        self.style = style
        self.score = score
        self.author = author
        self.date = date
        self.mime = mime
    }

    /// What a tile shows first: the thumbnail, except that SteamGridDB gives some images a WebM thumbnail the app cannot
    /// decode, so those use the full image.
    public var previewURL: URL { thumb.path.lowercased().hasSuffix(".webm") ? url : thumb }

    /// The file format as the info strip shows it ("WEBP", "JPG", "PNG"), nil when unknown.
    public var format: String? {
        guard let subtype = mime?.split(separator: "/").last.map({ $0.lowercased() }), !subtype.isEmpty else { return nil }
        return subtype == "jpeg" ? "JPG" : subtype.uppercased()
    }
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
    /// An image address that is not https.
    case insecureURL
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
    /// Fetches a file and stops reading once it is larger than the limit (the second argument).
    typealias Downloader = @Sendable (URLRequest, Int64) async throws -> (Data, HTTPURLResponse)
    let downloader: Downloader

    /// - Parameter transport: replaces the network for the API and the downloads (tests); nil uses URLSession, and
    ///   downloads stop at their size limit while they are read.
    public init(key: String, transport: Transport? = nil) {
        self.key = key
        self.transport = transport ?? SteamGridDB.urlSession
        if let transport {
            downloader = { request, _ in try await transport(request) }
        } else {
            downloader = SteamGridDB.boundedDownload
        }
    }

    /// URLSession with Android's time-outs (10 s to connect, 30 s to read).
    public static let urlSession: Transport = { request in
        var request = request
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SteamGridDBError.badReply }
        return (data, http)
    }

    /// A download that is refused as soon as the announced length, or the bytes read so far, pass [limit]: a huge
    /// reply is never held whole. A reply that is not 2xx is not read.
    static let boundedDownload: Downloader = { request, limit in
        var request = request
        request.timeoutInterval = 30
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SteamGridDBError.badReply }
        guard (200..<300).contains(http.statusCode) else { return (Data(), http) }
        guard response.expectedContentLength <= limit else { throw SteamGridDBError.imageTooLarge }
        var data = Data()
        var chunk = [UInt8]()
        chunk.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 64 * 1024 {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                guard Int64(data.count) <= limit else { throw SteamGridDBError.imageTooLarge }
            }
        }
        data.append(contentsOf: chunk)
        guard Int64(data.count) <= limit else { throw SteamGridDBError.imageTooLarge }
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
        guard url.scheme == "https" else { throw SteamGridDBError.insecureURL }
        let (data, response) = try await downloader(URLRequest(url: url), limit)
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
    /// left out. What the API tells about an image (thumbnail, style, score, author, date, file type) is kept for the
    /// Artwork screen's choices.
    static func parseImages(_ reply: Data?) throws -> [SteamGridDBImage] {
        try dataList(reply)?.compactMap { entry in
            guard let id = number(entry["id"]), let text = entry["url"] as? String, let url = URL(string: text),
                  url.scheme == "https" else { return nil }
            let mime = entry["mime"] as? String
            if mime == "image/webm" || text.lowercased().hasSuffix(".webm") { return nil }
            let thumb = (entry["thumb"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            // Newer answers may list several styles: the first is shown
            let style = ((entry["style"] as? [String])?.first ?? entry["style"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return SteamGridDBImage(
                id: id, url: url, width: number(entry["width"]) ?? 0, height: number(entry["height"]) ?? 0,
                thumb: thumb ?? url, style: style, score: number(entry["score"]) ?? 0,
                author: ((entry["author"] as? [String: Any])?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                date: epochSeconds(entry["date"] ?? entry["created_at"]), mime: mime)
        } ?? []
    }

    /// Epoch seconds from a number (seconds or milliseconds) or an ISO date string; nil when it is neither.
    static func epochSeconds(_ value: Any?) -> Int? {
        func seconds(_ n: Int) -> Int { n > 100_000_000_000 ? n / 1000 : n }
        if let n = number(value) { return seconds(n) }
        guard let text = value as? String else { return nil }
        if let n = Int(text) { return seconds(n) }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (plain.date(from: text) ?? fractional.date(from: text)).map { Int($0.timeIntervalSince1970) }
    }

    private static func number(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.intValue
    }
}
