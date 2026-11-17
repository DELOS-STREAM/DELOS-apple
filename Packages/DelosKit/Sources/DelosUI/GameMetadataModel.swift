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
        Task { await load(key: key, title: title) }
    }

    private func load(key: String, title: String) async {
        let cached = await store.state(for: title)
        if states[key] == nil { states[key] = cached }
        do {
            states[key] = try await store.lookup(title: title)
        } catch {
            asked.remove(key)
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
        var started = 0
        await withTaskGroup(of: Void.self) { group in
            while started < min(Self.libraryConcurrency, todo.count) {
                let (key, title) = todo[started]
                started += 1
                group.addTask { await self.load(key: key, title: title) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                guard started < todo.count else { continue }
                let (key, title) = todo[started]
                started += 1
                group.addTask { await self.load(key: key, title: title) }
            }
        }
        // What was not asked about because the screen went away is asked about next time
        for item in todo[started...] { asked.remove(item.key) }
    }

    /// How many games the library's refresh asks about at once.
    static let libraryConcurrency = 3

    /// A refresh, reset or match the user asked for. The state afterwards is the store's; a thrown error is the caller's.
    func perform(_ app: HostApp, _ operation: @Sendable (MetadataStore, String) async throws -> GameMetadataState) async throws -> GameMetadataState {
        let state = try await operation(store, app.title)
        states[Self.key(app.title)] = state
        asked.insert(Self.key(app.title))
        return state
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
