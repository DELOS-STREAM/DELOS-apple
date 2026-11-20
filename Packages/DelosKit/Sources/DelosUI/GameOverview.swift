import DelosData
import DelosHost
import DelosInput
import SwiftUI

/// One opening of the game overview (variant A · Descent, DELOS-android#107): the dashboard continues downward into the
/// game's page. Owned by ``HomeScreen``; [flight] runs the shared-element cover from the card (0) to the header (1) and
/// back, [shown] drives everything else that moves with it (the other covers lifting away, the page rising, the
/// sections' staggered entrance). The overview takes input from its first frame.
@MainActor
@Observable
final class OverviewSession {
    enum Phase: Equatable { case opening, open, closing }

    let hostID: String
    let app: HostApp
    /// The library's focus id of the game's cover, which keeps the focus underneath.
    let coverID: AnyHashable
    /// The card's frame where the flight starts and ends (the home's space, points, as it shows: focused and dragged).
    var source: CGRect
    var phase = Phase.opening
    var flight = 0.0
    var shown = false
    /// The flight has landed: the header's own cover shows instead of the flying one.
    var landed = false
    /// The ratings fill and count up.
    var ratingsOn = false
    /// The details' lookup has finished (the page says "not available" instead of "loading" when none came).
    var detailsSettled = false
    /// The viewer's last step: 1 to the next item, -1 to the previous one (the side the new picture comes from).
    var viewerDirection = 1.0
    /// B asked the viewer to close (it zooms back into the thumbnail first).
    var viewerClosing = false
    /// The streaming section's numbers have counted up.
    var streamingOn = false
    var details: GameDetails?
    /// Back came while the overview was still opening: it closes once open.
    @ObservationIgnored var closeWhenOpen = false
    let focus = FocusModel(initial: OverviewNavigation.initialFocus)
    let ring = OverviewRing()
    /// The screenshot viewer's item, nil when it is closed.
    var viewer: Int?
    /// The page's scroll position (page pixels, points) and the request to scroll it.
    var scroll = 0.0
    var position = ScrollPosition(y: 0)
    /// The focused screenshot or video, for the backdrop.
    var mediaFocus: Int?
    /// Frames (in the page's space) of the sections and items, for the focus scroll.
    @ObservationIgnored var sectionFrames: [String: CGRect] = [:]
    /// The thumbnails' frames in the home's space, for the viewer's zoom.
    @ObservationIgnored var thumbFrames: [Int: CGRect] = [:]
    var storyOpen = false

    init(hostID: String, app: HostApp, coverID: AnyHashable, source: CGRect, details: GameDetails?) {
        self.hostID = hostID
        self.app = app
        self.coverID = coverID
        self.source = source
        self.details = details
    }
}

extension EnvironmentValues {
    /// The overview's descent as the dashboard sees it: whether it is open (the other covers lift away, the info rises) and
    /// which game's card is flying (hidden in the row meanwhile).
    @Entry var overviewDescent = OverviewDescent()
    /// Opens the overview from the dashboard (the hint, a swipe of the cover).
    @Entry var overviewLauncher: OverviewLauncher?
}

struct OverviewDescent: Equatable {
    var active = false
    /// The app whose card is in the overview.
    var appID: Int?
}

/// What the dashboard's covers and hint ask of the overview: open it for a game, and the finger's drag of the focused
/// cover (swipe up), which the cover follows with resistance before the flight starts from where the finger left it.
@MainActor
@Observable
final class OverviewLauncher {
    var dragApp: Int?
    var dragOffset = 0.0
    @ObservationIgnored var open: (HostApp, Double) -> Void = { _, _ in }
    @ObservationIgnored var canOpen: (HostApp) -> Bool = { _ in false }

    /// A drag of [app]'s focused cover moved by [translation] (points).
    func drag(_ app: HostApp, translation: CGSize, slop: CGFloat) {
        guard canOpen(app), translation.height < 0 || dragApp == app.id else { return }
        guard dragApp == app.id || (abs(translation.height) > slop && abs(translation.height) > abs(translation.width)) else { return }
        dragApp = app.id
        dragOffset = OverviewMotion.swipeFollow(translation.height)
    }

    /// The drag ended: far enough up opens the overview from there, else the cover springs back.
    func end(_ app: HostApp, translation: CGSize, threshold: CGFloat) {
        guard dragApp == app.id else { return }
        if -translation.height > threshold {
            open(app, dragOffset)
            dragOffset = 0
            dragApp = nil
        } else {
            withAnimation(Motion.spring(500)) { dragOffset = 0 }
            dragApp = nil
        }
    }
}

