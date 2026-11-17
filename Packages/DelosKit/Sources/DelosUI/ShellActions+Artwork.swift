import DelosData
import DelosHost
import Foundation

/// The Artwork entry of a game's menu and what the Artwork screen does (`apply`, `searchDialog` and `changeGame` of
/// `ArtworkScreen.kt`): each result is reported in a toast.
extension ShellActions {
    /// Opens the Artwork screen of [app] above the library.
    func openArtwork(hostID: String, app: HostApp) {
        go { navigator.push(.artwork(hostID: hostID, appID: app.id), focus: ArtworkScreen.firstFocus) }
    }

    /// Uses [image] (nil: none) for [tab]'s kind of [app]'s artwork.
    func applyArtwork(hostID: String, app: HostApp, tab: ArtworkTab, image: SteamGridDBImage?) {
        feedback?.play(.select)
        Task {
            if image != nil { toasts.show(tab.downloading, icon: Symbols.download) }
            do {
                try await artwork.apply(hostID: hostID, appID: app.id, kind: tab.kind, image: image)
                toasts.show(tab.updated, icon: Symbols.checkCircle)
            } catch {
                feedback?.play(.error)
                toasts.show(Self.artworkErrorText(error, fallback: "artwork_download_failed"), icon: Symbols.error)
            }
        }
    }

    /// "Search for another name": a text dialog; the games found for the name come as a menu.
    func openArtworkSearch(hostID: String, app: HostApp, term: String) {
        guard artwork.enabled else { return }
        feedback?.play(.open)
        layers.openDialog(DialogSpec(
            title: L("artwork_search_title"), note: L("artwork_search_note"),
            fields: [DialogField(icon: Symbols.search, initial: term, placeholder: L("artwork_search_hint"), maxLength: 80)],
            confirm: L("artwork_search_action")
        ) { [self] values in
            let next = values[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if next.isEmpty { return false }
            changeArtworkGame(hostID: hostID, app: app, term: next)
            return true
        })
    }

    /// The SteamGridDB games found for [term]; a chosen game re-matches the artwork.
    private func changeArtworkGame(hostID: String, app: HostApp, term: String) {
        Task {
            toasts.show(L("artwork_searching_toast", term), icon: Symbols.search)
            let found: [SteamGridDBGame]
            do {
                found = try await artwork.search(term)
            } catch {
                feedback?.play(.error)
                toasts.show(Self.artworkErrorText(error, fallback: "artwork_unreachable"), icon: Symbols.error)
                return
            }
            var items = found.prefix(ArtworkSearch.shown).map { game in
                MenuItem(icon: Symbols.sportsEsports, label: ArtworkSearch.label(game)) { [self] in setArtworkGame(hostID: hostID, app: app, game: game) }
            }
            items.append(MenuItem(icon: Symbols.searchName, label: L("artwork_search_other")) { [self] in
                openArtworkSearch(hostID: hostID, app: app, term: term)
            })
            let title = found.isEmpty ? L("artwork_found_none", term) : L("artwork_found_title")
            layers.openContextMenu(ContextMenu(title: title, items: items), anchor: layers.menuAnchor)
        }
    }

    private func setArtworkGame(hostID: String, app: HostApp, game: SteamGridDBGame) {
        Task {
            toasts.show(L("artwork_downloading_game_toast", game.name), icon: Symbols.download)
            do {
                try await artwork.setGame(hostID: hostID, appID: app.id, game: game)
                toasts.show(L("artwork_matched_toast", game.name), icon: Symbols.checkCircle)
            } catch {
                feedback?.play(.error)
                toasts.show(Self.artworkErrorText(error, fallback: "artwork_download_failed"), icon: Symbols.error)
            }
        }
    }

    /// Why a SteamGridDB call failed (`sgdbErrorText`): its own sentence, else [fallback].
    static func artworkErrorText(_ error: any Error, fallback: String) -> String {
        (error as? SteamGridDBError)?.text ?? L(fallback)
    }
}
