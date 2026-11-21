import Foundation

/// The game overview's IGDB details (`GET /v1/igdb/game-details?id=<igdbId>` of the metadata Worker,
/// tools/metadata-worker/README.md "Game details"): one flat shape in which every list is present and every missing
/// scalar is null. Image ids become URLs on the device (``IGDBImage``); the game's own cover is never asked for here,
/// it is always the library card's art.
public struct GameDetails: Codable, Equatable, Sendable {
    public struct Platform: Codable, Equatable, Sendable {
        public let name: String
        public let abbreviation: String?
        public init(name: String, abbreviation: String? = nil) { self.name = name; self.abbreviation = abbreviation }
    }
    public struct Company: Codable, Equatable, Sendable {
        public let name: String
        public let developer: Bool
        public let publisher: Bool
        public let porting: Bool
        public let supporting: Bool
        public init(name: String, developer: Bool = false, publisher: Bool = false, porting: Bool = false, supporting: Bool = false) {
            self.name = name; self.developer = developer; self.publisher = publisher; self.porting = porting; self.supporting = supporting
        }
    }
    public struct AgeRating: Codable, Equatable, Sendable {
        public let organization: String
        public let rating: String
        public let descriptors: [String]
        public init(organization: String, rating: String, descriptors: [String] = []) {
            self.organization = organization; self.rating = rating; self.descriptors = descriptors
        }
    }
    public struct Image: Codable, Equatable, Sendable {
        public let imageId: String
        public let width: Int?
        public let height: Int?
        public init(imageId: String, width: Int? = nil, height: Int? = nil) { self.imageId = imageId; self.width = width; self.height = height }
    }
    public struct Video: Codable, Equatable, Sendable {
        public let name: String?
        public let videoId: String
        public init(name: String?, videoId: String) { self.name = name; self.videoId = videoId }
    }
    public struct Website: Codable, Equatable, Sendable {
        public let url: String
        /// IGDB's website type name ("Official Website", "Steam", "GOG", ...), nil when IGDB has none.
        public let type: String?
        public init(url: String, type: String?) { self.url = url; self.type = type }
    }
    public struct SimilarGame: Codable, Equatable, Sendable {
        public let id: Int64
        public let name: String
        public let coverImageId: String?
        public init(id: Int64, name: String, coverImageId: String? = nil) { self.id = id; self.name = name; self.coverImageId = coverImageId }
    }
    public struct Multiplayer: Codable, Equatable, Sendable {
        public let onlineMax: Int
        public let offlineMax: Int
        public let onlineCoopMax: Int
        public let offlineCoopMax: Int
        public let onlineCoop: Bool
        public let offlineCoop: Bool
        public let lanCoop: Bool
        public let campaignCoop: Bool
        public let dropIn: Bool
        public let splitscreen: Bool
        public init(onlineMax: Int = 0, offlineMax: Int = 0, onlineCoopMax: Int = 0, offlineCoopMax: Int = 0, onlineCoop: Bool = false,
                    offlineCoop: Bool = false, lanCoop: Bool = false, campaignCoop: Bool = false, dropIn: Bool = false, splitscreen: Bool = false) {
            self.onlineMax = onlineMax; self.offlineMax = offlineMax; self.onlineCoopMax = onlineCoopMax; self.offlineCoopMax = offlineCoopMax
            self.onlineCoop = onlineCoop; self.offlineCoop = offlineCoop; self.lanCoop = lanCoop; self.campaignCoop = campaignCoop
            self.dropIn = dropIn; self.splitscreen = splitscreen
        }
    }
    public struct ExternalGame: Codable, Equatable, Sendable {
        public let uid: String
        public let source: Int
        public init(uid: String, source: Int) { self.uid = uid; self.source = source }
    }
    /// Steam's media of the game (the Worker's `steam`, from the store's appdetails); absent without a Steam match.
    /// Absent fields of a movie stay nil; a malformed movie or screenshot is dropped.
    public struct Steam: Codable, Equatable, Sendable {
        public struct Movie: Codable, Equatable, Sendable {
            public let id: Int64
            public let name: String?
            /// Steam's poster, 293 × 165 (`movie.293x165.jpg`).
            public let thumbnail: String?
            public let hls: String?
            public let dash: String?
            public let mp4: String?
            public let webm: String?
            public let highlight: Bool
            public init(id: Int64, name: String? = nil, thumbnail: String? = nil, hls: String? = nil, dash: String? = nil,
                        mp4: String? = nil, webm: String? = nil, highlight: Bool = false) {
                self.id = id; self.name = name; self.thumbnail = thumbnail; self.hls = hls; self.dash = dash; self.mp4 = mp4
                self.webm = webm; self.highlight = highlight
            }
            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                func text(_ key: CodingKeys) -> String? {
                    ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
                }
                self.init(id: try c.decode(Int64.self, forKey: .id), name: text(.name), thumbnail: text(.thumbnail), hls: text(.hls),
                          dash: text(.dash), mp4: text(.mp4), webm: text(.webm),
                          highlight: (try? c.decodeIfPresent(Bool.self, forKey: .highlight)) ?? false)
            }
            /// What AVPlayer plays: the HLS master playlist, else the MP4; nil when Steam gave neither (DASH and WebM
            /// do not play there).
            public var stream: URL? { SteamMedia.url(hls) ?? SteamMedia.url(mp4) }
        }
        public struct Screenshot: Codable, Equatable, Sendable {
            public let id: Int
            /// 600 × 338.
            public let thumbnail: String
            /// 1920 × 1080.
            public let full: String
            public init(id: Int, thumbnail: String, full: String) { self.id = id; self.thumbnail = thumbnail; self.full = full }
        }
        public let appId: Int64
        public var movies: [Movie]
        public var screenshots: [Screenshot]
        public init(appId: Int64, movies: [Movie] = [], screenshots: [Screenshot] = []) {
            self.appId = appId; self.movies = movies; self.screenshots = screenshots
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func list<T: Decodable>(_ key: CodingKeys) -> [T] {
                ((try? c.decodeIfPresent([Lenient<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
            }
            self.init(appId: try c.decode(Int64.self, forKey: .appId), movies: list(.movies), screenshots: list(.screenshots))
        }
    }

    public let id: Int64
    public let name: String
    public var summary: String?
    public var storyline: String?
    /// Epoch seconds.
    public var firstReleaseDate: Int64?
    /// Players' rating (IGDB `rating`, 0–100) and its count; critics' (`aggregated_rating`) and its count.
    public var rating: Double?
    public var ratingCount: Int
    public var criticRating: Double?
    public var criticRatingCount: Int
    public var genres: [String]
    public var themes: [String]
    public var modes: [String]
    public var perspectives: [String]
    public var platforms: [Platform]
    public var companies: [Company]
    public var ageRatings: [AgeRating]
    public var screenshots: [Image]
    public var artworks: [Image]
    public var videos: [Video]
    public var websites: [Website]
    public var similarGames: [SimilarGame]
    public var franchises: [String]
    public var collections: [String]
    public var engines: [String]
    public var keywords: [String]
    public var languages: [String]
    public var multiplayer: Multiplayer?
    public var externalGames: [ExternalGame]
    /// Steam's trailers and screenshots; nil without a Steam match (older cached details lack it too).
    public var steam: Steam?

    public init(id: Int64, name: String, summary: String? = nil, storyline: String? = nil, firstReleaseDate: Int64? = nil,
                rating: Double? = nil, ratingCount: Int = 0, criticRating: Double? = nil, criticRatingCount: Int = 0,
                genres: [String] = [], themes: [String] = [], modes: [String] = [], perspectives: [String] = [],
                platforms: [Platform] = [], companies: [Company] = [], ageRatings: [AgeRating] = [], screenshots: [Image] = [],
                artworks: [Image] = [], videos: [Video] = [], websites: [Website] = [], similarGames: [SimilarGame] = [],
                franchises: [String] = [], collections: [String] = [], engines: [String] = [], keywords: [String] = [],
                languages: [String] = [], multiplayer: Multiplayer? = nil, externalGames: [ExternalGame] = [], steam: Steam? = nil) {
        self.id = id; self.name = name; self.summary = summary; self.storyline = storyline; self.firstReleaseDate = firstReleaseDate
        self.rating = rating; self.ratingCount = ratingCount; self.criticRating = criticRating; self.criticRatingCount = criticRatingCount
        self.genres = genres; self.themes = themes; self.modes = modes; self.perspectives = perspectives; self.platforms = platforms
        self.companies = companies; self.ageRatings = ageRatings; self.screenshots = screenshots; self.artworks = artworks
        self.videos = videos; self.websites = websites; self.similarGames = similarGames; self.franchises = franchises
        self.collections = collections; self.engines = engines; self.keywords = keywords; self.languages = languages
        self.multiplayer = multiplayer; self.externalGames = externalGames; self.steam = steam
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, storyline, firstReleaseDate, rating, ratingCount, criticRating, criticRatingCount, genres, themes, modes,
             perspectives, platforms, companies, ageRatings, screenshots, artworks, videos, websites, similarGames, franchises,
             collections, engines, keywords, languages, multiplayer, externalGames, steam
    }

    /// Lenient past the identity: a list the Worker (or an older cache) lacks is empty, a malformed entry of a list is
    /// dropped, so one odd field never hides the whole overview.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "Empty game name")
        }
        func list<T: Decodable>(_ key: CodingKeys) -> [T] {
            ((try? c.decodeIfPresent([Lenient<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
        }
        func value<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        func text(_ key: CodingKeys) -> String? {
            guard let raw: String = value(key) else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return text
        }
        self.init(id: try c.decode(Int64.self, forKey: .id), name: name, summary: text(.summary), storyline: text(.storyline),
                  firstReleaseDate: value(.firstReleaseDate), rating: value(.rating), ratingCount: value(.ratingCount) ?? 0,
                  criticRating: value(.criticRating), criticRatingCount: value(.criticRatingCount) ?? 0,
                  genres: list(.genres), themes: list(.themes), modes: list(.modes), perspectives: list(.perspectives),
                  platforms: list(.platforms), companies: list(.companies), ageRatings: list(.ageRatings), screenshots: list(.screenshots),
                  artworks: list(.artworks), videos: list(.videos), websites: list(.websites), similarGames: list(.similarGames),
                  franchises: list(.franchises), collections: list(.collections), engines: list(.engines), keywords: list(.keywords),
                  languages: list(.languages), multiplayer: value(.multiplayer), externalGames: list(.externalGames), steam: value(.steam))
    }

    /// Parses the Worker's answer; anything that is not one game object is ``MetadataError/malformedResponse``.
    public static func parse(_ data: Data) throws -> GameDetails {
        do { return try JSONDecoder().decode(GameDetails.self, from: data) } catch { throw MetadataError.malformedResponse }
    }

    // MARK: What the overview shows

    public var developers: [String] { companies.filter(\.developer).map(\.name) }
    public var publishers: [String] { companies.filter(\.publisher).map(\.name) }
    public var porters: [String] { companies.filter(\.porting).map(\.name) }
    /// The series the game belongs to: its franchise, else its collection.
    public var series: String? { franchises.first ?? collections.first }
    /// IGDB's Steam app id (external source 1), for the Steam link when IGDB lists no Steam website.
    public var steamAppID: Int64? { externalGames.first { $0.source == 1 }.flatMap { Int64($0.uid) } }
    /// Player ratings below this many read "few so far".
    public static let fewRatings = 50
    public var fewRatings: Bool { rating != nil && ratingCount < Self.fewRatings }

    /// The release year in UTC, as IGDB stores the date.
    public var year: Int? {
        guard let firstReleaseDate else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.component(.year, from: Date(timeIntervalSince1970: Double(firstReleaseDate)))
    }

    /// The age ratings with the organization of [region] first: PEGI in Europe and elsewhere, ESRB in the Americas.
    public func ageRatings(region: String?) -> [AgeRating] {
        let americas: Set<String> = ["US", "CA", "MX", "BR", "AR", "CL", "CO", "PE"]
        let first = americas.contains(region ?? "") ? "ESRB" : "PEGI"
        return ageRatings.filter { $0.organization == first } + ageRatings.filter { $0.organization != first }
    }
}

private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}

/// IGDB's public image server (no credentials): `https://images.igdb.com/igdb/image/upload/t_<size>/<image_id>.jpg`.
public enum IGDBImage {
    public enum Size: String, Sendable, CaseIterable {
        /// 264 × 374: a similar game's cover outside the library.
        case coverBig = "cover_big"
        /// 569 × 320: carousel thumbnails.
        case screenshotMed = "screenshot_med"
        /// 889 × 500: larger thumbnails (iPad).
        case screenshotBig = "screenshot_big"
        /// 1280 × 720: the viewer on a 1080p stage.
        case screenshotHuge = "screenshot_huge"
        /// 1920 × 1080: the viewer on a larger display.
        case full = "1080p"
    }

    private static let validID = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{1,64}$")

    /// The URL of [imageID] at [size] (`_2x` for a retina density); nil for an id that is not IGDB's.
    public static func url(_ imageID: String, size: Size, retina: Bool = false) -> URL? {
        guard validID.firstMatch(in: imageID, range: NSRange(imageID.startIndex..., in: imageID)) != nil else { return nil }
        return URL(string: "https://images.igdb.com/igdb/image/upload/t_\(size.rawValue)\(retina ? "_2x" : "")/\(imageID).jpg")
    }

    /// A YouTube video's thumbnail (IGDB `videos.video_id` is a YouTube id).
    public static func videoThumbnail(_ videoID: String) -> URL? {
        guard validID.firstMatch(in: videoID, range: NSRange(videoID.startIndex..., in: videoID)) != nil else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
    }

    /// The video's largest thumbnail (1280 × 720, `maxresdefault`); not every video has one (YouTube answers 404 with a
    /// 120 × 90 placeholder), so ``videoThumbnail(_:)`` stays the fallback.
    public static func videoThumbnailMax(_ videoID: String) -> URL? {
        guard validID.firstMatch(in: videoID, range: NSRange(videoID.startIndex..., in: videoID)) != nil else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg")
    }

    /// Whether [id] is safe to put in a URL path or a query: letters, digits, `_` and `-` only.
    public static func validVideoID(_ id: String) -> Bool {
        validID.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
    }
}

/// Steam's media servers (`*.steamstatic.com`, `*.steampowered.com`): only their URLs are loaded, always over HTTPS (older
/// appdetails answers give `http://` MP4s).
public enum SteamMedia {
    public static func url(_ string: String?) -> URL? {
        guard let string, var parts = URLComponents(string: string), let host = parts.host?.lowercased(),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              ["steamstatic.com", "steampowered.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        parts.scheme = "https"
        return parts.url
    }

    /// The pixel width an image's file name states (`movie.293x165.jpg`, `ss_….600x338.jpg`); nil when it states none.
    public static func width(_ url: URL) -> Int? {
        let name = url.lastPathComponent.split(separator: ".")
        guard name.count >= 3, let size = name.dropLast().last?.split(separator: "x"), size.count == 2 else { return nil }
        return Int(size[0])
    }
}

/// Whether YouTube lets a video play in another app's player: its oEmbed endpoint answers 401 for a video whose owner
/// disabled embedding and 400 or 404 for one that is gone or invalid. Asked without cookies and without a cache.
public enum YouTubeEmbed {
    public static func oEmbedURL(_ videoID: String) -> URL? {
        guard IGDBImage.validVideoID(videoID) else { return nil }
        return URL(string: "https://www.youtube.com/oembed?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D\(videoID)&format=json")
    }

    /// False for the answers that say the video cannot be embedded (400, 401, 403, 404); any other answer keeps it.
    public static func playable(status: Int) -> Bool { ![400, 401, 403, 404].contains(status) }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Asks YouTube whether [videoID] can be embedded; nil when no answer came (the caller keeps the video: fails open).
    public static func embeddable(_ videoID: String) async -> Bool? {
        guard let url = oEmbedURL(videoID) else { return false }
        guard let (_, response) = try? await session.data(from: url), let http = response as? HTTPURLResponse else { return nil }
        return playable(status: http.statusCode)
    }
}
