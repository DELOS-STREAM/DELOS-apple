import DelosData
import Foundation

/// The tab of each kind on the Artwork screen (`ArtTab` of DELOS for Android), with the columns of its grid (the
/// prototype's: 7 covers, 4 wide covers, 3 backgrounds, 5 logos per row) and the shape of its images. Every sentence that
/// names the kind has a string of its own per tab, so each language inflects it.
enum ArtworkTab: CaseIterable, Hashable {
    case cover, wide, hero, logo

    var kind: ArtKind {
        switch self {
        case .cover: .cover
        case .wide: .wide
        case .hero: .hero
        case .logo: .logo
        }
    }

    var label: String {
        switch self {
        case .cover: L("artwork_tab_cover")
        case .wide: L("artwork_tab_wide")
        case .hero: L("artwork_tab_hero")
        case .logo: L("artwork_tab_logo")
        }
    }

    /// "41 covers".
    func count(_ images: Int) -> String {
        switch self {
        case .cover: LPlural("artwork_count_cover", images)
        case .wide: LPlural("artwork_count_wide", images)
        case .hero: LPlural("artwork_count_hero", images)
        case .logo: LPlural("artwork_count_logo", images)
        }
    }

    /// "All 41 covers" (`countAll`).
    func countAll(_ images: Int) -> String {
        switch self {
        case .cover: LPlural("artwork_count_all_cover", images)
        case .wide: LPlural("artwork_count_all_wide", images)
        case .hero: LPlural("artwork_count_all_hero", images)
        case .logo: LPlural("artwork_count_all_logo", images)
        }
    }

    /// "10 of 41 covers" (`countOf`): the quantity is the total.
    func countOf(_ shown: Int, _ total: Int) -> String {
        switch self {
        case .cover: LPlural("artwork_count_of_cover", total, shown)
        case .wide: LPlural("artwork_count_of_wide", total, shown)
        case .hero: LPlural("artwork_count_of_hero", total, shown)
        case .logo: LPlural("artwork_count_of_logo", total, shown)
        }
    }

    /// "10 of 41 covers" when the unfiltered total differs, else "41 covers"; [all] says "All 41 covers" for an unfiltered
    /// list (`resultLine`).
    func resultLine(shown: Int, total: Int?, all: Bool) -> String {
        if let total, total != shown { return countOf(shown, total) }
        return all ? countAll(shown) : count(shown)
    }

    /// No image matches the filters.
    var none: String {
        switch self {
        case .cover: L("artwork_filtered_none_cover")
        case .wide: L("artwork_filtered_none_wide")
        case .hero: L("artwork_filtered_none_hero")
        case .logo: L("artwork_filtered_none_logo")
        }
    }

    /// Why none matches when the game's total is known: "Hades has 41 covers on SteamGridDB, none of them matches ...".
    func has(game: String, total: Int) -> String {
        switch self {
        case .cover: LPlural("artwork_filtered_has_cover", total, game)
        case .wide: LPlural("artwork_filtered_has_wide", total, game)
        case .hero: LPlural("artwork_filtered_has_hero", total, game)
        case .logo: LPlural("artwork_filtered_has_logo", total, game)
        }
    }

    /// Why none matches when the total is not known.
    var unknown: String {
        switch self {
        case .cover: L("artwork_filtered_unknown_cover")
        case .wide: L("artwork_filtered_unknown_wide")
        case .hero: L("artwork_filtered_unknown_hero")
        case .logo: L("artwork_filtered_unknown_logo")
        }
    }

    /// SteamGridDB has none for this app.
    var empty: String {
        switch self {
        case .cover: L("artwork_empty_cover")
        case .wide: L("artwork_empty_wide")
        case .hero: L("artwork_empty_hero")
        case .logo: L("artwork_empty_logo")
        }
    }

