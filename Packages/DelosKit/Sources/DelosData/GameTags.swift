import Foundation

/// The genres and themes a game's card shows (`GameTags.kt` and `SteamTags.kt` of DELOS for Android): IGDB's lists ranked
/// by how well they describe a game, Steam's user tags mapped onto IGDB's entries, at most two of each.
public enum GameTags {
    /// IGDB's genre "Indie": a business model, not a genre, so it only counts when nothing else is listed.
    private static let indie = 32
    /// IGDB's theme "Erotic": never shown.
    private static let erotic = 42
    /// IGDB's theme "Action": a genre in disguise, so it only counts as the one usable theme.
    private static let action = 1

    /// Genres from the most to the least specific for what the game plays like (a Shooter and Adventure is a Shooter).
    private static let genreLadder = [5, 4, 10, 12, 11, 16, 24, 25, 8, 31, 9, 36, 7, 34, 35, 26, 30, 2, 14, 13, 15, 33]
    /// Themes from the most to the least telling.
    private static let themeLadder = [19, 21, 38, 18, 17, 23, 39, 33, 43, 20, 40, 41, 22, 27, 31, 44, 28, 34, 35, 32]

    /// Only the most voted Steam tags describe a game; the long tail is noise.
    static let steamTagsConsidered = 15

    private static func ranked(_ entries: [GameGenre], _ ladder: [Int]) -> [GameGenre] {
        var seen = Set<Int>()
        let distinct = entries.filter { seen.insert($0.id).inserted }
        let known = distinct.filter { ladder.contains($0.id) }.sorted { ladder.firstIndex(of: $0.id)! < ladder.firstIndex(of: $1.id)! }
        return known + distinct.filter { !ladder.contains($0.id) }
    }

    /// Every genre from the one that describes the game best to the least; Indie only when nothing else is listed.
    public static func rankedGenres(_ genres: [GameGenre]) -> [GameGenre] {
        let ranked = ranked(genres.filter { $0.id != indie }, genreLadder)
        return ranked.isEmpty ? Array(genres.filter { $0.id == indie }.prefix(1)) : ranked
    }

    /// Every usable theme from the most to the least telling. Action only counts when no other usable theme is listed;
    /// Erotic never does.
    public static func rankedThemes(_ themes: [GameGenre]) -> [GameGenre] {
        let usable = themes.filter { $0.id != erotic }
        let ranked = ranked(usable.filter { $0.id != action }, themeLadder)
        return ranked.isEmpty ? Array(usable.filter { $0.id == action }.prefix(1)) : ranked
    }

    /// Up to [limit] entries: [steam] in its order, then the first ranked IGDB entries that are eligible and not present.
    private static func top(_ steam: [GameGenre], _ ranked: [GameGenre], _ limit: Int, eligible: (GameGenre) -> Bool) -> [GameGenre] {
        if steam.isEmpty { return Array(ranked.prefix(limit)) }
        var result = Array(steam.prefix(limit))
        for entry in ranked where result.count < limit {
            if eligible(entry), !result.contains(where: { $0.id == entry.id }) { result.append(entry) }
        }
        return result
    }

    /// The genres shown on the card: those Steam's user tags give, the next ones from IGDB's ranking when Steam gives
    /// fewer, or IGDB's ranking alone. Never a duplicate; Indie only when nothing else exists.
    public static func topGenres(_ igdb: [GameGenre], steamTags: [String], limit: Int = 2) -> [GameGenre] {
        top(steamGenres(steamTags), rankedGenres(igdb), limit) { $0.id != indie }
    }

    /// The themes shown on the card, chosen like ``topGenres``; Action counts only when it is the one usable theme.
    public static func topThemes(_ igdb: [GameGenre], steamTags: [String], limit: Int = 2) -> [GameGenre] {
        let steam = steamThemes(steamTags)
        let chosen = top(steam.filter { $0.id != action }, rankedThemes(igdb), limit) { $0.id != action }
        return chosen.isEmpty ? Array(steam.prefix(limit)) : chosen
    }

    // MARK: Steam tags

