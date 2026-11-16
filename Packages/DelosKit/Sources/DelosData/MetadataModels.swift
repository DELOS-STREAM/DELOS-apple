import Foundation

/// Consume a malformed optional cached element without discarding a valid game identity.
private struct MetadataCachedValue<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}

public struct GameGenre: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public init(id: Int, name: String) { self.id = id; self.name = name }
}

public struct MetadataCandidate: Codable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let year: Int?
    public let steamAppIDs: [Int64]
    public let genres: [GameGenre]
    public let summary: String?
    public let platformIDs: [Int]
    public let ratingCount: Int
    public let themes: [GameGenre]
    public var isPC: Bool { platformIDs.contains(6) }

    public init(id: Int64, name: String, year: Int? = nil, steamAppIDs: [Int64] = [], genres: [GameGenre] = [],
                summary: String? = nil, platformIDs: [Int] = [], ratingCount: Int = 0, themes: [GameGenre] = []) {
        self.id = id; self.name = name; self.year = year; self.steamAppIDs = steamAppIDs; self.genres = genres
        self.summary = summary; self.platformIDs = platformIDs; self.ratingCount = ratingCount; self.themes = themes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, year, steamAppIDs, genres, summary, platformIDs, ratingCount, themes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "Empty metadata identity")
        }
        self.init(id: try c.decode(Int64.self, forKey: .id), name: name,
                  year: try c.decodeIfPresent(Int.self, forKey: .year),
                  steamAppIDs: try c.decodeIfPresent([Int64].self, forKey: .steamAppIDs) ?? [],
                  genres: try c.decodeIfPresent([MetadataCachedValue<GameGenre>].self, forKey: .genres)?.compactMap(\.value) ?? [],
                  summary: try c.decodeIfPresent(String.self, forKey: .summary),
                  platformIDs: try c.decodeIfPresent([Int].self, forKey: .platformIDs) ?? [],
                  ratingCount: try c.decodeIfPresent(Int.self, forKey: .ratingCount) ?? 0,
                  themes: try c.decodeIfPresent([MetadataCachedValue<GameGenre>].self, forKey: .themes)?.compactMap(\.value) ?? [])
    }
}

public enum NativeHDR: String, Codable, Sendable { case hdr, sdr, unknown }
public struct HDREvidence: Codable, Equatable, Sendable {
    public let support: NativeHDR
    public let page: String?
    public let notes: String?
    public init(support: NativeHDR = .unknown, page: String? = nil, notes: String? = nil) {
        self.support = support; self.page = page; self.notes = notes
    }
    private enum CodingKeys: String, CodingKey { case support, page, notes }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(support: (try? c.decodeIfPresent(NativeHDR.self, forKey: .support)) ?? .unknown,
                  page: try c.decodeIfPresent(String.self, forKey: .page),
                  notes: try c.decodeIfPresent(String.self, forKey: .notes))
    }
}

/// HLTB comp_all seconds, never a Main Story figure or an arithmetic mean of its detailed table.
public struct CompletionTime: Codable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let seconds: Int64
    public let url: String
    public init(id: Int64, name: String, seconds: Int64, url: String) {
        self.id = id; self.name = name; self.seconds = seconds; self.url = url
    }
}

/// All timestamps use epoch milliseconds, matching Android's provider-failure and refresh policy.
public struct GameMetadata: Codable, Equatable, Sendable {
    public var candidate: MetadataCandidate?
    public var hdr: HDREvidence
    public var completion: CompletionTime?
    public var updatedAt: Int64
    public var manual: Bool
    public var igdbFailedAt: Int64
    public var pcgwFailedAt: Int64
    public var hltbFailedAt: Int64
    public var steamFailedAt: Int64
    public var steamTags: [String]