    var downloading: String {
        switch self {
        case .cover: L("artwork_downloading_cover")
        case .wide: L("artwork_downloading_wide")
        case .hero: L("artwork_downloading_hero")
        case .logo: L("artwork_downloading_logo")
        }
    }

    var updated: String {
        switch self {
        case .cover: L("artwork_updated_cover")
        case .wide: L("artwork_updated_wide")
        case .hero: L("artwork_updated_hero")
        case .logo: L("artwork_updated_logo")
        }
    }

    var icon: String {
        switch self {
        case .cover: Symbols.image
        case .wide: Symbols.aspectRatio
        case .hero: Symbols.wallpaper
        case .logo: Symbols.logo
        }
    }

    var columns: Int {
        switch self {
        case .cover: 7
        case .wide: 4
        case .hero: 3
        case .logo: 5
        }
    }

    /// Width over height of a tile.
    var ratio: Double {
        switch self {
        case .cover: 600.0 / 900
        case .wide: 920.0 / 430
        case .hero: 1920.0 / 620
        case .logo: 2
        }
    }

    /// The tab [direction] places further (L1 and R1), wrapping round.
    func step(_ direction: Int) -> ArtworkTab {
        let all = Self.allCases
        return all[((all.firstIndex(of: self)! + direction) % all.count + all.count) % all.count]
    }

    /// The columns of a grid on a stage [stageWidth] stage pixels wide: [columns] at the 1720 of a 1920 stage, in
    /// proportion otherwise.
    func columns(forStageWidth stageWidth: Double) -> Int {
        max(Int((Double(columns) * (stageWidth - 200) / 1720).rounded()), 1)
    }
}

/// Where the grid's tiles stand (`ArtGridLayout` of DELOS for Android), stage pixels: the focused tile grows by 6 %, its
/// 4 + 4 px ring and 12 px of air have to fit between two tiles.
struct ArtworkGrid: Equatable {
    static let focusScale = 1.06
    static let ring = 8.0
    static let clearance = 12.0
    static let minGap = 28.0

    let columns: Int
    let tileWidth: Double
    let tileHeight: Double
    let gapX: Double
    let gapY: Double

    /// The room between two tiles of width [tile].
    static func gap(_ tile: Double) -> Double { max(minGap, tile * (focusScale - 1) + ring + clearance) }

    /// The tile width that [columns] tiles and their gaps fill [width] with.
    static func tileWidth(width: Double, columns: Int) -> Double {
        guard columns > 1 else { return width }
        let byRule = (width - Double(columns - 1) * (ring + clearance)) / (Double(columns) + Double(columns - 1) * (focusScale - 1))
        return gap(byRule) > minGap ? byRule : (width - Double(columns - 1) * minGap) / Double(columns)
    }

    /// The grid of [columns] tiles of [ratio] across [width].
    init(width: Double, ratio: Double, columns: Int) {
        let tile = Self.tileWidth(width: width, columns: columns)
        self.columns = columns
        tileWidth = tile
        tileHeight = tile / ratio
        gapX = columns > 1 ? (width - Double(columns) * tile) / Double(columns - 1) : Self.gap(tile)
        gapY = Self.gap(tile)
    }
}

/// What the grid of a tab shows (`Choices`).
enum ArtworkChoices: Equatable {
    case loading
    case noKey
    case noGame
    case failed(String)
    /// [total] is the unfiltered count when it is known (the unfiltered list was loaded).
    case ready(gameID: Int, images: [SteamGridDBImage], total: Int?)
}

/// The labels of the filter sheet and the strip (`ArtType.label`, `ArtSort.label`/`chip`/`first`, `ActiveFilter.label`).
extension ArtType {
    var label: String {
        switch self {
        case .all: L("filters_art_type_all")
        case .still: L("filters_art_type_static")
        case .animated: L("filters_art_type_animated")
        }
    }
}

extension ArtSort {
    var label: String {
        switch self {
        case .score: L("filters_art_sort_score")
        case .newest: L("filters_art_sort_newest")
        case .oldest: L("filters_art_sort_oldest")
        }
    }

