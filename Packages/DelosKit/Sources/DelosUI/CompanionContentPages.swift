import DelosData
import DelosInput
import SwiftUI

/*
 * The companion pages of the screens that show a summary of the main display (`CompanionArtworkPage.kt` and
 * `CompanionContentPages.kt` of DELOS for Android; docs/DUAL_SCREEN.md, "Content pages"): the focused artwork, the two
 * filter sheets, the profile, the profile being created and the first-run welcome. Everything is data the owning screen
 * published; the touch buttons run the owner's own paths (the tile's apply, the sheet's reset).
 */

// MARK: - Artwork

/// How a line of the artwork's metadata is drawn (`ArtTone`): white, sea, muted, gold.
enum CompanionArtTone: Hashable, Sendable { case normal, sea, muted, gold }

/// One line of the metadata beside the picture (`ArtLine`, CompanionArtworkPage.kt:38-39): [short] is what a short panel
/// shows; [priority] ranks the lines when fewer fit (the lowest goes first, the order of display stays).
struct CompanionArtLine: Hashable, Sendable {
    let text: String
    var short: String
    let tone: CompanionArtTone
    let priority: Int

    init(_ text: String, tone: CompanionArtTone, priority: Int, short: String? = nil) {
        self.text = text
        self.short = short ?? text
        self.tone = tone
        self.priority = priority
    }

    /// The lines that stay when only [capacity] fit: the highest priorities, in the order they are shown (`keepTop`).
    static func keepTop(_ lines: [CompanionArtLine], capacity: Int) -> [CompanionArtLine] {
        if capacity <= 0 { return [] }
        if lines.count <= capacity { return lines }
        let dropped = Set(lines.enumerated()
            .sorted { $0.element.priority != $1.element.priority ? $0.element.priority < $1.element.priority : $0.offset > $1.offset }
            .prefix(lines.count - capacity).map(\.offset))
        return lines.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }
}

/// The picture of the artwork page (`ArtworkFit`, CompanionArtworkPage.kt:51-65): the biggest box of its own ratio that fits.
enum CompanionArtworkFit {
    /// The picture takes at most this share of the row's width; the metadata has the rest.
    static let widthShare = 0.45

    /// The box for [ratio] (width / height) in [width] × [height]: never larger than either, never cropped, the ratio kept.
    static func box(width: Double, height: Double, ratio: Double, share: Double = widthShare) -> CGSize {
        guard width > 0, height > 0, ratio > 0, ratio.isFinite else { return .zero }
        let w = min(width * share, height * ratio)
        return CGSize(width: w, height: w / ratio)
    }

    /// How many lines of [lineHeight] with [gap] between them fit [height].
    static func lineCapacity(height: Double, lineHeight: Double, gap: Double) -> Int {
        guard height > 0, lineHeight > 0 else { return 0 }
        return max(Int(((height + gap) / (lineHeight + gap)).rounded(.down)), 0)
    }
}

/// What the artwork page shows (`ArtworkPage`, CompanionArtworkPage.kt:72-84).
struct CompanionArtwork: Hashable {
    let title: String
    /// The picture the main display already decoded; nil while it has not arrived.
    let image: CGImage?
    /// The ratio of a picture that has not arrived yet (the tab's own shape); the image's own ratio wins.
    let placeholderRatio: Double
    let lines: [CompanionArtLine]
    let inUse: Bool
    /// The tile's own apply; nil for the built-in artwork of DELOS's own entries (read-only, no button).
    let onUse: (@MainActor () -> Void)?

    static func == (a: CompanionArtwork, b: CompanionArtwork) -> Bool {
        a.title == b.title && a.image.map(ObjectIdentifier.init) == b.image.map(ObjectIdentifier.init) && a.placeholderRatio == b.placeholderRatio
            && a.lines == b.lines && a.inUse == b.inUse && (a.onUse == nil) == (b.onUse == nil)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(lines)
        hasher.combine(inUse)
    }

