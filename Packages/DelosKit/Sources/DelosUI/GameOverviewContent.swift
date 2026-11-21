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
        /// Steam's media: the carousel's picture, the viewer's and a movie's stream (HLS, else MP4) for AVPlayer.
        struct Steam: Equatable {
            let thumb: URL?
            let full: URL?
            var stream: URL? = nil
        }
        let kind: Kind
        /// IGDB's image id of a screenshot, the YouTube id of a video; `steam-movie-<id>` and `steam-shot-<id>` for Steam's.
        let id: String
        let name: String?
        /// Steam's media; nil for IGDB's screenshots and YouTube's videos.
        var steam: Steam? = nil
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

        media = Self.media(details, unplayable: unplayable)

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

    /// The narrowest picture the carousel and the viewer take: Steam's own 293 px movie poster is never stretched.
    static let posterWidth = 600

    /// Steam's movies (the ones AVPlayer can play) first, then Steam's screenshots. YouTube's videos come only when Steam
    /// has no movie (never on Apple TV, which has no web view, and never the ones in [unplayable]); IGDB's screenshots only
    /// when Steam has no screenshot. A movie's picture is its own poster when that is at least ``posterWidth`` wide, else
    /// Steam's first screenshot, else none (the surface).
    static func media(_ details: GameDetails, unplayable: Set<String>) -> [Media] {
        let shots = (details.steam?.screenshots ?? []).compactMap { shot -> Media? in
            guard let full = SteamMedia.url(shot.full) else { return nil }
            return Media(kind: .screenshot, id: "steam-shot-\(shot.id)", name: nil, steam: .init(thumb: SteamMedia.url(shot.thumbnail) ?? full, full: full))
        }
        let poster = shots.first?.steam
        let movies = (details.steam?.movies ?? []).compactMap { movie -> Media? in
            guard let stream = movie.stream else { return nil }
            let own = SteamMedia.url(movie.thumbnail).flatMap { (SteamMedia.width($0) ?? 0) >= posterWidth ? $0 : nil }
            return Media(kind: .video, id: "steam-movie-\(movie.id)", name: movie.name,
                         steam: .init(thumb: own ?? poster?.thumb, full: own ?? poster?.full, stream: stream))
        }
        #if os(tvOS)
        let youTube: [Media] = []
        #else
        let youTube = youTubeVideos(details).filter { !unplayable.contains($0.videoId) }.map { Media(kind: .video, id: $0.videoId, name: $0.name) }
        #endif
        let screenshots = shots.isEmpty ? details.screenshots.map { Media(kind: .screenshot, id: $0.imageId, name: nil) } : shots
        return (movies.isEmpty ? youTube : movies) + screenshots
    }

    /// IGDB's YouTube videos, the fallback: none when Steam has a movie that plays.
    static func youTubeVideos(_ details: GameDetails) -> [GameDetails.Video] {
        details.steam?.movies.contains { $0.stream != nil } == true ? [] : details.videos
    }

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
/// muted, and the dock's focus), or a video that cannot play (it browses like a screenshot).
enum OverviewViewerItem: Equatable, Sendable {
    case screenshot
    case video(playing: Bool, muted: Bool, focus: OverviewDockFocus = .timeline)
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

/// The overview's motion numbers (stage pixels and milliseconds; the springs are in ``OverviewMotion/flightOpenSpring``
/// and its siblings). The timeline runs at the prototype's own pace (1.0 times its table).
enum OverviewMotion {
    /// How long the cover's flight takes to look landed out to the header and back (the springs' perceived length): the
    /// title's crossfade is timed by it (out over its first 40 %, in over its last 50 %).
    static let flight = 780.0, flightBack = 640.0
    /// The flight rises this far above the straight line at its middle and grows by this much.
    static let arc = 30.0, midScale = 1.04
    /// The page rises from this far below with the flight, and sinks back there over [pageSink] ms as it closes.
    static let pageRise = 120.0, pageSink = 560.0
    /// The header's parts rise one after another, [headerStagger] ms apart from [headerDelay]; the cue, the sixth step,
    /// counts from [cueDelay] (it starts at 730 ms).
    static let headerDelay = 260.0, cueDelay = 500.0, headerStagger = 46.0
    /// The hero fades in over [heroIn] ms and out over [heroOut] ms; the header's buttons take input after [buttonsDelay].
    static let heroIn = 900.0, heroOut = 640.0, buttonsDelay = 400.0
    /// The other covers lift away: 160 px plus 30 per cover of distance, to 92 %, 45 ms apart; the info row rises 90 px.
    static func coverLift(distance: Int) -> Double { -160 - Double(distance) * 30 }
    static let coverLiftScale = 0.92, coverLiftStagger = 45.0, infoLift = -90.0
    /// The streaming card's count-up and bars run over this long; the ratings start this long after the opening, the
    /// second ring [ratingStagger] ms after the first.
    static let ratings = 1300.0, ratingsDelay = 380.0, ratingStagger = 90.0
    /// A ring's overshoot is softly capped near this share of its target (tanh: about 7.3 % at most).
    static let ratingOvershoot = 0.08
    /// The ring and its number grow from this scale; a chip pops from [chipFrom].
    static let ratingFrom = 0.92, chipFrom = 0.9
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
    static let pullClose = 150.0, swipeOpen = 72.0
    /// A drag counts as a swipe of the cover once it moved this far, mostly vertically.
    static let swipeSlop = 10.0
    /// The swiped cover's rubber band: it follows the finger up at [swipeShare] of its travel at first and eases towards
    /// [swipeCap] stage pixels, never past it; it grows by [swipeGrow] and fades to 70 % near the cap (the standard row's
    /// numbers on every platform).
    static let swipeShare = 0.6, swipeCap = 56.0, swipeGrow = 0.03

