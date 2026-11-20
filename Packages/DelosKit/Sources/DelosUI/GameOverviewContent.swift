import DelosData
import DelosHost
import DelosInput
import Foundation

/// What the game overview (variant A · Descent, DELOS-android#107) shows of a game, worked out from its IGDB details and
/// what the app already knows (streaming time, HowLongToBeat, HDR): every section and row that has nothing to show is left
/// out, so a game with sparse data looks complete rather than broken.
struct OverviewContent: Equatable {
    enum Section: String, CaseIterable, Equatable, Sendable {
        case about, media, details, streaming, links, similar
    }

    struct Rating: Equatable {
        /// 0–100, nil: not rated.
        let value: Double?
        let count: Int
    }

    struct Fact: Equatable {
        let label: String
        let value: String
        /// A muted note after the value ("· self-published").
        var note: String?
    }

    struct DetailGroup: Equatable {
        enum Kind: Equatable { case genres, themes, modes, perspectives, platforms, ageRatings, multiplayer, languages, keywords }
        let kind: Kind
        let values: [String]
    }

    struct Media: Equatable, Identifiable {
        enum Kind: Equatable { case video, screenshot }
        let kind: Kind
        /// IGDB's image id of a screenshot, the YouTube id of a video.
        let id: String
        let name: String?
    }

    struct Link: Equatable, Identifiable {
        enum Kind: Equatable { case official, steam, gog, epic, wikipedia, twitch, youtube, discord, other }
        let kind: Kind
        let url: URL
        /// IGDB's type name for a link of a kind the app has no name of.
        let typeName: String?
        var id: String { url.absoluteString }
    }

    struct Similar: Equatable, Identifiable {
        let id: Int64
        let name: String
        /// The library's app of the same game, when it is in the library (its own card art and overview).
        let app: HostApp?
        let coverImageID: String?
    }

    let details: GameDetails
    let critics: Rating
    let players: Rating
    let facts: [Fact]
    let groups: [DetailGroup]
    let ageRatings: [GameDetails.AgeRating]
    let media: [Media]
    let links: [Link]
    let similar: [Similar]
    let sections: [Section]

