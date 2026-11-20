import Foundation
import Synchronization
import Testing
@testable import DelosData

/// The game overview's details: the Worker's shape (tools/metadata-worker/README.md "Game details"), the URLs built from
/// IGDB's image ids, the record that keeps them (schema 7, the 7-day refresh, the backoff) and the image disk cache.
@Suite struct GameDetailsTests {
    /// The Worker's normalized answer for a complete game (its test's `NORMALIZED`, abridged).
    static let complete = Data("""
    {"id":214337,"name":"Hollow Meridian","slug":"hollow-meridian","summary":"A salvage diver wakes.","storyline":"Forty years later.",
     "firstReleaseDate":1758153600,"releaseDates":[{"platform":"PC","date":1758153600,"human":"Sep 18, 2025"}],
     "rating":82.37,"ratingCount":1284,"criticRating":86.1,"criticRatingCount":42,"totalRating":84.24,"totalRatingCount":1326,
     "genres":["Shooter","Adventure"],"themes":["Horror"],"modes":["Single player"],"perspectives":["Third person"],
     "platforms":[{"name":"PC (Microsoft Windows)","abbreviation":"PC"},{"name":"PlayStation 5","abbreviation":null}],
     "companies":[{"name":"Driftlight Studios","developer":true,"publisher":false,"porting":false,"supporting":false},
                  {"name":"Northvale Interactive","developer":false,"publisher":true,"porting":false,"supporting":false}],
     "ageRatings":[{"organization":"ESRB","rating":"M","descriptors":["Blood and Gore"]},{"organization":"PEGI","rating":"18","descriptors":[]}],
     "screenshots":[{"imageId":"sc6abc","width":1920,"height":1080},{"imageId":"sc6abd","width":null,"height":null}],
     "artworks":[],"videos":[{"name":"Launch Trailer","videoId":"dQw4w9WgXcQ"}],
     "websites":[{"url":"https://hollowmeridian.example/","type":"Official Website"},{"url":"https://store.steampowered.com/app/2741160","type":"Steam"}],
     "similarGames":[{"id":1,"name":"Ashfall Protocol","coverImageId":"co1abc"},{"id":2,"name":"Deepwake","coverImageId":null}],
     "franchises":["Meridian"],"collections":[],"engines":["Unreal Engine 5"],"keywords":["space station"],"languages":["English","Czech"],
     "multiplayer":{"onlineMax":0,"offlineMax":0,"onlineCoopMax":4,"offlineCoopMax":0,"onlineCoop":true,"offlineCoop":false,"lanCoop":false,
                    "campaignCoop":true,"dropIn":false,"splitscreen":false},
     "externalGames":[{"uid":"2741160","source":1}]}
    """.utf8)

    @Test func parsesTheWorkersShape() throws {
        let d = try GameDetails.parse(Self.complete)
        #expect(d.id == 214337 && d.name == "Hollow Meridian")
        #expect(d.summary == "A salvage diver wakes." && d.storyline == "Forty years later.")
        #expect(d.year == 2025)
        #expect(d.rating == 82.37 && d.ratingCount == 1284 && d.criticRating == 86.1 && d.criticRatingCount == 42)
        #expect(d.genres == ["Shooter", "Adventure"] && d.modes == ["Single player"])
        #expect(d.platforms[1] == .init(name: "PlayStation 5", abbreviation: nil))
        #expect(d.developers == ["Driftlight Studios"] && d.publishers == ["Northvale Interactive"])
        #expect(d.screenshots.map(\.imageId) == ["sc6abc", "sc6abd"] && d.screenshots[1].width == nil)
        #expect(d.videos == [.init(name: "Launch Trailer", videoId: "dQw4w9WgXcQ")])
        #expect(d.similarGames[1].coverImageId == nil)
        #expect(d.series == "Meridian" && d.steamAppID == 2741160)
        #expect(d.multiplayer?.onlineCoopMax == 4)
        #expect(!d.fewRatings)
    }

