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
    /// The game overview's details of ``candidate`` (fetched when the overview first opens), when it was fetched and when
    /// its last fetch failed (epoch milliseconds): the same 7-day refresh and failure backoff as the rest of the record.
    public var details: GameDetails?
    public var detailsUpdatedAt: Int64
    public var detailsFailedAt: Int64

    public init(candidate: MetadataCandidate? = nil, hdr: HDREvidence = HDREvidence(), completion: CompletionTime? = nil,
                updatedAt: Int64 = 0, manual: Bool = false, igdbFailedAt: Int64 = 0, pcgwFailedAt: Int64 = 0,
                hltbFailedAt: Int64 = 0, steamFailedAt: Int64 = 0, steamTags: [String] = [], details: GameDetails? = nil,
                detailsUpdatedAt: Int64 = 0, detailsFailedAt: Int64 = 0) {
        self.candidate = candidate; self.hdr = hdr; self.completion = completion; self.updatedAt = updatedAt
        self.manual = manual; self.igdbFailedAt = igdbFailedAt; self.pcgwFailedAt = pcgwFailedAt
        self.hltbFailedAt = hltbFailedAt; self.steamFailedAt = steamFailedAt; self.steamTags = steamTags
        self.details = details; self.detailsUpdatedAt = detailsUpdatedAt; self.detailsFailedAt = detailsFailedAt
    }

    private enum CodingKeys: String, CodingKey {
        case candidate, hdr, completion, updatedAt, manual, igdbFailedAt, pcgwFailedAt, hltbFailedAt, steamFailedAt, steamTags
        case details, detailsUpdatedAt, detailsFailedAt
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Details of another game than the candidate are never shown
        let candidate = try c.decodeIfPresent(MetadataCandidate.self, forKey: .candidate)
        let details = (try? c.decodeIfPresent(GameDetails.self, forKey: .details)).flatMap { $0?.id == candidate?.id ? $0 : nil }
        self.init(candidate: candidate,
                  hdr: try c.decodeIfPresent(HDREvidence.self, forKey: .hdr) ?? HDREvidence(),
                  completion: try? c.decodeIfPresent(CompletionTime.self, forKey: .completion),
                  updatedAt: try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0,
                  manual: try c.decodeIfPresent(Bool.self, forKey: .manual) ?? false,
                  igdbFailedAt: try c.decodeIfPresent(Int64.self, forKey: .igdbFailedAt) ?? 0,
                  pcgwFailedAt: try c.decodeIfPresent(Int64.self, forKey: .pcgwFailedAt) ?? 0,
                  hltbFailedAt: try c.decodeIfPresent(Int64.self, forKey: .hltbFailedAt) ?? 0,
                  steamFailedAt: try c.decodeIfPresent(Int64.self, forKey: .steamFailedAt) ?? 0,
                  steamTags: try c.decodeIfPresent([MetadataCachedValue<String>].self, forKey: .steamTags)?.compactMap(\.value) ?? [],
                  details: details,
                  detailsUpdatedAt: details == nil ? 0 : (try? c.decodeIfPresent(Int64.self, forKey: .detailsUpdatedAt)) ?? 0,
                  detailsFailedAt: (try? c.decodeIfPresent(Int64.self, forKey: .detailsFailedAt)) ?? 0)
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

public enum HDRFilter: String, Codable, Sendable, CaseIterable { case hdr, sdr, unknown }
public enum LengthFilter: String, Codable, Sendable, CaseIterable { case under10, from10To30, from30To60, over60, unknown }

/// The library filter: each row (genres, themes, HDR support, length) keeps the values chosen in it. A game matches a row with
/// any of its values (an empty row matches every game) and the filter when it matches every row.
public struct MetadataFilters: Codable, Equatable, Sendable {
    public var genres: Set<Int>
    public var themes: Set<Int>
    public var hdr: Set<HDRFilter>
    public var length: Set<LengthFilter>
    public init(genres: Set<Int> = [], themes: Set<Int> = [], hdr: Set<HDRFilter> = [], length: Set<LengthFilter> = []) {
        self.genres = genres; self.themes = themes; self.hdr = hdr; self.length = length
    }
    /// How many values narrow the library, over all rows (two genres and HDR: 3).
    public var activeCount: Int { genres.count + themes.count + hdr.count + length.count }
    public var active: Bool { activeCount > 0 }

    public mutating func toggleGenre(_ id: Int) { Self.toggle(id, in: &genres) }
    public mutating func toggleTheme(_ id: Int) { Self.toggle(id, in: &themes) }
    public mutating func toggleHDR(_ value: HDRFilter) { Self.toggle(value, in: &hdr) }
    public mutating func toggleLength(_ value: LengthFilter) { Self.toggle(value, in: &length) }

    private static func toggle<T>(_ value: T, in set: inout Set<T>) {
        if set.remove(value) == nil { set.insert(value) }
    }

    public func matches(_ metadata: GameMetadata?, builtIn: Bool = false) -> Bool {
        if builtIn { return !active }
        if !genres.isEmpty, metadata?.candidate?.genres.contains(where: { genres.contains($0.id) }) != true { return false }
        if !themes.isEmpty, metadata?.candidate?.themes.contains(where: { themes.contains($0.id) }) != true { return false }
        let support = metadata?.hdr.support ?? .unknown
        if !hdr.isEmpty, !hdr.contains(where: { $0.rawValue == support.rawValue }) { return false }
        let seconds = metadata?.completion?.seconds ?? 0
        return length.isEmpty || length.contains { $0.matches(seconds) }
    }

    private enum CodingKeys: String, CodingKey { case genres, themes, hdr, length, genreID, themeID }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(genres.sorted(), forKey: .genres)
        try c.encode(themes.sorted(), forKey: .themes)
        try c.encode(hdr.map(\.rawValue).sorted(), forKey: .hdr)
        try c.encode(length.map(\.rawValue).sorted(), forKey: .length)
    }

    /// Also reads a filter kept while a row held one value (`genreID`, `themeID`, and one name for HDR and length, "any" for none).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func names(_ key: CodingKeys) -> [String] {
            (try? c.decodeIfPresent([String].self, forKey: key)) ?? (try? c.decodeIfPresent(String.self, forKey: key)).map { [$0] } ?? []
        }
        func ids(_ key: CodingKeys, old: CodingKeys) -> Set<Int> {
            if let ids = try? c.decodeIfPresent([Int].self, forKey: key) { return Set(ids) }
            return Set((try? c.decodeIfPresent(Int.self, forKey: old)).map { [$0] } ?? [])
        }
        self.init(
            genres: ids(.genres, old: .genreID), themes: ids(.themes, old: .themeID),
            hdr: Set(names(.hdr).compactMap(HDRFilter.init(rawValue:))), length: Set(names(.length).compactMap(LengthFilter.init(rawValue:))))
    }
}

private extension LengthFilter {
    func matches(_ seconds: Int64) -> Bool {
        let known = seconds > 0
        switch self {
        case .unknown: return !known
        case .under10: return known && seconds < 36_000
        case .from10To30: return known && seconds >= 36_000 && seconds < 108_000
        case .from30To60: return known && seconds >= 108_000 && seconds < 216_000
        case .over60: return known && seconds >= 216_000
        }
    }
}