    /// [library]: the PC's apps, to find similar games the player owns; [region]: the device's region, which age rating
    /// comes first; [unplayable]: the videos YouTube does not let play in the app (``OverviewVideos``), left out.
    init(details: GameDetails, library: [HostApp], region: String?, unplayable: Set<String> = []) {
        self.details = details
        critics = Rating(value: details.criticRating, count: details.criticRatingCount)
        players = Rating(value: details.rating, count: details.ratingCount)
        ageRatings = details.ageRatings(region: region)

        var facts: [Fact] = []
        let devs = details.developers, pubs = details.publishers
        if !devs.isEmpty { facts.append(Fact(label: L("overview_fact_developer"), value: devs.joined(separator: ", "))) }
        if !pubs.isEmpty {
            facts.append(Fact(label: L("overview_fact_publisher"), value: pubs.joined(separator: ", "),
                              note: pubs == devs ? L("overview_self_published") : nil))
        }
        if let date = details.firstReleaseDate { facts.append(Fact(label: L("overview_fact_released"), value: Self.date(date))) }
        if !details.porters.isEmpty { facts.append(Fact(label: L("overview_fact_ported"), value: details.porters.joined(separator: ", "))) }
        if !details.engines.isEmpty { facts.append(Fact(label: L("overview_fact_engine"), value: details.engines.joined(separator: ", "))) }
        if let series = details.series { facts.append(Fact(label: L("overview_fact_series"), value: series)) }
        self.facts = facts

        var groups: [DetailGroup] = []
        func add(_ kind: DetailGroup.Kind, _ values: [String]) { if !values.isEmpty { groups.append(DetailGroup(kind: kind, values: values)) } }
        add(.genres, details.genres.map(Self.genreName))
        add(.themes, details.themes)
        add(.modes, details.modes.map(Self.modeName))
        add(.perspectives, details.perspectives)
        add(.platforms, details.platforms.map { $0.abbreviation ?? $0.name })
        add(.ageRatings, details.ageRatings.isEmpty ? [] : ["-"])
        add(.multiplayer, Self.multiplayer(details.multiplayer))
        add(.languages, details.languages.isEmpty ? [] : [LPlural("overview_languages", details.languages.count, details.languages.count)])
        add(.keywords, Array(details.keywords.prefix(5)))
        self.groups = groups

        // Videos first, then screenshots. Apple TV has no web view to play a video in: no videos there
        #if os(tvOS)
        let videos: [Media] = []
        #else
        let videos = details.videos.filter { !unplayable.contains($0.videoId) }.map { Media(kind: .video, id: $0.videoId, name: $0.name) }
        #endif
        media = videos + details.screenshots.map { Media(kind: .screenshot, id: $0.imageId, name: nil) }

        var links = details.websites.compactMap { site -> Link? in
            guard let url = URL(string: site.url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return Link(kind: Self.linkKind(site.type), url: url, typeName: site.type)
        }
        // IGDB lists no Steam page: the store page of the Steam app id it knows
        if !links.contains(where: { $0.kind == .steam }), let steam = details.steamAppID,
           let url = URL(string: "https://store.steampowered.com/app/\(steam)") {
            links.append(Link(kind: .steam, url: url, typeName: nil))
        }
        self.links = links

        let owned = Dictionary(library.map { (MetadataPolicy.matchKey($0.title), $0) }, uniquingKeysWith: { first, _ in first })
        similar = details.similarGames.map { game in
            Similar(id: game.id, name: game.name, app: owned[MetadataPolicy.matchKey(game.name)], coverImageID: game.coverImageId)
        }

        var sections: [Section] = []
        if details.summary != nil || details.storyline != nil || !facts.isEmpty { sections.append(.about) }
        if !media.isEmpty { sections.append(.media) }
        if !groups.isEmpty { sections.append(.details) }
        sections.append(.streaming)
        if !links.isEmpty { sections.append(.links) }
        if !similar.isEmpty { sections.append(.similar) }
        self.sections = sections
    }

    /// IGDB's "Role-playing (RPG)" reads "Role-playing".
    static func genreName(_ name: String) -> String { name.replacingOccurrences(of: " (RPG)", with: "") }
    /// "Massively Multiplayer Online (MMO)" reads "MMO".
    static func modeName(_ name: String) -> String { name.hasPrefix("Massively") ? "MMO" : name }

    static func multiplayer(_ m: GameDetails.Multiplayer?) -> [String] {
        guard let m else { return [] }
        var parts: [String] = []
        if m.onlineCoopMax > 0 { parts.append(L("overview_online_coop", m.onlineCoopMax)) }
        if m.offlineCoopMax > 0 { parts.append(L("overview_couch_coop", m.offlineCoopMax)) }
        if m.lanCoop { parts.append(L("overview_lan_coop")) }
        if m.onlineMax > 0 { parts.append(L("overview_online_max", m.onlineMax)) }
        if m.splitscreen { parts.append(L("overview_split_screen")) }
        return parts.isEmpty ? [] : [parts.joined(separator: " · ")]
    }

    static func linkKind(_ type: String?) -> Link.Kind {
        switch type?.lowercased() {
        case "official website", "official": .official
        case "steam": .steam
        case "gog": .gog
        case "epic", "epic games", "epic games store": .epic
        case "wikipedia": .wikipedia
        case "twitch": .twitch
        case "youtube": .youtube
        case "discord": .discord
        default: .other
        }
    }

    /// "September 18, 2025" in the current locale, the date as IGDB stores it (UTC).
    static func date(_ seconds: Int64, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .long, time: .omitted).locale(locale)
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return Date(timeIntervalSince1970: Double(seconds)).formatted(style)
    }