    /// The removable chip of a non-default order.
    var chip: String {
        switch self {
        case .score: L("filters_art_sort_score_chip")
        case .newest: L("filters_art_sort_newest_chip")
        case .oldest: L("filters_art_sort_oldest_chip")
        }
    }

    /// The note under the toolbar.
    var first: String {
        switch self {
        case .score: L("filters_art_sort_score_first")
        case .newest: L("filters_art_sort_newest_first")
        case .oldest: L("filters_art_sort_oldest_first")
        }
    }
}

extension ActiveFilter {
    var label: String {
        switch self {
        case .type(let type): type.label
        case .style(let style): ArtworkFact.styleLabel(style)
        case .dimensions(let dimensions): ArtFilterRules.dimensionsLabel(dimensions)
        case .sort(let sort): sort.chip
        }
    }
}

/// A fact the info strip tells about the focused image (`ArtworkFact`): only what SteamGridDB's answer contained.
enum ArtworkFact: Equatable {
    case size(width: Int, height: Int)
    case file(String)
    case score(Int?, author: String?)
    case added(Int)

    /// The facts of [image] in the strip's order.
    static func of(_ image: SteamGridDBImage) -> [ArtworkFact] {
        var facts: [ArtworkFact] = []
        if image.width > 0, image.height > 0 { facts.append(.size(width: image.width, height: image.height)) }
        if let format = image.format { facts.append(.file(format)) }
        let author = image.author.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        if image.score != 0 || author != nil { facts.append(.score(image.score == 0 ? nil : image.score, author: author)) }
        if let date = image.date { facts.append(.added(date)) }
        return facts
    }

    /// The label and the value in the language of the interface.
    var text: (label: String, value: String) {
        switch self {
        case let .size(width, height): (L("artwork_fact_size"), String(format: L("artwork_fact_size_value"), width, height))
        case .file(let format): (L("artwork_fact_file"), format)
        case let .score(score, author):
            (L("artwork_fact_score"), Self.scoreText(score, author: author))
        case .added(let seconds): (L("artwork_fact_added"), Self.date(seconds))
        }
    }

    private static func scoreText(_ score: Int?, author: String?) -> String {
        switch (score, author) {
        case let (score?, author?): String(format: L("artwork_fact_score_by"), score, author)
        case let (score?, nil): String(format: L("artwork_fact_score_only"), score)
        default: String(format: L("artwork_fact_by_only"), author ?? "")
        }
    }

    /// The day an image was added in the medium date style, in UTC whatever the time zone of the device.
    static func date(_ epochSeconds: Int, locale: Locale = .current) -> String {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds))
            .formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: .gmt))
    }

    /// The strip's title: the image's style ("White logo"), else the kind's own name.
    static func title(_ image: SteamGridDBImage, fallback: String) -> String {
        image.style.map(styleLabel) ?? fallback
    }

    static func styleLabel(_ style: String) -> String {
        switch style {
        case "alternate": L("filters_art_style_alternate")
        case "blurred": L("filters_art_style_blurred")
        case "white_logo": L("filters_art_style_white_logo")
        case "material": L("filters_art_style_material")
        case "no_logo": L("filters_art_style_no_logo")
        case "official": L("filters_art_style_official")
        case "white": L("filters_art_style_white")
        case "black": L("filters_art_style_black")
        case "custom": L("filters_art_style_custom")
        default:
            style.replacingOccurrences(of: "_", with: " ").prefix(1).uppercased()
                + style.replacingOccurrences(of: "_", with: " ").dropFirst()
        }
    }
}

/// The games in the choose-a-game menu (`changeGame`: at most eight).
enum ArtworkSearch {
    static let shown = 8

    static func label(_ game: SteamGridDBGame) -> String {
        game.year.map { String(format: L("artwork_game_with_year"), game.name, $0) } ?? game.name
    }
}