    /// The lines of a SteamGridDB image ([image] nil: the first choice of [tab]), as the info strip tells them
    /// (`artworkPage`, ArtworkScreen.kt:711-749).
    static func lines(tab: ArtworkTab, image: SteamGridDBImage?, inUse: Bool) -> (title: String, lines: [CompanionArtLine]) {
        var lines: [CompanionArtLine] = []
        let title: String
        if let image {
            title = ArtworkFact.title(image, fallback: tab.label)
            let facts = ArtworkFact.of(image)
            var size: (Int, Int)?
            var file: String?
            for fact in facts {
                switch fact {
                case let .size(width, height): size = (width, height)
                case .file(let format): file = format
                default: break
                }
            }
            switch (size, file) {
            case let ((w, h)?, format?): lines.append(CompanionArtLine(L("companion_art_size_file", w, h, format), tone: .normal, priority: 90))
            case let ((w, h)?, nil): lines.append(CompanionArtLine(L("artwork_fact_size_value", w, h), tone: .normal, priority: 90))
            case let (nil, format?): lines.append(CompanionArtLine(format, tone: .normal, priority: 90))
            case (nil, nil): break
            }
            for fact in facts {
                switch fact {
                case let .score(score, author):
                    if let score { lines.append(CompanionArtLine(L("companion_art_score", score), tone: .sea, priority: 70)) }
                    if let author { lines.append(CompanionArtLine(author, tone: .normal, priority: 30)) }
                case .added(let seconds):
                    let date = ArtworkFact.date(seconds)
                    lines.append(CompanionArtLine(L("companion_art_added", date), tone: .muted, priority: 50, short: date))
                default: break
                }
            }
        } else {
            let name = tab == .logo
            title = L(name ? "artwork_first_name_only" : "artwork_first_from_pc")
            lines.append(CompanionArtLine(L(name ? "artwork_fact_name_source" : "artwork_fact_pc_source"), tone: .normal, priority: 90))
            lines.append(CompanionArtLine(L(name ? "artwork_fact_name_shows" : "artwork_fact_pc_shows"), tone: .muted, priority: 60))
        }
        if inUse { lines.append(CompanionArtLine(L("artwork_in_use"), tone: .gold, priority: 100)) }
        return (title, lines)
    }
}

/// The image the artwork screen has focused (`ArtworkPage`): the picture at its own ratio, never cropped, beside what is
/// known about it, and Use this image (disabled for the image in use). One key for every image: a focus move updates it.
enum CompanionArtworkPage {
    static func page(_ artwork: CompanionArtwork) -> CompanionPage {
        CompanionPage(key: "artwork", revision: artwork) { CompanionArtworkCard(artwork: artwork) }
    }
}

private struct CompanionArtworkCard: View {
    let artwork: CompanionArtwork
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    static let gap = 24.0
    static let line = 1.2
    static let lineGap = 8.0

