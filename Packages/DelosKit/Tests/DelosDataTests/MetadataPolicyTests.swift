import Foundation
import Synchronization
import Testing
@testable import DelosData

// Matching/cache fixtures: Android MetadataPolicyTest.kt and GameMetadataStoreTest.kt.
struct MetadataPolicyTests {
    @Test func proxyConfigurationSanitizesTermsAndEncodesQueriesWithoutInsecureFallback() throws {
        #expect(!MetadataConfiguration().enabled)
        #expect(!MetadataConfiguration(baseURL: "http://worker.example").enabled)
        #expect(MetadataConfiguration(baseURL: "http://127.0.0.1:8787/base").enabled)
        let url = try #require(MetadataProxy.url(baseURL: "https://worker.example/base", path: "v1/igdb/games",
                                                parameters: [URLQueryItem(name: "search", value: "Game & II")]))
        #expect(url.path == "/base/v1/igdb/games")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "Game & II")
        #expect(MetadataProxy.term(" Game\n\u{2028} Two ") == "Game Two")
        #expect(MetadataProxy.term(String(repeating: "🌙", count: 130)).unicodeScalars.count == 128)
        #expect(MetadataProxy.title("Game#fragment") == nil)
        #expect(MetadataProxy.title(String(repeating: "a", count: 201)) == nil)
    }
    @Test func editionsArticlesAccentsAndNumeralsMatchButSequelsDoNot() {
        let pairs = [
            ("The Witcher 3: Wild Hunt - Game of the Year Edition", "The Witcher 3: Wild Hunt"),
            ("Final Fantasy VII", "Final Fantasy 7"), ("Tom & Jerry", "Tom and Jerry"),
            ("Hades (Steam)", "Hades"), ("Dishonored: Director's Cut", "Dishonored"),
            ("Half-Life 2", "Half Life II"), ("Pokémon Arena", "Pokemon Arena"),
        ]
        for (host, name) in pairs {
            #expect(MetadataPolicy.chooseMatch(hostName: host, candidates: [MetadataCandidate(id: 1, name: name)])?.id == 1)
        }
        #expect(MetadataPolicy.chooseMatch(hostName: "Game 2", candidates: [MetadataCandidate(id: 1, name: "Game 3")]) == nil)
        #expect(MetadataPolicy.chooseMatch(hostName: "(Steam)", candidates: [MetadataCandidate(id: 1, name: "Game")]) == nil)
        #expect(MetadataPolicy.searchTerm("LEGO® Batman™: Legacy of the Dark Knight") == "LEGO Batman: Legacy of the Dark Knight")
    }
    @Test func literalYearSteamPlatformRecencyAndRatingsDisambiguate() {
        let old = MetadataCandidate(id: 1, name: "Doom", year: 1993, platformIDs: [13])
        let recent = MetadataCandidate(id: 2, name: "DOOM", year: 2016, steamAppIDs: [379720], platformIDs: [6])
        #expect(MetadataPolicy.chooseMatch(hostName: "Doom", candidates: [old, recent])?.id == 2)
        #expect(MetadataPolicy.chooseMatch(hostName: "Doom (1993)", candidates: [old, recent])?.id == 1)
        #expect(MetadataPolicy.chooseMatch(hostName: "Game Remastered", candidates: [MetadataCandidate(id: 1, name: "Game"), MetadataCandidate(id: 2, name: "Game Remastered")])?.id == 2)
        let peak = MetadataCandidate(id: 349524, name: "Peak", year: 2025, steamAppIDs: [3527290], platformIDs: [6], ratingCount: 154)
        let other = MetadataCandidate(id: 360757, name: "Peak", year: 2025, steamAppIDs: [3506430], platformIDs: [6], ratingCount: 50)
        #expect(MetadataPolicy.chooseMatch(hostName: "PEAK", candidates: [other, peak])?.id == peak.id)
        let comparable = MetadataCandidate(id: 3, name: "Peak", year: 2025, steamAppIDs: [10], platformIDs: [6], ratingCount: 100)
        #expect(MetadataPolicy.chooseMatch(hostName: "PEAK", candidates: [peak, comparable]) == nil)
        let same = MetadataCandidate(id: 4, name: "Peak", year: 2025, steamAppIDs: [11], platformIDs: [6], ratingCount: 154)
        #expect(MetadataPolicy.chooseMatch(hostName: "PEAK", candidates: [peak, same]) == nil)
    }
    @Test func subtitleFallbackRequiresOnePCIdentityAndNeverOverridesExact() {
        let pc = MetadataCandidate(id: 1, name: "Planet of Lana II: Children of the Leaf", platformIDs: [6])
        #expect(MetadataPolicy.chooseMatch(hostName: "Planet of Lana II", candidates: [pc])?.id == 1)
        #expect(MetadataPolicy.chooseMatch(hostName: "Game", candidates: [MetadataCandidate(id: 1, name: "Game: Console Edition", platformIDs: [48])]) == nil)
        let one = MetadataCandidate(id: 2, name: "Game: One", platformIDs: [6])
        let two = MetadataCandidate(id: 3, name: "Game - Two", platformIDs: [6])
        #expect(MetadataPolicy.chooseMatch(hostName: "Game", candidates: [one, two]) == nil)
        #expect(MetadataPolicy.chooseMatch(hostName: "Game", candidates: [one, MetadataCandidate(id: 4, name: "Game")])?.id == 4)
    }
    @Test func refreshWindowsAndIndependentBackoffHandleClockChanges() {
        let now: Int64 = 10_000_000_000_000
        let game = MetadataCandidate(id: 1, name: "Game")
        #expect(!MetadataPolicy.refreshDue(GameMetadata(candidate: game, updatedAt: now - 86_400_000), now: now))
        #expect(MetadataPolicy.refreshDue(GameMetadata(updatedAt: now - 86_400_000), now: now))
        #expect(!MetadataPolicy.refreshDue(GameMetadata(updatedAt: now - 300_000), now: now))
        #expect(MetadataPolicy.refreshDue(GameMetadata(candidate: game, updatedAt: now + 1), now: now))
        #expect(!MetadataPolicy.refreshDue(GameMetadata(candidate: game, pcgwFailedAt: now - 60_000, hltbFailedAt: now - 60_000), now: now))
        #expect(MetadataPolicy.refreshDue(GameMetadata(candidate: game, pcgwFailedAt: now - 60_000, hltbFailedAt: now - MetadataPolicy.failureBackoff), now: now))
        #expect(!MetadataPolicy.refreshDue(GameMetadata(igdbFailedAt: now), now: now))
        #expect(MetadataPolicy.refreshDue(GameMetadata(candidate: game, steamFailedAt: now + 1), now: now))
    }
    @Test func optionalCacheDamageDoesNotDiscardValidIdentity() throws {
        let data = Data(#"{"candidate":{"id":1,"name":"Game","themes":[{"id":17,"name":"Fantasy"},{"id":3},null]},"hdr":{"page":"Game"},"completion":{"id":1,"seconds":3600},"steamTags":["Horror",null,"Sci-fi"]}"#.utf8)
        let parsed = try JSONDecoder().decode(GameMetadata.self, from: data)
        #expect(parsed.candidate?.themes == [GameGenre(id: 17, name: "Fantasy")])
        #expect(parsed.candidate?.steamAppIDs == [])
        #expect(parsed.hdr == HDREvidence(page: "Game"))
        #expect(parsed.completion == nil)
        #expect(parsed.steamTags == ["Horror", "Sci-fi"])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(GameMetadata.self, from: Data(#"{"candidate":{"id":1}}"#.utf8)) }
    }
    @Test func filtersPreserveUnknownAndDurationBoundaries() {
        let time = CompletionTime(id: 1, name: "Game", seconds: 36_000, url: "https://example.invalid/game/1")
        let data = GameMetadata(candidate: MetadataCandidate(id: 1, name: "Game", genres: [GameGenre(id: 12, name: "RPG")]), hdr: HDREvidence(support: .hdr), completion: time)
        #expect(!MetadataFilters(length: .under10).matches(data))
        #expect(MetadataFilters(genreID: 12, hdr: .hdr, length: .from10To30).matches(data))
        #expect(!MetadataFilters(genreID: 7).matches(data))
        #expect(MetadataFilters(hdr: .unknown, length: .unknown).matches(nil))
        #expect(!MetadataFilters(hdr: .hdr).matches(data, builtIn: true))
    }
    @Test func concurrentPacerReservationsAreDistinctWithoutWallClockSleeps() async throws {
        let base = ContinuousClock().now
        let deadlines = Mutex<[Duration]>([])
        let pacer = RequestPacer(intervalMilliseconds: 40, now: { base }, sleep: { instant in
            deadlines.withLock { $0.append(base.duration(to: instant)) }
            await Task.yield()
        })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { try await pacer.wait() } }
            try await group.waitForAll()
        }
        #expect(deadlines.withLock { $0.sorted() } == [.milliseconds(40), .milliseconds(80), .milliseconds(120)])
        let cancelled = RequestPacer(intervalMilliseconds: 10, now: { base }, sleep: { _ in throw CancellationError() })
        try await cancelled.wait()
        await #expect(throws: CancellationError.self) { try await cancelled.wait() }
    }
}