/// The overview's page: the header (the cover beside the eyebrow, the title, tags and HDR, the rings with the age rating,
/// Play and App settings, the streaming time and HowLongToBeat), then About, Screenshots and videos, Details, Your
/// streaming, Links, Similar games and the data credit. Everything moves up together; scrolling deepens the hero's blur,
/// drifts it slower than the page and zooms it slightly.
struct GameOverview: View {
    let session: OverviewSession
    let actions: ShellActions
    let library: [HostApp]
    let onClose: () -> Void
    let onJump: (HostApp) -> Void
    /// The library's focus model (Play offers the running game's menu through it, on the cover that keeps the focus).
    let libraryFocus: FocusModel
    @Environment(GameMetadataModel.self) private var metadata
    @Environment(HomeArt.self) private var art
    @Environment(HostStore.self) private var hosts
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.openURL) private var openURL

    private var kind: InputKind { ControllerGlyphs.shared.kind }

    var body: some View {
        let content = session.details.map { OverviewContent(details: $0, library: library, region: Locale.current.region?.identifier) }
        ZStack(alignment: .topLeading) {
            OverviewBackdrop(session: session, content: content)
            page(content)
                .opacity(session.shown ? 1 : 0)
                .offset(y: session.shown || reduced ? 0 : stage.px(OverviewMotion.pageRise))
            if kind == .touch || kind == .pointer {
                backButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: session.app.id) {
            // The details come from the cache, else they are fetched now; the first thumbnails and the first full
            // screenshot are fetched while the overview opens
            if session.details == nil, let details = await metadata.loadDetails(session.app) {
                withAnimation(.easeOut(duration: 0.3)) { session.details = details }
            }
            session.detailsSettled = true
            if let content = session.details.map({ OverviewContent(details: $0, library: library, region: nil) }) {
                let tall = stage.height > 1200
                for media in content.media.prefix(2) { if let url = OverviewImageSizes.thumb(media, tall: tall) { _ = await metadata.images.data(url) } }
                if let first = content.media.first(where: { $0.kind == .screenshot }), let url = OverviewImageSizes.full(first, tall: tall) {
                    _ = await metadata.images.data(url)
                }
            }
        }
    }

    // MARK: Page

    private func page(_ content: OverviewContent?) -> some View {
        let side = 150 + stage.safe.leading
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header(content)
                if let content {
                    ForEach(Array(content.sections.enumerated()), id: \.element) { index, section in
                        sectionView(section, content: content)
                            .padding(.top, stage.px(70))
                            .modifier(Rise(index: 9 + index, delay: 260, shown: session.shown))
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(OverviewRing.space)) } action: {
                                session.sectionFrames[section.rawValue] = $0
                            }
                    }
                    credit.padding(.top, stage.px(80))
                }
            }
            .padding(.leading, stage.px(side))
            .padding(.trailing, stage.px(150 + stage.safe.trailing))
            .padding(.bottom, stage.px(220))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overviewRingHost(session.ring, hidden: kind == .touch || session.viewer != nil || !session.shown)
        }
        .scrollPosition(Binding(get: { session.position }, set: { session.position = $0 }))
        .onGeometryChange(for: Double.self) { $0.frame(in: .global).minY } action: { globalTop = $0 }
        .onScrollGeometryChange(for: Double.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, now in
            session.scroll = now
        }
        .onScrollPhaseChange { old, now in
            // Pulling the page down at its top closes the overview
            if old == .interacting, now != .interacting, -session.scroll > stage.px(OverviewMotion.pullClose) { onClose() }
        }
        // The page fades out under the status bar and at the bottom (`.a-view`'s mask)
        .mask {
            GeometryReader { proxy in
                let h = max(proxy.size.height, 1)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .clear, location: stage.px(70) / h),
                    .init(color: .black, location: stage.px(140) / h), .init(color: .black, location: 1 - stage.px(60) / h),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .onChange(of: session.focus.focused) { _, now in focused(now, content: content) }
        .environment(\.focusReveal, nil)
    }

    /// The focus moved: the page scrolls the focused section to its line (the header to the top), a screenshot crossfades
    /// the backdrop to it, the streaming numbers count up when their section comes into view.
    private func focused(_ id: AnyHashable?, content: OverviewContent?) {
        guard let id = id as? String, content != nil else { return }
        let section = sectionOf(id)
        if section == .streaming, !session.streamingOn {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                session.streamingOn = true
            }
        }
        session.mediaFocus = id.hasPrefix("ov-media-") ? Int(id.dropFirst("ov-media-".count)) : nil
        guard kind != .pointer, kind != .touch else { return }
        let k = max(stage.scale, 0.01)
        let frame = session.focus.registeredFrames[AnyHashable(id)]
        let target: Double
        if let section, let sectionFrame = session.sectionFrames[section.rawValue] {
            // Stage pixels: the section's frame is in the page's own space, the item's is global (moved by the scroll)
            let itemTop = frame.map { ($0.minY - globalTop + session.scroll) / k } ?? sectionFrame.minY / k
            target = OverviewNavigation.scrollTarget(
                header: false, sectionTop: sectionFrame.minY / k, sectionHeight: sectionFrame.height / k,
                itemTop: itemTop, itemHeight: (frame?.height ?? 0) / k, viewport: stage.height, maximum: .infinity, current: session.scroll / k)
        } else {
            target = 0
        }
        let scroll = { session.position.scrollTo(y: stage.px(target)) }
        if reduced { scroll() } else { withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.62)) { scroll() } }
    }

    /// The page's viewport top in global points.
    @State private var globalTop = 0.0

    private func sectionOf(_ id: String) -> OverviewContent.Section? {
        switch id {
        case OverviewNavigation.play, OverviewNavigation.settings: nil
        case OverviewNavigation.summary, OverviewNavigation.story, OverviewNavigation.facts: .about
        case OverviewNavigation.details: .details
        case OverviewNavigation.streaming: .streaming
        default:
            if id.hasPrefix("ov-media-") { .media } else if id.hasPrefix("ov-link-") { .links } else if id.hasPrefix("ov-similar-") { .similar } else { nil }
        }
    }

    // MARK: Header

    private func header(_ content: OverviewContent?) -> some View {
        let data = metadata.data(for: session.app)
        let playtime = actions.playtime(hostID: session.hostID, appID: session.app.id)
        let texts = PlaytimeTexts(playtime)
        let completion = data?.completionSeconds.map(CompletionLength.init(seconds:))
        let genres = GameTags.topGenres(data?.candidate?.genres.filter { !$0.name.isEmpty } ?? [], steamTags: data?.steamTags ?? [])
        let themes = GameTags.topThemes(data?.candidate?.themes.filter { !$0.name.isEmpty } ?? [], steamTags: data?.steamTags ?? [])
        let ages = content?.ageRatings ?? []
        return ZStack(alignment: .bottom) {
            HStack(alignment: .top, spacing: stage.px(72)) {
                OverviewCover(session: session)
                VStack(alignment: .leading, spacing: stage.px(24)) {
                    if let eyebrow = content?.eyebrow {
                        Text(eyebrow.uppercased())
                            .font(DelosFonts.figtree(stage.tpx(15), .bold)).tracking(stage.px(15 * 0.16))
                            .foregroundStyle(colors.accent.color)
                            .modifier(Rise(index: 0, delay: 260, shown: session.shown))
                    }
                    OverviewTitle(session: session)
                    WrapLayout(spacing: stage.px(10), lineSpacing: stage.px(10)) {
                        ForEach(genres.prefix(2), id: \.id) { OverviewTag(icon: TagLook.genreIcon($0.id), label: TagLook.genreName($0), genre: true) }
                        ForEach(themes.prefix(2), id: \.id) { OverviewTag(icon: TagLook.themeIcon($0.id), label: TagLook.themeName($0)) }
                        switch data?.hdrBadge {
                        case .hdr?: NativeHDRChip()
                        case .sdr?: InfoChip(icon: Symbols.sdr, label: "SDR")
                        case .unknown?: InfoChip(icon: Symbols.hdrUnknown, label: L("metadata_hdr_unverified"))
                        case nil: EmptyView()
                        }
                    }
                    .modifier(Rise(index: 1, delay: 260, shown: session.shown))
                    if let content {
                        HStack(spacing: stage.px(46)) {
                            rating(content.critics, label: L("overview_critics"), color: colors.accent,
                                   sub: content.critics.value == nil ? L("overview_no_critics") : LPlural("overview_reviews", content.critics.count, content.critics.count.formatted()))
                            rating(content.players, label: L("overview_players"), color: colors.accent2,
                                   sub: content.players.value == nil ? L("overview_not_rated_yet")
                                       : content.details.fewRatings ? LPlural("overview_ratings_few", content.players.count, content.players.count.formatted())
                                       : LPlural("overview_ratings", content.players.count, content.players.count.formatted()))
                            AgeBadge(rating: ages.first)
                        }
                        .modifier(Rise(index: 2, delay: 260, shown: session.shown))
                    } else {
                        Text(session.detailsSettled ? L("overview_unavailable") : L("overview_loading"))
                            .font(DelosFonts.figtree(stage.tpx(22))).foregroundStyle(colors.text3.color)
                            .modifier(Rise(index: 2, delay: 260, shown: session.shown))
                    }
                    HStack(spacing: stage.px(20)) {
                        OverviewButton(id: OverviewNavigation.play, focus: session.focus, icon: Symbols.playArrow, label: L("overview_play"), primary: true) {
                            actions.activate(hostID: session.hostID, app: session.app, focus: libraryFocus)
                        }
                        OverviewButton(id: OverviewNavigation.settings, focus: session.focus, icon: Symbols.settings, label: L("home_menu_settings"), primary: false) {
                            actions.navigator.push(.appSettings(hostID: session.hostID, appID: session.app.id), focus: GameSettingsScreen.firstFocus())
                        }
                    }
                    .modifier(Rise(index: 3, delay: 260, shown: session.shown))
                    HStack(spacing: stage.px(36)) {
                        statColumn(eyebrow: texts.eyebrowTime, accent: true) {
                            HStack(alignment: .firstTextBaseline, spacing: stage.px(8)) {
                                Text(texts.full.number).font(DelosFonts.figtree(stage.tpx(30), .bold)).monospacedDigit().foregroundStyle(colors.text.color)
                                Text(texts.full.unit).font(DelosFonts.figtree(stage.tpx(20), .semibold)).foregroundStyle(colors.text2.color)
                            }
                        }
                        Rectangle().fill(colors.accent.opacity(0.7).color).frame(width: stage.px(2), height: stage.px(38))
                        statColumn(eyebrow: texts.eyebrowLast, accent: false) {
                            Text(texts.last).font(DelosFonts.figtree(stage.tpx(23), .semibold)).foregroundStyle(colors.text2.color)
                        }
                        if let completion {
                            Rectangle().fill(colors.text3.opacity(0.4).color).frame(width: stage.px(2), height: stage.px(38))
                            statColumn(eyebrow: "HowLongToBeat".uppercased(), accent: false) {
                                Text(TagLook.completionText(completion)).font(DelosFonts.figtree(stage.tpx(23), .semibold)).foregroundStyle(colors.text2.color)
                            }
                        }
                    }
                    .shadow(color: .black.opacity(0.6), radius: stage.px(4), y: stage.px(2))
                    .modifier(Rise(index: 4, delay: 260, shown: session.shown))
                }
                .padding(.top, stage.px(4))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, stage.px(150))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The cue names the page's main sections: About · Media · Details · Similar games
            let cue = content?.sections.compactMap { section -> String? in
                switch section {
                case .media: L("overview_cue_media")
                case .about, .details, .similar: sectionTitle(section)
                case .streaming, .links: nil
                }
            } ?? []
            if !cue.isEmpty {
                HStack(spacing: stage.px(12)) {
                    SymbolView(symbol: Symbols.expandMore, size: 24, color: colors.accent, filled: true)
                    Text(cue.joined(separator: " · "))
                        .font(DelosFonts.figtree(stage.tpx(19), .semibold)).tracking(stage.px(19 * 0.04))
                        .foregroundStyle(colors.text3.color)
                }
                .padding(.bottom, stage.px(18))
                .modifier(Rise(index: 5, delay: 500, shown: session.shown))
            }
        }
        .frame(height: stage.px(stage.height - 160))
    }


    private func statColumn<V: View>(eyebrow: String, accent: Bool, @ViewBuilder value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: stage.px(2)) {
            Text(eyebrow).font(DelosFonts.figtree(stage.tpx(13), .bold)).tracking(stage.px(13 * 0.16))
                .foregroundStyle((accent ? colors.accent : colors.text3).color)
            value()
        }
    }

    private func rating(_ rating: OverviewContent.Rating, label: String, color: RGBA, sub: String) -> some View {
        HStack(spacing: stage.px(18)) {
            RatingRing(value: rating.value, size: 104, color: color, active: session.ratingsOn)
            VStack(alignment: .leading, spacing: stage.px(4)) {
                Text(label).font(DelosFonts.figtree(stage.tpx(22), .bold)).foregroundStyle(colors.text.color)
                Text(sub).font(DelosFonts.figtree(stage.tpx(18))).foregroundStyle(colors.text3.color)
            }
        }
        .fixedSize()
    }

    // MARK: Sections

    private func sectionTitle(_ section: OverviewContent.Section) -> String {
        switch section {
        case .about: L("overview_section_about")
        case .media: L("overview_section_media")
        case .details: L("overview_section_details")
        case .streaming: L("overview_section_streaming")
        case .links: L("overview_section_links")
        case .similar: L("overview_section_similar")
        }
    }

    private func sectionIcon(_ section: OverviewContent.Section) -> String {
        switch section {
        case .about: Symbols.info
        case .media: Symbols.photoLibrary
        case .details: Symbols.metadata
        case .streaming: Symbols.timer
        case .links: Symbols.addLink
        case .similar: Symbols.viewCarousel
        }
    }

    @ViewBuilder private func sectionView(_ section: OverviewContent.Section, content: OverviewContent) -> some View {
        VStack(alignment: .leading, spacing: stage.px(28)) {
            HStack(spacing: stage.px(14)) {
                SymbolView(symbol: sectionIcon(section), size: 32, color: colors.accent2)
                Text(sectionTitle(section)).font(DelosFonts.unbounded(stage.tpx(30), .semibold)).foregroundStyle(colors.text.color)
                if section == .media {
                    Text("\(content.media.count)").font(DelosFonts.figtree(stage.tpx(15), .bold)).foregroundStyle(colors.text3.color)
                        .padding(.leading, stage.px(6))
                }
            }
            switch section {
            case .about: about(content)
            case .media: OverviewCarousel(session: session, media: content.media)
            case .details: detailsCard(content)
            case .streaming: streamingCard(content)
            case .links: links(content)
            case .similar: similar(content)
            }
        }
    }

    private func about(_ content: OverviewContent) -> some View {
        HStack(alignment: .top, spacing: stage.px(56)) {
            VStack(alignment: .leading, spacing: 0) {
                if let summary = content.details.summary {
                    OverviewFocusable(id: OverviewNavigation.summary, focus: session.focus, corner: 18, pad: 14, scale: 1) {
                        Text(summary).font(DelosFonts.figtree(stage.tpx(28))).lineSpacing(stage.px(28 * 0.5) - stage.px(6))
                            .foregroundStyle(colors.text.color)
                            .fixedSize(horizontal: false, vertical: true)
                    } action: {}
                }
                if let story = content.details.storyline {
                    Text(story).font(DelosFonts.figtree(stage.tpx(25))).lineSpacing(stage.px(25 * 0.5) - stage.px(6))
                        .foregroundStyle(colors.text2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, stage.px(22))
                        .frame(height: session.storyOpen ? nil : 0, alignment: .top)
                        .clipped()
                        .opacity(session.storyOpen ? 1 : 0)
                    OverviewFocusable(id: OverviewNavigation.story, focus: session.focus, corner: 26, pad: 0, scale: 1.06) {
                        HStack(spacing: stage.px(10)) {
                            SymbolView(symbol: Symbols.expandMore, size: 24, color: colors.text)
                                .rotationEffect(.degrees(session.storyOpen ? 180 : 0))
                            Text(session.storyOpen ? L("overview_show_less") : L("overview_read_story"))
                                .font(DelosFonts.figtree(stage.tpx(20), .bold)).foregroundStyle(colors.text.color)
                        }
                        .padding(.horizontal, stage.px(22))
                        .frame(height: stage.px(52))
                        .background(Capsule().fill(Color.white.opacity(0.06)).overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1))))
                    } action: {
                        withAnimation(reduced ? .easeOut(duration: 0.28) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.6)) { session.storyOpen.toggle() }
                    }
                    .padding(.top, stage.px(26))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !content.facts.isEmpty {
                OverviewFocusable(id: OverviewNavigation.facts, focus: session.focus, corner: 34, pad: 8, scale: 1) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: stage.px(28), verticalSpacing: stage.px(16)) {
                        ForEach(content.facts, id: \.label) { fact in
                            GridRow {
                                Text(fact.label.uppercased()).font(DelosFonts.figtree(stage.tpx(17), .semibold)).tracking(stage.px(1.7))
                                    .foregroundStyle(colors.text3.color)
                                (Text(fact.value).foregroundStyle(colors.text.color)
                                    + Text(fact.note.map { " · \($0)" } ?? "").foregroundStyle(colors.text3.color).font(DelosFonts.figtree(stage.tpx(18), .medium)))
                                    .font(DelosFonts.figtree(stage.tpx(21), .semibold))
                            }
                        }
                    }
                    .padding(.horizontal, stage.px(40))
                    .padding(.vertical, stage.px(36))
                    .frame(width: stage.px(560), alignment: .leading)
                    .background(OverviewCard())
                } action: {}
            }
        }
    }

    private func detailsCard(_ content: OverviewContent) -> some View {
        let candidate = metadata.data(for: session.app)?.candidate
        return OverviewFocusable(id: OverviewNavigation.details, focus: session.focus, corner: 34, pad: 8, scale: 1) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: stage.px(64), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: stage.px(30)) {
                ForEach(content.groups, id: \.kind) { group in
                    VStack(alignment: .leading, spacing: stage.px(12)) {
                        Text(groupTitle(group.kind).uppercased()).font(DelosFonts.figtree(stage.tpx(15), .bold)).tracking(stage.px(15 * 0.16))
                            .foregroundStyle(colors.text3.color)
                        if group.kind == .ageRatings {
                            WrapLayout(spacing: stage.px(28), lineSpacing: stage.px(12)) {
                                ForEach(content.ageRatings, id: \.organization) { AgeBadge(rating: $0) }
                            }
                        } else {
                            WrapLayout(spacing: stage.px(10), lineSpacing: stage.px(10)) {
                                ForEach(group.values, id: \.self) { value in
                                    OverviewTag(icon: groupIcon(group.kind, value, candidate: candidate), label: value, genre: group.kind == .genres)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, stage.px(40))
            .padding(.vertical, stage.px(36))
            .background(OverviewCard())
        } action: {}
    }

    private func groupTitle(_ kind: OverviewContent.DetailGroup.Kind) -> String {
        switch kind {
        case .genres: L("overview_detail_genres")
        case .themes: L("overview_detail_themes")
        case .modes: L("overview_detail_modes")
        case .perspectives: L("overview_detail_perspective")
        case .platforms: L("overview_detail_platforms")
        case .ageRatings: L("overview_detail_age")
        case .multiplayer: L("overview_detail_multiplayer")
        case .languages: L("overview_detail_languages")
        case .keywords: L("overview_detail_keywords")
        }
    }

    private func groupIcon(_ kind: OverviewContent.DetailGroup.Kind, _ value: String, candidate: MetadataCandidate?) -> String? {
        switch kind {
        case .genres: candidate?.genres.first { OverviewContent.genreName($0.name) == value }.map { TagLook.genreIcon($0.id) } ?? Symbols.genreUnknown
        case .themes: candidate?.themes.first { $0.name == value }.map { TagLook.themeIcon($0.id) } ?? Symbols.genreUnknown
        case .modes: value.contains("player") && !value.contains("Multi") ? Symbols.accountCircle : Symbols.group
        case .perspectives: Symbols.visibility
        case .platforms: value == "PC" ? Symbols.desktopWindows : value == "Mac" ? Symbols.monitor : Symbols.sportsEsports
        case .multiplayer: Symbols.group
        case .languages: Symbols.language
        case .keywords, .ageRatings: nil
        }
    }

    private func streamingCard(_ content: OverviewContent) -> some View {
        let playtime = actions.playtime(hostID: session.hostID, appID: session.app.id)
        let texts = PlaytimeTexts(playtime)
        let hours = Double(playtime.totalSeconds) / 3600
        let completion = metadata.data(for: session.app)?.completionSeconds
        let share = OverviewContent.completionShare(streamedSeconds: playtime.totalSeconds, completionSeconds: completion)
        let running = hosts.host(session.hostID).map { $0.runningAppID == session.app.id } ?? false
        let on = session.streamingOn
        return OverviewFocusable(id: OverviewNavigation.streaming, focus: session.focus, corner: 34, pad: 8, scale: 1) {
            HStack(alignment: .bottom, spacing: stage.px(48)) {
                VStack(alignment: .leading, spacing: 0) {
                    eyebrow(texts.eyebrowTime, accent: true)
                    HStack(alignment: .firstTextBaseline, spacing: stage.px(10)) {
                        CountUpText(value: on ? hours : 0, decimals: hours < 10 ? 1 : 0, font: DelosFonts.unbounded(stage.tpx(54), .bold), color: colors.text.color)
                            .animation(reduced ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: OverviewMotion.ratings / 1000), value: on)
                        Text(LPlural("playtime_unit_hours", max(Int(hours.rounded()), 2))).font(DelosFonts.figtree(stage.tpx(24), .semibold)).foregroundStyle(colors.text2.color)
                    }
                    note(L("overview_streaming_note"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    eyebrow(texts.eyebrowLast, accent: false)
                    Text(texts.last).font(DelosFonts.unbounded(stage.tpx(40), .bold)).foregroundStyle(colors.text.color)
                    note(running ? L("overview_running_on", hosts.host(session.hostID)?.name ?? "") : " ")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let completion, let share {
                    VStack(alignment: .leading, spacing: 0) {
                        eyebrow(L("overview_hltb_all"), accent: false)
                        Text(TagLook.completionText(CompletionLength(seconds: completion))).font(DelosFonts.unbounded(stage.tpx(40), .bold)).foregroundStyle(colors.text.color)
                        FillBar(value: share, active: on).padding(.top, stage.px(18))
                        note(L("overview_hltb_share", "\(texts.full.number) \(texts.full.unit)", share))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, stage.px(40))
            .padding(.vertical, stage.px(36))
            .background(OverviewCard())
        } action: {}
    }

    private func eyebrow(_ text: String, accent: Bool) -> some View {
        Text(text.uppercased()).font(DelosFonts.figtree(stage.tpx(15), .bold)).tracking(stage.px(15 * 0.16))
            .foregroundStyle((accent ? colors.accent : colors.text3).color)
            .padding(.bottom, stage.px(8))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(DelosFonts.figtree(stage.tpx(19))).foregroundStyle(colors.text3.color).padding(.top, stage.px(14)).lineLimit(1)
    }

    private func links(_ content: OverviewContent) -> some View {
        WrapLayout(spacing: stage.px(18), lineSpacing: stage.px(18)) {
            ForEach(Array(content.links.enumerated()), id: \.element.id) { index, link in
                OverviewFocusable(id: OverviewNavigation.link(index), focus: session.focus, corner: 32, pad: 0, scale: 1.05) {
                    HStack(spacing: stage.px(14)) {
                        SymbolView(symbol: linkIcon(link.kind), size: 28, color: colors.accent2)
                        Text(linkName(link)).font(DelosFonts.figtree(stage.tpx(21), .semibold)).foregroundStyle(colors.text.color)
                        SymbolView(symbol: Symbols.arrowForward, size: 20, color: colors.text3)
                    }
                    .padding(.horizontal, stage.px(24))
                    .frame(height: stage.px(64))
                    .background(Capsule().fill(Color.white.opacity(0.06)).overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1))))
                } action: {
                    openURL(link.url)
                }
            }
        }
    }

    private func linkIcon(_ kind: OverviewContent.Link.Kind) -> String {
        switch kind {
        case .steam: Symbols.steam
        case .twitch, .youtube: Symbols.movie
        case .wikipedia: Symbols.library
        case .gog, .epic: Symbols.download
        case .official, .discord, .other: Symbols.public
        }
    }

    private func linkName(_ link: OverviewContent.Link) -> String {
        switch link.kind {
        case .official: L("overview_official_site")
        case .steam: "Steam"
        case .gog: "GOG"
        case .epic: "Epic Games Store"
        case .wikipedia: "Wikipedia"
        case .twitch: "Twitch"
        case .youtube: "YouTube"
        case .discord: "Discord"
        case .other: link.typeName ?? link.url.host() ?? link.url.absoluteString
        }
    }

    private func similar(_ content: OverviewContent) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: stage.px(30)) {
                ForEach(Array(content.similar.enumerated()), id: \.element.id) { index, game in
                    OverviewFocusable(id: OverviewNavigation.similar(index), focus: session.focus, corner: 20, pad: 0, scale: 1.06) {
                        SimilarCover(hostID: session.hostID, game: game)
                    } action: {
                        if let app = game.app { onJump(app) } else { actions.toasts.show(L("overview_not_in_library", game.name), icon: Symbols.info) }
                    }
                }
            }
            .padding(.vertical, stage.px(24))
        }
        .scrollClipDisabled()
    }

    private var credit: some View {
        HStack(spacing: stage.px(10)) {
            SymbolView(symbol: Symbols.info, size: 22, color: colors.text3)
            Text(L("overview_credit")).font(DelosFonts.figtree(stage.tpx(17))).foregroundStyle(colors.text3.color)
        }
    }

    private var backButton: some View {
        Button(action: onClose) {
            SymbolView(symbol: Symbols.arrowBack, size: 34, color: colors.text)
                .frame(width: stage.px(72), height: stage.px(72))
                .background(GlassShape(Circle(), tint: colors.surface))
        }
        .buttonStyle(.plain)
        .padding(.leading, stage.px(56 + stage.safe.leading))
        .padding(.top, stage.px(130))
        .opacity(session.shown ? 1 : 0)
        .accessibilityLabel(L("shell_hint_back"))
    }
}

