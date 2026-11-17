import Foundation
import DelosData

/// What the user reads and sees for an IGDB genre or theme (`GenreIcons.kt` of DELOS for Android): the translated name of
/// its id, IGDB's own English name for one we have no string for, and one icon per entry.
enum TagLook {
    private static let genres: [Int: (name: String, icon: String)] = [
        2: ("tags_genre_point_and_click", Symbols.genrePointAndClick), 4: ("tags_genre_fighting", Symbols.genreFighting),
        5: ("tags_genre_shooter", Symbols.genreShooter), 7: ("tags_genre_music", Symbols.genreMusic),
        8: ("tags_genre_platform", Symbols.genrePlatform), 9: ("tags_genre_puzzle", Symbols.genrePuzzle),
        10: ("tags_genre_racing", Symbols.genreRacing), 11: ("tags_genre_real_time_strategy", Symbols.genreRealTimeStrategy),
        12: ("tags_genre_role_playing", Symbols.genreRolePlaying), 13: ("tags_genre_simulator", Symbols.genreSimulator),
        14: ("tags_genre_sport", Symbols.genreSport), 15: ("tags_genre_strategy", Symbols.genreStrategy),
        16: ("tags_genre_turn_based_strategy", Symbols.genreTurnBasedStrategy), 24: ("tags_genre_tactical", Symbols.genreTactical),
        25: ("tags_genre_hack_and_slash", Symbols.genreHackAndSlash), 26: ("tags_genre_quiz", Symbols.genreQuiz),
        30: ("tags_genre_pinball", Symbols.genrePinball), 31: ("tags_genre_adventure", Symbols.genreAdventure),
        32: ("tags_genre_indie", Symbols.genreIndie), 33: ("tags_genre_arcade", Symbols.genreArcade),
        34: ("tags_genre_visual_novel", Symbols.genreVisualNovel), 35: ("tags_genre_card_and_board", Symbols.genreCardAndBoard),
        36: ("tags_genre_moba", Symbols.genreMoba),
    ]

    private static let themes: [Int: (name: String, icon: String)] = [
        1: ("tags_theme_action", Symbols.themeAction), 17: ("tags_theme_fantasy", Symbols.themeFantasy),
        18: ("tags_theme_science_fiction", Symbols.themeScienceFiction), 19: ("tags_theme_horror", Symbols.themeHorror),
        20: ("tags_theme_thriller", Symbols.themeThriller), 21: ("tags_theme_survival", Symbols.themeSurvival),
        22: ("tags_theme_historical", Symbols.themeHistorical), 23: ("tags_theme_stealth", Symbols.themeStealth),
        27: ("tags_theme_comedy", Symbols.themeComedy), 28: ("tags_theme_business", Symbols.themeBusiness),
        31: ("tags_theme_drama", Symbols.themeDrama), 32: ("tags_theme_non_fiction", Symbols.themeNonFiction),
        33: ("tags_theme_sandbox", Symbols.themeSandbox), 34: ("tags_theme_educational", Symbols.themeEducational),
        35: ("tags_theme_kids", Symbols.themeKids), 38: ("tags_theme_open_world", Symbols.themeOpenWorld),
        39: ("tags_theme_warfare", Symbols.themeWarfare), 40: ("tags_theme_party", Symbols.themeParty),
        41: ("tags_theme_four_x", Symbols.theme4x), 42: ("tags_theme_erotic", Symbols.genreUnknown),
        43: ("tags_theme_mystery", Symbols.themeMystery), 44: ("tags_theme_romance", Symbols.themeRomance),
    ]

    static func genreName(_ genre: GameGenre) -> String { genres[genre.id].map { L($0.name) } ?? genre.name }
    static func themeName(_ theme: GameGenre) -> String { themes[theme.id].map { L($0.name) } ?? theme.name }
    static func genreIcon(_ id: Int) -> String { genres[id]?.icon ?? Symbols.genreUnknown }
    static func themeIcon(_ id: Int) -> String { themes[id]?.icon ?? Symbols.genreUnknown }

    /// How long a game takes as the HLTB chip writes it ("45 Mins", "3½ Hours").
    static func completionText(_ length: CompletionLength) -> String {
        switch length {
        case .minutes(let count): LPlural("metadata_hltb_minutes", count)
        case .hours:
            String.localizedStringWithFormat(
                Bundle.module.localizedString(forKey: "metadata_hltb_hours", value: nil, table: nil), length.quantity, length.hoursText ?? "")
        }
    }
}
