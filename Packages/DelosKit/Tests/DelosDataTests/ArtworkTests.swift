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

@MainActor
@Suite struct ArtworkChoiceTests {
    private let fake = FakeSteamGridDB([
        "search/autocomplete/Hades": (200, list(#"{"id":7,"name":"Hades","release_date":1600000000}"#)),
        "search/autocomplete/Hades%20II": (200, list(#"{"id":8,"name":"Hades II"}"#)),
        "grids/game/7": (200, list(image(70, "cover.png") + "," + image(72, "other.png"))),
        "heroes/game/7": (200, list(image(71, "hero.png"))),
        "logos/game/7": (200, list("")),
        "grids/game/8": (200, list(image(80, "cover2.png"))),
        "heroes/game/8": (200, list("")),
        "logos/game/8": (200, list("")),
        "/cover.png": (200, "COVER"), "/other.png": (200, "OTHER"), "/hero.png": (200, "HERO"), "/cover2.png": (200, "COVER2"),
    ])

    private func store() -> ArtworkStore {
        let secrets = ArtworkStoreTests.MemoryStorage()
        try? secrets.write(Data("k".utf8), account: "api-key")
        return ArtworkStore(
            secrets: secrets, defaults: UserDefaults(suiteName: "delos.tests.\(UUID().uuidString)")!, matches: temporaryDirectory(),
            cache: DiskCache(directory: temporaryDirectory(), budget: 1_000_000, maxEntryBytes: 1000), transport: fake.transport)
    }

    @Test func theChoicesAreTheMatchedGamesImagesBestRatedFirst() async throws {
        let artwork = store()
        // Not matched yet: nothing to choose from
        #expect(try await artwork.choices(hostID: "PC", appID: 1, kind: .cover).isEmpty)
        try await artwork.fetch(hostID: "PC", appID: 1, name: "Hades")
        #expect(await artwork.matchedGame(hostID: "PC", appID: 1)?.id == 7)
        #expect(try await artwork.choices(hostID: "PC", appID: 1, kind: .cover).map(\.id) == [70, 72])
        #expect(await artwork.choice(hostID: "PC", appID: 1, kind: .cover) == .image(70))
        #expect(await artwork.choice(hostID: "PC", appID: 1, kind: .logo) == .none)
        #expect(await artwork.choice(hostID: "PC", appID: 2, kind: .cover) == .unset)
    }

    @Test func equalScoresKeepTheOrderAndTheBestScoreComesFirst() throws {
        let url = URL(string: "https://cdn.example/a.png")!
        let images = [1, 2, 3, 4].map { SteamGridDBImage(id: $0, url: url, score: [5, 9, 5, 9][$0 - 1]) }
        #expect(ArtFilterRules.sort(images, .score).map(\.id) == [2, 4, 1, 3])
    }

    @Test func choosingAnImageStoresItAndAnAutomaticRefreshLeavesItAlone() async throws {
        let artwork = store()
        try await artwork.fetch(hostID: "PC", appID: 1, name: "Hades")
        let other = try #require(try await artwork.choices(hostID: "PC", appID: 1, kind: .cover).last)
        try await artwork.apply(hostID: "PC", appID: 1, kind: .cover, image: other)
        #expect(await artwork.choice(hostID: "PC", appID: 1, kind: .cover) == .image(72))
        #expect(await artwork.image(hostID: "PC", appID: 1, kind: .cover) == Data("OTHER".utf8))
        #expect(artwork.applying(hostID: "PC", appID: 1, kind: .cover) == nil)
        // Refreshing every game downloads the best-rated image of each kind again, except the one picked by hand
        try await artwork.fetch(hostID: "PC", appID: 1, name: "Hades", refresh: true)
        #expect(await artwork.choice(hostID: "PC", appID: 1, kind: .cover) == .image(72))
        #expect(await artwork.image(hostID: "PC", appID: 1, kind: .cover) == Data("OTHER".utf8))
    }

    @Test func choosingNoImageRemovesTheStoredOneAndSaysSo() async throws {
        let artwork = store()
        try await artwork.fetch(hostID: "PC", appID: 1, name: "Hades")
        try await artwork.apply(hostID: "PC", appID: 1, kind: .hero, image: nil)
        #expect(await artwork.choice(hostID: "PC", appID: 1, kind: .hero) == .none)
        #expect(await artwork.image(hostID: "PC", appID: 1, kind: .hero) == nil)
    }

    @Test func aGameMatchedByHandKeepsItsMatchAndStartsTheImagesOver() async throws {
        let artwork = store()
        try await artwork.fetch(hostID: "PC", appID: 1, name: "Hades")
        let other = try #require(try await artwork.choices(hostID: "PC", appID: 1, kind: .cover).last)
        try await artwork.apply(hostID: "PC", appID: 1, kind: .cover, image: other)
        let games = try await artwork.search("Hades II")
        try await artwork.setGame(hostID: "PC", appID: 1, game: try #require(games.first))
        #expect(await artwork.matchedGame(hostID: "PC", appID: 1)?.name == "Hades II")
        #expect(await artwork.choice(hostID: "PC", appID: 1, kind: .cover) == .image(80))
        #expect(await artwork.image(hostID: "PC", appID: 1, kind: .cover) == Data("COVER2".utf8))
        // A later refresh does not search for the name again: the game was chosen by hand
        let searches = fake.count("autocomplete/Hades")
        try await artwork.fetch(hostID: "PC", appID: 1, name: "Hades", refresh: true)
        #expect(fake.count("autocomplete/Hades") == searches)
        #expect(await artwork.matchedGame(hostID: "PC", appID: 1)?.name == "Hades II")
    }

    @Test func thumbnailsAreDownloadedOnceAndKept() async throws {
        let artwork = store()
        let image = SteamGridDBImage(id: 70, url: URL(string: "https://cdn.example/cover.png")!, thumb: URL(string: "https://cdn.example/other.png")!)
        #expect(await artwork.thumbnail(image) == Data("OTHER".utf8))
        #expect(await artwork.thumbnail(image) == Data("OTHER".utf8))
        #expect(fake.count("/other.png") == 1)
    }

    @Test func theReplyKeepsWhatTheAPITellsAboutAnImage() throws {
        let reply = Data(#"""
        {"data":[{"id":5,"url":"https://cdn.example/a.jpg","thumb":"https://cdn.example/t.jpg","width":600,"height":900,
        "style":["white_logo","alternate"],"score":12,"author":{"name":"Zed"},"date":1700000000000,"mime":"image/jpeg"},
        {"id":6,"url":"https://cdn.example/b.png","date":"2025-06-23T10:00:00.000Z"},
        {"id":7,"url":"https://cdn.example/c.webm","mime":"image/webm"}]}
        """#.utf8)
        let images = try SteamGridDB.parseImages(reply)
        #expect(images.map(\.id) == [5, 6])
        let first = try #require(images.first)
        #expect(first.thumb.lastPathComponent == "t.jpg" && first.style == "white_logo" && first.score == 12)
        #expect(first.author == "Zed" && first.date == 1_700_000_000 && first.format == "JPG")
        // Without a thumbnail the full image stands in; a date can be ISO text
        #expect(images[1].thumb == images[1].url && images[1].date == 1_750_672_800 && images[1].format == nil)
        #expect(SteamGridDBImage(id: 1, url: URL(string: "https://cdn.example/x.png")!, thumb: URL(string: "https://cdn.example/t.webm")!)
            .previewURL.lastPathComponent == "x.png")
    }
}

/// A body that counts how many downloads run at once.
private actor Concurrency {
    private(set) var running = 0
    private(set) var peak = 0
    private(set) var starts = 0
    func enter() { running += 1; starts += 1; peak = max(peak, running) }
    func leave() { running -= 1 }
}

@Suite struct ArtworkDownloadTests {
    private func files(_ tag: String) -> (ArtworkFiles, DiskCache) {
        let cache = DiskCache(directory: temporaryDirectory(), budget: 1_000_000, maxEntryBytes: 1000)
        return (ArtworkFiles(matches: temporaryDirectory(), cache: cache), cache)
    }

    @Test func tilesAskingForTheSameImageShareOneDownloadAndTheNumberOfDownloadsIsBounded() async {
        let (files, _) = files("a")
        let counter = Concurrency()
        let fetch: @Sendable () async throws -> Data = {
            await counter.enter()
            try await Task.sleep(for: .milliseconds(40))
            await counter.leave()
            return Data(count: 10)
        }
        await withTaskGroup(of: Void.self) { group in
            // 10 tiles of one image, and 12 different images
            for _ in 0..<10 { group.addTask { _ = await files.boxArt(hostID: "h", appID: 0, fetch: fetch) } }
            for id in 1...12 { group.addTask { _ = await files.boxArt(hostID: "h", appID: id, fetch: fetch) } }
        }
        #expect(await counter.starts == 13)
        #expect(await counter.peak <= ArtworkFiles.parallelDownloads)
    }

    @Test func aPlainHTTPImageAddressIsRefused() async throws {
        let fake = FakeSteamGridDB(["/a.png": (200, "x")])
        let client = SteamGridDB(key: "k", transport: fake.transport)
        await #expect(throws: SteamGridDBError.insecureURL) { try await client.download(URL(string: "http://cdn.example/a.png")!, limit: 10) }
        #expect(fake.count("a.png") == 0)
        #expect(try SteamGridDB.parseImages(Data(list(#"{"id":1,"url":"http://cdn.example/a.png"}"#).utf8)).isEmpty)
    }
}
