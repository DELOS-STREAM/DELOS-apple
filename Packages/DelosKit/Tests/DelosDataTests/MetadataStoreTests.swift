import Foundation
import Synchronization
import Testing
@testable import DelosData

// State and failure fixtures port Android GameMetadataStoreTest.kt. No real services or host connections.
private final class MetadataTestClock: Sendable {
    private let time = Mutex<Int64>(10_000_000_000)
    var now: Int64 { time.withLock { $0 } }
    func advance(_ milliseconds: Int64) { time.withLock { $0 += milliseconds } }
}
private enum MetadataTestCall: Hashable, Sendable { case search, game, hdr, completion, steam }
private actor FakeMetadataProviders: MetadataProviders {
    nonisolated let available: Bool
    private var candidates: [MetadataCandidate]
    private var failures: Set<MetadataTestCall> = []
    private var counts: [MetadataTestCall: Int] = [:]
    private var block = false
    private var searchWaiters: [CheckedContinuation<Void, Error>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    init(available: Bool = true, candidates: [MetadataCandidate] = [MetadataCandidate(id: 1, name: "Game", steamAppIDs: [100], genres: [GameGenre(id: 12, name: "RPG")], platformIDs: [6])]) {
        self.available = available; self.candidates = candidates
    }
    func configure(candidates: [MetadataCandidate]? = nil, failures: Set<MetadataTestCall> = [], block: Bool = false) {
        if let candidates { self.candidates = candidates }
        self.failures = failures; self.block = block
    }
    func count(_ call: MetadataTestCall) -> Int { counts[call, default: 0] }
    private func call(_ call: MetadataTestCall) throws {
        counts[call, default: 0] += 1
        if failures.contains(call) { throw MetadataError.httpStatus(503) }
    }
    func search(_ title: String) async throws -> [MetadataCandidate] {
        try call(.search)
        let ready = observers; observers = []; ready.forEach { $0.resume() }
        if block {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { searchWaiters.append(continuation) }
                }
            } onCancel: { Task { await self.cancelSearch() } }
        }
        try Task.checkCancellation()
        return candidates
    }
    func waitForSearch() async {
        if counts[.search, default: 0] > 0 { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func releaseSearch() {
        block = false
        let ready = searchWaiters; searchWaiters = []; ready.forEach { $0.resume() }
    }
    private func cancelSearch() {
        let ready = searchWaiters; searchWaiters = []
        ready.forEach { $0.resume(throwing: CancellationError()) }
    }
    func game(_ id: Int64) async throws -> MetadataCandidate? {
        try call(.game); return candidates.first { $0.id == id }
    }
    func hdr(steamAppIDs: [Int64], name: String) async throws -> HDREvidence {
        try call(.hdr); return HDREvidence(support: .hdr, page: name, notes: "Native HDR")
    }
    func completion(steamAppIDs: [Int64], name: String) async throws -> CompletionTime? {
        try call(.completion)
        return CompletionTime(id: 5, name: name, seconds: 72000, url: "https://example.invalid/game/5")
    }
    func steamTags(_ steamAppIDs: [Int64]) async throws -> [String] { try call(.steam); return ["Adventure", "Fantasy"] }
}
private actor DisabledMetadataTransport: MetadataTransport {
    private(set) var calls = 0
    func response(for request: URLRequest) async throws -> MetadataHTTPResponse {
        calls += 1
        return MetadataHTTPResponse(data: Data(), status: 503)
    }
}
private func metadataCache() -> (URL, DiskCache) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-test-" + UUID().uuidString)
    return (directory, DiskCache(directory: directory, budget: 1024 * 1024, maxEntryBytes: 64 * 1024))
}

