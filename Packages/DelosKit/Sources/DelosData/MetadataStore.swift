import Foundation

/// Title identities belong to the host, while provider identities and manual choices belong to this store.
/// No host refresh, artwork fetch or UI work is started by constructing it.
public actor MetadataStore {
    private struct Record: Codable { let schema: Int; let data: GameMetadata }
    private struct Pending { let id: UUID; let task: Task<GameMetadataState, Error> }
    private let providers: any MetadataProviders
    private let cache: DiskCache
    private let now: @Sendable () -> Int64
    private let network = MetadataRequestGate()
    private var states: [String: GameMetadataState] = [:]
    private var pending: [String: Pending] = [:]

    public init(providers: any MetadataProviders = HTTPMetadataProviders(), cache: DiskCache? = nil,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.providers = providers
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.cache = cache ?? DiskCache(directory: support.appendingPathComponent("game-metadata", isDirectory: true),
                                        budget: 32 * 1024 * 1024, maxEntryBytes: 1024 * 1024)
        self.now = now
    }

    /// Whether a metadata service is configured; without one every lookup answers "unavailable" and nothing is requested.
    public nonisolated var available: Bool { providers.available }

    /// Returns cached state without starting a network request. Call again after a completed operation for its state.
    public func state(for title: String) async -> GameMetadataState {
        let key = Self.key(title)
        if let state = states[key] { return state }
        let bytes = await cache.data(for: key)
        if let state = states[key] { return state }
        let record = bytes.flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        let data = record?.schema == 6 ? record?.data : nil
        let state = GameMetadataState(data: data, resolved: data != nil, error: Self.problem(data))
        states[key] = state
        return state
    }

    /// Concurrent lookups for the same title share one operation. Cancellation cancels that shared operation.
    @discardableResult
    public func lookup(title: String, force: Bool = false, builtIn: Bool = false) async throws -> GameMetadataState {
        if builtIn || Self.isBuiltIn(title) { return GameMetadataState(resolved: true) }
        guard !Self.key(title).isEmpty else { return GameMetadataState(resolved: true) }
        return try await operation(title: title, coalesce: true) { try await self.refresh(title: title, force: force) }
    }

    public func search(_ query: String) async throws -> [MetadataCandidate] {
        guard providers.available else { throw MetadataError.unavailable }
        return try await network.withPermit { try await self.providers.search(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Persist the chosen identity before secondary providers run; evidence from a different game is never carried over.
    @discardableResult
    public func select(title: String, candidate: MetadataCandidate) async throws -> GameMetadataState {
        guard !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MetadataError.invalidRequest }
        return try await operation(title: title, coalesce: false) {
            guard self.providers.available else { return await self.unavailable(title: title) }
            return try await self.selectCandidate(title: title, candidate: candidate)
        }
    }

    @discardableResult
    public func reset(title: String) async throws -> GameMetadataState {
        try await operation(title: title, coalesce: false) {
            await self.clear(title: title)
            return try await self.refresh(title: title, force: true)
        }
    }

    private static func key(_ title: String) -> String { MetadataPolicy.literalKey(title) }
    private static func isBuiltIn(_ title: String) -> Bool {
        ["desktop", "remoteinput", "remotemonitor", "steambigpicture"].contains(key(title))
    }
    private func unavailable(title: String) async -> GameMetadataState {
        var state = await state(for: title)
        state.loading = false; state.resolved = true; state.error = .unavailable
        states[Self.key(title)] = state
        return state
    }
    private func clear(title: String) async {
        await cache.remove(Self.key(title))
        states[Self.key(title)] = GameMetadataState()
    }
    private func operation(title: String, coalesce: Bool,
                           body: @escaping @Sendable () async throws -> GameMetadataState) async throws -> GameMetadataState {
        let key = Self.key(title)
        if coalesce, let old = pending[key] { return try await Self.value(old.task) }
        let old = pending[key]
        let id = UUID()
        let task = Task {
            if let old { _ = try? await old.task.value }
            try Task.checkCancellation()
            return try await body()
        }
        pending[key] = Pending(id: id, task: task)
        defer { if pending[key]?.id == id { pending[key] = nil } }
        return try await Self.value(task)
    }
    private nonisolated static func value(_ task: Task<GameMetadataState, Error>) async throws -> GameMetadataState {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let state = try await task.value
            try Task.checkCancellation()
            return state
        } onCancel: { task.cancel() }
    }

    private func refresh(title: String, force: Bool) async throws -> GameMetadataState {
        let initial = await state(for: title)
        guard providers.available else { return await unavailable(title: title) }
        if !force && !MetadataPolicy.refreshDue(initial.data, now: now()) { return initial }
        let key = Self.key(title)
        states[key] = GameMetadataState(data: initial.data, loading: true, resolved: initial.resolved, error: initial.error)
        defer { states[key]?.loading = false }
        do {
            return try await network.withPermit {
                let candidate: MetadataCandidate?
                if let manual = initial.data, manual.manual, let selected = manual.candidate {
                    guard let refreshed = try await self.providers.game(selected.id) else { throw MetadataError.malformedResponse }
                    candidate = refreshed
                } else {
                    candidate = MetadataPolicy.chooseMatch(hostName: title, candidates: try await self.providers.search(title))
                }
                try Task.checkCancellation()
                if let candidate {
                    return try await self.resolve(title: title, candidate: candidate, manual: initial.data?.manual ?? false,
                                                  previous: initial.data, force: force)
                }
                return try await self.save(GameMetadata(updatedAt: self.now()), title: title)
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            var failed = initial.data ?? GameMetadata()
            failed.updatedAt = 0; failed.igdbFailedAt = now()
            // A failed disk write must not defeat the in-memory retry window either.
            try? await persist(failed, title: title)
            let result = GameMetadataState(data: failed, resolved: true, error: .updateFailed)
            states[key] = result
            return result
        }
    }

    private func selectCandidate(title: String, candidate: MetadataCandidate) async throws -> GameMetadataState {
        let key = Self.key(title)
        let selected = GameMetadata(candidate: candidate, manual: true)
        _ = try await save(selected, title: title)
        states[key]?.loading = true
        defer { states[key]?.loading = false }
        return try await network.withPermit {
            try await self.resolve(title: title, candidate: candidate, manual: true, previous: nil, force: true)
        }
    }

    private func resolve(title: String, candidate: MetadataCandidate, manual: Bool,
                         previous: GameMetadata?, force: Bool) async throws -> GameMetadataState {
        var result = previous.flatMap { $0.candidate?.id == candidate.id ? $0 : nil } ?? GameMetadata()
        result.candidate = candidate; result.manual = manual; result.igdbFailedAt = 0
        let started = now()
        if force || !MetadataPolicy.isBackedOff(result.pcgwFailedAt, now: started) {
            do {
                result.hdr = try await providers.hdr(steamAppIDs: candidate.steamAppIDs, name: candidate.name)
                result.pcgwFailedAt = 0
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                result.pcgwFailedAt = now()
            }
        }
        if force || !MetadataPolicy.isBackedOff(result.hltbFailedAt, now: started) {
            do {
                result.completion = try await providers.completion(steamAppIDs: candidate.steamAppIDs, name: candidate.name)
                result.hltbFailedAt = 0
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                result.hltbFailedAt = now()
            }
        }
        if candidate.steamAppIDs.isEmpty { result.steamTags = []; result.steamFailedAt = 0 }
        else if force || !MetadataPolicy.isBackedOff(result.steamFailedAt, now: started) {
            do { result.steamTags = try await providers.steamTags(candidate.steamAppIDs); result.steamFailedAt = 0 }
            catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                result.steamFailedAt = now()
            }
        }
        try Task.checkCancellation()
        result.updatedAt = [result.pcgwFailedAt, result.hltbFailedAt, result.steamFailedAt].contains(where: { $0 > 0 }) ? 0 : now()
        return try await save(result, title: title)
    }
    private func persist(_ data: GameMetadata, title: String) async throws {
        try await cache.store(JSONEncoder().encode(Record(schema: 6, data: data)), for: Self.key(title))
    }
    private func save(_ data: GameMetadata, title: String) async throws -> GameMetadataState {
        try await persist(data, title: title)
        let state = GameMetadataState(data: data, resolved: true, error: Self.problem(data))
        states[Self.key(title)] = state
        return state
    }
    private static func problem(_ data: GameMetadata?) -> MetadataProblem? {
        guard let data else { return nil }
        if data.igdbFailedAt > 0 { return .updateFailed }
        if data.pcgwFailedAt > 0 || data.hltbFailedAt > 0 { return .partial }
        return nil // Android deliberately lets missing Steam tags fall back to genres without a warning.
    }
}

/// At most two title resolutions at once, matching Android's network gate. Waiters are cancellation-aware.
private actor MetadataRequestGate {
    private var permits = 2
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await body()
    }
    private func acquire() async throws {
        try Task.checkCancellation()
        if permits > 0 { permits -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { permits += 1 }
        else { waiters.removeFirst().1.resume() }
    }
}