    /// How far the dragged cover follows a finger that moved [travel] points (negative: up), with [cap] the most it rises
    /// (points): up it is a rubber band, at most [swipeShare] of the travel and never past [cap]; down it barely gives.
    static func swipeFollow(_ travel: Double, cap: Double) -> Double {
        guard travel < 0, cap > 0 else { return max(travel, 0) * 0.15 }
        return -cap * (1 - exp(-swipeShare * -travel / cap))
    }

    /// The header cover's scale while the page is pulled down [pull] stage pixels past its top.
    static func pullScale(_ pull: Double) -> Double { 1 - min(max(pull, 0), 300) / 2400 }

    /// The closing flight's start when the finger let go of the page it pulled down: the header cover's frame as it shows
    /// ([slot] moved down by [pull] points and shrunk by [scale] about its middle) and the spring's initial velocity, in
    /// flights per second towards the card ([card]): the cover's downward [speed] (points per second) along the way to
    /// the card, so the flight carries on from the finger's motion without a stop.
    static func pullHandoff(slot: CGRect, pull: Double, scale: Double, speed: Double, card: CGRect) -> (frame: CGRect, velocity: Double) {
        let width = slot.width * scale, height = slot.height * scale
        let frame = CGRect(x: slot.midX - width / 2, y: slot.midY + max(pull, 0) - height / 2, width: width, height: height)
        let dx = card.midX - frame.midX, dy = card.midY - frame.midY
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 1, dy > 0 else { return (frame, 0) }
        // Only the part of the speed that heads towards the card counts, at most 6 flights per second
        return (frame, min(max(speed, 0) * dy / distance / distance, 6))
    }

    /// The flight's position overshoot past an end: at most [overshootCap] stage pixels, with [overshootGainIn] times the
    /// spring's overshoot (as a share of the travel) into the slot and [overshootGainOut] past the card.
    static let overshootCap = 40.0, overshootGainIn = 1.6, overshootGainOut = 2.5

