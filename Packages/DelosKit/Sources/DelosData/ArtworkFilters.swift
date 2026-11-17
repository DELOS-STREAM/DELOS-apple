import Foundation

/// Which images the Artwork screen lists: still ones, animated ones or both (`ArtType` of DELOS for Android).
public enum ArtType: String, CaseIterable, Sendable {
    case all, still, animated
}

/// The order of the artwork grid (`ArtSort`). SteamGridDB has no sort parameter, so it is applied to what was loaded.
public enum ArtSort: String, CaseIterable, Sendable {
    case score, newest, oldest
}

/// The filters of one artwork tab (`ArtFilters`). NSFW and humor images are never requested, so they are not filters.
/// [style] and [dimensions] are SteamGridDB's own values (nil: any).
public struct ArtFilters: Equatable, Sendable {
    public var type: ArtType
    public var style: String?
    public var dimensions: String?
    public var sort: ArtSort

    public init(type: ArtType = .all, style: String? = nil, dimensions: String? = nil, sort: ArtSort = .score) {
        self.type = type
        self.style = style
        self.dimensions = dimensions
        self.sort = sort
    }

    /// How many criteria differ from the defaults (the badge of the Filter pill).
    public var activeCount: Int {
        (type != .all ? 1 : 0) + (style != nil ? 1 : 0) + (dimensions != nil ? 1 : 0) + (sort != .score ? 1 : 0)
    }

    public var active: Bool { activeCount > 0 }
}

/// One SteamGridDB request of a filter: [animated] marks its images, [params] are the query parameters in Android's order.
public struct ArtQuery: Equatable, Sendable {
    public let animated: Bool
    public let params: [URLQueryItem]
}

/// An active filter as a chip; each kind clears one field (`ActiveFilter`).
public enum ActiveFilter: Hashable, Sendable {
    case type(ArtType)
    case style(String)
    case dimensions(String)
    case sort(ArtSort)
}

/// What can be filtered per kind, and how filters become SteamGridDB requests (`ArtFilterRules`; everything here is pure).
public enum ArtFilterRules {
    /// Logos have no animated variant.
    public static func hasType(_ kind: ArtKind) -> Bool { kind != .logo }

    public static func styles(_ kind: ArtKind) -> [String] {
        switch kind {
        case .cover, .wide: ["alternate", "blurred", "white_logo", "material", "no_logo"]
        case .hero: ["alternate", "blurred", "material"]
        case .logo: ["official", "white", "black", "custom"]
        }
    }

    public static func dimensions(_ kind: ArtKind) -> [String] {
        switch kind {
        case .cover: SteamGridDB.coverDimensions
        case .wide: SteamGridDB.wideDimensions
        case .hero: ["1920x620", "3840x1240", "1600x650"]
        case .logo: []
        }
    }

    /// "600x900" → "600 × 900" (a technical readout, the same in every language).
    public static func dimensionsLabel(_ dimensions: String) -> String {
        dimensions.replacingOccurrences(of: "x", with: " × ")
    }

    /// Drops what [kind] cannot filter by, so a stale value never reaches a request.
    public static func normalized(_ kind: ArtKind, _ filters: ArtFilters) -> ArtFilters {
        var result = filters
        if !hasType(kind) { result.type = .all }
        result.style = filters.style.flatMap { styles(kind).contains($0) ? $0 : nil }
        result.dimensions = filters.dimensions.flatMap { dimensions(kind).contains($0) ? $0 : nil }
        return result
    }

    /// The requests of [filters] for [kind]. Both types are two requests (SteamGridDB's answers do not say which image is
    /// animated); animated ones ask for WebP only, the one animated format the app can show.
    public static func queries(_ kind: ArtKind, _ filters: ArtFilters) -> [ArtQuery] {
        let f = normalized(kind, filters)
        func query(animated: Bool) -> ArtQuery {
            var items = [
                URLQueryItem(name: "types", value: animated ? "animated" : "static"),
                URLQueryItem(name: "nsfw", value: "false"),
                URLQueryItem(name: "humor", value: "false"),
                URLQueryItem(name: "mimes", value: animated ? "image/webp"
                    : kind == .logo ? "image/png,image/webp" : "image/png,image/jpeg,image/webp"),
            ]
            if let style = f.style { items.append(URLQueryItem(name: "styles", value: style)) }
            // Covers and wide covers are limited to the shapes the app lays out well, even without a choice
            let sizes = f.dimensions
                ?? (kind == .cover || kind == .wide ? dimensions(kind).joined(separator: ",") : nil)
            if let sizes { items.append(URLQueryItem(name: "dimensions", value: sizes)) }
            return ArtQuery(animated: animated, params: items)
        }
        if !hasType(kind) { return [query(animated: false)] }
        switch f.type {
        case .still: return [query(animated: false)]
        case .animated: return [query(animated: true)]
        case .all: return [query(animated: false), query(animated: true)]
        }
    }

    /// One list from several answers, an image once (the earlier answer's copy), the answers interleaved so that neither
    /// the still nor the animated images end up behind the other when the sort cannot tell them apart.
    public static func merge(_ lists: [[SteamGridDBImage]]) -> [SteamGridDBImage] {
        var seen = Set<Int>()
        let unique = lists.map { list in list.filter { seen.insert($0.id).inserted } }
        let longest = unique.map(\.count).max() ?? 0
        return (0..<longest).flatMap { index in unique.compactMap { index < $0.count ? $0[index] : nil } }
    }

    /// [images] in the order of [sort]; ties keep the order they came in (SteamGridDB lists the best rated first).
    public static func sort(_ images: [SteamGridDBImage], _ sort: ArtSort) -> [SteamGridDBImage] {
        let indexed = Array(images.enumerated())
        let ordered: [(offset: Int, element: SteamGridDBImage)]
        switch sort {
        case .score:
            ordered = indexed.sorted { ($0.element.score, $1.offset) > ($1.element.score, $0.offset) }
        case .newest:
            // Without a date the id stands in: SteamGridDB numbers images as they are uploaded
            ordered = indexed.sorted {
                (($0.element.date ?? 0), $0.element.id, $1.offset) > (($1.element.date ?? 0), $1.element.id, $0.offset)
            }
        case .oldest:
            ordered = indexed.sorted {
                (($0.element.date ?? Int.max), $0.element.id, $0.offset) < (($1.element.date ?? Int.max), $1.element.id, $1.offset)
            }
        }
        return ordered.map(\.element)
    }

    /// What a loaded list is kept under: the request's own parameters, not the sort.
    public static func cacheKey(_ kind: ArtKind, _ filters: ArtFilters) -> String {
        let f = normalized(kind, filters)
        return "\(kind.rawValue)|\(f.type.rawValue)|\(f.style ?? "")|\(f.dimensions ?? "")"
    }

    /// The removable chips under the toolbar, in order.
    public static func chips(_ filters: ArtFilters) -> [ActiveFilter] {
        var result: [ActiveFilter] = []
        if filters.type != .all { result.append(.type(filters.type)) }
        if let style = filters.style { result.append(.style(style)) }
        if let dimensions = filters.dimensions { result.append(.dimensions(dimensions)) }
        if filters.sort != .score { result.append(.sort(filters.sort)) }
        return result
    }

    /// [filters] without what [chip] stands for.
    public static func clear(_ filters: ArtFilters, _ chip: ActiveFilter) -> ArtFilters {
        var result = filters
        switch chip {
        case .type: result.type = .all
        case .style: result.style = nil
        case .dimensions: result.dimensions = nil
        case .sort: result.sort = .score
        }
        return result
    }
}
