import CryptoKit
import DelosData
import DelosHost
import DelosInput
import Foundation
import Testing
@testable import DelosUI

private func game(genres: [Int] = [], themes: [Int] = [], hdr: NativeHDR = .unknown, hours: Int64 = 0) -> GameMetadata {
    GameMetadata(
        candidate: MetadataCandidate(
            id: 1, name: "G", genres: genres.map { GameGenre(id: $0, name: "g\($0)") }, themes: themes.map { GameGenre(id: $0, name: "t\($0)") }),
        hdr: HDREvidence(support: hdr),
        completion: hours > 0 ? CompletionTime(id: 1, name: "G", seconds: hours * 3600, url: "") : nil)
}

@MainActor @Suite struct LibraryFilterTests {
    private let apps = [
        HostApp(id: 1, title: "Desktop"), HostApp(id: 2, title: "Doom"), HostApp(id: 3, title: "Hades"), HostApp(id: 4, title: "Unknown Game"),
    ]
    private var data: [Int: GameMetadata] {
        [2: game(genres: [5], themes: [19], hdr: .hdr, hours: 12), 3: game(genres: [31, 32], themes: [1], hdr: .sdr, hours: 25)]
    }

    @Test func withoutAFilterEverythingPassesInOrder() {
        #expect(LibraryFilter.apply(MetadataFilters(), to: apps) { data[$0.id] } == apps)
    }

    @Test func aFilterLetsThroughTheGamesThatMatchAndNeverTheBuiltInEntries() {
        let shooters = LibraryFilter.apply(MetadataFilters(genres: [5]), to: apps) { data[$0.id] }
        #expect(shooters.map(\.id) == [2])
        // Desktop is DELOS's own entry: it has no metadata and shows only while nothing is filtered
        #expect(!LibraryFilter.apply(MetadataFilters(hdr: [.unknown]), to: apps) { data[$0.id] }.map(\.id).contains(1))
        #expect(LibraryFilter.apply(MetadataFilters(hdr: [.unknown]), to: apps) { data[$0.id] }.map(\.id) == [4])
    }

    @Test func theCriteriaCombine() {
        let filters = MetadataFilters(genres: [31], hdr: [.sdr], length: [.from10To30])
        #expect(LibraryFilter.apply(filters, to: apps) { data[$0.id] }.map(\.id) == [3])
        #expect(LibraryFilter.apply(MetadataFilters(genres: [31], hdr: [.hdr]), to: apps) { data[$0.id] }.isEmpty)
        #expect(filters.activeCount == 3)
    }

    @Test func severalValuesOfARowLetThroughAnyOfThemAndTheRowsAllMustMatch() {
        // Doom (shooter, HDR) or Hades (adventure, SDR)
        #expect(LibraryFilter.apply(MetadataFilters(genres: [5, 31]), to: apps) { data[$0.id] }.map(\.id) == [2, 3])
        #expect(LibraryFilter.apply(MetadataFilters(genres: [5, 31], hdr: [.hdr]), to: apps) { data[$0.id] }.map(\.id) == [2])
        #expect(LibraryFilter.apply(MetadataFilters(genres: [5, 31], themes: [1], hdr: [.hdr, .sdr]), to: apps) { data[$0.id] }.map(\.id) == [3])
    }

    @Test func theSheetsChoicesApplyOnlyOnConfirmAndClosingDropsThem() {
        let applied = MetadataFilters(genres: [5])
        var draft = LibraryFilterDraft(applied: applied)
        #expect(draft.filters == applied)
        #expect(draft.confirmed == nil)
        draft.filters.toggleGenre(31)
        draft.filters.toggleHDR(.hdr)
        #expect(draft.confirmed == MetadataFilters(genres: [5, 31], hdr: [.hdr]))
        // Closing without confirming: the next opening starts from the applied filter
        #expect(LibraryFilterDraft(applied: applied).filters == applied)
        // Reset clears the choices; confirming applies the empty filter
        draft.reset()
        #expect(draft.confirmed == MetadataFilters())
        draft.filters.toggleGenre(5)
        #expect(draft.confirmed == nil)
    }

    @Test func countsAreOnePerGameAndGenreAndThemeAreSeparate() {
        let games: [GameMetadata?] = [game(genres: [5, 5], themes: [5]), game(genres: [5]), nil]
        #expect(LibraryFilter.genreCounts(games) == [5: 2])
        #expect(LibraryFilter.themeCounts(games) == [5: 1])
    }

    @Test func theChipsAreEachGenreOnceInTheOrderOfTheirNames() {
        let games: [GameMetadata?] = [game(genres: [31, 5]), nil, game(genres: [5, 12])]
        let names = [5: "Shooter", 12: "Role-playing", 31: "Adventure"]
        let sorted = LibraryFilter.genres(games) { names[$0.id] ?? $0.name }
        #expect(sorted.map(\.id) == [31, 12, 5])
    }

