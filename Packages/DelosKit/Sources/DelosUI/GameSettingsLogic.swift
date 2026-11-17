import DelosData
import DelosHost
import Foundation
import Observation

/// The rows of the App settings screen and what editing them does (`GameSettingsLogic.kt` and the screen's state of DELOS
/// for Android, docs/PER_APP_SETTINGS.md): the stream settings that exist here, over the profile's settings with the
/// app's overrides laid on them. Everything a row shows and does is here; the view only draws it.
@MainActor
@Observable
final class GameSettingsModel {
    let hostID: String
    let app: HostApp
    let profileID: String
    let device: StreamDevice
    /// What the app overrides now; every edit is stored at once.
    private(set) var overrides: GameSettingsOverride
    /// The profile's own settings (never written here).
    private(set) var profile: StreamSettings
    @ObservationIgnored private let store: GameSettingsStore

    init(hostID: String, app: HostApp, profileID: String, device: StreamDevice, store: GameSettingsStore = GameSettingsStore(),
         streams: StreamSettingsStore = StreamSettingsStore()) {
        self.hostID = hostID
        self.app = app
        self.profileID = profileID
        self.device = device
        self.store = store
        overrides = store.load(profile: profileID, hostID: hostID, appID: app.id)
        profile = streams.load(profile: profileID)
    }

    /// The rows over what a stream of the app uses.
    var form: StreamSettingsForm { StreamSettingsForm(settings: overrides.merged(onto: profile), device: device) }
    private var profileForm: StreamSettingsForm { StreamSettingsForm(settings: profile, device: device) }

    /// The rows in the order of the screen: each says where its value comes from.
    var rows: [SettingRow] {
        let profileRows = Dictionary((profileForm.rows(.stream) + profileForm.rows(.audio)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let custom = overrides.keys
        let form = form
        return (form.rows(.stream) + form.rows(.audio)).map { row in
            var row = row
            if let key = GameSettingsOverride.Key(rawValue: row.id), custom.contains(key) {
                row.customLine = L("settings_game_profile_line", profileRows[row.id].map(Self.valueLabel) ?? "")
            } else {
                row.note = L("settings_game_from_profile")
            }
            return row
        }
    }

    func isCustom(_ id: String) -> Bool {
        GameSettingsOverride.Key(rawValue: id).map(overrides.keys.contains) ?? false
    }

    /// The profile's value of row [id] and the app's current one, as the rows show them.
    func profileLabel(_ id: String) -> String {
        (profileForm.rows(.stream) + profileForm.rows(.audio)).first { $0.id == id }.map(Self.valueLabel) ?? ""
    }

    func currentLabel(_ id: String) -> String { rows.first { $0.id == id }.map(Self.valueLabel) ?? "" }

    /// [row]'s value as a short label (`profileValueLabel`): "On", "1080p", "225 Mbps".
    static func valueLabel(_ row: SettingRow) -> String {
        switch row.value {
        case .choice(let label, _, _): label
        case .toggle(let on): L(on ? "settings_game_value_on" : "settings_game_value_off")
        case let .slider(value, _, _, divisor, unit):
            (value % divisor == 0 ? String(value / divisor) : String(format: "%.1f", Double(value) / Double(divisor))) + unit
        case .action(let label): label ?? ""
        case .appSettings(let language): language
        case .info(let text): text
        }
    }

    // MARK: Changes

    /// Left / right (A: +1) on row [id]; false when nothing changed.
    @discardableResult
    func step(_ id: String, by direction: Int) -> Bool { edit { $0.step(id, by: direction) } }

    /// A value picked from a choice row's list.
    func pick(_ id: String, option index: Int) { edit { $0.pick(id, option: index) } }

    /// The bitrate set on the slider's track.
    func slide(to kbps: Int) { edit { $0.setBitrate(kbps) } }

    @discardableResult
    private func edit(_ change: (inout StreamSettingsForm) -> Void) -> Bool {
        var next = form
        let before = next.settings
        change(&next)
        guard next.settings != before else { return false }
        overrides.record(from: before, to: next.settings)
        save()
        return true
    }

    /// The row follows the profile again; returns what was there, for the Undo.
    func reset(_ id: String) -> GameSettingsOverride {
        let backup = overrides
        if let key = GameSettingsOverride.Key(rawValue: id) { overrides.reset(key) }
        save()
        return backup
    }

    /// Every setting follows the profile again; returns what was there, for the Undo.
    func resetAll() -> GameSettingsOverride {
        let backup = overrides
        overrides = GameSettingsOverride()
        save()
        return backup
    }

    /// The Undo of a reset: puts back what it removed and keeps anything changed since.
    func restore(_ backup: GameSettingsOverride) {
        overrides.restoreMissing(from: backup)
        save()
    }

    private func save() { store.save(overrides, profile: profileID, hostID: hostID, appID: app.id) }
}

/// The banner chip and the panel's summary (`customSettingsLabel`, `customSummary`).
enum GameSettingsText {
    /// How many settings are custom for the app, or that it follows the profile.
    static func customLabel(_ count: Int) -> String {
        count <= 0 ? L("settings_game_follows_profile") : LPlural("settings_game_custom_count", count)
    }

    /// The panel's text while no row is focused: what makes a setting custom, or how much of the app is.
    static func summary(_ count: Int, app: String) -> String {
        count == 0 ? L("settings_game_summary_none") : L("settings_game_only_this_game", app)
    }
}
