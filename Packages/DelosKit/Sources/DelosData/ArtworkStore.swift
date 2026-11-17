import DelosHost
import Foundation
import Observation

/// The game an app was matched with on SteamGridDB and the image used for each kind (`Match` of DELOS for Android).
/// [id] nil: searched, nothing found. A kind in [chosen] with no URL was left empty on purpose (SteamGridDB has none),
/// so the PC's artwork or the name is shown.
struct ArtworkMatch: Codable, Equatable, Sendable {
    struct Chosen: Codable, Equatable, Sendable {
        var id: Int?
        var url: URL?
    }

    var id: Int?
    var name: String?
    var year: Int?
    var chosen: [String: Chosen]?
    /// The game was chosen by hand: a refresh does not search for another one.
    var manual: Bool?
    /// The kinds chosen by hand: a refresh leaves them alone.
    var picked: [String]?
}

/// The image used for a kind of a game's artwork (`ArtworkStore.chosen` of DELOS for Android).
public enum ArtworkChoice: Equatable, Sendable {
    /// Never set.
    case unset
    /// Left empty on purpose: the PC's artwork, or the game's name instead of a logo.
    case none
    /// The SteamGridDB image with this id.
    case image(Int)
}

/// The library's artwork (`ArtworkStore` and `BoxArtCache` of DELOS for Android): the SteamGridDB images of the PCs'
/// games and the PCs' own box art. The images are kept in a ``DiskCache`` with a size limit; which game each app was
/// matched with and which image each kind uses (its URL) are kept in small files under Application Support, so an
/// image the cache dropped is downloaded again without a new search. The API key is the user's own (Settings → Covers),
/// kept in the Keychain and the same for every profile on this device, as is "download automatically". [version]
/// changes whenever images change, so the screens load them again.
@MainActor
@Observable
public final class ArtworkStore {
    /// Bumped whenever stored images change.
    public private(set) var version = 0
    /// The SteamGridDB API key; empty: SteamGridDB is off and the library shows the PCs' box art.
    public private(set) var apiKey: String
    /// New games get their best-rated artwork in the background.
    public var automatic: Bool {
        didSet { defaults.set(automatic, forKey: Self.automaticKey) }
    }
    /// The games ("host/app") whose artwork is being downloaded now.
    public private(set) var busy: Set<String> = []
    /// Downloading the artwork of many games: how far it is, nil when nothing runs.
    public private(set) var progress: (done: Int, total: Int)?
    /// The image being downloaded for a kind of a game ("host/app/kind" → the image's id, ``noImage`` for none).
    private(set) var applyingImages: [String: Int] = [:]
    /// How far the animations the Artwork screen's tiles fetch are downloaded (0…1) by URL; absent: not started, or its size
    /// is not known (`Thumbnails.progress`).
    public private(set) var animationProgress: [URL: Double] = [:]
    /// The URLs whose file was found to be (true) or not to be (false) an animation that plays (`Thumbnails.animatedKnown`).
    private var animatedKnown: [URL: Bool] = [:]

    @ObservationIgnored private let files: ArtworkFiles
    @ObservationIgnored private let secrets: any SecretStorage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: SteamGridDB.Transport?
    /// Games whose lookup has finished (matched with every kind stored, or not found).
    @ObservationIgnored private var settled: Set<String> = []
    @ObservationIgnored private var running: [String: Task<Bool, any Error>] = [:]

    public static let keychainService = "io.github.meitoncz.delos.sgdb"
    static let keyAccount = "api-key"
    static let automaticKey = "sgdb.automatic"

