import DelosHost
import Foundation
import Synchronization
import Testing
@testable import DelosData

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "delos-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// A clock the tests move by hand, so the cache's order does not depend on the file system's timestamps.
private final class TestClock: Sendable {
    private let seconds = Mutex(1_000_000.0)
    func now() -> Date { Date(timeIntervalSince1970: seconds.withLock { $0 }) }
    func advance() { seconds.withLock { $0 += 10 } }
}

@Suite struct DiskCacheTests {
    @Test func anEntryIsStoredAndReadBack() async throws {
        let cache = DiskCache(directory: temporaryDirectory(), budget: 1000, maxEntryBytes: 100)
        #expect(await cache.data(for: "a") == nil)
        try await cache.store(Data([1, 2, 3]), for: "sgdb/host/1/cover")
        #expect(await cache.data(for: "sgdb/host/1/cover") == Data([1, 2, 3]))
        #expect(await cache.contains("sgdb/host/1/cover"))
        // Any key is a file name: a key with slashes and dots stays inside the folder
        try await cache.store(Data([4]), for: "../../x")
        #expect(await cache.data(for: "../../x") == Data([4]))
        await cache.remove("sgdb/host/1/cover")
        #expect(await cache.data(for: "sgdb/host/1/cover") == nil)
    }

    @Test func storingBeyondTheBudgetDropsTheLeastRecentlyUsedEntries() async throws {
        let clock = TestClock()
        let cache = DiskCache(directory: temporaryDirectory(), budget: 300, maxEntryBytes: 200, now: { clock.now() })
        for key in ["a", "b", "c"] {
            try await cache.store(Data(repeating: 1, count: 100), for: key)
            clock.advance()
        }
        // Reading "a" makes it the most recently used: "b" goes first
        _ = await cache.data(for: "a")
        clock.advance()
        try await cache.store(Data(repeating: 2, count: 100), for: "d")
        #expect(await cache.totalBytes() == 300)
        #expect(await kept(cache, ["a", "b", "c", "d"]) == ["a", "c", "d"])
        // A large entry pushes out as many as it needs, never itself
        clock.advance()
        try await cache.store(Data(repeating: 3, count: 200), for: "e")
        #expect(await cache.totalBytes() <= 300)
        #expect(await kept(cache, ["c", "d", "e"]) == ["d", "e"])
    }

    /// Which of [keys] the cache still holds.
    private func kept(_ cache: DiskCache, _ keys: [String]) async -> [String] {
        var found: [String] = []
        for key in keys where await cache.contains(key) { found.append(key) }
        return found
    }

    @Test func anEntryLargerThanTheLimitIsRefused() async throws {
        let cache = DiskCache(directory: temporaryDirectory(), budget: 1000, maxEntryBytes: 10)
        await #expect(throws: DiskCacheError.tooLarge) { try await cache.store(Data(count: 11), for: "big") }
        #expect(await cache.data(for: "big") == nil)
    }
}

/// A SteamGridDB fake: answers by path, records every request.
private final class FakeSteamGridDB: Sendable {
    let requests = Mutex<[URLRequest]>([])
    let routes: [String: (Int, Data)]

    init(_ routes: [String: (Int, String)]) {
        self.routes = routes.mapValues { ($0.0, Data($0.1.utf8)) }
    }