    @Test func theSheetStartsOnTheFirstSelectedGenreOrOnAll() {
        let genres = [GameGenre(id: 31, name: "Adventure"), GameGenre(id: 5, name: "Shooter")]
        #expect(LibraryFilterIDs.start(MetadataFilters(), genres: genres) == "filter-genre-all")
        #expect(LibraryFilterIDs.start(MetadataFilters(genres: [5]), genres: genres) == "filter-genre-5")
        #expect(LibraryFilterIDs.start(MetadataFilters(genres: [5, 31]), genres: genres) == "filter-genre-31")
        #expect(LibraryFilterIDs.start(MetadataFilters(genres: [77]), genres: genres) == "filter-genre-all")
    }

    @Test func aFocusedItemKnowsItsSection() {
        #expect(LibraryFilterIDs.section(of: LibraryFilterIDs.genre(5)) == 0)
        #expect(LibraryFilterIDs.section(of: LibraryFilterIDs.theme(nil)) == 1)
        #expect(LibraryFilterIDs.section(of: LibraryFilterIDs.hdr(.sdr)) == 2)
        #expect(LibraryFilterIDs.section(of: LibraryFilterIDs.hdr(nil)) == 2)
        #expect(LibraryFilterIDs.section(of: LibraryFilterIDs.length(.over60)) == 3)
        #expect(LibraryFilterIDs.section(of: LibraryFilterIDs.show) == nil)
        #expect(LibraryFilterIDs.section(of: nil) == nil)
    }

    @Test func theTextsReadLikeAndroids() {
        #expect(LibraryFilter.resultLine(shown: 27, total: 55, active: true) == "27 of 55 apps")
        #expect(LibraryFilter.resultLine(shown: 55, total: 55, active: false) == "All 55 apps")
        #expect(LibraryFilter.resultLine(shown: 1, total: 1, active: false) == "All 1 app")
        #expect(LibraryFilter.hintLabel(MetadataFilters()) == "Filter")
        #expect(LibraryFilter.hintLabel(MetadataFilters(genres: [5], hdr: [.hdr])) == "Filter \u{2022} 2 active")
        // Two genres, a theme and HDR
        #expect(LibraryFilter.hintLabel(MetadataFilters(genres: [5, 31], themes: [1], hdr: [.hdr])) == "Filter \u{2022} 4 active")
        #expect(LibraryFilter.showLabel(matching: 12) == "Show 12 apps")
        #expect(LibraryFilter.showLabel(matching: 1) == "Show 1 app")
        #expect(LibraryFilter.filteredNote(shown: 27, total: 55, pc: "PC") == "27 of 55 apps on PC")
        #expect(LibraryFilter.hdrLabel(.hdr) == "Native HDR")
        #expect(LibraryFilter.lengthLabel(.over60) == "60+ h")
        #expect(LibraryFilter.lengthLabel(.under10) == "<10 h")
    }

    @Test func theHintBarOffersYWhileTheLibraryHasSomethingToFilter() {
        var context = ShellHints.Context(screen: .home(hostID: "h"))
        #expect(ShellHints.hints(context, kind: .controller).map(\.button) == [.pad(.south), .pad(.menuLeft)])
        context.screenHints.filterLabel = "Filter"
        #expect(ShellHints.hints(context, kind: .controller).map(\.button) == [.pad(.south), .pad(.north), .pad(.menuLeft)])
        #expect(ShellHints.hints(context, kind: .controller).map(\.label)[1] == "Filter")
        context.screenHints.sheetOpen = true
        #expect(ShellHints.hints(context, kind: .controller).map(\.button) == [.pad(.south), .pad(.west), .pad(.north), .pad(.east)])
        #expect(ShellHints.hints(context, kind: .controller).map(\.label) == ["Select", "Reset", "Apply", "Close"])
        // A keyboard: Space toggles a chip, Return applies the choices
        #expect(ShellHints.hints(context, kind: .keyboard).map(\.button) == [.key(.space), .key(.letterO), .key(.returnKey), .key(.escape)])
        #expect(ShellHints.hints(context, kind: .keyboard).map(\.label) == ["Select", "Reset", "Apply", "Close"])
    }
}

@MainActor @Suite struct LibraryFiltersStoreTests {
    private func defaults() -> UserDefaults {
        let name = "library-filters-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func eachPCKeepsItsOwnFilterAcrossLaunches() {
        let suite = defaults()
        let store = LibraryFilters(defaults: suite)
        #expect(!store.filters(hostID: "a").active)
        store.set(MetadataFilters(genres: [5, 31], hdr: [.hdr]), hostID: "a")
        store.set(MetadataFilters(length: [.over60]), hostID: "b")
        #expect(store.filters(hostID: "a") == MetadataFilters(genres: [5, 31], hdr: [.hdr]))
        #expect(store.filters(hostID: "b") == MetadataFilters(length: [.over60]))
        let again = LibraryFilters(defaults: suite)
        #expect(again.filters(hostID: "a") == MetadataFilters(genres: [5, 31], hdr: [.hdr]))
        #expect(again.filters(hostID: "c") == MetadataFilters())
        // Resetting forgets the entry
        again.set(MetadataFilters(), hostID: "a")
        #expect(LibraryFilters(defaults: suite).filters(hostID: "a") == MetadataFilters())
        #expect(LibraryFilters(defaults: suite).filters(hostID: "b").length == [.over60])
    }
}