    /// Where the matches are kept: Application Support/artwork; on tvOS, which has no persistent files (only the caches
    /// may be written, and the system may empty them), Caches/artwork-matches. A lost match is looked up again, as a lost
    /// image is downloaded again.
    public static var defaultMatchesDirectory: URL {
        #if os(tvOS)
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "artwork-matches", directoryHint: .isDirectory)
        #else
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "artwork", directoryHint: .isDirectory)
        #endif
    }

    /// - Parameters:
    ///   - matches: where the matches are kept (nil: ``defaultMatchesDirectory``).
    ///   - cache: the images.
    public init(
        secrets: any SecretStorage = KeychainStorage(service: ArtworkStore.keychainService),
        defaults: UserDefaults = .standard,
        matches: URL? = nil,
        cache: DiskCache = .artwork(),
        transport: SteamGridDB.Transport? = nil
    ) {
        self.secrets = secrets
        self.defaults = defaults
        self.transport = transport
        files = ArtworkFiles(matches: matches ?? Self.defaultMatchesDirectory, cache: cache)
        apiKey = (try? secrets.read(account: Self.keyAccount)).flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } } ?? ""
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    public var enabled: Bool { !apiKey.isEmpty }

    /// Stores the key (trimmed; empty removes it and turns SteamGridDB off).
    public func setAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try secrets.delete(account: Self.keyAccount)
        } else {
            try secrets.write(Data(trimmed.utf8), account: Self.keyAccount)
        }
        apiKey = trimmed
        settled.removeAll()
    }

    /// Whether a background lookup is expected to bring [app]'s artwork: SteamGridDB is on and automatic.
    public var lookupExpected: Bool { enabled && automatic }

    public func isBusy(hostID: String, appID: Int) -> Bool { busy.contains(Self.game(hostID, appID)) }

    // MARK: Images

    /// The stored image of [kind] for the app, downloaded again when the cache dropped it; nil when there is none.
    public func image(hostID: String, appID: Int, kind: ArtKind) async -> Data? {
        await files.image(hostID: hostID, appID: appID, kind: kind, client: enabled ? client : nil)
    }

    /// The PC's box art of the app: from the cache, else from [fetch] (the PC's `appasset`), which is then kept.
    public func boxArt(hostID: String, appID: Int, fetch: @escaping @Sendable () async throws -> Data) async -> Data? {
        await files.boxArt(hostID: hostID, appID: appID, fetch: fetch)
    }

    /// Whether the lookup of the app has finished, so the images stored are final (`lookupSettled`).
    public func lookupSettled(hostID: String, appID: Int) async -> Bool {
        let game = Self.game(hostID, appID)
        if settled.contains(game) { return true }
        guard let match = await files.match(hostID: hostID, appID: appID), match.id == nil || match.chosen != nil else { return false }
        settled.insert(game)
        return true
    }

    // MARK: Animations

    /// The stored image of [kind] when it is an animation that plays (``AnimatedImageInfo``), mapped from the cache; nil for
    /// a still image, none, or one the cache dropped (``image(hostID:appID:kind:)`` downloads that again and bumps
    /// ``version``). The file is stored as downloaded, so the animation stays; the still readers decode its first frame
    /// (`animatedFile`).
    public func animation(hostID: String, appID: Int, kind: ArtKind) async -> Data? {
        await files.animation(key: ArtworkFiles.imageKey(hostID, appID, kind))
    }

    /// The file types SteamGridDB serves that play as animations: the full file of a choice is fetched for its tile only in
    /// one of these.
    public static let animatedMimes: Set<String> = ["image/webp", "image/png", "image/gif"]

    /// The animation of an animated choice ([image] `animated`) to play in its tile: its thumbnail, else the full file when
    /// that is another URL of a type that animates; nil when neither plays (`Thumbnails.loadAnimation`). Each URL is
    /// downloaded once and kept in the cache; ``animationProgress`` follows the download.
    public func animation(of image: SteamGridDBImage) async -> Data? {
        guard enabled, image.animated else { return nil }
        if let data = await probe(image.previewURL, key: ArtworkFiles.thumbnailKey(image)) { return data }
        guard Self.animatedMimes.contains(image.mime ?? ""), image.url != image.previewURL else { return nil }
        return await probe(image.url, key: ArtworkFiles.animationKey(image))
    }

    /// Whether [image]'s animation was looked for and nothing plays (its tile keeps the first frame): `hasNoAnimation`.
    public func hasNoAnimation(_ image: SteamGridDBImage) -> Bool {
        animatedKnown[image.previewURL] == false
            && (!Self.animatedMimes.contains(image.mime ?? "") || image.url == image.previewURL || animatedKnown[image.url] == false)
    }

    /// The file at [url] (cache [key]) when it plays; a download that fails is not remembered, so it is tried again.
    private func probe(_ url: URL, key: String) async -> Data? {
        if animatedKnown[url] == false { return nil }
        let (updates, progress) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let watcher = Task { for await share in updates { animationProgress[url] = share } }
        let result = await files.animation(url: url, key: key, client: client) { progress.yield($0) }
        progress.finish()
        await watcher.value
        animationProgress[url] = nil
        guard let result else { return nil }
        animatedKnown[url] = result.animation != nil
        return result.animation
    }

    // MARK: Downloads

    /// Downloads the app's best-rated image of each kind; the game is looked up by its [name] the first time, and kinds
    /// already chosen are kept unless [refresh]. Returns whether SteamGridDB knows the game.
    @discardableResult
    public func fetch(hostID: String, appID: Int, name: String, refresh: Bool = false) async throws -> Bool {
        let game = Self.game(hostID, appID)
        if let task = running[game] { return try await task.value }
        guard enabled else { throw SteamGridDBError.noKey }
        let client = client
        let files = files
        let task = Task { try await files.fetch(hostID: hostID, appID: appID, name: name, refresh: refresh, client: client) }
        running[game] = task
        busy.insert(game)
        defer {
            running[game] = nil
            busy.remove(game)
        }
        let found = try await task.value
        settled.insert(game)
        version += 1
        return found
    }

    /// Downloads the artwork of [apps] (id and name): only games never looked up, or all of them again with [refresh].
    /// Stops at the first error that concerns every game (no key, a rejected key) and throws it; other failures skip
    /// the game. Returns how many games SteamGridDB knows.
    @discardableResult
    public func downloadAll(hostID: String, apps: [(id: Int, name: String)], refresh: Bool) async throws -> Int {
        guard progress == nil else { return 0 }
        var todo = apps
        if !refresh {
            var missing: [(id: Int, name: String)] = []
            for app in apps where await files.match(hostID: hostID, appID: app.id) == nil { missing.append(app) }
            todo = missing
        }
        guard !todo.isEmpty else { return 0 }
        progress = (0, todo.count)
        defer { progress = nil }
        var found = 0
        for (index, app) in todo.enumerated() {
            do {
                if try await fetch(hostID: hostID, appID: app.id, name: app.name, refresh: refresh) { found += 1 }
            } catch let error as SteamGridDBError where error == .noKey || error == .keyRejected {
                throw error
            } catch {
                // A network failure costs this game its artwork, not the others
            }
            progress = (index + 1, todo.count)
        }
        return found
    }

    // MARK: Choosing artwork (the Artwork screen)

    /// The id `applying` reports for an image being left empty.
    public static let noImage = -1

    /// Whether the app has been looked up on SteamGridDB (found or not).
    public func isSearched(hostID: String, appID: Int) async -> Bool {
        await files.match(hostID: hostID, appID: appID) != nil
    }

    /// The SteamGridDB game the app is matched with.
    public func matchedGame(hostID: String, appID: Int) async -> SteamGridDBGame? {
        await files.matchedGame(hostID: hostID, appID: appID)
    }

    /// The image in use for [kind].
    public func choice(hostID: String, appID: Int, kind: ArtKind) async -> ArtworkChoice {
        await files.choice(hostID: hostID, appID: appID, kind: kind)
    }

    /// The id of the image being downloaded for [kind] (``noImage`` for none), nil when nothing is.
    public func applying(hostID: String, appID: Int, kind: ArtKind) -> Int? {
        applyingImages[Self.game(hostID, appID) + "/" + kind.rawValue]
    }

    /// The games SteamGridDB knows under [term] (`search`).
    public func search(_ term: String) async throws -> [SteamGridDBGame] {
        guard enabled else { throw SteamGridDBError.noKey }
        return try await client.search(term)
    }

    /// The images [kind] can be chosen from for the app's matched game that match [filters], in the order of their sort
    /// (`choices`). Empty for an app that was not matched.
    public func choices(hostID: String, appID: Int, kind: ArtKind, filters: ArtFilters = ArtFilters()) async throws -> [SteamGridDBImage] {
        guard enabled else { throw SteamGridDBError.noKey }
        guard let id = await files.matchedGame(hostID: hostID, appID: appID)?.id else { return [] }
        return try await client.images(gameID: id, kind: kind, filters: filters)
    }

    /// A choice's thumbnail.
    public func thumbnail(_ image: SteamGridDBImage) async -> Data? {
        await files.thumbnail(image, client: client)
    }

    /// Uses [image] for [kind] (nil: none, so the PC's artwork or the game's name), picked by hand (`apply`).
    public func apply(hostID: String, appID: Int, kind: ArtKind, image: SteamGridDBImage?) async throws {
        guard enabled else { throw SteamGridDBError.noKey }
        let game = Self.game(hostID, appID)
        let key = game + "/" + kind.rawValue
        applyingImages[key] = image?.id ?? Self.noImage
        busy.insert(game)
        defer {
            applyingImages[key] = nil
            busy.remove(game)
            version += 1
        }
        try await files.apply(hostID: hostID, appID: appID, kind: kind, image: image, client: client)
    }

    /// Matches the app with [game] by hand and downloads its best-rated images, the ones chosen before starting over
    /// (`setGame`).
    public func setGame(hostID: String, appID: Int, game: SteamGridDBGame) async throws {
        guard enabled else { throw SteamGridDBError.noKey }
        await files.setGame(hostID: hostID, appID: appID, game: game)
        try await fetch(hostID: hostID, appID: appID, name: game.name, refresh: true)
    }

    private var client: SteamGridDB { SteamGridDB(key: apiKey, transport: transport) }

    private static func game(_ hostID: String, _ appID: Int) -> String { "\(hostID)/\(appID)" }
}