    var body: some View {
        let ratio = artwork.image.map { Double($0.width) / Double(max($0.height, 1)) } ?? artwork.placeholderRatio
        PageCard { fit in
            let heading = CompanionFit.title(
                artwork.title, alias: L("companion_screen_artwork"), width: fit.budget.innerWidth - PageHeading.chrome, metrics: fit.metrics)
            PageHeading(icon: Symbols.image, title: heading, subtitle: L("companion_art_subtitle"))
            GeometryReader { proxy in
                let width = proxy.size.width / stage.scale
                let height = proxy.size.height / stage.scale
                let box = CompanionArtworkFit.box(width: width, height: height, ratio: ratio)
                let metaWidth = (width - box.width - Self.gap) / stage.textScale
                let capacity = CompanionArtworkFit.lineCapacity(
                    height: height, lineHeight: CompanionFit.minText * Self.line * stage.textScale, gap: Self.lineGap)
                // A line that would wrap is left out, never cut: the column is as wide as the picture leaves it
                let shown = CompanionArtLine.keepTop(
                    artwork.lines.map { line in CompanionArtLine(fit.budget.roomy ? line.text : line.short, tone: line.tone, priority: line.priority) }
                        .filter { fit.metrics.lines($0.text, width: metaWidth) <= 1 },
                    capacity: capacity)
                HStack(spacing: stage.px(Self.gap)) {
                    let shape = RoundedRectangle(cornerRadius: stage.px(16), style: .continuous)
                    Group {
                        if let image = artwork.image {
                            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            ZStack {
                                colors.surface3.color
                                SymbolView(symbol: Symbols.image, size: 64, color: colors.text3)
                            }
                        }
                    }
                    .frame(width: stage.px(box.width), height: stage.px(box.height))
                    .clipShape(shape)
                    VStack(alignment: .leading, spacing: stage.px(Self.lineGap)) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                            BodyText(line.text, color: color(line.tone), maxLines: 1)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .fills(minHeight: stage.px(CompanionFit.minTarget))
            if let onUse = artwork.onUse {
                ActionRow(actions: [PageAction(label: L("companion_art_use"), style: .primary, enabled: !artwork.inUse, run: onUse)])
            }
        }
    }

    private func color(_ tone: CompanionArtTone) -> RGBA {
        switch tone {
        case .normal: colors.text
        case .sea: colors.accent2
        case .muted: colors.text2
        case .gold: colors.accent
        }
    }
}

/// Publishes what the companion screen shows of the Artwork screen (`PublishArtworkPages`, ArtworkScreen.kt:686-708): the
/// focused choice (the thumbnail its tile decoded, from the art cache; the PC's box art for the first choice of the cover
/// tab) with its facts and Use this image (what A runs on the tile), and while the filter sheet is open the summary of
/// this tab's filters with the sheet's own reset. A view of its own, so the screen's body reads neither the focus nor the
/// sheet.
struct CompanionArtworkPublisher: View {
    let model: ArtworkModel
    let focus: FocusModel
    let actions: ShellActions
    let onReset: @MainActor () -> Void
    @Environment(HomeArt.self) private var art
    @Environment(HostStore.self) private var hosts
    @State private var picture: CGImage?

    /// The focused SteamGridDB image; nil: the first choice (or nothing of the grid is focused).
    private var image: SteamGridDBImage? {
        model.images?.first { AnyHashable(ArtworkScreen.tileID($0.id)) == focus.focused }
    }

    var body: some View {
        let image = self.image
        let tab = model.tab
        Color.clear
            .frame(width: 0, height: 0)
            .companionPage {
                let inUse = image.map { model.chosen == .image($0.id) } ?? model.noneInUse
                let text = CompanionArtwork.lines(tab: tab, image: image, inUse: inUse)
                return CompanionArtworkPage.page(CompanionArtwork(
                    title: text.title, image: image != nil || tab == .cover ? picture : nil, placeholderRatio: tab.ratio, lines: text.lines,
                    inUse: inUse
                ) { actions.applyArtwork(hostID: model.hostID, app: model.app, tab: tab, image: image) })
            }
            .companionPage {
                guard model.sheetOpen else { return nil }
                let filters = model.filters
                return CompanionFilterPage.page(CompanionFilter(
                    library: false, chips: ArtFilterRules.chips(filters).map(\.label),
                    count: model.images.map { .counting(shown: $0.count, total: model.total, active: filters.active) }, unit: .images,
                    onReset: onReset))
            }
            .task(id: [AnyHashable(image?.id), AnyHashable(tab)]) {
                picture = nil
                if let image {
                    picture = await art.thumbnail(image)
                } else if tab == .cover {
                    picture = await art.boxArt(hostID: model.hostID, appID: model.app.id, hosts: hosts)
                }
            }
    }
}

// MARK: - Filters

/// How many filter chips a filter page shows; the rest is counted ("+2").
let companionFilterChips = 3

/// The sentence about the number of matches (`FilterCount`): "12 of 36 match." / "All 36." / "12 images match." (the
/// total of an artwork list is not always known).
enum CompanionFilterCount: Hashable, Sendable {
    case of(shown: Int, total: Int)
    case all(total: Int)
    case matching(shown: Int)

    /// Which sentence tells [shown] of [total] while the filters are [active]; [total] nil: only [shown] is said.
    static func counting(shown: Int, total: Int?, active: Bool) -> CompanionFilterCount {
        if !active { return .all(total: total ?? shown) }
        if let total { return .of(shown: shown, total: total) }
        return .matching(shown: shown)
    }
}

/// What a filter sheet counts.
enum CompanionFilterUnit: Hashable, Sendable { case games, images }

/// The summary of a filter sheet that is open on the main display (`FilterPage`, CompanionContentPages.kt:45-80).
struct CompanionFilter: Hashable {
    let library: Bool
    /// The labels of the filters that are set.
    let chips: [String]
    let count: CompanionFilterCount?
    let unit: CompanionFilterUnit
    /// What the sheet's Reset runs, for this list only; the sheet stays open.
    let onReset: @MainActor () -> Void

    static func == (a: CompanionFilter, b: CompanionFilter) -> Bool {
        a.library == b.library && a.chips == b.chips && a.count == b.count && a.unit == b.unit
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(library)
        hasher.combine(chips)
        hasher.combine(count)
    }

    /// The count in words, nil without one.
    var countText: String? {
        switch count {
        case nil: nil
        case let .of(shown, total)?: LPlural(unit == .games ? "companion_filter_games_of" : "companion_filter_images_of", shown, total)
        case let .all(total)?: LPlural(unit == .games ? "companion_filter_games_all" : "companion_filter_images_all", total)
        case let .matching(shown)?: LPlural("companion_filter_images_some", shown)
        }
    }

    /// Reset filters: primary and live while a filter is set, dimmed and disabled when none is (`filterResetAction`).
    static func resetAction(label: String, active: Bool, onReset: @escaping @MainActor () -> Void) -> PageAction {
        PageAction(label: label, style: active ? .primary : .normal, enabled: active, run: onReset)
    }

    /// The labels of the library's active filters (`libraryFilterLabels`, FilterModal.kt:132-141): genre, theme, HDR, length.
    static func libraryLabels(_ filters: MetadataFilters, genres: [GameGenre], themes: [GameGenre]) -> [String] {
        var labels: [String] = []
        if let id = filters.genreID {
            labels.append(genres.first { $0.id == id }.map(TagLook.genreName) ?? L("filters_section_genre"))
        }
        if let id = filters.themeID {
            labels.append(themes.first { $0.id == id }.map(TagLook.themeName) ?? L("filters_section_theme"))
        }
        if filters.hdr != .any { labels.append(LibraryFilter.hdrLabel(filters.hdr)) }
        if filters.length != .any { labels.append(LibraryFilter.lengthLabel(filters.length)) }
        return labels
    }
}

/// The filter page; wins over the screen under the sheet (priority modal): the sheet is what the user is changing.
enum CompanionFilterPage {
    static func page(_ filter: CompanionFilter) -> CompanionPage {
        CompanionPage(key: filter.library ? "filter/library" : "filter/artwork", priority: PagePriority.modal, revision: filter) {
            CompanionFilterCard(filter: filter)
        }
    }
}

private struct CompanionFilterCard: View {
    let filter: CompanionFilter
    @Environment(\.delosColors) private var colors

    var body: some View {
        PageCard { fit in
            PageHeading(
                icon: Symbols.filter, title: L(filter.library ? "companion_filter_library_title" : "companion_filter_art_title"),
                subtitle: L("companion_filter_sub"))
            if let count = filter.countText { BodyText(count, color: colors.accent2) }
            let labels = CompanionFit.chips(
                filter.chips, maxItems: companionFilterChips, width: fit.budget.innerWidth, metrics: fit.metrics) { L("companion_filter_more", $0) }
            ChipRow(labels: labels.isEmpty ? [L("companion_filter_none")] : labels)
            BodyText(L("companion_filter_change_main"), color: colors.text2).optional(60)
            Filler()
            ActionRow(actions: [CompanionFilter.resetAction(label: L("filters_art_reset"), active: !filter.chips.isEmpty, onReset: filter.onReset)])
        }
    }
}

// MARK: - Profile

/// Which sentence says what a profile has changed (`ProfileLine`): none while the counts are unknown.
enum CompanionProfileLine: Hashable, Sendable {
    case unknown, defaults, settings, overrides, both

    static func of(settings: Int?, overrides: Int?) -> CompanionProfileLine {
        guard let settings, let overrides else { return .unknown }
        if settings > 0, overrides > 0 { return .both }
        if settings > 0 { return .settings }
        if overrides > 0 { return .overrides }
        return .defaults
    }

    /// The number of stored settings of [settings] that differ from the defaults (`customSettingCount`). Android compares
    /// the catalog's keys with their defaults; here the profile's ``StreamSettings`` are compared with a new one's, field by
    /// field (a stored dictionary of settings counts by its entries).
    static func customCount(_ settings: StreamSettings) -> Int {
        guard let now = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(StreamSettings())) as? [String: Any] else { return 0 }
        return differences(now, base)
    }

    private static func differences(_ a: [String: Any], _ b: [String: Any]) -> Int {
        Set(a.keys).union(b.keys).reduce(0) { sum, key in
            switch (a[key], b[key]) {
            case let (x as [String: Any], y as [String: Any]): sum + differences(x, y)
            case let (x as [String: Any], nil): sum + x.count
            case let (x?, y?): sum + ((x as AnyObject).isEqual(y) ? 0 : 1)
            case (nil, nil): sum
            default: sum + 1
            }
        }
    }
}

/// What the profile page shows (`ProfilePage`, CompanionContentPages.kt:108-139).
struct CompanionProfile: Hashable, Sendable {
    let name: String
    let avatar: Int
    /// The custom settings and the apps with overrides; nil while they are counted.
    let settings: Int?
    let overrides: Int?
    let defaultPC: String?
}

/// The current profile: avatar, name, what it changed and the default PC. Read-only: edits stay on the main display.
enum CompanionProfilePage {
    static func page(_ profile: CompanionProfile) -> CompanionPage {
        CompanionPage(key: "profile", revision: profile) { CompanionProfileCard(profile: profile) }
    }
}

/// The avatar of the profile pages, stage pixels.
private let companionAvatarSize = 100.0

private struct CompanionProfileCard: View {
    let profile: CompanionProfile
    @Environment(\.delosColors) private var colors