    /// The flying cover's frame at [progress] (0 at the card, 1 at the header slot): its size runs from the card's to the
    /// slot's and grows a little at the middle, its centre runs along a slight arc [lift] points high. [from], [to]: the
    /// card's and the slot's frames. Past either end (the spring's overshoot) only the position carries on, along the half
    /// of the arc it arrived on, by [cap]·tanh(raw / [cap]) points (raw: the overshoot times the travel times
    /// ``overshootGainIn`` or ``overshootGainOut``); the size stays the end's, so the slot's or the card's edge never shows
    /// a bigger cover.
    static func flightFrame(from: CGRect, to: CGRect, progress: Double, lift: Double, cap: Double = 0) -> CGRect {
        let t = min(max(progress, 0), 1)
        // A quadratic through the start, the lifted middle and the end
        let u = 1 - t
        let grow = 1 + (midScale - 1) * 4 * t * u
        let width = (from.width * u + to.width * t) * grow, height = (from.height * u + to.height * t) * grow
        var x = from.midX * u + to.midX * t, y = from.midY * u + to.midY * t - lift * 4 * t * u
        let over = progress - t
        if over != 0, cap > 0 {
            let midX = (from.midX + to.midX) / 2, midY = (from.midY + to.midY) / 2 - lift
            let end = over > 0 ? CGPoint(x: to.midX, y: to.midY) : CGPoint(x: from.midX, y: from.midY)
            let dx = end.x - midX, dy = end.y - midY, length = (dx * dx + dy * dy).squareRoot()
            let travel = hypot(from.midX - to.midX, from.midY - to.midY)
            if length > 0 {
                let raw = abs(over) * (over > 0 ? overshootGainIn : overshootGainOut) * travel
                let shift = cap * tanh(raw / cap)
                x += dx / length * shift
                y += dy / length * shift
            }
        }
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    /// The card as the row shows it, from the cover's frame at rest ([rest], its layout): focused (grown by the focus
    /// scale about its middle; the wide first cover only to the left), then lifted [lift] points and grown by [scale]
    /// about the item's middle as a finger left it.
    static func cardFrame(rest: CGRect, lift: Double = 0, scale: Double = 1) -> CGRect {
        let s = CoverGeometry.focusScale
        let width = rest.width * s, height = rest.height * s
        let x = rest.width > rest.height ? rest.maxX - width : rest.midX - width / 2
        let focused = CGRect(x: x, y: rest.midY - height / 2, width: width, height: height)
        return CGRect(x: rest.midX + (focused.minX - rest.midX) * scale, y: rest.midY + (focused.minY - rest.midY) * scale + lift,
                      width: focused.width * scale, height: focused.height * scale)
    }

    /// The card the closing flight heads for at [progress]: the frame the opening left from ([from], where a finger had
    /// lifted the card) at the progress the closing began at ([start]), turning into the card at rest ([back]) on the way,
    /// so the flight lands exactly where the card is, without a jump where it began.
    static func closingFrom(progress: Double, start: Double, from: CGRect, back: CGRect) -> CGRect {
        guard start > 0, from != back else { return back }
        let t = min(max(progress / start, 0), 1)
        return CGRect(x: back.minX + (from.minX - back.minX) * t, y: back.minY + (from.minY - back.minY) * t,
                      width: back.width + (from.width - back.width) * t, height: back.height + (from.height - back.height) * t)
    }

    /// The flying cover's opacity at [progress] of an opening whose card left at [from] (a swiped cover fades near the
    /// top of its rubber band): back to whole by 30 % of the flight.
    static func flightOpacity(progress: Double, from: Double) -> Double {
        from + (1 - from) * min(max(progress / 0.3, 0), 1)
    }

    /// A finger's hand-off at the opening: the flight's initial velocity (flights per second, at most 6) that carries on
    /// a cover let go of while it moved [velocityY] points per second (negative: up) from [from] towards the slot [to],
    /// along the arc's start ([lift] points high). Only motion towards the slot carries over.
    static func openVelocity(velocityY: Double, from: CGRect, to: CGRect, lift: Double) -> Double {
        // d(centre y) / d(progress) at the card: the straight way plus the arc's rise
        let slope = to.midY - from.midY - 4 * lift
        guard abs(slope) >= 1 else { return 0 }
        return min(max(velocityY / slope, 0), 6)
    }

    /// The ring arc's spring: response 1.0 s, damping 0.55, settled exactly at [ratingRun] ms (a ring's own clock, from
    /// its start); its number counts up with a plain ease-out over [ratingCount] ms.
    static let ratingResponse = 1.0, ratingDamping = 0.55, ratingRun = 1600.0, ratingCount = 1100.0

    /// A rating ring's arc at [ms] into its spring, 1 being its target: the spring's step response up to its peak
    /// (π/ωd ≈ 599 ms), then the peak's overshoot decays as (1 + x)·e^(−x), x = (t − peak)·ω, with no second bounce; an
    /// overshoot is softly capped by 1 + 0.08·tanh(over / 0.08) (about 7.3 % at most).
    static func ratingFill(ms: Double) -> Double {
        guard ms > 0 else { return 0 }
        guard ms < ratingRun else { return 1 }
        let t = ms / 1000, zeta = ratingDamping, omega = 2 * Double.pi / ratingResponse
        let root = (1 - zeta * zeta).squareRoot(), damped = omega * root, peak = Double.pi / damped
        func step(_ t: Double) -> Double { 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta / root * sin(damped * t)) }
        let over: Double
        if t < peak {
            over = step(t) - 1
        } else {
            let x = (t - peak) * omega
            over = (step(peak) - 1) * (1 + x) * exp(-x)
        }
        return over > 0 ? 1 + ratingOvershoot * tanh(over / ratingOvershoot) : 1 + over
    }

    /// A rating's number at [ms] into its ring's clock, 1 being the rating: CSS's ease-out (`cubic-bezier(0, 0, .58, 1)`)
    /// over [ratingCount] ms, never past it.
    static func ratingNumber(ms: Double) -> Double {
        let u = ms / ratingCount
        guard u > 0 else { return 0 }
        guard u < 1 else { return 1 }
        // The curve's parameter where its x is [u] (x rises with it), then its y there
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let s = (low + high) / 2
            if 3 * (1 - s) * s * s * 0.58 + s * s * s < u { low = s } else { high = s }
        }
        let s = (low + high) / 2
        return min(3 * (1 - s) * s * s + s * s * s, 1)
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