/// The files of ``ArtworkStore``, off the main actor: the matches and the image cache.
actor ArtworkFiles {
    let matches: URL
    let cache: DiskCache
    /// At most this many images are downloaded at once, whatever number of tiles ask for one.
    static let parallelDownloads = 4
    private let gate = MetadataRequestGate(permits: ArtworkFiles.parallelDownloads)
    /// The downloads under way by cache key: tiles that ask for the same image wait for one download.
    private var inflight: [String: Task<Data?, Never>] = [:]

    init(matches: URL, cache: DiskCache) {
        self.matches = matches
        self.cache = cache
    }

    /// The largest box art the PC may send (Android's `BoxArtCache`).
    static let boxArtLimit: Int64 = 5 * 1024 * 1024

    func match(hostID: String, appID: Int) -> ArtworkMatch? {
        guard let data = try? Data(contentsOf: matchFile(hostID, appID)) else { return nil }
        return try? JSONDecoder().decode(ArtworkMatch.self, from: data)
    }

    private func write(_ match: ArtworkMatch, hostID: String, appID: Int) {
        let url = matchFile(hostID, appID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(match).write(to: url, options: .atomic)
    }

    /// The match file of an app; the host id is ASCII letters, digits and hyphens (`HostRecord`), so it is a safe name.
    private func matchFile(_ hostID: String, _ appID: Int) -> URL {
        matches.appending(path: hostID, directoryHint: .isDirectory).appending(path: "\(appID).json", directoryHint: .notDirectory)
    }

    static func imageKey(_ hostID: String, _ appID: Int, _ kind: ArtKind) -> String { "sgdb/\(hostID)/\(appID)/\(kind.rawValue)" }
    static func boxArtKey(_ hostID: String, _ appID: Int) -> String { "boxart/\(hostID)/\(appID)" }
    static func thumbnailKey(_ image: SteamGridDBImage) -> String { "thumb/\(image.id)" }
    /// The full file of an animated choice whose thumbnail does not play.
    static func animationKey(_ image: SteamGridDBImage) -> String { "anim/\(image.id)" }

    /// The entry of [key], mapped, when it is an animation that plays.
    func animation(key: String) async -> Data? {
        guard let data = await cache.mappedData(for: key), AnimatedImageInfo.of(data) != nil else { return nil }
        return data
    }

    /// What fetching a file for its animation found: nil when the download failed, else the animation (nil: it does not play).
    struct Probe: Sendable {
        let animation: Data?
    }

    /// The file at [url] as cache entry [key] (downloaded once, [progress] hearing how far), and whether it plays.
    func animation(url: URL, key: String, client: SteamGridDB, progress: @escaping @Sendable (Double) -> Void) async -> Probe? {
        if let data = await cache.mappedData(for: key) { return Probe(animation: AnimatedImageInfo.of(data) != nil ? data : nil) }
        let (cache, limit) = (cache, cache.maxEntryBytes)
        guard let data = await download(key, work: { try await client.download(url, limit: limit, progress: progress) },
                                        store: { try? await cache.store($0, for: key) }) else { return nil }
        guard AnimatedImageInfo.of(data) != nil else { return Probe(animation: nil) }
        // Played from the file rather than held in memory, when it was stored
        return Probe(animation: await cache.mappedData(for: key) ?? data)
    }

    func image(hostID: String, appID: Int, kind: ArtKind, client: SteamGridDB?) async -> Data? {
        let key = Self.imageKey(hostID, appID, kind)
        if let data = await cache.data(for: key) { return data }
        // The cache dropped it: the chosen image is downloaded again
        guard let client, let url = match(hostID: hostID, appID: appID)?.chosen?[kind.rawValue]?.url else { return nil }
        let (cache, limit) = (cache, cache.maxEntryBytes)
        return await download(key) { try await client.download(url, limit: limit) } store: { try? await cache.store($0, for: key) }
    }

    /// Runs [work] once per [key] at a time, and at most ``parallelDownloads`` at a time; every asker gets its result.
    private func download(_ key: String, work: @escaping @Sendable () async throws -> Data,
                          store: @escaping @Sendable (Data) async -> Void) async -> Data? {
        if let running = inflight[key] { return await running.value }
        let gate = gate
        let task = Task<Data?, Never> {
            guard let data = try? await gate.withPermit(work) else { return nil }
            await store(data)
            return data
        }
        inflight[key] = task
        let data = await task.value
        inflight[key] = nil
        return data
    }

    func boxArt(hostID: String, appID: Int, fetch: @escaping @Sendable () async throws -> Data) async -> Data? {
        let key = Self.boxArtKey(hostID, appID)
        if let data = await cache.data(for: key) { return data }
        let cache = cache
        return await download(key) {
            let data = try await fetch()
            guard Int64(data.count) <= Self.boxArtLimit else { throw SteamGridDBError.imageTooLarge }
            return data
        } store: { try? await cache.store($0, for: key) }
    }

    /// `fetchNow` of DELOS for Android. A kind picked by hand stays; a game matched by hand is not searched for again.
    func fetch(hostID: String, appID: Int, name: String, refresh: Bool, client: SteamGridDB) async throws -> Bool {
        var match = match(hostID: hostID, appID: appID)
        if match == nil || (refresh && match?.manual != true) {
            let found = try await client.search(name).first
            match = match != nil && found?.id == match?.id ? match : ArtworkMatch(id: found?.id, name: found?.name, year: found?.year)
        }
        guard var match else { return false }
        write(match, hostID: hostID, appID: appID)
        guard let gameID = match.id else { return false }
        var chosen = match.chosen ?? [:]
        let picked = Set(match.picked ?? [])
        for kind in ArtKind.allCases where !picked.contains(kind.rawValue) && (refresh || chosen[kind.rawValue] == nil) {
            do {
                let image = try await client.images(gameID: gameID, kind: kind).first
                let key = Self.imageKey(hostID, appID, kind)
                if let image {
                    try await cache.store(try await client.download(image.url, limit: cache.maxEntryBytes), for: key)
                } else {
                    await cache.remove(key)
                }
                chosen[kind.rawValue] = ArtworkMatch.Chosen(id: image?.id, url: image?.url)
            } catch SteamGridDBError.keyRejected {
                throw SteamGridDBError.keyRejected
            } catch {
                // This kind stays as it was; the next refresh tries again
            }
        }
        match.chosen = chosen
        write(match, hostID: hostID, appID: appID)
        return true
    }

    /// What the app is matched with, or nil when it was never looked up.
    func matchedGame(hostID: String, appID: Int) -> SteamGridDBGame? {
        guard let match = match(hostID: hostID, appID: appID), let id = match.id else { return nil }
        return SteamGridDBGame(id: id, name: match.name ?? "", year: match.year)
    }

    /// The image of [kind] in use (`chosen` of the Android store).
    func choice(hostID: String, appID: Int, kind: ArtKind) -> ArtworkChoice {
        guard let chosen = match(hostID: hostID, appID: appID)?.chosen?[kind.rawValue] else { return .unset }
        return chosen.id.map(ArtworkChoice.image) ?? .none
    }

    /// Matches the app with [game] by hand (`setGame`): the images chosen before are forgotten and downloaded again.
    func setGame(hostID: String, appID: Int, game: SteamGridDBGame) {
        write(ArtworkMatch(id: game.id, name: game.name, year: game.year, manual: true), hostID: hostID, appID: appID)
    }

    /// Uses [image] for [kind] (nil: none, so the PC's artwork or the game's name), picked by hand and kept by every
    /// later refresh (`applyNow`).
    func apply(hostID: String, appID: Int, kind: ArtKind, image: SteamGridDBImage?, client: SteamGridDB) async throws {
        let key = Self.imageKey(hostID, appID, kind)
        if let image {
            try await cache.store(try await client.download(image.url, limit: cache.maxEntryBytes), for: key)
        } else {
            await cache.remove(key)
        }
        var match = match(hostID: hostID, appID: appID) ?? ArtworkMatch()
        var chosen = match.chosen ?? [:]
        chosen[kind.rawValue] = ArtworkMatch.Chosen(id: image?.id, url: image?.url)
        match.chosen = chosen
        match.picked = Array(Set(match.picked ?? []).union([kind.rawValue])).sorted()
        write(match, hostID: hostID, appID: appID)
    }

    /// A thumbnail of a choice, kept in the cache.
    func thumbnail(_ image: SteamGridDBImage, client: SteamGridDB) async -> Data? {
        let key = Self.thumbnailKey(image)
        if let data = await cache.data(for: key) { return data }
        let (cache, limit, url) = (cache, cache.maxEntryBytes, image.previewURL)
        return await download(key) { try await client.download(url, limit: limit) } store: { try? await cache.store($0, for: key) }
    }
}