    var body: some View {
        PageCard { fit in
            let b = fit.budget
            let title = CompanionFit.title(profile.name, alias: L("companion_screen_profile"), width: b.innerWidth - PageHeading.chrome, metrics: fit.metrics)
            PageHeading(icon: Symbols.accountCircle, title: title, subtitle: L("companion_profile_current"))
            AvatarBadge(avatar: .of(profile.avatar), size: companionAvatarSize, iconSize: companionAvatarSize / 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .optional(40)
            let settings = LPlural("companion_profile_settings", profile.settings ?? 0)
            let overrides = LPlural("companion_profile_overrides", profile.overrides ?? 0)
            let text: String? = switch CompanionProfileLine.of(settings: profile.settings, overrides: profile.overrides) {
            case .unknown: nil
            case .defaults: L("companion_profile_defaults")
            case .settings: L("companion_profile_line_one", settings)
            case .overrides: L("companion_profile_line_one", overrides)
            case .both: L("companion_profile_line_both", settings, overrides)
            }
            if let text, fit.metrics.lines(text, width: b.innerWidth) <= b.bodyLines { BodyText(text).optional(60) }
            if let pc = profile.defaultPC.map({ L("companion_profile_default_pc", $0) }), fit.metrics.lines(pc, width: b.innerWidth) <= 1 {
                BodyText(pc, color: colors.text2).optional(50)
            }
            Filler()
            BodyText(L("companion_profile_edit_main"), color: colors.accent).optional(30)
        }
    }
}

extension View {
    /// Publishes the current profile (`ProfileScreen.kt:75-85`): its settings and overrides counted once per profile, off
    /// the main thread; the default PC by its name.
    func companionProfile(_ profile: Profile, actions: ShellActions) -> some View {
        modifier(CompanionProfilePublisher(profile: profile, actions: actions))
    }
}

private struct CompanionProfilePublisher: ViewModifier {
    let profile: Profile
    let actions: ShellActions
    @State private var counts: (settings: Int, overrides: Int)?