/// A glass card of the overview (`.a-card.glass`): real blur behind it (Liquid Glass, or a material before it).
struct OverviewCard: View {
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(34), style: .continuous)
        ZStack {
            if #available(iOS 26, tvOS 26, macOS 26, *) {
                GlassShape(shape, tint: RGBA(red: 22 / 255, green: 32 / 255, blue: 60 / 255, alpha: 0.46), role: .panel)
            } else {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color(.sRGB, red: 22 / 255, green: 32 / 255, blue: 60 / 255, opacity: 0.46))
            }
            shape.strokeBorder(Color.white.opacity(0.1), lineWidth: stage.px(1))
        }
        .shadow(color: .black.opacity(0.4), radius: stage.px(40), y: stage.px(30))
    }
}

/// A focusable element of the overview: a ``FocusItem`` of the overview's focus model, with its focus scale and the ring.
/// Touch is focus-first: a tap on an element without the focus only focuses it.
struct OverviewFocusable<Content: View>: View {
    let id: String
    let focus: FocusModel
    let corner: Double
    let pad: Double
    let scale: Double
    @ViewBuilder let content: () -> Content
    let action: () -> Void
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.pressed) private var pressed

    var body: some View {
        FocusItem(id: id, model: focus, action: action, tap: { wasFocused in if wasFocused { action() } }) { focused in
            OverviewFocusLook(focused: focused, corner: corner, pad: pad, scale: scale, content: content)
        }
    }
}

