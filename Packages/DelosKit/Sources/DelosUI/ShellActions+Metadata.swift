import DelosData
import DelosHost
import Foundation

/// The Metadata entry of a game's menu (`openMetadataMenu` and `searchMetadata` of DELOS for Android): search IGDB and
/// change the match, refresh, reset the match. Each result is reported in a toast.
extension ShellActions {
    /// How many matches a page of the list shows.
    static let matchesPerPage = 6

    static func problemText(_ problem: MetadataProblem) -> String {
        switch problem {
        case .unavailable: L("metadata_error_unavailable")
        case .updateFailed: L("metadata_error_update")
        case .partial: L("metadata_error_partial")
        }
    }

    func openMetadataMenu(hostID: String, app: HostApp) {
        guard metadata.offers(app) else { return }
        let menu = ContextMenu(title: L("metadata_menu_title", app.title), items: [
            MenuItem(icon: Symbols.search, label: L("metadata_menu_search")) { [self] in
                searchMetadata(app: app, term: app.title, anchor: layers.menuAnchor)
            },
            MenuItem(icon: Symbols.refresh, label: L("metadata_menu_refresh")) { [self] in
                perform(app, success: "metadata_refreshed_toast") { try await $0.lookup(title: $1, force: true) }
            },
            MenuItem(icon: Symbols.reset, label: L("metadata_menu_reset")) { [self] in
                perform(app, success: "metadata_reset_toast") { try await $0.reset(title: $1) }
            },
        ])
        layers.openContextMenu(menu, anchor: layers.menuAnchor)
    }

    /// Runs a refresh or reset and says how it went: a finished one that found no IGDB match is not a success.
    private func perform(_ app: HostApp, success: String,
                         _ operation: @escaping @Sendable (MetadataStore, String) async throws -> GameMetadataState) {
        Task {
            do {
                let state = try await metadata.perform(app, operation)
                if state.error == nil, state.data?.candidate == nil {
                    toasts.show(L("metadata_no_match_toast"), icon: Symbols.search)
                } else if let error = state.error {
                    layers.feedback?.play(.error)
                    toasts.show(Self.problemText(error), icon: Symbols.error)
                } else {
                    toasts.show(L(success), icon: Symbols.checkCircle)
                }
            } catch is CancellationError {
            } catch {
                layers.feedback?.play(.error)
                toasts.show(L("metadata_update_failed_toast"), icon: Symbols.error)
            }
        }
    }

    private func searchMetadata(app: HostApp, term: String, anchor: CGRect?) {
        Task {
            toasts.show(L("metadata_searching_toast", term), icon: Symbols.search)
            let found: [MetadataCandidate]
            do {
                found = try await metadata.store.search(term)
            } catch is CancellationError {
                return
            } catch {
                layers.feedback?.play(.error)
                toasts.show(L("metadata_search_unavailable_toast"), icon: Symbols.error)
                return
            }
            showMatches(app: app, term: term, found: found, page: 0, anchor: anchor)
        }
    }

    private func showMatches(app: HostApp, term: String, found: [MetadataCandidate], page: Int, anchor: CGRect?) {
        let per = Self.matchesPerPage
        var items = found.dropFirst(page * per).prefix(per).map { candidate in
            MenuItem(
                icon: Symbols.sportsEsports,
                // A year is not a quantity: formatted without the locale's digit grouping ("2 007")
                label: candidate.year.map { String(format: L("metadata_candidate_with_year"), candidate.name, $0) } ?? candidate.name
            ) { [self] in match(app, candidate) }
        }
        if page > 0 {
            items.append(MenuItem(icon: Symbols.arrowBack, label: L("metadata_matches_previous")) { [self] in
                showMatches(app: app, term: term, found: found, page: page - 1, anchor: anchor)
            })
        }
        if (page + 1) * per < found.count {
            items.append(MenuItem(icon: Symbols.arrowForward, label: L("metadata_matches_more")) { [self] in
                showMatches(app: app, term: term, found: found, page: page + 1, anchor: anchor)
            })
        }
        items.append(MenuItem(icon: Symbols.searchName, label: L("metadata_search_other")) { [self] in
            layers.openDialog(DialogSpec(
                title: L("metadata_search_title"), note: L("metadata_search_note"),
                fields: [DialogField(icon: Symbols.search, initial: term, placeholder: L("metadata_search_hint"), maxLength: 100)],
                confirm: L("metadata_search_action")
            ) { [self] values in
                let next = values.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if next.isEmpty { return false }
                searchMetadata(app: app, term: next, anchor: anchor)
                return true
            })
        })
        let title = found.isEmpty ? L("metadata_matches_none", term) : L("metadata_matches_title")
        layers.openContextMenu(ContextMenu(title: title, items: items), anchor: anchor)
    }

    private func match(_ app: HostApp, _ candidate: MetadataCandidate) {
        Task {
            do {
                let state = try await metadata.perform(app) { try await $0.select(title: $1, candidate: candidate) }
                if let error = state.error {
                    layers.feedback?.play(.error)
                    toasts.show(Self.problemText(error), icon: Symbols.error)
                } else {
                    toasts.show(L("metadata_matched_toast", candidate.name), icon: Symbols.checkCircle)
                }
            } catch is CancellationError {
            } catch {
                layers.feedback?.play(.error)
                toasts.show(L("metadata_match_save_failed_toast"), icon: Symbols.error)
            }
        }
    }
}