    var transport: SteamGridDB.Transport {
        { [self] request in
            requests.withLock { $0.append(request) }
            let url = request.url!
            let key = url.host() == "cdn.example" ? url.path() : String(url.path().dropFirst("/api/v2/".count))
            let (status, data) = routes[key] ?? (404, Data())
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func count(_ path: String) -> Int { requests.withLock { $0.filter { $0.url!.path().hasSuffix(path) }.count } }
}

private func list(_ entries: String) -> String { #"{"success":true,"data":[\#(entries)]}"# }
private func image(_ id: Int, _ file: String) -> String { #"{"id":\#(id),"url":"https://cdn.example/\#(file)","width":600,"height":900}"# }

@Suite struct SteamGridDBTests {
    let client = SteamGridDB(key: "secret") { _ in throw URLError(.notConnectedToInternet) }

    @Test func theSearchSendsTheNameAsOnePathSegmentWithTheKey() throws {
        let request = try #require(client.searchRequest("  Fate/Grand Order? #1 "))
        #expect(request.url?.absoluteString == "https://www.steamgriddb.com/api/v2/search/autocomplete/Fate%2FGrand%20Order%3F%20%231")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(client.searchRequest("Café Ünïcode")?.url?.absoluteString
            == "https://www.steamgriddb.com/api/v2/search/autocomplete/Caf%C3%A9%20%C3%9Cn%C3%AFcode")
        // A URL cannot carry these as a segment of their own: no such game
        #expect(client.searchRequest(".") == nil && client.searchRequest("..") == nil && client.searchRequest("  ") == nil)
    }

    @Test func eachKindAsksForStillImagesOfItsShapes() throws {
        func query(_ kind: ArtKind) throws -> (path: String, items: [String: String]) {
            let url = try #require(client.imagesRequest(gameID: 42, kind: kind).url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            return (components.path, Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }))
        }
        let cover = try query(.cover)
        #expect(cover.path == "/api/v2/grids/game/42")
        #expect(cover.items == ["types": "static", "nsfw": "false", "humor": "false", "mimes": "image/png,image/jpeg,image/webp",
                                "dimensions": "600x900,660x930,342x482"])
        let wide = try query(.wide)
        #expect(wide.path == "/api/v2/grids/game/42" && wide.items["dimensions"] == "920x430,460x215")
        let hero = try query(.hero)
        #expect(hero.path == "/api/v2/heroes/game/42" && hero.items["dimensions"] == nil && hero.items["mimes"] == "image/png,image/jpeg,image/webp")
        let logo = try query(.logo)
        #expect(logo.path == "/api/v2/logos/game/42" && logo.items["mimes"] == "image/png,image/webp" && logo.items["types"] == "static")
    }

    @Test func repliesAreReadLeniently() throws {
        let games = try SteamGridDB.parseGames(Data(#"{"data":[{"id":5,"name":"Hades","release_date":1600992000},{"id":"x"},{"id":6,"name":"No date"}]}"#.utf8))
        #expect(games.map(\.id) == [5, 6])
        #expect(games[0].name == "Hades" && games[0].year == 2020 && games[1].year == nil)
        let images = try SteamGridDB.parseImages(Data(list([
            image(1, "a.png"),
            #"{"id":2,"url":"https://cdn.example/b.webm"}"#,
            #"{"id":3,"url":"https://cdn.example/c.png","mime":"image/webm"}"#,
            #"{"id":4}"#,
            #"{"id":true,"url":"https://cdn.example/d.png"}"#,
            #"{"id":5,"url":"file:///etc/passwd"}"#,
        ].joined(separator: ",")).utf8))
        #expect(images.map(\.id) == [1])
        #expect(images[0].width == 600 && images[0].height == 900)
        #expect(try SteamGridDB.parseImages(Data(#"{"success":true,"data":null}"#.utf8)).isEmpty)
        #expect(try SteamGridDB.parseImages(nil).isEmpty)
        // A captive portal's page or a changed API is a failed call, not a crash
        #expect(throws: SteamGridDBError.badReply) { try SteamGridDB.parseImages(Data("<html>".utf8)) }
        #expect(throws: SteamGridDBError.badReply) { try SteamGridDB.parseImages(Data(#"{"data":{"id":1}}"#.utf8)) }
    }

    @Test func statusCodesMapToAndroidsFailures() async throws {
        func client(_ status: Int) -> SteamGridDB {
            SteamGridDB(key: "k", transport: FakeSteamGridDB(["search/autocomplete/Game": (status, list(""))]).transport)
        }
        await #expect(throws: SteamGridDBError.keyRejected) { try await client(401).search("Game") }
        await #expect(throws: SteamGridDBError.keyRejected) { try await client(403).search("Game") }
        await #expect(throws: SteamGridDBError.apiHTTP(500)) { try await client(500).search("Game") }
        #expect(try await client(404).search("Game").isEmpty)
        let download = SteamGridDB(key: "k", transport: FakeSteamGridDB(["/big.png": (200, String(repeating: "x", count: 20)), "/gone.png": (410, "")]).transport)
        await #expect(throws: SteamGridDBError.imageTooLarge) { try await download.download(URL(string: "https://cdn.example/big.png")!, limit: 10) }
        await #expect(throws: SteamGridDBError.downloadHTTP(410)) { try await download.download(URL(string: "https://cdn.example/gone.png")!, limit: 10) }
    }
}

@MainActor
@Suite struct ArtworkStoreTests {
    final class MemoryStorage: SecretStorage {
        let items = Mutex<[String: Data]>([:])
        func read(account: String) throws -> Data? { items.withLock { $0[account] } }
        func write(_ data: Data, account: String) throws { items.withLock { $0[account] = data } }
        func delete(account: String) throws { _ = items.withLock { $0.removeValue(forKey: account) } }
    }

    private let fake = FakeSteamGridDB([
        "search/autocomplete/Hades": (200, list(#"{"id":7,"name":"Hades"}"#)),
        "search/autocomplete/Unknown": (200, list("")),
        "grids/game/7": (200, list(image(70, "cover.png"))),
        "heroes/game/7": (200, list(image(71, "hero.png"))),
        "logos/game/7": (200, list("")),
        "/cover.png": (200, "COVER"),
        "/hero.png": (200, "HERO"),
    ])

    private func store(key: String? = "k", cache: DiskCache? = nil, defaults: UserDefaults? = nil) throws -> ArtworkStore {
        let secrets = MemoryStorage()
        if let key { try secrets.write(Data(key.utf8), account: "api-key") }
        return ArtworkStore(
            secrets: secrets, defaults: defaults ?? UserDefaults(suiteName: "delos.tests.\(UUID().uuidString)")!,
            matches: temporaryDirectory(), cache: cache ?? DiskCache(directory: temporaryDirectory(), budget: 1_000_000, maxEntryBytes: 1000),
            transport: fake.transport)
    }

    @Test func theKeyIsKeptInTheSecretsAndEmptyTurnsSteamGridDBOff() throws {
        let secrets = MemoryStorage()
        let defaults = UserDefaults(suiteName: "delos.tests.\(UUID().uuidString)")!
        let artwork = ArtworkStore(secrets: secrets, defaults: defaults, matches: temporaryDirectory(), transport: fake.transport)
        #expect(!artwork.enabled && artwork.automatic && !artwork.lookupExpected)
        try artwork.setAPIKey("  abc  ")
        #expect(artwork.apiKey == "abc" && artwork.enabled && artwork.lookupExpected)
        #expect(try secrets.read(account: "api-key") == Data("abc".utf8))
        #expect(ArtworkStore(secrets: secrets, defaults: defaults, matches: temporaryDirectory()).apiKey == "abc")
        artwork.automatic = false
        #expect(!artwork.lookupExpected)
        #expect(!ArtworkStore(secrets: secrets, defaults: defaults, matches: temporaryDirectory()).automatic)
        try artwork.setAPIKey(" ")
        let stored = try secrets.read(account: "api-key")
        #expect(!artwork.enabled && stored == nil)
    }

    @Test func aGameIsMatchedByNameAndItsBestImagesStored() async throws {
        let artwork = try store()
        #expect(!(await artwork.lookupSettled(hostID: "PC", appID: 1)))
        let found = try await artwork.fetch(hostID: "PC", appID: 1, name: "Hades")
        #expect(found && artwork.version == 1)
        #expect(await artwork.lookupSettled(hostID: "PC", appID: 1))
        #expect(await artwork.image(hostID: "PC", appID: 1, kind: .cover) == Data("COVER".utf8))
        #expect(await artwork.image(hostID: "PC", appID: 1, kind: .wide) == Data("COVER".utf8))
        #expect(await artwork.image(hostID: "PC", appID: 1, kind: .hero) == Data("HERO".utf8))
        // No logo on SteamGridDB: the name is shown
        #expect(await artwork.image(hostID: "PC", appID: 1, kind: .logo) == nil)
        // A second fetch keeps what was chosen: no new search or download
        let searches = fake.count("autocomplete/Hades")
        try await artwork.fetch(hostID: "PC", appID: 1, name: "Hades")
        #expect(fake.count("autocomplete/Hades") == searches)
        #expect(fake.requests.withLock { $0.allSatisfy { $0.url?.host() == "cdn.example" || $0.value(forHTTPHeaderField: "Authorization") == "Bearer k" } })
    }

    @Test func anImageTheCacheDroppedIsDownloadedAgainWithoutASearch() async throws {
        let cache = DiskCache(directory: temporaryDirectory(), budget: 1_000_000, maxEntryBytes: 1000)
        let artwork = try store(cache: cache)
        try await artwork.fetch(hostID: "PC", appID: 1, name: "Hades")
        await cache.remove("sgdb/PC/1/hero")
        let searches = fake.count("autocomplete/Hades"), downloads = fake.count("/hero.png")
        #expect(await artwork.image(hostID: "PC", appID: 1, kind: .hero) == Data("HERO".utf8))
        #expect(fake.count("autocomplete/Hades") == searches && fake.count("/hero.png") == downloads + 1)
    }

    @Test func downloadingAllSkipsGamesLookedUpAndCountsTheFoundOnes() async throws {
        let artwork = try store()
        let apps = [(id: 1, name: "Hades"), (id: 2, name: "Unknown")]
        #expect(try await artwork.downloadAll(hostID: "PC", apps: apps, refresh: false) == 1)
        #expect(await artwork.lookupSettled(hostID: "PC", appID: 2))
        #expect(await artwork.image(hostID: "PC", appID: 2, kind: .cover) == nil)
        #expect(try await artwork.downloadAll(hostID: "PC", apps: apps, refresh: false) == 0)
        #expect(artwork.progress == nil)
        // Refreshing searches every game again
        let searches = fake.count("autocomplete/Hades")
        #expect(try await artwork.downloadAll(hostID: "PC", apps: apps, refresh: true) == 1)
        #expect(fake.count("autocomplete/Hades") == searches + 1)
    }

    @Test func aRejectedKeyStopsTheDownloadAndNoKeyIsAFailure() async throws {
        let rejecting = ArtworkStore(
            secrets: MemoryStorage(), defaults: UserDefaults(suiteName: "delos.tests.\(UUID().uuidString)")!, matches: temporaryDirectory(),
            transport: FakeSteamGridDB(["search/autocomplete/Hades": (401, "")]).transport)
        await #expect(throws: SteamGridDBError.noKey) { try await rejecting.fetch(hostID: "PC", appID: 1, name: "Hades") }
        try rejecting.setAPIKey("wrong")
        await #expect(throws: SteamGridDBError.keyRejected) {
            try await rejecting.downloadAll(hostID: "PC", apps: [(1, "Hades"), (2, "Hades")], refresh: false)
        }
        #expect(!(await rejecting.lookupSettled(hostID: "PC", appID: 1)))
    }

    @Test func boxArtComesFromThePCOnceAndThenFromTheCache() async throws {
        let artwork = try store(key: nil)
        let calls = Mutex(0)
        let fetch: @Sendable () async throws -> Data = {
            calls.withLock { $0 += 1 }
            return Data("BOX".utf8)
        }
        #expect(await artwork.boxArt(hostID: "PC", appID: 3, fetch: fetch) == Data("BOX".utf8))
        #expect(await artwork.boxArt(hostID: "PC", appID: 3, fetch: fetch) == Data("BOX".utf8))
        #expect(calls.withLock { $0 } == 1)
        // A PC that sends nothing gives nothing, and is asked again next time
        #expect(await artwork.boxArt(hostID: "PC", appID: 4) { throw URLError(.timedOut) } == nil)
    }
}