    public init(candidate: MetadataCandidate? = nil, hdr: HDREvidence = HDREvidence(), completion: CompletionTime? = nil,
                updatedAt: Int64 = 0, manual: Bool = false, igdbFailedAt: Int64 = 0, pcgwFailedAt: Int64 = 0,
                hltbFailedAt: Int64 = 0, steamFailedAt: Int64 = 0, steamTags: [String] = []) {
        self.candidate = candidate; self.hdr = hdr; self.completion = completion; self.updatedAt = updatedAt
        self.manual = manual; self.igdbFailedAt = igdbFailedAt; self.pcgwFailedAt = pcgwFailedAt
        self.hltbFailedAt = hltbFailedAt; self.steamFailedAt = steamFailedAt; self.steamTags = steamTags
    }

    private enum CodingKeys: String, CodingKey {
        case candidate, hdr, completion, updatedAt, manual, igdbFailedAt, pcgwFailedAt, hltbFailedAt, steamFailedAt, steamTags
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(candidate: try c.decodeIfPresent(MetadataCandidate.self, forKey: .candidate),
                  hdr: try c.decodeIfPresent(HDREvidence.self, forKey: .hdr) ?? HDREvidence(),
                  completion: try? c.decodeIfPresent(CompletionTime.self, forKey: .completion),
                  updatedAt: try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0,
                  manual: try c.decodeIfPresent(Bool.self, forKey: .manual) ?? false,
                  igdbFailedAt: try c.decodeIfPresent(Int64.self, forKey: .igdbFailedAt) ?? 0,
                  pcgwFailedAt: try c.decodeIfPresent(Int64.self, forKey: .pcgwFailedAt) ?? 0,
                  hltbFailedAt: try c.decodeIfPresent(Int64.self, forKey: .hltbFailedAt) ?? 0,
                  steamFailedAt: try c.decodeIfPresent(Int64.self, forKey: .steamFailedAt) ?? 0,
                  steamTags: try c.decodeIfPresent([MetadataCachedValue<String>].self, forKey: .steamTags)?.compactMap(\.value) ?? [])
    }
}

public enum MetadataProblem: String, Codable, Sendable { case unavailable, updateFailed, partial }
public struct GameMetadataState: Equatable, Sendable {
    public var data: GameMetadata?
    public var loading: Bool
    public var resolved: Bool
    public var error: MetadataProblem?
    public init(data: GameMetadata? = nil, loading: Bool = false, resolved: Bool = false, error: MetadataProblem? = nil) {
        self.data = data; self.loading = loading; self.resolved = resolved; self.error = error
    }
}

public enum HDRFilter: String, Codable, Sendable { case any, hdr, sdr, unknown }
public enum LengthFilter: String, Codable, Sendable { case any, under10, from10To30, from30To60, over60, unknown }
public struct MetadataFilters: Codable, Equatable, Sendable {
    public var genreID: Int?
    public var themeID: Int?
    public var hdr: HDRFilter
    public var length: LengthFilter
    public init(genreID: Int? = nil, themeID: Int? = nil, hdr: HDRFilter = .any, length: LengthFilter = .any) {
        self.genreID = genreID; self.themeID = themeID; self.hdr = hdr; self.length = length
    }
    public var activeCount: Int { (genreID == nil ? 0 : 1) + (themeID == nil ? 0 : 1) + (hdr == .any ? 0 : 1) + (length == .any ? 0 : 1) }
    public var active: Bool { activeCount > 0 }
    public func matches(_ metadata: GameMetadata?, builtIn: Bool = false) -> Bool {
        if builtIn { return !active }
        if let genreID, metadata?.candidate?.genres.contains(where: { $0.id == genreID }) != true { return false }
        if let themeID, metadata?.candidate?.themes.contains(where: { $0.id == themeID }) != true { return false }
        let support = metadata?.hdr.support ?? .unknown
        if hdr != .any, hdr.rawValue != support.rawValue { return false }
        let seconds = metadata?.completion?.seconds ?? 0
        let known = seconds > 0
        switch length {
        case .any: return true
        case .unknown: return !known
        case .under10: return known && seconds < 36_000
        case .from10To30: return known && seconds >= 36_000 && seconds < 108_000
        case .from30To60: return known && seconds >= 108_000 && seconds < 216_000
        case .over60: return known && seconds >= 216_000
        }
    }
}