struct MetadataStoreTests {
    @Test func lookupPersistsEvidenceAndReloadsWithoutRequests() async throws {
        let (directory, cache) = metadataCache(); defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MetadataTestClock(); let providers = FakeMetadataProviders()
        let store = MetadataStore(providers: providers, cache: cache, now: { clock.now })
        let result = try await store.lookup(title: "Game")
        #expect(result.data?.candidate?.id == 1)
        #expect(result.data?.hdr.support == .hdr)
        #expect(result.data?.completion?.seconds == 72000)
        #expect(result.data?.steamTags == ["Adventure", "Fantasy"])
        #expect(result.data?.updatedAt == clock.now)
        let offline = FakeMetadataProviders()
        let reloaded = MetadataStore(providers: offline, cache: cache, now: { clock.now })
        #expect(try await reloaded.lookup(title: "GAME") == result)
        #expect(await offline.count(.search) == 0)
        #expect(await offline.count(.hdr) == 0)
    }
    @Test func emptyConfigurationDisablesAllProvidersIncludingDirectHLTB() async throws {
        let transport = DisabledMetadataTransport()
        let providers = HTTPMetadataProviders(configuration: MetadataConfiguration(), http: MetadataHTTP(transport: transport))
        await #expect(throws: MetadataError.unavailable) { try await providers.search("Game") }
        await #expect(throws: MetadataError.unavailable) { try await providers.completion(steamAppIDs: [100], name: "Game") }
        let (directory, cache) = metadataCache(); defer { try? FileManager.default.removeItem(at: directory) }
        let state = try await MetadataStore(providers: providers, cache: cache).lookup(title: "Game")
        #expect(state.error == .unavailable)
        #expect(state.resolved && !state.loading)
        #expect(await transport.calls == 0)
    }
    @Test func disabledStoreRetainsCachedEvidenceAndBuiltInsNeverFetch() async throws {
        let (directory, cache) = metadataCache(); defer { try? FileManager.default.removeItem(at: directory) }
        let providers = FakeMetadataProviders()
        let result = try await MetadataStore(providers: providers, cache: cache).lookup(title: "Game")
        let disabled = FakeMetadataProviders(available: false)
        let store = MetadataStore(providers: disabled, cache: cache)
        let cached = try await store.lookup(title: "Game")
        #expect(cached.data == result.data)
        #expect(cached.error == .unavailable)
        for title in ["Desktop", "Remote Input", "Remote Monitor", " steam bigpicture "] {
            #expect(try await store.lookup(title: title) == GameMetadataState(resolved: true))
        }
        #expect(try await store.lookup(title: "Renamed built-in", builtIn: true).data == nil)
        #expect(await disabled.count(.search) == 0)
    }
    @Test func failuresPersistBackoffAndNeverBecomeSuccessfulAbsence() async throws {
        let (directory, cache) = metadataCache(); defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MetadataTestClock(); let providers = FakeMetadataProviders()
        await providers.configure(failures: [.search])
        let first = MetadataStore(providers: providers, cache: cache, now: { clock.now })
        let failed = try await first.lookup(title: "Game")
        #expect(failed.error == .updateFailed)
        #expect(failed.data?.igdbFailedAt == clock.now)
        #expect(failed.data?.updatedAt == 0)
        let next = MetadataStore(providers: providers, cache: cache, now: { clock.now })
        _ = try await next.lookup(title: "Game")
        #expect(await providers.count(.search) == 1)
        await providers.configure()
        _ = try await next.lookup(title: "Game", force: true)
        #expect(await providers.count(.search) == 2)
        #expect(await next.state(for: "Game").data?.candidate?.id == 1)
    }
    @Test func secondaryFailureKeepsSameGameEvidenceAndRetriesAfterThirtyMinutes() async throws {
        let (directory, cache) = metadataCache(); defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MetadataTestClock(); let providers = FakeMetadataProviders()
        let store = MetadataStore(providers: providers, cache: cache, now: { clock.now })
        let good = try await store.lookup(title: "Game")
        await providers.configure(failures: [.hdr, .steam])
        let partial = try await store.lookup(title: "Game", force: true)
        #expect(partial.error == .partial)
        #expect(partial.data?.hdr == good.data?.hdr)
        #expect(partial.data?.steamTags == good.data?.steamTags)
        #expect(partial.data?.pcgwFailedAt == clock.now)
        #expect(partial.data?.steamFailedAt == clock.now)
        #expect(partial.data?.updatedAt == 0)
        _ = try await store.lookup(title: "Game")
        #expect(await providers.count(.search) == 2)
        clock.advance(MetadataPolicy.failureBackoff)
        await providers.configure()
        let recovered = try await store.lookup(title: "Game")
        #expect(recovered.error == nil)
        #expect(recovered.data?.pcgwFailedAt == 0)
        #expect(recovered.data?.steamFailedAt == 0)
        #expect(await providers.count(.hdr) == 3)
    }
    @Test func successfulAbsenceUsesSixHourWindowWithoutSecondaryCalls() async throws {
        let (directory, cache) = metadataCache(); defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MetadataTestClock(); let providers = FakeMetadataProviders(candidates: [])
        let store = MetadataStore(providers: providers, cache: cache, now: { clock.now })
        let absent = try await store.lookup(title: "Unknown")
        #expect(absent.data?.candidate == nil && absent.data?.updatedAt == clock.now)
        #expect(absent.error == nil)
        clock.advance(MetadataPolicy.absentMaximumAge - 1)
        _ = try await store.lookup(title: "Unknown")
        #expect(await providers.count(.search) == 1)
        clock.advance(1)
        _ = try await store.lookup(title: "Unknown")
        #expect(await providers.count(.search) == 2)
        #expect(await providers.count(.hdr) == 0)
    }
    @Test func manualSelectionNeverCarriesAnotherGamesEvidenceAndRefreshesByID() async throws {
        let (directory, cache) = metadataCache(); defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MetadataTestClock(); let providers = FakeMetadataProviders()
        let store = MetadataStore(providers: providers, cache: cache, now: { clock.now })
        _ = try await store.lookup(title: "Game")
        let selected = MetadataCandidate(id: 2, name: "Different Game")
        await providers.configure(candidates: [selected], failures: [.hdr, .completion])
        let changed = try await store.select(title: "Game", candidate: selected)
        #expect(changed.data?.candidate?.id == 2 && changed.data?.manual == true)
        #expect(changed.data?.hdr.support == .unknown)
        #expect(changed.data?.completion == nil)
        #expect(changed.data?.steamTags == [])
        let reloaded = MetadataStore(providers: providers, cache: cache, now: { clock.now })
        #expect(await reloaded.state(for: "Game").data?.manual == true)
        await providers.configure(candidates: [selected])
        _ = try await reloaded.lookup(title: "Game", force: true)
        #expect(await providers.count(.game) == 1)
        #expect(await providers.count(.search) == 1)
        _ = try await reloaded.reset(title: "Game")
        #expect(await providers.count(.search) == 2)
        #expect(await reloaded.state(for: "Game").data?.manual == false)
    }
    @Test func obsoleteAndMalformedCacheRecordsAreIgnored() async throws {
        let (directory, cache) = metadataCache(); defer { try? FileManager.default.removeItem(at: directory) }
        for record in [#"{"schema":5,"data":{"candidate":{"id":99,"name":"Old"},"updatedAt":10000000000}}"#,
                       #"{"schema":6,"data":{"candidate":{"id":99}}}"#] {
            try await cache.store(Data(record.utf8), for: "game")
            let providers = FakeMetadataProviders()
            let store = MetadataStore(providers: providers, cache: cache)
            #expect(await store.state(for: "Game").data == nil)
            #expect(try await store.lookup(title: "Game").data?.candidate?.id == 1)
            #expect(await providers.count(.search) == 1)
        }
    }
    @Test func cancellationClearsLoadingWithoutRecordingProviderFailure() async throws {
        let (directory, cache) = metadataCache(); defer { try? FileManager.default.removeItem(at: directory) }
        let providers = FakeMetadataProviders(); await providers.configure(block: true)
        let store = MetadataStore(providers: providers, cache: cache)
        let task = Task { try await store.lookup(title: "Game") }
        await providers.waitForSearch()
        #expect(await store.state(for: "Game").loading)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let cancelled = await store.state(for: "Game")
        #expect(!cancelled.loading)
        #expect(cancelled.data == nil && cancelled.error == nil)
        await providers.releaseSearch()
        #expect(try await store.lookup(title: "Game").data?.candidate?.id == 1)
    }
    @Test func concurrentLookupsShareOneResolution() async throws {
        let (directory, cache) = metadataCache(); defer { try? FileManager.default.removeItem(at: directory) }
        let providers = FakeMetadataProviders(); await providers.configure(block: true)
        let store = MetadataStore(providers: providers, cache: cache)
        let first = Task { try await store.lookup(title: "Game") }
        await providers.waitForSearch()
        let second = Task { try await store.lookup(title: "GAME") }
        await providers.releaseSearch()
        let result = try await first.value
        #expect(try await second.value == result)
        #expect(await providers.count(.search) == 1)
        #expect(await providers.count(.completion) == 1)
    }
    @Test func rateLimitIsAnErrorWithoutImmediateNetworkRetry() async throws {
        let transport = DisabledMetadataTransport()
        let http = MetadataHTTP(transport: transport)
        let request = URLRequest(url: URL(string: "https://example.invalid/v1/igdb/games?search=Game")!)
        await #expect(throws: MetadataError.httpStatus(503)) { try await http.send(request) }
        #expect(await transport.calls == 1)
    }
}