@MainActor @Suite struct BundledArtworkTests {
    @Test func theFourEntriesAreToldApartByUUIDOrName() {
        #expect(BundledArtwork.kind(HostApp(id: 1, title: " Desktop ")) == .desktop)
        #expect(BundledArtwork.kind(HostApp(id: 2, title: "REMOTE INPUT")) == .remoteInput)
        #expect(BundledArtwork.kind(HostApp(id: 3, title: "x", uuid: "9A1C5A25-58FE-40E0-B9AA-7D3F00000006")) == .remoteInput)
        #expect(BundledArtwork.kind(HostApp(id: 4, title: "x", uuid: "9a1c5a25-58fe-40e0-b9aa-7d3f00000005")) == .remoteMonitor)
        #expect(BundledArtwork.kind(HostApp(id: 5, title: "Steam BigPicture")) == .steamBigPicture)
        #expect(BundledArtwork.kind(HostApp(id: 6, title: "Hades")) == nil)
    }

    /// The files are Android's, byte for byte (docs/THIRD_PARTY.md has the digests).
    @Test func theBundledFilesAreThereAndAreTheOnesRecorded() throws {
        let expected: [String: String] = [
            "desktop/cover": "9c94f172ce3a81b3632ca8e965bbf408668b65a9ea3a0d09d93b737aa7e6c696",
            "desktop/wide": "fe6791e9b8390ee38efa0a0d078e8f25a4568527ddd3d026a40d5c417d828b8b",
            "desktop/hero": "bd73e5216a77c62c44aa8c89897d95ec4fcd2d17057cc0277eb9dd734ea12d24",
            "remote-input/cover": "8e08227fb3db35e8907199b05c9f2dbff01733926f4db1391bfae13deeb8186f",
            "remote-input/wide": "c62cb96c2f93523ef6b289ad68723d6ffd72795a2d01ccc3395642284b9f2a35",
            "remote-input/hero": "87f0a62c463dce6449014d0bf98dd63735bcff21ff476730a78a7ce031557203",
        ]
        for (name, digest) in expected {
            let parts = name.split(separator: "/").map(String.init)
            let kind = try #require(BundledArtwork.Kind(rawValue: parts[0]))
            let art = try #require(ArtKind(rawValue: parts[1]))
            let url = try #require(BundledArtwork.url(kind, art))
            let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            #expect(hash == digest, "\(name)")
        }
        for kind in BundledArtwork.Kind.allCases {
            for art in [ArtKind.cover, .wide, .hero] { #expect(BundledArtwork.url(kind, art) != nil, "\(kind) \(art)") }
            // The logo stays the rendered name
            #expect(BundledArtwork.url(kind, .logo) == nil)
        }
    }

    @Test func aBundledImageDecodesNoLargerThanAskedFor() async throws {
        let image = try #require(await BundledArtwork.image(.desktop, .cover, maxPixels: 200))
        #expect(max(image.width, image.height) <= 200)
        #expect(image.height > image.width)
    }
}

@Suite struct PlaceholderTitleTests {
    @Test func theTitleShrinksUntilItsLongestWordFitsAndNoFurtherThanTwoFifths() {
        #expect(PlaceholderTitle.factor(widest: 100, room: 300) == 1)
        #expect(abs(PlaceholderTitle.factor(widest: 400, room: 200) - (200 * 0.97 - 1) / 400) < 1e-9)
        #expect(PlaceholderTitle.factor(widest: 1000, room: 100) == 0.4)
        #expect(PlaceholderTitle.factor(widest: 0, room: 100) == 1)
        #expect(PlaceholderTitle.widestWord("a bb", size: 30) > 0)
    }
}

@MainActor @Suite struct LibraryFilterHintTests {
    @Test func aTappableHintIsOnlyTheFilterAndOnlyWhenTheLibraryOffersIt() {
        var context = ShellHints.Context(screen: .home(hostID: "h"))
        #expect(ShellHints.hints(context).allSatisfy { !$0.tappable })
        context.screenHints.filterLabel = "Filter"
        #expect(ShellHints.hints(context, kind: .controller).filter(\.tappable).map(\.button) == [.pad(.north)])
        // Without a controller the other hints go, the Filter pill stays for a finger and the pointer
        for kind in [InputKind.touch, .pointer] {
            #expect(ShellHints.hints(context, kind: kind).filter(\.tappable).map(\.label) == ["Filter"], "\(kind)")
            // The pill carries the filter symbol before its label, so it reads as a button
            #expect(ShellHints.hints(context, kind: kind).filter(\.tappable).map(\.icon) == [Symbols.filter], "\(kind)")
        }
        // The keyboard presses F instead: a key hint, no pill
        let keyboard = ShellHints.hints(context, kind: .keyboard)
        #expect(keyboard.allSatisfy { !$0.tappable })
        #expect(keyboard.first { $0.label == "Filter" }?.button == .key(.letterF))
    }
}