    /// Case-insensitive key of a Steam tag name: trimmed, typographic apostrophes straightened, spaces collapsed.
    static func tagKey(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func lookup(_ groups: [(id: Int, tags: [String])]) -> [String: Int] {
        var table: [String: Int] = [:]
        for group in groups { for tag in group.tags { table[tagKey(tag)] = group.id } }
        return table
    }

    /// The genres Steam's user tags give a game, in vote order. Weak mappings (Roguelike is an RPG) only join when fewer
    /// than two strong genres exist.
    public static func steamGenres(_ tags: [String]) -> [GameGenre] {
        select(tags, strong: genreLookup, weak: weakGenreLookup, names: genreNames, weakBelow: 2)
    }

    /// The themes Steam's user tags give a game, in vote order. The weak theme Action only counts when no other exists.
    public static func steamThemes(_ tags: [String]) -> [GameGenre] {
        select(tags, strong: themeLookup, weak: weakThemeLookup, names: themeNames, weakBelow: 1)
    }

    private static func select(_ tags: [String], strong: [String: Int], weak: [String: Int], names: [Int: String], weakBelow: Int) -> [GameGenre] {
        let considered = tags.prefix(steamTagsConsidered).map(tagKey)
        var ids: [Int] = []
        func add(_ id: Int?) { if let id, !ids.contains(id) { ids.append(id) } }
        for tag in considered { add(strong[tag]) }
        if ids.count < weakBelow { for tag in considered { add(weak[tag]) } }
        return ids.compactMap { id in names[id].map { GameGenre(id: id, name: $0) } }
    }

    private static let genreLookup = lookup(genreTags)
    private static let weakGenreLookup = lookup(weakGenreTags)
    private static let themeLookup = lookup(themeTags)
    private static let weakThemeLookup = lookup(weakThemeTags)

    /// IGDB's genre names by id (the names IGDB returns, so a Steam-derived entry reads like an IGDB-derived one).
    static let genreNames: [Int: String] = [
        2: "Point-and-click", 4: "Fighting", 5: "Shooter", 7: "Music", 8: "Platform", 9: "Puzzle", 10: "Racing",
        11: "Real Time Strategy (RTS)", 12: "Role-playing (RPG)", 13: "Simulator", 14: "Sport", 15: "Strategy",
        16: "Turn-based strategy (TBS)", 24: "Tactical", 25: "Hack and slash/Beat 'em up", 26: "Quiz/Trivia", 30: "Pinball",
        31: "Adventure", 32: "Indie", 33: "Arcade", 34: "Visual Novel", 35: "Card & Board Game", 36: "MOBA",
    ]

    /// IGDB's theme names by id.
    static let themeNames: [Int: String] = [
        1: "Action", 17: "Fantasy", 18: "Science fiction", 19: "Horror", 20: "Thriller", 21: "Survival", 22: "Historical",
        23: "Stealth", 27: "Comedy", 28: "Business", 31: "Drama", 32: "Non-fiction", 33: "Sandbox", 34: "Educational",
        35: "Kids", 38: "Open world", 39: "Warfare", 40: "Party", 41: "4X (explore, expand, exploit, and exterminate)",
        42: "Erotic", 43: "Mystery", 44: "Romance",
    ]

    // The Steam tag names below are data: the English names Steam's store returns, matched case-insensitively; never shown.

    static let genreTags: [(id: Int, tags: [String])] = [
        (5, ["Shooter", "First-Person Shooter", "Third-Person Shooter", "FPS", "Bullet Hell", "Shoot 'Em Up", "Shmup", "Looter Shooter", "Hero Shooter", "Arena Shooter", "Tactical Shooter", "Twin Stick Shooter", "Top-Down Shooter", "Rail Shooter", "On-Rails Shooter", "Extraction Shooter", "Boomer Shooter", "Battle Royale"]),
        (4, ["Fighting", "2D Fighter", "3D Fighter", "Martial Arts"]),
        (25, ["Hack and Slash", "Beat 'em up", "Brawler", "Character Action Game", "Character Action", "Souls-like", "Soulslike", "Spectacle fighter"]),
        (12, ["RPG", "Action RPG", "ARPG", "JRPG", "CRPG", "Party-Based RPG", "MMORPG", "Dungeon Crawler"]),
        (10, ["Racing", "Driving", "Combat Racing", "Motorsports", "Kart Racing"]),
        (8, ["Platformer", "2D Platformer", "3D Platformer", "Precision Platformer", "Metroidvania"]),
        (9, ["Puzzle", "Puzzle Platformer", "Hidden Object", "Match 3", "Logic", "Tile-Matching", "Escape Room", "Jigsaw"]),
        (31, ["Adventure", "Action-Adventure", "Walking Simulator", "Interactive Fiction", "Text-Based", "Choose Your Own Adventure"]),
        (2, ["Point & Click"]),
        (15, ["Strategy", "Grand Strategy", "4X", "City Builder", "Tower Defense", "Auto Battler", "Wargame"]),
        (11, ["RTS", "Real Time Strategy"]),
        (16, ["Turn-Based Strategy", "Strategy RPG"]),
        (24, ["Tactical", "Tactical RPG", "Turn-Based Tactics", "Real Time Tactics"]),
        (35, ["Card Battler", "Deckbuilding", "Card Game", "Roguelike Deckbuilder", "Board Game", "Tabletop", "Trading Card Game"]),
        (36, ["MOBA"]),
        (13, ["Simulation", "Life Sim", "Farming Sim", "Management", "Resource Management", "Time Management", "Colony Sim", "Cooking", "Flight", "Space Sim", "Automobile Sim", "Medical Sim", "Trains", "Hunting", "Sailing", "God Game", "Hobby Sim", "Job Simulator"]),
        (14, ["Sports", "Football", "Football (Soccer)", "Football (American)", "Soccer", "Basketball", "Baseball", "Golf", "Mini Golf", "Tennis", "Hockey", "Skateboarding", "Wrestling", "Boxing", "Cycling", "Bowling", "Fishing", "Pool", "Skating", "Skiing"]),
        (7, ["Rhythm", "Music", "Dance"]),
        (34, ["Visual Novel"]),
        (26, ["Trivia", "Word Game"]),
        (33, ["Arcade"]),
        (30, ["Pinball"]),
    ]

    static let weakGenreTags: [(id: Int, tags: [String])] = [
        (12, ["Roguelike", "Roguelite", "Action Roguelike", "Roguevania", "Rogue-like", "Rogue-lite"]),
    ]

    static let themeTags: [(id: Int, tags: [String])] = [
        (19, ["Horror", "Survival Horror", "Psychological Horror", "Cosmic Horror", "Lovecraftian", "Zombies"]),
        (18, ["Sci-fi", "Science Fiction", "Cyberpunk", "Space", "Aliens", "Futuristic", "Dystopian", "Mechs", "Robots", "Space Sim"]),
        (17, ["Fantasy", "Dark Fantasy", "Medieval", "Magic", "Dragons", "Mythology"]),
        (38, ["Open World"]),
        (21, ["Survival", "Open World Survival Craft", "Post-apocalyptic"]),
        (23, ["Stealth"]),
        (39, ["War", "WWII", "World War I", "World War II", "Military", "Cold War", "Wargame"]),
        (33, ["Sandbox"]),
        (43, ["Mystery", "Detective", "Noir", "Crime", "Investigation"]),
        (20, ["Thriller", "Psychological", "Conspiracy", "Espionage"]),
        (27, ["Comedy", "Funny", "Parody", "Dark Humor", "Satire", "Black Comedy", "Memes"]),
        (40, ["Party", "Party Game"]),
        (41, ["4X"]),
        (22, ["Historical", "Ancient", "Alternate History", "Vikings"]),
        (31, ["Drama"]),
        (44, ["Romance", "Dating Sim", "Otome"]),
        (28, ["Business", "Economy", "Trading"]),
        (34, ["Education", "Educational"]),
        (35, ["Kids", "Family Friendly"]),
        (32, ["Documentary"]),
    ]

    static let weakThemeTags: [(id: Int, tags: [String])] = [
        (1, ["Action", "Superhero"]),
    ]
}