private struct OverviewFocusLook<Content: View>: View {
    let focused: Bool
    let corner: Double
    let pad: Double
    let scale: Double
    let content: () -> Content
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.pressed) private var pressed
    @State private var hovered = false

    var body: some View {
        content()
            .overviewRingTarget(focused: focused, corner: corner, pad: pad, scale: scale)
            .scaleEffect(focusScale(focused: focused && scale > 1, pressed: pressed, focus: scale))
            .brightness(hovered && !focused ? 0.04 : 0)
            .animation(.focusScale(pressed: pressed, reduced: reduced), value: focused)
            .animation(.focusScale(pressed: pressed, reduced: reduced), value: pressed)
            .pointerHover { hovered = $0 }
    }
}

/// Play and App settings (`.btn`): 76 px pills, Play solid in the main color, App settings glass.
private struct OverviewButton: View {
    let id: String
    let focus: FocusModel
    let icon: String
    let label: String
    let primary: Bool
    let action: () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        OverviewFocusable(id: id, focus: focus, corner: 38, pad: 0, scale: 1.06) {
            HStack(spacing: stage.px(14)) {
                SymbolView(symbol: icon, size: 32, color: primary ? colors.onAccent : colors.text, filled: primary)
                Text(label).font(DelosFonts.figtree(stage.tpx(26), .bold)).foregroundStyle((primary ? colors.onAccent : colors.text).color)
            }
            .padding(.horizontal, stage.px(38))
            .frame(height: stage.px(76))
            .background {
                if primary {
                    Capsule().fill(colors.accent.color)
                } else {
                    GlassShape(Capsule(), tint: colors.surface).overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                }
            }
        } action: { action() }
    }
}

