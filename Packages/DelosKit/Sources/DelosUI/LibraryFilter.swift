import DelosData
import DelosHost
import Foundation
import Observation

/// The library filter of each PC (`GameMetadataStore.filters` of DELOS for Android, kept per PC here): which of the four
/// criteria narrow the library of that PC. Kept across launches; a PC without a filter has no entry.
@MainActor @Observable
final class LibraryFilters {
    private var values: [String: MetadataFilters]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    static let defaultsKey = "delos.libraryFilters"

    init(defaults: UserDefaults = .standard, key: String = LibraryFilters.defaultsKey) {
        self.defaults = defaults
        self.key = key
        values = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: MetadataFilters].self, from: $0) } ?? [:]
    }

    func filters(hostID: String) -> MetadataFilters { values[hostID] ?? MetadataFilters() }

    func set(_ filters: MetadataFilters, hostID: String) {
        if filters.active { values[hostID] = filters } else { values[hostID] = nil }
        defaults.set(try? JSONEncoder().encode(values), forKey: key)
    }
}

/// What the library filter does to the list and how it reads (`FilterModal.kt`, `MetadataUi.kt` of DELOS for Android).
enum LibraryFilter {
    /// The games of [apps] that [filters] let through, in order. DELOS's own entries pass only while nothing is filtered.
    static func apply(_ filters: MetadataFilters, to apps: [HostApp], data: (HostApp) -> GameMetadata?) -> [HostApp] {
        guard filters.active else { return apps }
        return apps.filter { filters.matches(data($0), builtIn: BundledArtwork.kind($0) != nil) }
    }

    /// How many games carry each genre (by genre id); a game lists a genre at most once.
    static func genreCounts(_ games: [GameMetadata?]) -> [Int: Int] {
        counts(games) { $0.candidate?.genres ?? [] }
    }

    /// How many games carry each theme (by theme id); a game lists a theme at most once.
    static func themeCounts(_ games: [GameMetadata?]) -> [Int: Int] {
        counts(games) { $0.candidate?.themes ?? [] }
    }

    private static func counts(_ games: [GameMetadata?], _ entries: (GameMetadata) -> [GameGenre]) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for case let game? in games {
            for id in Set(entries(game).map(\.id)) { counts[id, default: 0] += 1 }
        }
        return counts
    }

    /// Every genre any of [games] has, once, ordered by its name in the language ([name]).
    static func genres(_ games: [GameMetadata?], name: (GameGenre) -> String = TagLook.genreName) -> [GameGenre] {
        sorted(games.flatMap { $0?.candidate?.genres ?? [] }, name: name)
    }

    /// Every theme any of [games] has, once, ordered by its name in the language ([name]).
    static func themes(_ games: [GameMetadata?], name: (GameGenre) -> String = TagLook.themeName) -> [GameGenre] {
        sorted(games.flatMap { $0?.candidate?.themes ?? [] }, name: name)
    }

    private static func sorted(_ all: [GameGenre], name: (GameGenre) -> String) -> [GameGenre] {
        var seen = Set<Int>()
        return all.filter { seen.insert($0.id).inserted }
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    /// The live result of the sheet's title: "27 of 55 apps", or "All 55 apps" without a filter.
    static func resultLine(shown: Int, total: Int, active: Bool) -> String {
        active ? LPlural("filters_result_active", total, shown) : LPlural("filters_result_all", total)
    }

    /// The home hint bar's label for Y: "Filter", with the number of narrowing criteria while any is set.
    static func hintLabel(_ filters: MetadataFilters) -> String {
        filters.active ? LPlural("filters_hint_active", filters.activeCount) : L("filters_hint")
    }

    /// The library note of the hint bar while a filter is on: "27 of 55 apps on PC".
    static func filteredNote(shown: Int, total: Int, pc: String) -> String {
        LPlural("shell_home_apps_filtered", total, shown, pc)
    }

    static func hdrLabel(_ filter: HDRFilter) -> String {
        switch filter {
        case .any: L("filters_hdr_any")
        case .hdr: L("filters_hdr_hdr")
        case .sdr: L("filters_hdr_sdr")
        case .unknown: L("metadata_hdr_unverified")
        }
    }

    static func hdrIcon(_ filter: HDRFilter) -> String? {
        switch filter {
        case .any: nil
        case .hdr: Symbols.hdrOn
        case .sdr: Symbols.sdr
        case .unknown: Symbols.hdrUnknown
        }
    }

    static func lengthLabel(_ filter: LengthFilter) -> String {
        switch filter {
        case .any: L("filters_length_any")
        case .under10: L("filters_length_under_10")
        case .from10To30: L("filters_length_10_30")
        case .from30To60: L("filters_length_30_60")
        case .over60: L("filters_length_over_60")
        case .unknown: L("filters_length_unknown")
        }
    }
}
