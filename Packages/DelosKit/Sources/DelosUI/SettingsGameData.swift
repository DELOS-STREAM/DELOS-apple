import DelosData
import Foundation

/// Android's About → Game data rows (`about_igdb`, `about_pcgw`, `about_steam`, `about_hltb`): the providers of the
/// information on the home screen, each opening its website. They show only while a metadata service is configured,
/// as no provider is asked without one.
enum GameDataSetting {
    /// Whether this build has a metadata service (`DelosMetadataURL`).
    static let configured = MetadataConfiguration.bundled().enabled

    private static let providers: [(id: String, icon: String, name: String, url: String)] = [
        ("about_igdb", Symbols.providerIgdb, "igdb", "https://www.igdb.com/"),
        ("about_pcgw", Symbols.providerPcgw, "pcgw", "https://www.pcgamingwiki.com/wiki/PCGamingWiki:Copyrights"),
        ("about_steam", Symbols.steam, "steam", "https://store.steampowered.com/"),
        ("about_hltb", Symbols.completionTime, "hltb", "https://howlongtobeat.com/"),
    ]

    static var firstID: String { providers[0].id }

    static func rows(_ tab: SettingsTab, enabled: Bool = configured) -> [SettingRow] {
        guard enabled, tab == .about else { return [] }
        return providers.map { provider in
            SettingRow(
                id: provider.id, tab: .about, section: L("settings_native_section_game_data"), icon: provider.icon,
                label: L("settings_native_\(provider.name)_title"), value: .action(label: nil),
                help: L("settings_native_\(provider.name)_description"))
        }
    }

    /// The website a game data row opens.
    static func website(_ id: String) -> URL? { providers.first { $0.id == id }.flatMap { URL(string: $0.url) } }
}