    func body(content: Content) -> some View {
        content
            .companionPage {
                let pc = actions.profiles.startup.defaultPC.flatMap { actions.hosts.host($0)?.name }
                return CompanionProfilePage.page(CompanionProfile(
                    name: profile.name, avatar: profile.avatar, settings: counts?.settings, overrides: counts?.overrides, defaultPC: pc))
            }
            .task(id: profile.id) {
                counts = nil
                let id = profile.id
                let streams = actions.streams, games = actions.gameSettings
                let hosts = actions.hosts.hosts.map(\.id)
                counts = await Task.detached(priority: .utility) {
                    let settings = CompanionProfileLine.customCount(streams.load(profile: id))
                    let overrides = hosts.reduce(0) { $0 + games.customApps(profile: id, hostID: $1).count }
                    return (settings: settings, overrides: overrides)
                }.value
            }
    }
}

// MARK: - Create profile

/// The profile being created or edited as it is on the main display (`CreateProfilePage`): a draft, nothing is saved.
enum CompanionCreateProfilePage {
    static func page(name: String, avatar: Int) -> CompanionPage {
        CompanionPage(key: "create-profile", revision: [AnyHashable(name), AnyHashable(avatar)]) {
            CompanionCreateProfileCard(name: name, avatar: avatar)
        }
    }
}

private struct CompanionCreateProfileCard: View {
    let name: String
    let avatar: Int
    @Environment(\.delosColors) private var colors

