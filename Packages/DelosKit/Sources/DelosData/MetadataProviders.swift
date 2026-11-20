import Foundation

public protocol MetadataProviders: Sendable {
    var available: Bool { get }
    func search(_ title: String) async throws -> [MetadataCandidate]
    func game(_ id: Int64) async throws -> MetadataCandidate?
    func hdr(steamAppIDs: [Int64], name: String) async throws -> HDREvidence
    func completion(steamAppIDs: [Int64], name: String) async throws -> CompletionTime?
    func steamTags(_ steamAppIDs: [Int64]) async throws -> [String]
    /// The game overview's details of IGDB game [id]; nil when IGDB has no such game.
    func details(_ id: Int64) async throws -> GameDetails?
}

extension MetadataProviders {
    /// A provider that has no overview details answers none.
    public func details(_ id: Int64) async throws -> GameDetails? { nil }
}

public struct HTTPMetadataProviders: MetadataProviders {
    public let available: Bool
    private let igdb: IGDBMetadataClient
    private let pcgw: PCGamingWikiClient
    private let hltb: HowLongToBeatClient
    private let steam: SteamTagsClient

    public init(configuration: MetadataConfiguration = .bundled(), http: MetadataHTTP = MetadataHTTP()) {
        available = configuration.enabled
        igdb = IGDBMetadataClient(baseURL: configuration.baseURL, http: http)
        pcgw = PCGamingWikiClient(baseURL: configuration.baseURL, http: http)
        hltb = HowLongToBeatClient(http: http)
        steam = SteamTagsClient(baseURL: configuration.baseURL, http: http)
    }
    private func requireAvailable() throws { if !available { throw MetadataError.unavailable } }
    public func search(_ title: String) async throws -> [MetadataCandidate] {
        try requireAvailable()
        return try await igdb.search(title)
    }
    public func game(_ id: Int64) async throws -> MetadataCandidate? {
        try requireAvailable()
        return try await igdb.game(id)
    }
    public func hdr(steamAppIDs: [Int64], name: String) async throws -> HDREvidence {
        try requireAvailable()
        return try await pcgw.lookup(steamAppIDs: steamAppIDs, name: name)
    }
    public func completion(steamAppIDs: [Int64], name: String) async throws -> CompletionTime? {
        try requireAvailable()
        return try await hltb.lookup(name: name, steamAppIDs: steamAppIDs)
    }
    public func details(_ id: Int64) async throws -> GameDetails? {
        try requireAvailable()
        return try await igdb.details(id)
    }
    public func steamTags(_ steamAppIDs: [Int64]) async throws -> [String] {
        try requireAvailable()
        guard let first = steamAppIDs.first, (1...SteamTagsClient.maxAppID).contains(first) else { return [] }
        return try await steam.tags(first)
    }
}
