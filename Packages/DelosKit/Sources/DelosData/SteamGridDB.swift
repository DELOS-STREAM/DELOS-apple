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
    /// Found by the request for animated images (SteamGridDB's answers do not say it themselves).
    public let animated: Bool

    public init(
        id: Int, url: URL, width: Int = 0, height: Int = 0, thumb: URL? = nil, style: String? = nil, score: Int = 0,
        author: String? = nil, date: Int? = nil, mime: String? = nil, animated: Bool = false
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
        self.animated = animated
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

/// The SteamGridDB API (v2) with the user's own key (`SteamGridDbClient` of DELOS for Android). Never NSFW or humor
/// images are asked for; the automatic downloads take still images. [transport] performs one
/// request; the tests give it fixtures.
public struct SteamGridDB: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let base = URL(string: "https://www.steamgriddb.com/api/v2")!
    /// The covers' and wide covers' shapes the app lays out well (`ArtFilterRules.dimensions`).
    public static let coverDimensions = ["600x900", "660x930", "342x482"]
    public static let wideDimensions = ["920x430", "460x215"]

    let key: String
    let transport: Transport
    /// Fetches a file into a temporary file of its own (the caller moves or deletes it) and stops reading once it is
    /// larger than the limit (the second argument), telling how far it is (0…1, only when the reply announces its
    /// length) to the third. A reply that is not 2xx leaves no file.
    typealias Downloader = @Sendable (URLRequest, Int64, (@Sendable (Double) -> Void)?) async throws -> (URL?, HTTPURLResponse)
    let downloader: Downloader

    /// The largest file an image download takes (`SteamGridDbClient.MAX_FILE_BYTES` of DELOS for Android): 2 GB, so a
    /// large animated background can be used. The file goes to disk as it arrives and is never held in memory.
    public static let maxFileBytes: Int64 = 2048 * 1024 * 1024

    /// - Parameter transport: replaces the network for the API and the downloads (tests); nil uses URLSession, and
    ///   downloads go to disk and stop at their size limit while they are read.
    public init(key: String, transport: Transport? = nil) {
        self.key = key
        self.transport = transport ?? SteamGridDB.urlSession
        if let transport {
            downloader = { request, _, _ in
                let (data, response) = try await transport(request)
                guard (200..<300).contains(response.statusCode) else { return (nil, response) }
                let file = FileManager.default.temporaryDirectory.appending(path: "sgdb-\(UUID().uuidString).part", directoryHint: .notDirectory)
                try data.write(to: file)
                return (file, response)
            }
        } else {
            downloader = FileDownload.run
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

    /// The request of [query] for the images of [kind] for the game [gameID]. The automatic downloads ask for the still
    /// images (`ArtFilters(type = STATIC)` of DELOS for Android).
    public func imagesRequest(gameID: Int, kind: ArtKind, query: ArtQuery? = nil) -> URLRequest {
        let path = switch kind {
        case .cover, .wide: "grids/game/\(gameID)"
        case .hero: "heroes/game/\(gameID)"
        case .logo: "logos/game/\(gameID)"
        }
        let query = query ?? ArtFilterRules.queries(kind, ArtFilters(type: .still))[0]
        return request(path: path, query: query.params)
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

    /// The images of [kind] for [gameID] that match [filters], in the order of its sort (`SteamGridDb.images`). Both
    /// types are two requests; the still images are still worth showing when the animated request fails.
    public func images(gameID: Int, kind: ArtKind, filters: ArtFilters = ArtFilters(type: .still)) async throws -> [SteamGridDBImage] {
        let queries = ArtFilterRules.queries(kind, filters)
        var lists: [[SteamGridDBImage]] = []
        for query in queries {
            do {
                lists.append(try Self.parseImages(try await call(imagesRequest(gameID: gameID, kind: kind, query: query)), animated: query.animated))
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                let rejected = (error as? SteamGridDBError) == .keyRejected
                guard queries.count > 1, query.animated, !cancelled, !rejected else { throw error }
                lists.append([])
            }
        }
        return ArtFilterRules.sort(ArtFilterRules.merge(lists), filters.sort)
    }

    /// The file at [url], at most [limit] bytes, as a temporary file the caller moves into place or deletes; [progress]
    /// hears how far the download is (0…1) when its length is known.
    public func download(_ url: URL, limit: Int64, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard url.scheme == "https" else { throw SteamGridDBError.insecureURL }
        let (file, response) = try await downloader(URLRequest(url: url), limit, progress)
        guard (200..<300).contains(response.statusCode), let file else {
            if let file { try? FileManager.default.removeItem(at: file) }
            throw SteamGridDBError.downloadHTTP(response.statusCode)
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= limit else {
            try? FileManager.default.removeItem(at: file)
            throw SteamGridDBError.imageTooLarge
        }
        return file
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
    static func parseImages(_ reply: Data?, animated: Bool = false) throws -> [SteamGridDBImage] {
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
                date: epochSeconds(entry["date"] ?? entry["created_at"]), mime: mime, animated: animated)
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

/// Retries for SteamGridDB calls that failed for a passing reason (`SgdbRetry` of DELOS for Android): the service busy
/// or briefly unreachable, a dropped connection. The Artwork screen keeps its loader up while it retries and only says
/// "not reachable" once every attempt has failed.
public enum SteamGridDBRetry {
    /// The waits before the 2nd, 3rd and 4th attempt: four attempts in about four seconds of waiting.
    public static let delays: [Duration] = [.milliseconds(500), .milliseconds(1200), .milliseconds(2500)]

    /// Whether trying again can help: a network failure or an overloaded or failing server (429, 5xx), never a rejected
    /// key, an unreadable reply or a bad file.
    public static func isTransient(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError: return false
        case let error as SteamGridDBError:
            if case .apiHTTP(let code) = error { return code == 429 || (500...599).contains(code) }
            return false
        case let error as URLError: return error.code != .cancelled
        default: return false
        }
    }

    /// Runs [block], retrying after each wait in [delays] while the failure ``isTransient(_:)``; the last failure is thrown.
    public static func run<T>(
        delays: [Duration] = delays,
        isolation: isolated (any Actor)? = #isolation,
        wait: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ block: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await block()
            } catch {
                guard isTransient(error), attempt < delays.count else { throw error }
                try await wait(delays[attempt])
                attempt += 1
            }
        }
    }
}

/// One download through URLSession that goes to a temporary file as it arrives (`SteamGridDbClient.download` and
/// `Thumbnails.fetch` of DELOS for Android): the announced length, then the bytes written so far, are checked against the
/// limit, so a huge reply is refused early and never held in memory. A reply that is not 2xx is not read.
final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int64
    private let progress: (@Sendable (Double) -> Void)?
    private let file = FileManager.default.temporaryDirectory.appending(path: "sgdb-\(UUID().uuidString).part", directoryHint: .notDirectory)
    // Touched only on the session's serial delegate queue, then read once the task has completed
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var total: Int64 = 0
    private var response: HTTPURLResponse?
    private var failure: (any Error)?
    private var continuation: CheckedContinuation<(URL?, HTTPURLResponse), any Error>?

    private init(limit: Int64, progress: (@Sendable (Double) -> Void)?) {
        self.limit = limit
        self.progress = progress
    }

    static let run: SteamGridDB.Downloader = { request, limit, progress in
        var request = request
        request.timeoutInterval = 30
        let download = FileDownload(limit: limit, progress: progress)
        let task = URLSession.shared.dataTask(with: request)
        task.delegate = download
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = SteamGridDBError.badReply
            return completionHandler(.cancel)
        }
        self.response = http
        guard (200..<300).contains(http.statusCode) else { return completionHandler(.cancel) }
        total = http.expectedContentLength
        guard total <= limit else {
            failure = SteamGridDBError.imageTooLarge
            return completionHandler(.cancel)
        }
        guard FileManager.default.createFile(atPath: file.path, contents: nil), let handle = try? FileHandle(forWritingTo: file) else {
            failure = CocoaError(.fileWriteUnknown)
            return completionHandler(.cancel)
        }
        self.handle = handle
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        written += Int64(data.count)
        guard written <= limit else {
            failure = SteamGridDBError.imageTooLarge
            return dataTask.cancel()
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            return dataTask.cancel()
        }
        if total > 0 { progress?(min(Double(written) / Double(total), 1)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        try? handle?.close()
        handle = nil
        let continuation = self.continuation
        self.continuation = nil
        if let response, !(200..<300).contains(response.statusCode) {
            try? FileManager.default.removeItem(at: file)
            continuation?.resume(returning: (nil, response))
        } else if let error = failure ?? error {
            try? FileManager.default.removeItem(at: file)
            continuation?.resume(throwing: error)
        } else if let response {
            continuation?.resume(returning: (file, response))
        } else {
            continuation?.resume(throwing: SteamGridDBError.badReply)
        }
    }
}
