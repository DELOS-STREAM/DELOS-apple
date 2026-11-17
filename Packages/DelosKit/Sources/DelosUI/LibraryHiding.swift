import DelosData
import DelosHost
import Observation

/// Hiding games in the library (`PcRepository.setHidden`, `showHidden` of DELOS for Android): the hidden games of the
/// current profile on each PC, and the side menu's switch that shows them again. The switch is not kept: hidden games are
/// out of the library again at the next launch.
@MainActor @Observable
final class HiddenLibrary {
    /// "Show hidden apps" of the side menu.
    var showHidden = false
    /// Changes with every store change, so a screen that read the hidden games reads them again.
    private var revision = 0
    @ObservationIgnored private let store: HiddenGames

    init(store: HiddenGames = HiddenGames()) {
        self.store = store
    }

    func ids(profile: String?, hostID: String) -> Set<Int> {
        _ = revision
        guard let profile else { return [] }
        return store.ids(profile: profile, hostID: hostID)
    }

    func set(_ hidden: Bool, appID: Int, profile: String?, hostID: String) {
        guard let profile else { return }
        store.set(hidden, appID: appID, profile: profile, hostID: hostID)
        revision += 1
    }
}

/// What hiding does to the library's list and the side menu.
enum LibraryHiding {
    /// [apps] without the hidden ones, unless [showHidden].
    static func visible(_ apps: [HostApp], hidden: Set<Int>, showHidden: Bool) -> [HostApp] {
        showHidden || hidden.isEmpty ? apps : apps.filter { !hidden.contains($0.id) }
    }

    /// How many of [apps] are hidden (ids of games the PC no longer has do not count).
    static func count(_ apps: [HostApp], hidden: Set<Int>) -> Int {
        apps.filter { hidden.contains($0.id) }.count
    }

    /// The side menu's "Show hidden apps" row (`Shell.kt`): there while a game is hidden or the switch is on, with the
    /// count and the PC under its label.
    static func sideRow(count: Int, showing: Bool, pcName: String?) -> SideMenu.HiddenRow? {
        guard count > 0 || showing else { return nil }
        let note = pcName.map { L("shell_side_hidden_on", count, $0) } ?? L("shell_side_hidden_on_this_pc", count)
        return SideMenu.HiddenRow(showing: showing, note: note)
    }
}

/// An icon-only pill in a cover's top-right corner (`CornerPill`): the app is hidden, or has settings of its own.
enum CoverMark: Hashable {
    case hidden, custom

    var icon: String { self == .hidden ? Symbols.visibilityOff : Symbols.tune }
    var opacity: Double { self == .hidden ? 0.85 : 1 }
    var label: String { self == .hidden ? L("home_tile_hidden_description") : L("home_tile_custom_description") }
}