    /// The eyebrow above the title: "2025 · Driftlight Studios"; nil when IGDB has neither.
    var eyebrow: String? {
        let parts = [details.year.map(String.init), details.developers.isEmpty ? nil : details.developers.joined(separator: ", ")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The share of HowLongToBeat's time the player has streamed, 0–100.
    static func completionShare(streamedSeconds: Double, completionSeconds: Int64?) -> Int? {
        guard let completionSeconds, completionSeconds > 0 else { return nil }
        return min(100, Int((streamedSeconds / Double(completionSeconds) * 100).rounded()))
    }
}

/// What the overview's viewer shows, for the hint bar: a screenshot, a video that plays (and whether it is playing and
/// muted), or a video that cannot play (it browses like a screenshot).
enum OverviewViewerItem: Equatable, Sendable {
    case screenshot
    case video(playing: Bool, muted: Bool)
    case unplayable
}

/// The overview's navigation by commands (controller, keyboard, the Siri Remote): the focus walks the page's items by their
/// geometry (``FocusModel``); what is the overview's own is decided here.
enum OverviewNavigation {
    /// The ids of the overview's focusable items.
    static let play = "ov-play"
    static let settings = "ov-settings"
    static let summary = "ov-summary"
    static let story = "ov-story"
    static let facts = "ov-facts"
    static let details = "ov-details"
    static let streaming = "ov-streaming"
    static func media(_ index: Int) -> String { "ov-media-\(index)" }
    static func link(_ index: Int) -> String { "ov-link-\(index)" }
    static func similar(_ index: Int) -> String { "ov-similar-\(index)" }
    static let back = "ov-back"

    /// The overview opens with the focus on Play: Down, A starts the game from the dashboard.
    static let initialFocus = play

    /// The header's items: Up from one of them returns to the dashboard, the natural reverse of Down.
    static func inHeader(_ id: AnyHashable?) -> Bool {
        id == AnyHashable(play) || id == AnyHashable(settings)
    }

    enum Outcome: Equatable {
        /// The overview closes (back to the focused cover).
        case close
        /// The command is the focus model's (a move, or A on the focused item).
        case focus
        /// Nothing happens.
        case ignore
    }

    /// What [command] does with [focused] focused.
    static func outcome(_ command: MenuCommand, focused: AnyHashable?) -> Outcome {
        switch command {
        case .back: .close
        case .up where inHeader(focused): .close
        case .up, .down, .left, .right, .accept: .focus
        case .menu, .options, .toastAction, .previousTab, .nextTab, .mute: .ignore
        }
    }

    /// Whether Down on the dashboard opens the overview of [app]: a game with details to show (DELOS's own entries,
    /// Desktop and Steam Big Picture have none; Down only nudges their cover).
    static func opens(_ app: HostApp, hasDetails: Bool) -> Bool {
        BundledArtwork.kind(app) == nil && hasDetails
    }

    /// The section line: a focused section scrolls so its top stands this far below the page's top (under the status bar).
    static let sectionAnchor = 132.0

    /// Where the page scrolls to for an item of [section] whose top is [sectionTop] and height [sectionHeight] (page
    /// pixels), the item itself at [itemTop]/[itemHeight], in a viewport [viewport] high: the header scrolls the page
    /// back to its top; a section taller than the viewport reveals the item with a margin; any other puts the section on
    /// the line. Never past [maximum].
    static func scrollTarget(header: Bool, sectionTop: Double, sectionHeight: Double, itemTop: Double, itemHeight: Double,
                             viewport: Double, maximum: Double, current: Double) -> Double {
        if header { return 0 }
        let target: Double
        if sectionHeight > viewport - 260 {
            let margin = 160.0
            if itemTop - margin < current { target = itemTop - margin }
            else if itemTop + itemHeight + margin > current + viewport { target = itemTop + itemHeight + margin - viewport }
            else { target = current }
        } else {
            target = sectionTop - sectionAnchor
        }
        return min(max(target, 0), max(maximum, 0))
    }
}

/// The overview's motion numbers (stage pixels and milliseconds; the prototype's a.js and core.css).
enum OverviewMotion {
    /// The cover's flight from the card to the header and back.
    static let flight = 780.0, flightBack = 640.0
    /// The flight's easing (`EASE.flight`) and the way back's (`EASE.inOut`).
    static let flightCurve = CubicBezier(0.2, 0.9, 0.25, 1)
    static let inOutCurve = CubicBezier(0.65, 0, 0.35, 1)
    /// The flight rises this far above the straight line at its middle and grows by this much.
    static let arc = 30.0, midScale = 1.04
    /// The page rises from this far below with the flight, and sinks back there over [pageSink] ms as it closes.
    static let pageRise = 120.0, pageSink = 560.0
    /// The other covers lift away: 160 px plus 30 per cover of distance, to 92 %, 45 ms apart; the info row rises 90 px.
    static func coverLift(distance: Int) -> Double { -160 - Double(distance) * 30 }
    static let coverLiftScale = 0.92, coverLiftStagger = 45.0, homeOut = 620.0, infoLift = -90.0
    /// The ratings fill and count up over this long, starting this long after the opening.
    static let ratings = 1300.0, ratingsDelay = 380.0
    /// The hero blurs fully over this much scroll, drifts at 10 % of it (up to 700 px) and zooms by 1/9000 per pixel.
    static let deepBlurScroll = 520.0
    static func heroDrift(_ scroll: Double) -> Double { -min(scroll, 700) * 0.1 }
    static func heroZoom(_ scroll: Double) -> Double { 1 + min(max(scroll, 0), 900) / 9000 }
    /// Only the additional overview blur is capped; the dashboard's configured blur is unchanged.
    static func deepBlur(from dashboard: Int) -> Int { max(dashboard, 0) + 24 }
    /// The header's logo box (the dashboard's 900 × 180 box at 80 %).
    static let logoWidth = 720.0, logoHeight = 144.0
    /// The screenshots move against the carousel by 7 % of their distance from its middle.
    static let parallax = 0.07
    /// Touch: pulling the page down this far at its top closes the overview; a cover swiped up this far opens it.
    static let pullClose = 150.0, swipeOpen = 90.0
    /// A drag counts as a swipe of the cover once it moved this far, mostly vertically.
    static let swipeSlop = 10.0
    /// The finger's travel the dragged cover follows, with resistance.
    static func swipeFollow(_ travel: Double) -> Double { travel >= 0 ? travel * 0.15 : -pow(-travel, 0.85) }

    /// The flying cover's frame at [progress] (0 at the card, 1 at the header slot): its size runs from the card's to the
    /// slot's and grows a little at the middle, its centre runs along a slight arc [lift] points high. [from], [to]: the
    /// card's and the slot's frames.
    static func flightFrame(from: CGRect, to: CGRect, progress t: Double, lift: Double) -> CGRect {
        // A quadratic through the start, the lifted middle and the end
        let u = 1 - t
        let grow = 1 + (midScale - 1) * 4 * t * u
        let width = (from.width * u + to.width * t) * grow, height = (from.height * u + to.height * t) * grow
        let x = from.midX * u + to.midX * t, y = from.midY * u + to.midY * t - lift * 4 * t * u
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    /// A picture of [aspect] (width / height) filling [frame] as `scaledToFill` does, centred: drawn at [base] (its size
    /// filling the slot), it is scaled by [scale] (the same on both axes: never stretched) and moved by [dx], [dy].
    static func fill(aspect: Double, base: CGSize, frame: CGRect) -> (scale: Double, dx: Double, dy: Double) {
        let a = max(aspect, 0.01)
        let width = max(frame.width, frame.height * a)
        let scale = width / max(base.width, 0.01)
        return (scale, frame.midX - width / 2, frame.midY - width / a / 2)
    }

    /// The size a picture of [aspect] has filling [box] (`scaledToFill`).
    static func fillSize(aspect: Double, box: CGSize) -> CGSize {
        let a = max(aspect, 0.01)
        let width = max(box.width, box.height * a)
        return CGSize(width: width, height: width / a)
    }
}
