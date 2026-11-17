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

    /// DELOS's own entries (Remote Input and Remote Monitor by their UUID, the others by name) have no metadata.
    static func isBuiltIn(_ app: HostApp) -> Bool {
        let uuid = app.uuid?.lowercased()
        if uuid == "9a1c5a25-58fe-40e0-b9aa-7d3f00000006" || uuid == "9a1c5a25-58fe-40e0-b9aa-7d3f00000005" { return true }
        return ["desktop", "remote input", "remote monitor", "steam big picture", "steam bigpicture"]
            .contains(app.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Whether the game can have metadata at all (the Metadata menu entry shows for these only).
    func offers(_ app: HostApp) -> Bool { enabled && !Self.isBuiltIn(app) }

    func data(for app: HostApp) -> GameMetadata? { states[Self.key(app.title)]?.data }

    /// Reads the game's stored information, then lets the store refresh it when it is due (once per session).
    func ensure(_ app: HostApp) {
        guard offers(app) else { return }
        let key = Self.key(app.title)
        guard !key.isEmpty, asked.insert(key).inserted else { return }
        let title = app.title
        Task {
            let cached = await store.state(for: title)
            if states[key] == nil { states[key] = cached }
            do {
                states[key] = try await store.lookup(title: title)
            } catch {
                asked.remove(key)
            }
        }
    }

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