    var body: some View {
        PageCard { fit in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            let shown = trimmed.isEmpty ? L("firstrun_create_name_placeholder") : trimmed
            let title = CompanionFit.title(
                shown, alias: L("companion_screen_create_profile"), width: fit.budget.innerWidth - PageHeading.chrome, metrics: fit.metrics)
            PageHeading(icon: Symbols.accountCircle, title: title, subtitle: L("companion_create_draft"))
            AvatarBadge(avatar: .of(avatar), size: companionAvatarSize, iconSize: companionAvatarSize / 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .optional(40)
            BodyText(L("companion_create_choose"), color: colors.text)
            BodyText(L("companion_create_no_account"), color: colors.text2).optional(50)
            Filler()
            BodyText(L("companion_profile_edit_main"), color: colors.accent).optional(30)
        }
    }
}

// MARK: - Boot

/// The first run's welcome (`BootPage`): what the second screen is for and the one step to take on the main display, with
/// the real hints (B only when Boot can go back).
enum CompanionBootPage {
    static func page(canGoBack: Bool) -> CompanionPage {
        CompanionPage(key: "boot", revision: canGoBack) { CompanionBootCard(canGoBack: canGoBack) }
    }

    /// The hints of Boot (`bootHints`): A begins, B goes back only when Boot was opened from another screen.
    static func hints(canGoBack: Bool, begin: String, back: String) -> [CompanionHint] {
        [CompanionHint(button: .pad(.south), label: begin)] + (canGoBack ? [CompanionHint(button: .pad(.east), label: back)] : [])
    }
}

private struct CompanionBootCard: View {
    let canGoBack: Bool
    @Environment(\.delosColors) private var colors

    var body: some View {
        PageCard { fit in
            let b = fit.budget
            PageHeading(icon: Symbols.info, title: L("companion_screen_boot"), subtitle: L("companion_boot_sub"))
            BodyText(CompanionFit.summary(
                L("companion_boot_text"), short: L("companion_purpose_boot"), maxLines: b.bodyLines, width: b.innerWidth, metrics: fit.metrics,
                last: L("companion_see_main")), color: colors.text)
            Filler()
            HintList(hints: CompanionBootPage.hints(canGoBack: canGoBack, begin: L("companion_boot_hint_begin"), back: L("shell_hint_back")), rest: 0)
                .optional(70)
        }
    }
}