/// The staggered entrance (`.st`): 18 px up and in over 420 ms, 46 ms apart (at most 8 steps) after [delay]; leaving, it
/// fades in 240 ms. Reduced motion keeps the fade only.
struct Rise: ViewModifier {
    let index: Int
    let delay: Double
    let shown: Bool
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.stage) private var stage

    func body(content: Content) -> some View {
        let wait = (delay + Double(min(index, Motion.staggerCap)) * Motion.staggerRow) / 1000
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduced ? 0 : stage.px(Motion.rise))
            .animation(shown ? .timingCurve(0.16, 1, 0.3, 1, duration: Motion.rowIn / 1000).delay(reduced ? 0 : wait)
                : .timingCurve(0.5, 0, 0.75, 0, duration: Motion.exit / 1000), value: shown)
    }
}

/// The header's cover: exactly the library card's image (the user's SteamGridDB choice, else the default card art, the
/// same decoded bitmap), shown once the flight has landed; it shrinks a little while the page is pulled down.
struct OverviewCover: View {
    let session: OverviewSession
    @Environment(\.stage) private var stage

    var body: some View {
        let pull = max(-session.scroll, 0) / stage.scale
        CardArt(hostID: session.hostID, app: session.app)
            .frame(width: stage.px(340), height: stage.px(510))
            .clipShape(RoundedRectangle(cornerRadius: stage.px(30), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: stage.px(30), style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: stage.px(1)))
            .shadow(color: .black.opacity(0.7), radius: stage.px(60), y: stage.px(50))
            .scaleEffect(1 - min(pull, 300) / 2400)
            .opacity(session.landed ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// A game's card art, as its library cover shows it: the SteamGridDB cover (playing when animated), else the PC's box
/// art, else the placeholder art with the title.
struct CardArt: View {
    let hostID: String
    let app: HostApp
    @Environment(HomeArt.self) private var art
    @Environment(HostStore.self) private var hosts
    @Environment(\.artMotion) private var artMotion
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var animation: AnimatedSource?
    @State private var animating = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .opacity(animating ? 0 : 1)
                        .overlay {
                            AnimatedArtLayer(source: animation, playing: artMotion,
                                             width: Int(proxy.size.width * displayScale), height: Int(proxy.size.height * displayScale),
                                             covering: $animating)
                        }
                } else {
                    let placeholder = GameArt(hostID: hostID, app: app)
                    PlaceholderArt(hue: placeholder.hue, hue2: placeholder.hue2, icon: placeholder.icon, glyphSize: 320 * proxy.size.width / 300 / 1.13,
                                   glyphRight: -36, glyphTop: 0.24, title: app.title, titleSize: 34 * proxy.size.width / 300,
                                   titleInset: 26, titleBottom: 26, titleFit: false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: "\(app.id)#\(art.artwork.version)") {
            if art.artwork.enabled, let cover = await art.image(hostID: hostID, appID: app.id, kind: .cover) {
                image = cover
                animation = await art.animation(hostID: hostID, app: app, kind: .cover)
            } else if let box = await art.boxArt(hostID: hostID, appID: app.id, hosts: hosts) {
                image = box
            }
        }
    }
}

/// A similar game's cover (`.mini-cover`): the library's card art for a game the player owns, with "In library"; IGDB's
/// cover for one outside the library (the lead's decision), else its name on the placeholder art.
private struct SimilarCover: View {
    let hostID: String
    let game: OverviewContent.Similar
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let app = game.app {
                CardArt(hostID: hostID, app: app)
            } else if let id = game.coverImageID {
                RemoteImage(url: IGDBImage.url(id, size: .coverBig, retina: displayScale > 1), maxPixels: 600)
            } else {
                let art = GameArt(hostID: hostID, app: HostApp(id: Int(game.id % 100_000), title: game.name))
                PlaceholderArt(hue: art.hue, hue2: art.hue2, icon: art.icon, glyphSize: 210, glyphRight: -24, glyphTop: 0.24,
                               title: game.name, titleSize: 22, titleInset: 16, titleBottom: 16, titleFit: true)
            }
            if game.app != nil {
                Text(L("overview_in_library"))
                    .font(DelosFonts.figtree(stage.tpx(15), .bold)).foregroundStyle(colors.accent.color)
                    .padding(.horizontal, stage.px(10)).padding(.vertical, stage.px(4))
                    .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().fill(Color(.sRGB, red: 5 / 255, green: 10 / 255, blue: 20 / 255, opacity: 0.6))))
                    .padding(stage.px(12))
            }
        }
        .frame(width: stage.px(200), height: stage.px(300))
        .clipShape(RoundedRectangle(cornerRadius: stage.px(20), style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.name)
    }
}

