import CoreGraphics
import DelosData
import DelosHost
import DelosInput
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

/// Why a ready list has no image (`NoImages`).
enum ArtworkEmpty: Equatable {
    /// The filters left nothing: the message with Reset filters and Change filters and no tile. The first choice (the PC's
    /// artwork) is not drawn: it would stand beside the message as a stray cover, and Reset gives the whole grid back.
    case filtered
    /// SteamGridDB has no image of this kind: the first choice stays, with a note beside it.
    case bare

    static let resetID = "art-none-reset"
    static let changeID = "art-none-change"
    /// The glyphs on the two buttons: the button that does the same. Reset has none: X is the search by name on this screen
    /// (it resets the filters only inside the open sheet), so A is its button; Change filters is Y, which opens the sheet.
    static let resetGlyph: GlyphRole? = nil
    static let changeGlyph: GlyphRole? = .north

    /// Nil: the list has images.
    init?(images: Int, filters: ArtFilters) {
        guard images == 0 else { return nil }
        self = filters.active ? .filtered : .bare
    }

    /// Whether the first choice is drawn as a tile.
    var showsFirstChoice: Bool { self == .bare }

    /// The item the focus starts on.
    var firstFocus: String { self == .filtered ? Self.resetID : ArtworkScreen.noneID }
}

/// What A does on the focused item of the Artwork screen, which the hint bar's A button says (``ScreenHints/artworkSouth``).
/// The buttons of the whole screen are fixed, as on Android: X searches for another name (it resets the filters only in the
/// open sheet) and Y opens the sheet. So an item that resets the filters, such as the empty state's Reset, is not marked with
/// X, and the hint bar names what A does on it.
enum ArtworkSouth: Equatable, Sendable {
    case useImage, select, searchName, filter, resetFilters, changeFilters

    /// What A does on the item with this id.
    static func of(_ focused: AnyHashable?) -> ArtworkSouth {
        guard let id = focused as? String else { return .useImage }
        switch id {
        case ArtworkScreen.searchID: return .searchName
        case ArtworkScreen.filterID: return .filter
        case ArtworkFilterStrip.resetID, ArtworkEmpty.resetID: return .resetFilters
        case ArtworkEmpty.changeID: return .changeFilters
        default: return id.hasPrefix("art-tab-") || id.hasPrefix("art-chip-") ? .select : .useImage
        }
    }
}

/// What a command of the controller or keyboard does on the Artwork screen. L1 and R1 switch the tab, X (`.options`) searches
/// for another name and Y (`.toastAction`) opens the filter sheet; the open sheet takes every command (its own focus is moved
/// by the directions, A chooses, X resets, Y and B close it) so that nothing reaches the grid behind it.
enum ArtworkCommand: Equatable {
    case tab(Int)
    case search
    case openSheet
    case closeSheet
    case resetFilters
    case sheetAccept
    case sheetMove
    /// Consumed, nothing happens (a command the open sheet has no use for).
    case nothing
    /// Not the screen's: the focus gets it.
    case pass

    /// [toastOwnsY]: a toast with its own action keeps Y.
    static func route(_ command: MenuCommand, sheetOpen: Bool, toastOwnsY: Bool) -> ArtworkCommand {
        if sheetOpen {
            switch command {
            case .back, .toastAction: return .closeSheet
            case .options: return .resetFilters
            case .accept: return .sheetAccept
            case .up, .down, .left, .right: return .sheetMove
            case .previousTab, .nextTab, .menu, .mute: return .nothing
            }
        }
        switch command {
        case .previousTab: return .tab(-1)
        case .nextTab: return .tab(1)
        case .options: return .search
        case .toastAction: return toastOwnsY ? .pass : .openSheet
        case .up, .down, .left, .right, .accept, .back, .menu: return .pass
        case .mute: return .nothing
        }
    }
}

/// The info strip under the grid (`InfoStrip`), in stage px: as high as its content needs (the text of tvOS, 24 pt at least,
/// and of a big interface scale needs more than the design's 84), never less than that.
enum ArtworkInfoLayout {
    static let minHeight = 84.0
    /// Air above and below the content.
    static let padding = 14.0
    /// Between the title and the facts, and between the facts.
    static let gap = 44.0
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

/// What the grid says when the app has no SteamGridDB game (`GridMessage` of `Choices.NoGame`): a game SteamGridDB did not
/// find, or, for an app whose artwork does not come from SteamGridDB (DELOS's own entries), "Choose what X looks like".
enum ArtworkNoGame {
    static func text(_ app: HostApp) -> (title: String, note: String) {
        BundledArtwork.kind(app) == nil
            ? (L("artwork_no_game_title", app.title), L("artwork_no_game_note"))
            : (L("artwork_choose_title", app.title), L("artwork_choose_note", app.title))
    }
}

/// SteamGridDB's takedown placeholder (`Thumbnails.looksRemoved` of DELOS for Android): the API does not flag a removed
/// image, its thumbnail does, as a black picture with one line of text. The grid leaves such a choice out unless it is
/// the one in use.
enum TakedownPlaceholder {
    /// The side of the square the thumbnail is shrunk to before it is looked at.
    static let side = 48

    /// Whether [rgba] (a small thumbnail, 4 bytes per pixel, red first) is a placeholder rather than artwork: nearly all of
    /// it opaque pure black, which real artwork, even a dark one, hardly ever is. Transparent images (logos) never qualify.
    static func looksRemoved(rgba: [UInt8]) -> Bool {
        let pixels = rgba.count / 4
        guard pixels > 0 else { return false }
        var black = 0
        for i in 0..<pixels {
            let p = i * 4
            if rgba[p + 3] >= 200, rgba[p] < 6, rgba[p + 1] < 6, rgba[p + 2] < 6 { black += 1 }
        }
        return Double(black) >= Double(pixels) * 0.9
    }

    /// [image] shrunk to ``side`` × ``side`` and looked at.
    static func looksRemoved(_ image: CGImage) -> Bool {
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn && looksRemoved(rgba: rgba)
    }

    /// The choices the grid shows: [images] without the placeholders found so far, except the one [chosen].
    static func shown(_ images: [SteamGridDBImage], chosen: ArtworkChoice, removed: Set<URL>) -> [SteamGridDBImage] {
        guard !removed.isEmpty else { return images }
        return images.filter { chosen == .image($0.id) || !removed.contains($0.previewURL) }
    }
}
