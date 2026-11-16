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

    @ObservationIgnored private let files: ArtworkFiles
    @ObservationIgnored private let secrets: any SecretStorage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: SteamGridDB.Transport
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
        transport: @escaping SteamGridDB.Transport = SteamGridDB.urlSession
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
    public func boxArt(hostID: String, appID: Int, fetch: @Sendable () async throws -> Data) async -> Data? {
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

    private var client: SteamGridDB { SteamGridDB(key: apiKey, transport: transport) }

    private static func game(_ hostID: String, _ appID: Int) -> String { "\(hostID)/\(appID)" }
}

/// The files of ``ArtworkStore``, off the main actor: the matches and the image cache.
actor ArtworkFiles {
    let matches: URL
    let cache: DiskCache

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

    func image(hostID: String, appID: Int, kind: ArtKind, client: SteamGridDB?) async -> Data? {
        let key = Self.imageKey(hostID, appID, kind)
        if let data = await cache.data(for: key) { return data }
        // The cache dropped it: the chosen image is downloaded again
        guard let client, let url = match(hostID: hostID, appID: appID)?.chosen?[kind.rawValue]?.url,
              let data = try? await client.download(url, limit: cache.maxEntryBytes) else { return nil }
        try? await cache.store(data, for: key)
        return data
    }

    func boxArt(hostID: String, appID: Int, fetch: @Sendable () async throws -> Data) async -> Data? {
        let key = Self.boxArtKey(hostID, appID)
        if let data = await cache.data(for: key) { return data }
        guard let data = try? await fetch(), Int64(data.count) <= Self.boxArtLimit else { return nil }
        try? await cache.store(data, for: key)
        return data
    }

    /// `fetchNow` of DELOS for Android.
    func fetch(hostID: String, appID: Int, name: String, refresh: Bool, client: SteamGridDB) async throws -> Bool {
        var match = match(hostID: hostID, appID: appID)
        if match == nil || refresh {
            let found = try await client.search(name).first
            match = match != nil && found?.id == match?.id ? match : ArtworkMatch(id: found?.id, name: found?.name, year: found?.year)
        }
        guard var match else { return false }
        write(match, hostID: hostID, appID: appID)
        guard let gameID = match.id else { return false }
        var chosen = match.chosen ?? [:]
        for kind in ArtKind.allCases where refresh || chosen[kind.rawValue] == nil {
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
}