/// The title beside the cover (`.a-title`): Unbounded 68 px in the gradient of the dashboard's title, flying in from the
/// dashboard's title box as the overview opens.
private struct OverviewTitle: View {
    let session: OverviewSession
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors
    @Environment(\.reducedMotion) private var reduced

    var body: some View {
        // The dashboard's title sits 562 px to the left, about 70 px higher, in its larger size
        let home = HomeMetrics(stage: stage)
        let dx = home.infoStart - (150 + stage.safe.leading + 340 + 72)
        let dy = home.titleTop + home.titleBox / 2 - 230
        let k = home.titleSize(length: session.app.title.count) / 68
        Text(session.app.title)
            .font(DelosFonts.unbounded(stage.tpx(68), .bold))
            .lineSpacing(0)
            .foregroundStyle(LinearGradient(colors: [colors.text.color, colors.accent2.color], startPoint: UnitPoint(x: 0.5, y: 0.3), endPoint: .bottom))
            .shadow(color: .black.opacity(0.4), radius: stage.px(14), y: stage.px(6))
            .frame(maxWidth: stage.px(1150), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .scaleEffect(session.shown || reduced ? 1 : k, anchor: .leading)
            .offset(x: session.shown || reduced ? 0 : stage.px(dx), y: session.shown || reduced ? 0 : stage.px(dy))
            .opacity(session.shown || !reduced ? 1 : 0)
            .animation(.timingCurve(0.2, 0.9, 0.25, 1, duration: (session.shown ? 720 : 600) / 1000), value: session.shown)
    }
}

/// The hero behind the overview (the prototype's `#backdrop` steered by `linkBackdrop`): sharp at the top, crossfading to
/// a deeply blurred copy as the page scrolls, drifting slower than the page and zooming slightly; a focused screenshot
/// takes the blurred layer's place. Opacity and transforms only: the blur itself is fixed.
private struct OverviewBackdrop: View {
    let session: OverviewSession
    let content: OverviewContent?
    @Environment(HomeArt.self) private var art
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors
    @Environment(\.reducedMotion) private var reduced

