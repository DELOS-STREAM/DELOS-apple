import DelosData
import Foundation

/// The rows of Settings → Covers (the SteamGridDB rows of `nativeSettings` in DELOS for Android): the API key (a dialog;
/// the value says whether one is added), Download automatically, Download missing artwork and Download all artwork
/// again; the last three need a key. "Choose artwork" only tells where the game menu's Artwork screen is.
struct CoversForm: Equatable {
    /// SteamGridDB has a key.
    var enabled: Bool
    var automatic: Bool
    /// The PC whose library is open below Settings, by name.
    var pcName: String?

    static let key = "covers_sgdb_key"
    static let automaticID = "covers_sgdb_auto"
    static let missing = "covers_sgdb_missing"
    static let refresh = "covers_sgdb_refresh"
    static let choose = "covers_sgdb_choose"
    static let ids: Set<String> = [key, automaticID, missing, refresh]

    func rows(_ tab: SettingsTab) -> [SettingRow] {
        guard tab == .covers else { return [] }
        // A product name: Android does not translate it either
        let section = "SteamGridDB"
        return [
            SettingRow(
                id: Self.key, tab: .covers, section: section, icon: Symbols.key, label: L("settings_native_sgdb_key_title"),
                value: .action(label: enabled ? L("settings_native_sgdb_key_added") : L("settings_native_sgdb_key_not_set")),
                help: L("settings_native_sgdb_key_description")),
            SettingRow(
                id: Self.automaticID, tab: .covers, section: section, icon: Symbols.cloudDownload, label: L("settings_native_sgdb_auto_title"),
                value: .toggle(automatic), help: L("settings_native_sgdb_auto_description"), enabled: enabled),
            SettingRow(
                id: Self.missing, tab: .covers, section: section, icon: Symbols.download, label: L("settings_native_missing_artwork_title"),
                value: .action(label: nil),
                help: pcName.map { L("settings_native_missing_artwork_description", $0) } ?? L("settings_native_missing_artwork_description_current"),
                enabled: enabled),
            SettingRow(
                id: Self.refresh, tab: .covers, section: section, icon: Symbols.refresh, label: L("settings_native_refresh_artwork_title"),
                value: .action(label: nil), help: L("settings_native_refresh_artwork_description"), enabled: enabled),
            // Choosing artwork is done per game, in its menu (the Artwork screen): the row says where
            SettingRow(
                id: Self.choose, tab: .covers, section: section, icon: Symbols.imageChoose,
                label: L("settings_native_choose_artwork_title"), value: .info(L("settings_native_choose_artwork_value")),
                help: L("settings_native_choose_artwork_description")),
        ]
    }
}

extension SteamGridDBError {
    /// The sentence for the user (`SteamGridDbException.text`).
    var text: String {
        switch self {
        case .noKey: L("artwork_error_no_key")
        case .keyRejected: L("artwork_error_key_rejected")
        case .apiHTTP(let code): L("artwork_error_api_http", code)
        case .badReply, .insecureURL: L("artwork_error_bad_reply")
        // Android does not translate it either
        case .downloadHTTP(let code): "HTTP \(code)"
        case .imageTooLarge: L("artwork_error_too_large")
        }
    }
}