    @Test func sparseAnswerIsComplete() throws {
        let d = try GameDetails.parse(Data(#"{"id":5,"name":"Paper Lanterns","summary":"  ","storyline":null,"rating":78.2,"ratingCount":23,"criticRating":null,"criticRatingCount":0,"ageRatings":[],"multiplayer":null}"#.utf8))
        #expect(d.summary == nil && d.storyline == nil && d.criticRating == nil)
        #expect(d.screenshots.isEmpty && d.genres.isEmpty && d.multiplayer == nil)
        #expect(d.fewRatings)
    }

    @Test func malformedEntriesAreDroppedNotTheGame() throws {
        let d = try GameDetails.parse(Data(#"{"id":5,"name":"X","screenshots":[{"imageId":"ok1"},{"width":3},7],"genres":["A",null,"B"]}"#.utf8))
        #expect(d.screenshots.map(\.imageId) == ["ok1"])
        #expect(d.genres == ["A", "B"])
    }

    @Test func rejectsWhatIsNotAGame() {
        #expect(throws: MetadataError.malformedResponse) { try GameDetails.parse(Data("[]".utf8)) }
        #expect(throws: MetadataError.malformedResponse) { try GameDetails.parse(Data(#"{"id":1,"name":" "}"#.utf8)) }
        #expect(throws: MetadataError.malformedResponse) { try GameDetails.parse(Data("{".utf8)) }
    }

    @Test func ageRatingOfTheRegionComesFirst() throws {
        let d = try GameDetails.parse(Self.complete)
        #expect(d.ageRatings(region: "CZ").map(\.organization) == ["PEGI", "ESRB"])
        #expect(d.ageRatings(region: "US").map(\.organization) == ["ESRB", "PEGI"])
    }

    @Test func imageURLs() {
        #expect(IGDBImage.url("sc6abc", size: .screenshotMed)?.absoluteString == "https://images.igdb.com/igdb/image/upload/t_screenshot_med/sc6abc.jpg")
        #expect(IGDBImage.url("co1abc", size: .coverBig, retina: true)?.absoluteString == "https://images.igdb.com/igdb/image/upload/t_cover_big_2x/co1abc.jpg")
        #expect(IGDBImage.url("../etc", size: .full) == nil)
        #expect(IGDBImage.videoThumbnail("dQw4w9WgXcQ")?.absoluteString == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    }

    @Test func youTubeEmbedCheck() {
        #expect(YouTubeEmbed.oEmbedURL("dQw4w9WgXcQ")?.absoluteString
            == "https://www.youtube.com/oembed?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ&format=json")
        #expect(YouTubeEmbed.oEmbedURL("a&b=c") == nil)
        // Embedding disabled (401), gone or invalid (400, 404), forbidden (403): not playable; anything else keeps the video
        for status in [400, 401, 403, 404] { #expect(!YouTubeEmbed.playable(status: status)) }
        for status in [200, 429, 500, 503] { #expect(YouTubeEmbed.playable(status: status)) }
    }

    @Test func detailsRequestAndNotFound() async throws {
        let transport = RecordingTransport(answers: [MetadataHTTPResponse(data: Self.complete, status: 200),
                                                     MetadataHTTPResponse(data: Data(#"{"error":"game_not_found"}"#.utf8), status: 404)])
        let client = IGDBMetadataClient(baseURL: "https://worker.example", http: MetadataHTTP(transport: transport))
        let first = try await client.details(214337)
        #expect(first?.name == "Hollow Meridian")
        #expect(await transport.urls.first?.absoluteString == "https://worker.example/v1/igdb/game-details?id=214337")
        #expect(try await client.details(9) == nil)
    }

    @Test func recordKeepsDetailsOfItsCandidateOnly() throws {
        let details = try GameDetails.parse(Self.complete)
        let same = GameMetadata(candidate: MetadataCandidate(id: 214337, name: "Hollow Meridian"), details: details, detailsUpdatedAt: 5)
        let other = GameMetadata(candidate: MetadataCandidate(id: 1, name: "Other"), details: details, detailsUpdatedAt: 5)
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        #expect(try decoder.decode(GameMetadata.self, from: encoder.encode(same)).details == details)
        let dropped = try decoder.decode(GameMetadata.self, from: encoder.encode(other))
        #expect(dropped.details == nil && dropped.detailsUpdatedAt == 0)
    }

    @Test func detailsRefreshPolicy() {
        let day: Int64 = 24 * 60 * 60 * 1000, now: Int64 = 100 * day
        let matched = MetadataCandidate(id: 1, name: "G")
        #expect(MetadataPolicy.detailsDue(GameMetadata(candidate: matched), now: now))
        #expect(!MetadataPolicy.detailsDue(GameMetadata(candidate: matched, detailsUpdatedAt: now - 6 * day), now: now))
        #expect(MetadataPolicy.detailsDue(GameMetadata(candidate: matched, detailsUpdatedAt: now - 8 * day), now: now))
        #expect(!MetadataPolicy.detailsDue(GameMetadata(candidate: matched, detailsFailedAt: now - 60_000), now: now))
        #expect(MetadataPolicy.detailsDue(GameMetadata(candidate: matched, detailsFailedAt: now - 31 * 60_000), now: now))
        #expect(!MetadataPolicy.detailsDue(GameMetadata(), now: now))
    }

    @Test func storeFetchesOnceCachesAndBacksOff() async throws {
        let clock = TestClock()
        let providers = DetailsProviders()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("details-test-" + UUID().uuidString)
        let cache = DiskCache(directory: directory, budget: 1 << 20, maxEntryBytes: 1 << 18)
        let store = MetadataStore(providers: providers, cache: cache, now: { clock.now })
        try await store.lookup(title: "Hollow Meridian")
        let first = await store.details(title: "Hollow Meridian")
        #expect(first?.name == "Hollow Meridian")
        _ = await store.details(title: "Hollow Meridian")
        #expect(await providers.calls == 1)
        // Written as schema 7 and read back by a new store without a request
        let again = MetadataStore(providers: providers, cache: cache, now: { clock.now })
        #expect(await again.details(title: "Hollow Meridian") == first)
        #expect(await providers.calls == 1)
        // After 7 days a refresh fails: the cached details stay, and the backoff holds off the next try
        clock.advance(8 * 24 * 60 * 60 * 1000)
        await providers.fail(true)
        #expect(await again.details(title: "Hollow Meridian") == first)
        #expect(await again.details(title: "Hollow Meridian") == first)
        #expect(await providers.calls == 2)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func schemaSixRecordsAreStillRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("details-schema-" + UUID().uuidString)
        let cache = DiskCache(directory: directory, budget: 1 << 20, maxEntryBytes: 1 << 18)
        let old = #"{"schema":6,"data":{"candidate":{"id":1,"name":"Game"},"updatedAt":1}}"#
        try await cache.store(Data(old.utf8), for: MetadataPolicy.literalKey("Game"))
        let state = await MetadataStore(providers: DetailsProviders(), cache: cache).state(for: "Game")
        #expect(state.data?.candidate?.id == 1 && state.data?.details == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func imageStoreDownloadsOnceThenReadsFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("igdb-images-" + UUID().uuidString)
        let transport = RecordingTransport(answers: [MetadataHTTPResponse(data: Data([1, 2, 3]), status: 200)])
        let images = IGDBImageStore(cache: DiskCache(directory: directory, budget: 1 << 20, maxEntryBytes: 1 << 16), http: MetadataHTTP(transport: transport))
        let url = try #require(IGDBImage.url("sc6abc", size: .screenshotMed))
        #expect(await images.data(url) == Data([1, 2, 3]))
        #expect(await images.data(url) == Data([1, 2, 3]))
        #expect(await images.isCached(url))
        #expect(await transport.urls.count == 1)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class TestClock: Sendable {
    private let time = Mutex<Int64>(10_000_000_000)
    var now: Int64 { time.withLock { $0 } }
    func advance(_ milliseconds: Int64) { time.withLock { $0 += milliseconds } }
}

private actor RecordingTransport: MetadataTransport {
    private var answers: [MetadataHTTPResponse]
    private(set) var urls: [URL] = []
    init(answers: [MetadataHTTPResponse]) { self.answers = answers }
    func response(for request: URLRequest) async throws -> MetadataHTTPResponse {
        urls.append(request.url!)
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}

private actor DetailsProviders: MetadataProviders {
    nonisolated let available = true
    private(set) var calls = 0
    private var failing = false
    func fail(_ on: Bool) { failing = on }
    func search(_ title: String) async throws -> [MetadataCandidate] { [MetadataCandidate(id: 214337, name: title, platformIDs: [6])] }
    func game(_ id: Int64) async throws -> MetadataCandidate? { nil }
    func hdr(steamAppIDs: [Int64], name: String) async throws -> HDREvidence { HDREvidence() }
    func completion(steamAppIDs: [Int64], name: String) async throws -> CompletionTime? { nil }
    func steamTags(_ steamAppIDs: [Int64]) async throws -> [String] { [] }
    func details(_ id: Int64) async throws -> GameDetails? {
        calls += 1
        if failing { throw MetadataError.httpStatus(503) }
        return try GameDetails.parse(GameDetailsTests.complete)
    }
}