    var body: some View {
        let scroll = max(session.scroll, 0) / stage.scale
        let deep = session.mediaFocus != nil ? 1 : min(1, scroll / OverviewMotion.deepBlurScroll)
        let media = session.mediaFocus.flatMap { content?.media.indices.contains($0) == true ? content?.media[$0] : nil }
        // Sized by the screen, never by the pictures (filled pictures are larger than it)
        Color.clear.overlay {
        ZStack {
            if let hero = art.hero?.image {
                Image(decorative: hero, scale: 1).resizable().scaledToFill()
                    .opacity(0.62 * (1 - deep))
                Image(decorative: hero, scale: 1).resizable().scaledToFill()
                    .blur(radius: stage.px(56))
                    .brightness(-0.25)
                    .opacity(media == nil ? deep : 0)
            }
            if let media {
                RemoteImage(url: OverviewImageSizes.thumb(media, tall: false), maxPixels: 640)
                    .blur(radius: stage.px(56))
                    .brightness(-0.25)
                    .id(media.id)
                    .transition(.opacity)
            }
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.42), .init(color: colors.bg.color, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .opacity(0.62 + deep * 0.25)
        }
        }
        .scaleEffect(reduced ? 1 : OverviewMotion.heroZoom(scroll))
        .offset(y: reduced ? 0 : stage.px(OverviewMotion.heroDrift(scroll)))
        .animation(.easeInOut(duration: 0.8), value: media?.id)
        .opacity(session.shown ? 1 : 0)
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.9), value: session.shown)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Screenshots and videos (`.a-track`): a full-bleed carousel of 520 × 292 thumbnails that parallax inside their frames;
/// a focused one grows and the carousel brings it in with 150 px of margin. A opens the viewer.
private struct OverviewCarousel: View {
    let session: OverviewSession
    let media: [OverviewContent.Media]
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced
    @State private var position = ScrollPosition(x: 0)

