import DelosData
import DelosHost
import Foundation
import Observation
import SwiftUI

/// The library's view of ``MetadataStore``: what each game's information is right now, and the lookups that fill it
/// (`GameMetadataStore` of DELOS for Android). The service address is configuration; without one `enabled` is false,
/// nothing is looked up, no row, chip or menu entry shows and the library looks as it does without metadata.
@MainActor
@Observable
final class GameMetadataModel {
    @ObservationIgnored let store: MetadataStore
    let enabled: Bool
    /// The state of each game by its literal title key; games not asked for yet have none.
    private(set) var states: [String: GameMetadataState] = [:]
    /// Titles looked up in this session: a game is asked for once, the store decides from its cache and policy.
    @ObservationIgnored private var asked: Set<String> = []
    /// Games being looked up: how far the largest batch is (the library's refresh, or the one game a lookup or a choice is
    /// for), nil when none runs (`GameMetadataStore.progress`); the shell's progress pill shows it.
    private(set) var progress: ShellProgress?
    @ObservationIgnored private var batches: [ProgressBatch] = []
    /// The time the refresh policy is checked at, in milliseconds (the store's clock).
    @ObservationIgnored var now: @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    init(store: MetadataStore = MetadataStore()) {
        self.store = store
        enabled = store.available
    }

    static func key(_ title: String) -> String { MetadataPolicy.literalKey(title) }

    /// DELOS's own entries (Desktop, Remote Input, ...) have no metadata.
    static func isBuiltIn(_ app: HostApp) -> Bool { BundledArtwork.kind(app) != nil }

    /// Whether the game can have metadata at all (the Metadata menu entry shows for these only).
    func offers(_ app: HostApp) -> Bool { enabled && !Self.isBuiltIn(app) }

    func data(for app: HostApp) -> GameMetadata? { states[Self.key(app.title)]?.data }

    /// Reads the game's stored information, then lets the store refresh it when it is due (once per session).
    func ensure(_ app: HostApp) {
        guard offers(app) else { return }
        let key = Self.key(app.title)
        guard !key.isEmpty, asked.insert(key).inserted else { return }
        let title = app.title
        Task { await load(key: key, title: title, progress: .own) }
    }

    /// Whose progress a lookup counts in: a batch of its own when it refreshes, the library's batch, or none.
    private enum LoadProgress: Sendable {
        case own
        case batch(ProgressBatch)
        case none
    }

    private func load(key: String, title: String, progress: LoadProgress) async {
        let cached = await store.state(for: title)
        if states[key] == nil { states[key] = cached }
        let lookup = { [self] in
            do {
                states[key] = try await store.lookup(title: title)
            } catch {
                asked.remove(key)
            }
        }
        switch progress {
        case .own where MetadataPolicy.refreshDue(cached.data, now: now()):
            await withProgress(total: 1) { batch in
                await lookup()
                finish(batch)
            }
        case .batch(let batch):
            await lookup()
            finish(batch)
        case .own, .none:
            await lookup()
        }
    }

    /// The whole library's information (`ensureLibrary` of DELOS for Android): every stored record is published first, so
    /// the filter and its genre list are complete at once, then the ones that are due are refreshed, a few at a time.
    func ensureLibrary(_ apps: [HostApp]) async {
        let games = apps.filter(offers)
        for app in games {
            let key = Self.key(app.title)
            guard !key.isEmpty, states[key] == nil else { continue }
            let cached = await store.state(for: app.title)
            guard !Task.isCancelled else { return }
            if states[key] == nil { states[key] = cached }
        }
        var todo: [(key: String, title: String)] = []
        for app in games {
            let key = Self.key(app.title)
            if !key.isEmpty, asked.insert(key).inserted { todo.append((key, app.title)) }
        }
        // The games whose refresh is due count in the progress; the others only read their record
        let due = Set(todo.filter { MetadataPolicy.refreshDue(states[$0.key]?.data, now: now()) }.map(\.key))
        var started = 0
        await withProgress(total: due.count) { batch in
            await withTaskGroup(of: Void.self) { group in
                func start() {
                    let (key, title) = todo[started]
                    started += 1
                    let progress: LoadProgress = due.contains(key) ? .batch(batch) : .none
                    group.addTask { await self.load(key: key, title: title, progress: progress) }
                }
                while started < min(Self.libraryConcurrency, todo.count) { start() }
                while await group.next() != nil {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        break
                    }
                    if started < todo.count { start() }
                }
            }
        }
        // What was not asked about because the screen went away is asked about next time
        for item in todo[started...] { asked.remove(item.key) }
    }

    /// How many games the library's refresh asks about at once.
    static let libraryConcurrency = 3

    /// A refresh, reset or match the user asked for. The state afterwards is the store's; a thrown error is the caller's.
    func perform(_ app: HostApp, _ operation: @Sendable (MetadataStore, String) async throws -> GameMetadataState) async throws -> GameMetadataState {
        let state = try await withProgress(total: 1) { batch in
            let state = try await operation(store, app.title)
            finish(batch)
            return state
        }
        states[Self.key(app.title)] = state
        asked.insert(Self.key(app.title))
        return state
    }

    /// The IGDB matches for [term] (the Metadata menu's search), counted in the progress.
    func search(_ term: String) async throws -> [MetadataCandidate] {
        try await withProgress(total: 1) { batch in
            let found = try await store.search(term)
            finish(batch)
            return found
        }
    }

    // MARK: Progress

    @MainActor private final class ProgressBatch {
        var total: Int
        var done = 0
        init(total: Int) { self.total = total }
    }

    /// Runs [body] with a batch of [total] games in the progress; the batch leaves it when [body] ends, however it ends.
    private func withProgress<T>(total: Int, _ body: (ProgressBatch) async throws -> T) async rethrows -> T {
        let batch = ProgressBatch(total: total)
        batches.append(batch)
        publishProgress()
        defer {
            batches.removeAll { $0 === batch }
            publishProgress()
        }
        return try await body(batch)
    }

    private func finish(_ batch: ProgressBatch) {
        batch.done += 1
        publishProgress()
    }

    /// The largest batch: a single lookup does not replace the library's.
    private func publishProgress() {
        let batch = batches.max { $0.total < $1.total }
        let next = batch.flatMap { $0.total == 0 ? nil : ShellProgress(done: $0.done, total: $0.total) }
        if next != progress { progress = next }
    }

    /// Fills a state directly (screenshots only).
    func seed(_ title: String, _ state: GameMetadataState) {
        states[Self.key(title)] = state
        asked.insert(Self.key(title))
    }
}

extension EnvironmentValues {
    /// "Match the app's colors" is on: the genre and theme pills take the game's colors.
    @Entry var matchGameColors = false
}