    var body: some View {
        let side = 150 + stage.safe.leading
        let tall = stage.height > 1200
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: stage.px(26)) {
                ForEach(Array(media.enumerated()), id: \.offset) { index, item in
                    OverviewFocusable(id: OverviewNavigation.media(index), focus: session.focus, corner: 22, pad: 0, scale: 1.06) {
                        thumb(item, tall: tall)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.thumbFrames[index] = $0 }
                    } action: {
                        session.viewer = index
                    }
                    .id(index)
                }
            }
            .padding(.horizontal, stage.px(side))
            .padding(.top, stage.px(24))
            .padding(.bottom, stage.px(30))
        }
        .scrollPosition($position)
        .scrollClipDisabled()
        .padding(.horizontal, -stage.px(side))
        .onChange(of: session.focus.focused) { _, now in
            guard let id = now as? String, id.hasPrefix("ov-media-"), let index = Int(id.dropFirst("ov-media-".count)) else { return }
            reveal(index)
        }
        .onChange(of: session.viewer) { _, now in if let now { reveal(now, animated: false) } }
    }

    private func reveal(_ index: Int, animated: Bool = true) {
        let scroll = { position.scrollTo(id: index, anchor: UnitPoint(x: 0.5, y: 0.5)) }
        if reduced || !animated { scroll() } else { withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.56)) { scroll() } }
    }

    private func thumb(_ item: OverviewContent.Media, tall: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(22), style: .continuous)
        return ZStack(alignment: .bottomLeading) {
            // The picture is wider than its frame and moves against the carousel
            RemoteImage(url: OverviewImageSizes.thumb(item, tall: tall), maxPixels: tall ? 900 : 600)
                .frame(width: stage.px(520 * 1.28), height: stage.px(292))
                .visualEffect { content, proxy in
                    let frame = proxy.frame(in: .scrollView(axis: .horizontal))
                    let bounds = proxy.bounds(of: .scrollView(axis: .horizontal)) ?? .zero
                    return content.offset(x: -(frame.midX - bounds.midX) * OverviewMotion.parallax)
                }
                .frame(width: stage.px(520), height: stage.px(292))
                .clipped()
                .opacity(session.viewer.map { session.thumbFrames[$0] != nil } == true ? 1 : 1)
            if item.kind == .video {
                SymbolView(symbol: Symbols.playArrow, size: 64, color: RGBA(red: 1, green: 1, blue: 1), filled: true)
                    .shadow(color: .black.opacity(0.6), radius: stage.px(8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let name = item.name {
                    Text(name).font(DelosFonts.figtree(stage.tpx(18), .bold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: stage.px(5)).padding(.leading, stage.px(16)).padding(.bottom, stage.px(14))
                }
            }
        }
        .frame(width: stage.px(520), height: stage.px(292))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: stage.px(1)))
    }
}

/// The card flying between the dashboard and the header (`Flight.cover`): the card's own art drawn at the header slot's
/// size, moved and scaled from the card's frame along a slight arc. Transforms only.
struct OverviewFlight: View, Animatable {
    let hostID: String
    let app: HostApp
    let from: CGRect
    let to: CGRect
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    @Environment(\.stage) private var stage

    var body: some View {
        let t = OverviewMotion.flightTransform(from: from, to: to, progress: progress)
        let corner = Motion.lerp(26 * CoverGeometry.focusScale / max(from.width / max(to.width, 1), 0.01), 30, progress)
        CardArt(hostID: hostID, app: app)
            .frame(width: to.width, height: to.height)
            .clipShape(RoundedRectangle(cornerRadius: stage.px(corner), style: .continuous))
            .shadow(color: .black.opacity(Motion.lerp(0.5, 0.7, progress)), radius: stage.px(Motion.lerp(40, 60, progress)), y: stage.px(Motion.lerp(30, 50, progress)))
            .scaleEffect(x: t.sx, y: t.sy, anchor: .topLeading)
            .offset(x: to.minX + t.dx, y: to.minY + t.dy)
            .allowsHitTesting(false)
    }
}

/// A cover of the dashboard's row while the overview opens or closes (`homeOut` of the prototype): the others lift away
/// one after another (up by 160 px plus 30 per cover of distance, to 92 %, 45 ms apart), the one in the overview hides
/// while its card flies; with reduced motion they only fade. The focused cover follows a finger swiping it up.
struct CoverDescent: ViewModifier {
    let app: HostApp
    let distance: Int
    let descent: OverviewDescent
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.overviewLauncher) private var launcher

    func body(content: Content) -> some View {
        let mine = descent.appID == app.id
        let lift = descent.active && !mine && !reduced
        let dragged = launcher?.dragApp == app.id ? launcher?.dragOffset ?? 0 : 0
        content
            .offset(y: lift ? stage.px(OverviewMotion.coverLift(distance: distance)) : 0)
            .scaleEffect(lift ? OverviewMotion.coverLiftScale : 1)
            .opacity(mine ? 0 : descent.active ? 0 : 1)
            .animation(mine ? nil : descent.active
                ? Motion.out(OverviewMotion.homeOut).delay(reduced ? 0 : Double(distance) * OverviewMotion.coverLiftStagger / 1000)
                : .timingCurve(0.65, 0, 0.35, 1, duration: OverviewMotion.flightBack / 1000), value: descent)
            .offset(y: dragged)
            #if os(iOS)
            .simultaneousGesture(DragGesture(minimumDistance: OverviewMotion.swipeSlop)
                .onChanged { value in if distance == 0 { launcher?.drag(app, translation: value.translation, slop: OverviewMotion.swipeSlop) } }
                .onEnded { value in if distance == 0 { launcher?.end(app, translation: value.translation, threshold: stage.px(OverviewMotion.swipeOpen)) } })
            #endif
    }
}
