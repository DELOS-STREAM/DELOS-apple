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
    /// The card is the library's wide first cover (its own wide art in a landscape frame).
    @ObservationIgnored var wide = false
    /// The header cover's still picture (the card art: the SteamGridDB cover, else the PC's box art), from memory when the
    /// overview opens; nil until loaded when it was not there.
    @ObservationIgnored var coverStill: CGImage?
    /// What the flight shows at its two ends, taken as it starts so nothing loads or restarts during the motion: the card's
    /// picture ([flightFrom], the wide art for the wide cover) and the header's ([flightTo]); each the frame its animation
    /// showed at that moment when it plays.
    @ObservationIgnored var flightFrom: CGImage?
    @ObservationIgnored var flightTo: CGImage?
    /// The ratings fill and count up.
    var ratingsOn = false
    /// The sections below the header are composed: from the flight's landing on (nothing below the fold is laid out
    /// while the cover flies), then for the rest of the session.
    var belowFold = false
    /// The details' lookup has finished (the page says "not available" instead of "loading" when none came).
    var detailsSettled = false
    /// The viewer's last step: 1 to the next item, -1 to the previous one (the side the new picture comes from).
    var viewerDirection = 1.0
    /// B asked the viewer to close (it zooms back into the thumbnail first).
    var viewerClosing = false
    /// The streaming section's numbers have counted up.
    var streamingOn = false
    var details: GameDetails?
    let focus = FocusModel(initial: OverviewNavigation.initialFocus)
    let ring = OverviewRing()
    /// The viewer's item, nil when it is closed: an index into [viewerMedia].
    var viewer: Int?
    var viewerControlsVisible = true
    var buttonsVisible = false
    /// The owned Similar target is focused only after the current reverse flight finishes.
    var jumpTarget: HostApp?
    var visibleCoverDistance = 0
    /// The screenshots and videos as they were when the viewer opened: its indices stay put while it is open, even when
    /// the carousel leaves out a video that turned out not to play.
    var viewerMedia: [OverviewContent.Media] = []
    /// The viewer's video player.
    let video = OverviewVideo()
    /// The page's scroll position (page pixels, points) and the request to scroll it.
    var scroll = 0.0
    /// How far the page is pulled down past its top (points): changes only while pulled, so the header cover is not
    /// re-evaluated on every scroll frame.
    var pull = 0.0
    var position = ScrollPosition(y: 0)

    /// Frames (in the page's space) of the sections and items, for the focus scroll.
    @ObservationIgnored var sectionFrames: [String: CGRect] = [:]
    /// The thumbnails' frames in the home's space by media id, for the viewer's zoom.
    @ObservationIgnored var thumbFrames: [String: CGRect] = [:]
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
    var visibleCoverDistance = 0
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
        guard dragApp == app.id || CoverDragDirection.of(translation: translation, minimumDistance: slop) == .verticalSwipe else { return }
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
            cancel(app)
        }
    }

    /// A recognizer lost its touch: settle only its own cover and never turn a cancelled swipe into an open.
    func cancel(_ app: HostApp) {
        guard dragApp == app.id else { return }
        withAnimation(Motion.spring(500)) { dragOffset = 0 }
        dragApp = nil
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
    @Namespace private var buttonRing

    private var kind: InputKind { ControllerGlyphs.shared.kind }

    var body: some View {
        let content = session.details.map {
            OverviewContent(details: $0, library: library, region: Locale.current.region?.identifier, unplayable: OverviewVideos.shared.unplayable)
        }
        ZStack(alignment: .topLeading) {
            OverviewBackdrop(session: session)
            let covers = HomeMetrics(stage: stage).covers
            OverviewFlight(hostID: session.hostID, app: session.app, from: session.source,
                           to: CGRect(x: stage.px(150 + stage.safe.leading), y: stage.px(150), width: stage.px(340), height: stage.px(510)),
                           fromCorner: stage.px(covers.corner * CoverGeometry.focusScale), toCorner: stage.px(30),
                           fromArt: session.flightFrom, toArt: session.flightTo, wide: session.wide, coverScale: covers.scale,
                           progress: session.flight)
                .opacity(session.landed ? 0 : 1)
            // The page rises with the flight (the settle spring) and sinks back as it closes (`page.animate`), transforms
            // only; its parts fade in and out on their own (``Rise``), the title flies and the cover lands
            page(content)
                .animation(session.shown ? OverviewMotion.settle
                           : .timingCurve(0.65, 0, 0.35, 1, duration: OverviewMotion.pageSink / 1000)) {
                    $0.offset(y: session.shown || reduced ? 0 : stage.px(OverviewMotion.pageRise))
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: session.shown) {
            session.buttonsVisible = false
            guard session.shown else { return }
            if !reduced {
                do { try await Task.sleep(for: .milliseconds(Int(OverviewMotion.buttonsDelay))) } catch { return }
            }
            guard !Task.isCancelled else { return }
            session.buttonsVisible = true
        }
        .task(id: session.app.id) {
            // Load the cached details or fetch them now; media images load where they are displayed.
            if session.details == nil, let details = await metadata.loadDetails(session.app) {
                withAnimation(.easeOut(duration: 0.3)) { session.details = details }
            }
            session.detailsSettled = true
            // Check which videos YouTube lets play in the app (only the fallback's: Steam's movies play natively).
            await OverviewVideos.shared.check(session.details.map(OverviewContent.youTubeVideos)?.map(\.videoId) ?? [])
        }
    }

    // MARK: Page

    private func page(_ content: OverviewContent?) -> some View {
        let side = 150 + stage.safe.leading
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header(content)
                if let content, session.belowFold {
                    ForEach(content.sections, id: \.self) { section in
                        sectionView(section, content: content)
                            .padding(.top, stage.px(70))
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
            // Touch shows its focus too: a first tap only focuses (focus-first), and the ring says so
            .overviewRingHost(session.ring, hidden: session.viewer != nil || !session.shown)
        }
        .scrollPosition(Binding(get: { session.position }, set: { session.position = $0 }))
        .onGeometryChange(for: Double.self) { $0.frame(in: .global).minY } action: { globalTop = $0 }
        .onScrollGeometryChange(for: Double.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, now in
            session.scroll = now
            let pull = max(-now, 0)
            if pull != session.pull { session.pull = pull }
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

    /// The focus moved: scroll the focused section to its line and count the streaming numbers when their section appears.
    private func focused(_ id: AnyHashable?, content: OverviewContent?) {
        guard let id = id as? String, content != nil else { return }
        let section = sectionOf(id)
        if section == .streaming, !session.streamingOn {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                session.streamingOn = true
            }
        }
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
                            .modifier(Rise(index: 0, delay: OverviewMotion.headerDelay, shown: session.shown))
                    }
                    OverviewTitle(session: session, logo: art.cachedLogo(hostID: session.hostID, app: session.app))
                    // The tags pop one after another with their row (its Rise start, then 36 ms apart)
                    let genreTags = Array(genres.prefix(2)), themeTags = Array(themes.prefix(2))
                    let tagStart = OverviewMotion.headerDelay + OverviewMotion.headerStagger
                    WrapLayout(spacing: stage.px(OverviewSpacing.tagGap)) {
                        ForEach(Array(genreTags.enumerated()), id: \.element.id) { index, genre in
                            OverviewTag(icon: TagLook.genreIcon(genre.id), label: TagLook.genreName(genre), genre: true)
                                .modifier(ChipPop(active: session.shown, delay: tagStart + Double(index) * OverviewMotion.headerStagger))
                        }
                        ForEach(Array(themeTags.enumerated()), id: \.element.id) { index, theme in
                            OverviewTag(icon: TagLook.themeIcon(theme.id), label: TagLook.themeName(theme))
                                .modifier(ChipPop(active: session.shown, delay: tagStart + Double(genreTags.count + index) * OverviewMotion.headerStagger))
                        }
                        Group {
                            switch data?.hdrBadge {
                            case .hdr?: NativeHDRChip()
                            case .sdr?: InfoChip(icon: Symbols.sdr, label: "SDR")
                            case .unknown?: InfoChip(icon: Symbols.hdrUnknown, label: L("metadata_hdr_unverified"))
                            case nil: EmptyView()
                            }
                        }
                        .modifier(ChipPop(active: session.shown, delay: tagStart + Double(genreTags.count + themeTags.count) * OverviewMotion.headerStagger))
                    }
                    .modifier(Rise(index: 1, delay: OverviewMotion.headerDelay, shown: session.shown))
                    if let content {
                        HStack(spacing: stage.px(46)) {
                            rating(content.critics, label: L("overview_critics"), color: colors.accent, delay: 0,
                                   sub: content.critics.value == nil ? L("overview_no_critics") : LPlural("overview_reviews", content.critics.count, content.critics.count.formatted()))
                            rating(content.players, label: L("overview_players"), color: colors.accent2, delay: OverviewMotion.ratingStagger,
                                   sub: content.players.value == nil ? L("overview_not_rated_yet")
                                       : content.details.fewRatings ? LPlural("overview_ratings_few", content.players.count, content.players.count.formatted())
                                       : LPlural("overview_ratings", content.players.count, content.players.count.formatted()))
                            AgeBadge(rating: ages.first)
                                .modifier(ChipPop(active: session.ratingsOn, delay: OverviewMotion.ratingStagger * 2))
                        }
                        .modifier(Rise(index: 2, delay: OverviewMotion.headerDelay, shown: session.shown))
                    } else {
                        Text(session.detailsSettled ? L("overview_unavailable") : L("overview_loading"))
                            .font(DelosFonts.figtree(stage.tpx(22))).foregroundStyle(colors.text3.color)
                            .modifier(Rise(index: 2, delay: OverviewMotion.headerDelay, shown: session.shown))
                    }
                    HStack(spacing: stage.px(OverviewSpacing.buttonGap)) {
                        OverviewButton(id: OverviewNavigation.play, focus: session.focus, icon: Symbols.playArrow, label: L("overview_play"), primary: true,
                                       active: session.buttonsVisible && session.shown && session.viewer == nil, ringNamespace: buttonRing) {
                            actions.activate(hostID: session.hostID, app: session.app, focus: libraryFocus)
                        }
                        OverviewButton(id: OverviewNavigation.settings, focus: session.focus, icon: Symbols.settings, label: L("home_menu_settings"), primary: false,
                                       active: session.buttonsVisible && session.shown && session.viewer == nil, ringNamespace: buttonRing) {
                            actions.navigator.push(.appSettings(hostID: session.hostID, appID: session.app.id), focus: GameSettingsScreen.firstFocus())
                        }
                    }
                    .modifier(Rise(index: 3, delay: OverviewMotion.headerDelay, shown: session.shown))
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
                    .modifier(Rise(index: 4, delay: OverviewMotion.headerDelay, shown: session.shown))
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
                .modifier(Rise(index: 5, delay: OverviewMotion.cueDelay, shown: session.shown))
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

    private func rating(_ rating: OverviewContent.Rating, label: String, color: RGBA, delay: Double, sub: String) -> some View {
        HStack(spacing: stage.px(18)) {
            RatingRing(value: rating.value, size: 104, color: color, active: session.ratingsOn, delay: delay)
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
        case .about: Symbols.overviewAbout
        case .media: Symbols.overviewMedia
        case .details: Symbols.overviewDetails
        case .streaming: Symbols.overviewStreaming
        case .links: Symbols.overviewLinks
        case .similar: Symbols.overviewSimilar
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
                    OverviewFocusable(id: OverviewNavigation.summary, focus: session.focus, corner: 18, pad: OverviewSpacing.summaryPad, scale: 1) {
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
                        .modifier(StoryReveal(open: session.storyOpen ? 1 : 0, fade: stage.px(StoryReveal.fade)))
                        .opacity(session.storyOpen ? 1 : 0)
                    OverviewFocusable(id: OverviewNavigation.story, focus: session.focus, corner: 26, pad: 0, scale: OverviewSpacing.storyScale) {
                        HStack(spacing: stage.px(10)) {
                            SymbolView(symbol: Symbols.expandMore, size: 24, color: colors.text)
                                .rotationEffect(.degrees(session.storyOpen ? 180 : 0))
                            Text(session.storyOpen ? L("overview_show_less") : L("overview_read_story"))
                                .font(DelosFonts.figtree(stage.tpx(20), .bold)).foregroundStyle(colors.text.color)
                        }
                        .padding(.horizontal, stage.px(22))
                        .frame(height: stage.px(52))
                        .background(GlassShape(Capsule(), tint: RGBA(red: 1, green: 1, blue: 1, alpha: 0.06), share: 1).overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1))))
                    } action: {
                        withAnimation(reduced ? .easeOut(duration: 0.28) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.6)) { session.storyOpen.toggle() }
                    }
                    .padding(.top, stage.px(OverviewSpacing.storyGap))
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
                            WrapLayout(spacing: stage.px(OverviewSpacing.badgeGap)) {
                                ForEach(content.ageRatings, id: \.organization) { AgeBadge(rating: $0) }
                            }
                        } else {
                            WrapLayout(spacing: stage.px(OverviewSpacing.tagGap)) {
                                ForEach(group.values, id: \.self) { value in
                                    OverviewTag(icon: groupIcon(group.kind, value, candidate: candidate), label: value, genre: group.kind == .genres, onCard: true)
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
        case .modes: value.lowercased().hasPrefix("single") ? Symbols.modeSingle : Symbols.modeMulti
        case .perspectives: Symbols.perspective
        case .platforms: value == "PC" || value == "Linux" ? Symbols.desktopWindows : value == "Mac" ? Symbols.platformMac : Symbols.platformConsole
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
        WrapLayout(spacing: stage.px(OverviewSpacing.linkGap)) {
            ForEach(Array(content.links.enumerated()), id: \.element.id) { index, link in
                OverviewFocusable(id: OverviewNavigation.link(index), focus: session.focus, corner: 32, pad: 0, scale: OverviewSpacing.linkScale) {
                    HStack(spacing: stage.px(14)) {
                        SymbolView(symbol: linkIcon(link.kind), size: 28, color: colors.accent2)
                        Text(linkName(link)).font(DelosFonts.figtree(stage.tpx(21), .semibold)).foregroundStyle(colors.text.color)
                        SymbolView(symbol: Symbols.linkOpenExternal, size: 20, color: colors.text3)
                    }
                    .padding(.horizontal, stage.px(24))
                    .frame(height: stage.px(64))
                    .background(GlassShape(Capsule(), tint: RGBA(red: 1, green: 1, blue: 1, alpha: 0.06), share: 1).overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1))))
                } action: {
                    openURL(link.url)
                }
            }
        }
    }

    private func linkIcon(_ kind: OverviewContent.Link.Kind) -> String {
        switch kind {
        case .steam: Symbols.steam
        case .official: Symbols.websiteOfficial
        case .gog, .epic: Symbols.websiteStore
        case .wikipedia: Symbols.websiteWiki
        case .twitch, .youtube: Symbols.websiteVideo
        case .discord, .other: Symbols.overviewLinks
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
        let side = 150 + stage.safe.leading
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: stage.px(OverviewSpacing.similarGap)) {
                ForEach(Array(content.similar.enumerated()), id: \.element.id) { index, game in
                    OverviewFocusable(id: OverviewNavigation.similar(index), focus: session.focus, corner: SimilarCover.corner, pad: 0, scale: OverviewSpacing.similarScale) {
                        SimilarCover(hostID: session.hostID, game: game)
                    } action: {
                        if let app = game.app { onJump(app) } else { actions.toasts.show(L("overview_not_in_library", game.name), icon: Symbols.info) }
                    }
                    .id("ov-similar-\(index)")
                }
            }
            .padding(.horizontal, stage.px(side))
            .padding(.vertical, stage.px(24))
        }
        .scrollPosition($similarPosition)
        .scrollClipDisabled()
        .overviewAnchorRow()
        .padding(.horizontal, -stage.px(side))
        .onChange(of: session.focus.focused) { _, now in
            guard kind != .pointer, kind != .touch, !session.focus.pointerMoved,
                  let id = now as? String, id.hasPrefix("ov-similar-"),
                  let index = Int(id.dropFirst("ov-similar-".count)) else { return }
            OverviewAnchorRow.step(position: $similarPosition, x: stage.px(Double(index) * (SimilarCover.width + OverviewSpacing.similarGap)), reduced: reduced)
        }
    }

    @State private var similarPosition = ScrollPosition(x: 0)

    private var credit: some View {
        HStack(spacing: stage.px(10)) {
            SymbolView(symbol: Symbols.info, size: 22, color: colors.text3)
            Text(L("overview_credit")).font(DelosFonts.figtree(stage.tpx(17))).foregroundStyle(colors.text3.color)
        }
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
            .scaleEffect(focusScale(focused: focused && scale > 1, pressed: pressed, focus: scale))
            // Outside the scale: the ring reads the layout bounds and grows them itself
            .overviewRingTarget(focused: focused, corner: corner, pad: pad, scale: scale)
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
    let active: Bool
    let ringNamespace: Namespace.ID
    let action: () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.shellCoversArt) private var covered

    var body: some View {
        FocusItem(id: id, model: focus, action: action, tap: { wasFocused in if wasFocused { action() } }) { focused in
            HStack(spacing: stage.px(14)) {
                SymbolView(symbol: icon, size: 32, color: primary ? colors.onAccent : colors.text, filled: primary)
                Text(label).font(DelosFonts.figtree(stage.tpx(26), .bold)).foregroundStyle((primary ? colors.onAccent : colors.text).color)
            }
            .padding(.horizontal, stage.px(54))
            .frame(height: stage.px(86))
            .background {
                if primary { Capsule().fill(colors.accent.color) }
                else { GlassShape(Capsule(), tint: colors.surface).overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1))) }
            }
            .overlay {
                // The ring only once the pill itself has risen in (``Rise`` index 3), never ahead of it
                if focused && active {
                    // A 4 px band 2–6 px outside the pill, the pill's own capsule
                    Capsule().strokeBorder(colors.accent.color, lineWidth: stage.px(4)).padding(-stage.px(OverviewSpacing.buttonRingOut))
                        .shadow(color: colors.glow.color, radius: stage.px(primary && reduced ? 22 : 15))
                        .matchedGeometryEffect(id: "overview-button-ring", in: ringNamespace)
                        .animation(.timingCurve(0.3, 1.22, 0.42, 1, duration: 0.56), value: focused)
                    if primary && scenePhase == .active && !covered && !reduced && ControllerGlyphs.shared.kind != .touch { PlayPerimeterSweep() }
                }
            }
            .animation(.easeOut(duration: 0.24), value: active)
            .modifier(OverviewPillTransform(focused: focused))
        }
    }
}

private struct OverviewPillTransform: ViewModifier {
    let focused: Bool
    @Environment(\.pressed) private var pressed
    @Environment(\.reducedMotion) private var reduced

    func body(content: Content) -> some View {
        content
            .scaleEffect(focusScale(focused: focused, pressed: pressed, focus: OverviewSpacing.buttonScale))
            .animation(.focusScale(pressed: pressed, reduced: reduced), value: focused)
            .animation(.focusScale(pressed: pressed, reduced: reduced), value: pressed)
    }
}

/// Play's signature focus (`b.html`, "living gold sweep"): a warm highlight runs around a band just outside the ring once
/// every 5.8 s. Only the gradient turns; the pill, its text and its ring stay put. Not drawn with reduced motion (the
/// ring's static glow stays).
private struct PlayPerimeterSweep: View {
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @State private var turned = false

    var body: some View {
        GeometryReader { proxy in
            let side = hypot(proxy.size.width, proxy.size.height)
            // `conic-gradient(from 0deg, transparent 120deg, accent 27 % 190deg, #ffe9b8 235deg, accent 67 % 257deg, transparent 290deg)`
            AngularGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 120 / 360),
                .init(color: colors.accent.opacity(0.27).color, location: 190 / 360),
                .init(color: RGBA(red: colors.accent.red + (1 - colors.accent.red) * 0.65, green: colors.accent.green + (1 - colors.accent.green) * 0.65,
                                  blue: colors.accent.blue + (1 - colors.accent.blue) * 0.65).color, location: 235 / 360),
                .init(color: colors.accent.opacity(0.67).color, location: 257 / 360),
                .init(color: .clear, location: 290 / 360),
                .init(color: .clear, location: 1),
            ], center: .center, angle: .degrees(-90))
            .frame(width: side, height: side)
            .rotationEffect(.degrees(turned ? 360 : 0))
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        // `.sweep-mask`: a 4 px band 11 px outside the pill
        .mask(Capsule().strokeBorder(lineWidth: stage.px(4)))
        .padding(-stage.px(OverviewSpacing.playReachOut))
        .allowsHitTesting(false)
        .onAppear { withAnimation(.linear(duration: 5.8).repeatForever(autoreverses: false)) { turned = true } }
    }
}

/// The staggered entrance (`.st`): 18 px up and in with the settle spring (``OverviewMotion/settle``),
/// ``OverviewMotion/headerStagger`` ms apart (at most 8 steps) after [delay]; leaving, it fades in 180 ms
/// (``OverviewMotion/leave``). Reduced motion fades it in over 280 ms from its stagger start.
struct Rise: ViewModifier {
    let index: Int
    let delay: Double
    let shown: Bool
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.stage) private var stage
    @State private var hasEntered = false
    private var sessionExitOffset: Double { hasEntered ? Motion.rise * 0.6 : Motion.rise }

    func body(content: Content) -> some View {
        let wait = (delay + Double(min(index, Motion.staggerCap)) * OverviewMotion.headerStagger) / 1000
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduced ? 0 : stage.px(sessionExitOffset))
            .animation(!shown ? OverviewMotion.leave : reduced ? OverviewMotion.reducedFade.delay(wait) : OverviewMotion.settle.delay(wait), value: shown)
            .onChange(of: shown) { _, now in if now { hasEntered = true } }
    }
}

/// The storyline opening and closing ("Read the story"): its height runs from 0 to the text's by [open], and while
/// text continues below the clipped edge the last [fade] points fade out (as the dashboard row's ends do); fully open,
/// nothing is masked.
struct StoryReveal: ViewModifier, Animatable {
    /// The fade's height, stage pixels.
    static let fade = 90.0
    var open: Double
    let fade: Double
    @State private var full = 0.0

    nonisolated var animatableData: Double {
        get { open }
        set { open = newValue }
    }

    func body(content: Content) -> some View {
        let shown = full * min(max(open, 0), 1)
        let edge = shown < full - 0.5 ? min(fade, shown) : 0
        content
            .onGeometryChange(for: Double.self) { $0.size.height } action: { full = $0 }
            .frame(height: shown, alignment: .top)
            .clipped()
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: edge)
                }
            }
    }
}

/// The header's cover: exactly the library card's image (the user's SteamGridDB choice, else the default card art, the
/// same decoded bitmap), shown once the flight has landed; it shrinks a little while the page is pulled down.
struct OverviewCover: View {
    let session: OverviewSession
    @Environment(\.stage) private var stage

    var body: some View {
        let pull = session.pull / stage.scale
        // The picture in memory at once; its animation plays once the flight has landed (nothing decodes during the motion)
        CardArt(hostID: session.hostID, app: session.app, still: session.coverStill, plays: session.landed)
            .id(GameArt.key(session.hostID, session.app.id))
            .frame(width: stage.px(340), height: stage.px(510))
            .clipShape(RoundedRectangle(cornerRadius: stage.px(30), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: stage.px(30), style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: stage.px(1)))
            .shadow(color: .black.opacity(0.7), radius: stage.px(60), y: stage.px(50))
            .scaleEffect(1 - min(pull, 300) / 2400)
            .opacity(session.landed ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// A game's card art, as its library cover shows it: the SteamGridDB cover (playing when animated, while [plays], the
/// screen's artwork may play and it is on screen), else the PC's box art, else the placeholder art with the title.
/// [still]: the picture already in memory, shown from the first frame.
struct CardArt: View {
    let hostID: String
    let app: HostApp
    let plays: Bool
    private let initialStill: CGImage?
    @Environment(HomeArt.self) private var art
    @Environment(HostStore.self) private var hosts
    @Environment(\.artMotion) private var artMotion
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var animation: AnimatedSource?
    @State private var animating = false
    /// Some of it is on screen (its scroll view's).
    @State private var visible = false

    init(hostID: String, app: HostApp, still: CGImage? = nil, plays: Bool = true) {
        self.hostID = hostID
        self.app = app
        self.plays = plays
        initialStill = still
        _image = State(initialValue: still)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .opacity(animating ? 0 : 1)
                        .overlay {
                            AnimatedArtLayer(source: animation, playing: artMotion && plays && visible,
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
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .task(id: "\(hostID)#\(app.id)#\(art.artwork.version)") {
            image = initialStill
            animation = nil
            animating = false
            let cover = art.artwork.enabled ? await art.image(hostID: hostID, appID: app.id, kind: .cover) : nil
            let loaded: CGImage?
            if let cover { loaded = cover }
            else { loaded = await art.boxArt(hostID: hostID, appID: app.id, hosts: hosts) }
            guard !Task.isCancelled else { return }
            image = loaded
            if cover != nil {
                let source = await art.animation(hostID: hostID, app: app, kind: .cover)
                guard !Task.isCancelled else { return }
                animation = source
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

    /// 1.3 times the prototype's 200 × 300 cover with its 20 px corners (owner's decision).
    static let width = 260.0, height = 390.0, corner = 26.0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let app = game.app {
                CardArt(hostID: hostID, app: app)
            } else if let id = game.coverImageID {
                RemoteImage(url: IGDBImage.url(id, size: .coverBig, retina: displayScale > 1), maxPixels: 800)
            } else {
                let art = GameArt(hostID: hostID, app: HostApp(id: Int(game.id % 100_000), title: game.name))
                PlaceholderArt(hue: art.hue, hue2: art.hue2, icon: art.icon, glyphSize: 273, glyphRight: -31, glyphTop: 0.24,
                               title: game.name, titleSize: 29, titleInset: 21, titleBottom: 21, titleFit: true)
            }
            if game.app != nil {
                Text(L("overview_in_library"))
                    .font(DelosFonts.figtree(stage.tpx(17), .bold)).foregroundStyle(colors.accent.color)
                    .padding(.horizontal, stage.px(12)).padding(.vertical, stage.px(5))
                    .background(GlassShape(Capsule(), tint: .overArt(0.6), role: .panel, share: 1))
                    .padding(stage.px(15))
            }
        }
        .frame(width: stage.px(Self.width), height: stage.px(Self.height))
        .clipShape(RoundedRectangle(cornerRadius: stage.px(Self.corner), style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.name)
    }
}

/// The title beside the cover (`.a-title`): the game's logo as the dashboard's title box shows it (``HomeArt/logo(hostID:app:)``),
/// else its name in Unbounded 68 px in the gradient of the dashboard's title. It does not fly (owner's decision): the
/// dashboard's fades out where it is and this one fades in here, with the flight (``TitleCrossfade``).
private struct OverviewTitle: View {
    let session: OverviewSession
    @Environment(HomeArt.self) private var art
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors
    @Environment(\.artMotion) private var artMotion
    @State private var logo: CGImage?
    @State private var animation: AnimatedSource?

    init(session: OverviewSession, logo: CGImage?) {
        self.session = session
        _logo = State(initialValue: logo)
    }

    var body: some View {
        Group {
            if let logo {
                let box = CGSize(width: stage.px(OverviewMotion.logoWidth), height: stage.px(OverviewMotion.logoHeight))
                // The animated logo plays once the flight has landed
                LogoArt(logo: logo, animation: animation, box: box, playing: artMotion && session.landed)
                    .frame(width: box.width, height: box.height, alignment: .leading)
                    .accessibilityElement()
                    .accessibilityLabel(session.app.title)
            } else {
                Text(session.app.title)
                    .font(DelosFonts.unbounded(stage.tpx(68), .bold))
                    .lineSpacing(0)
                    .foregroundStyle(LinearGradient(colors: [colors.text.color, colors.accent2.color], startPoint: UnitPoint(x: 0.5, y: 0.3), endPoint: .bottom))
                    .shadow(color: .black.opacity(0.4), radius: stage.px(14), y: stage.px(6))
                    .frame(maxWidth: stage.px(1150), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(TitleCrossfade(shown: session.shown, here: true))
        .task(id: session.app.id) {
            if logo == nil { logo = await art.logo(hostID: session.hostID, app: session.app) }
            if logo != nil { animation = await art.animation(hostID: session.hostID, app: session.app, kind: .logo) }
        }
    }
}

/// The title's crossfade between the dashboard and the overview, by opacity only: the side being left fades out over
/// the first 40 % of the flight, the side arrived at fades in over its last 50 %. [here]: the overview's title (shown
/// while [shown]); else the dashboard's (shown while not).
struct TitleCrossfade: ViewModifier {
    let shown: Bool
    let here: Bool
    @Environment(\.reducedMotion) private var reduced

    func body(content: Content) -> some View {
        let visible = here == shown
        // Out over the first 40 % of the flight, in over its last 50 % (585 ms opening, 480 ms closing)
        let flight = (shown ? OverviewMotion.flight : OverviewMotion.flightBack) / 1000
        content
            .opacity(visible ? 1 : 0)
            .animation(reduced ? .easeOut(duration: 0.24)
                       : visible ? .easeOut(duration: flight * 0.5).delay(flight * 0.5) : .easeIn(duration: flight * 0.4), value: visible)
    }
}

/// The hero behind the overview: the dashboard's own game background shows through at its configured blur and keeps
/// playing when animated. Scrolling fades in a deeper render of that same hero, with parallax and a small zoom.
/// Carousel focus never changes the image source.
private struct OverviewBackdrop: View {
    let session: OverviewSession
    @Environment(HomeArt.self) private var art
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.heroLook) private var look
    @State private var deepImage: CGImage?

    private struct DeepKey: Equatable {
        let hero: GameArt?
        let blur: Int?
        let area: HeroArea
    }

    var body: some View {
        let scroll = max(session.scroll, 0) / stage.scale
        let deep = min(1, scroll / OverviewMotion.deepBlurScroll)
        let area = HeroArea.of(stageWidth: stage.width, stageHeight: stage.height)
        // Sized by the screen, never by the pictures (filled pictures are larger than it)
        Color.clear.overlay {
        ZStack {
            if let deepImage, let look {
                Image(decorative: deepImage, scale: 1).resizable().interpolation(.medium)
                    .frame(width: stage.px(area.width), height: stage.px(area.height))
                    .brightness(-0.25)
                    .opacity(deep * look.opacity)
            }
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.42), .init(color: colors.bg.color, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .opacity((0.62 + deep * 0.25) * 0.7)
        }
        }
        .scaleEffect(reduced ? 1 : OverviewMotion.heroZoom(scroll))
        .offset(y: reduced ? 0 : stage.px(OverviewMotion.heroDrift(scroll)))
        .opacity(session.shown ? 1 : 0)
        .animation(session.shown ? Motion.out(OverviewMotion.heroIn)
                   : .timingCurve(0.65, 0, 0.35, 1, duration: OverviewMotion.heroOut / 1000), value: session.shown)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .task(id: DeepKey(hero: art.hero, blur: look?.blur, area: area)) {
            guard let hero = art.hero, let look else {
                deepImage = nil
                return
            }
            deepImage = await art.background(hero, blur: OverviewMotion.deepBlur(from: look.blur), area: area)
        }
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
            // Not lazy: every thumbnail is registered, so the arrows can walk to one past the edge and the row follows
            HStack(spacing: stage.px(OverviewSpacing.mediaGap)) {
                ForEach(Array(media.enumerated()), id: \.offset) { index, item in
                    OverviewFocusable(id: OverviewNavigation.media(index), focus: session.focus, corner: 22, pad: 0, scale: OverviewSpacing.mediaScale) {
                        thumb(item, tall: tall)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.thumbFrames[item.id] = $0 }
                    } action: {
                        session.viewerMedia = media
                        session.viewer = index
                    }
                    .id("ov-media-\(index)")
                }
            }
            .padding(.horizontal, stage.px(side))
            .padding(.top, stage.px(24))
            .padding(.bottom, stage.px(30))
        }
        .scrollPosition($position)
        .scrollClipDisabled()
        .overviewAnchorRow()
        .padding(.horizontal, -stage.px(side))
        .onChange(of: session.focus.focused) { _, now in
            guard ControllerGlyphs.shared.kind != .pointer, ControllerGlyphs.shared.kind != .touch, !session.focus.pointerMoved else { return }
            guard let id = now as? String, id.hasPrefix("ov-media-"), let index = Int(id.dropFirst("ov-media-".count)) else { return }
            reveal(index)
        }
        .onChange(of: session.viewer) { _, now in
            // The viewer's index is into its own list: the same item here can sit elsewhere once a video is left out
            guard let now, session.viewerMedia.indices.contains(now), let here = media.firstIndex(of: session.viewerMedia[now]) else { return }
            reveal(here, animated: false)
        }
        .onChange(of: media.map(\.id)) { _, ids in
            // A video left out: the viewer fades instead of zooming into a place where another thumbnail now is
            let kept = Set(ids)
            session.thumbFrames = session.thumbFrames.filter { kept.contains($0.key) }
        }
    }

    /// The focused thumbnail glides to the row's start (150 px in, the previous one peeking into the fade), as the
    /// dashboard's covers do; the row clamps at its end.
    private func reveal(_ index: Int, animated: Bool = true) {
        OverviewAnchorRow.step(position: $position, x: stage.px(Double(index) * (OverviewSpacing.mediaWidth + OverviewSpacing.mediaGap)), reduced: reduced || !animated)
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
            if item.kind == .video {
                SymbolView(symbol: Symbols.videoPlay, size: 64, color: RGBA(red: 1, green: 1, blue: 1), filled: true)
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

/// The cover flying between the dashboard and the header (`Flight.cover`): a frame running from the card's place and size
/// to the header slot's along a slight arc, its corners rounding from the card's to the slot's, and in it the pictures
/// filling it as the cover does (cropped, the same scale on both axes, never stretched): the card's own picture (the wide
/// art of the wide first cover) under the header's, which fades in over it when they differ. The pictures are the ones
/// in memory as it starts; during the motion only transforms, the clip's outline and the opacity change (the body is not
/// evaluated on each frame, nothing is laid out or decoded).
struct OverviewFlight: View {
    let hostID: String
    let app: HostApp
    let from: CGRect
    let to: CGRect
    /// The card's corner radius as it shows (focused) and the slot's, points.
    let fromCorner: Double
    let toCorner: Double
    /// The pictures at the two ends (nil: the placeholder art the card or the header shows then); the card is the [wide]
    /// first cover at the covers' [coverScale].
    let fromArt: CGImage?
    let toArt: CGImage?
    let wide: Bool
    let coverScale: Double
    let progress: Double
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        let path = FlightPath(from: from, to: to, lift: stage.px(OverviewMotion.arc))
        let clip = FlightClip(path: path, fromCorner: fromCorner, toCorner: toCorner, progress: progress)
        let p = min(max(progress, 0), 1)
        ZStack(alignment: .topLeading) {
            // One shadow radius for the whole flight (an animated radius would re-blur it on every frame)
            clip.fill(Color.black)
                .shadow(color: .black.opacity(Motion.lerp(0.5, 0.7, p)), radius: stage.px(50), y: stage.px(Motion.lerp(30, 50, p)))
            ZStack(alignment: .topLeading) {
                card(path)
                if fromArt == nil || toArt == nil || fromArt !== toArt {
                    header(path).modifier(FlightCrossfade(progress: progress))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(clip)
            clip.stroke(colors.accent.color, lineWidth: stage.px(5))
                .shadow(color: colors.glow.color.opacity(1 - p), radius: stage.px(30))
                .opacity(1 - p)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The card's picture filling the flying frame, else the card's placeholder art laid out at the card's size.
    @ViewBuilder private func card(_ path: FlightPath) -> some View {
        if let fromArt {
            picture(fromArt, path: path)
        } else {
            let size = CGSize(width: from.width / CoverGeometry.focusScale, height: from.height / CoverGeometry.focusScale)
            PlaceholderArt(cover: app, hostID: hostID, wide: wide, scale: coverScale)
                .frame(width: size.width, height: size.height)
                .modifier(FlightFill(path: path, aspect: size.width / max(size.height, 1), base: size, progress: progress))
        }
    }

    /// The header's picture filling the flying frame, else its placeholder art (``CardArt``'s) laid out at the slot's size.
    @ViewBuilder private func header(_ path: FlightPath) -> some View {
        if let toArt {
            picture(toArt, path: path)
        } else {
            let placeholder = GameArt(hostID: hostID, app: app)
            PlaceholderArt(hue: placeholder.hue, hue2: placeholder.hue2, icon: placeholder.icon, glyphSize: 320 * to.width / 300 / 1.13,
                           glyphRight: -36, glyphTop: 0.24, title: app.title, titleSize: 34 * to.width / 300,
                           titleInset: 26, titleBottom: 26, titleFit: false)
                .frame(width: to.width, height: to.height)
                .modifier(FlightFill(path: path, aspect: to.width / max(to.height, 1), base: to.size, progress: progress))
        }
    }

    /// [image] filling the flying frame, drawn once at its size filling the slot.
    private func picture(_ image: CGImage, path: FlightPath) -> some View {
        let aspect = Double(image.width) / Double(max(image.height, 1))
        let base = OverviewMotion.fillSize(aspect: aspect, box: to.size)
        return Image(decorative: image, scale: 1).resizable().interpolation(.medium)
            .frame(width: base.width, height: base.height)
            .modifier(FlightFill(path: path, aspect: aspect, base: base, progress: progress))
    }
}

/// Where the flying cover is: ``OverviewMotion/flightFrame(from:to:progress:lift:)`` between two frames.
private struct FlightPath {
    let from: CGRect
    let to: CGRect
    let lift: Double

    func frame(_ progress: Double) -> CGRect {
        OverviewMotion.flightFrame(from: from, to: to, progress: progress, lift: lift)
    }
}

/// The flying cover's outline at the flight's progress: its frame with the corners between the card's and the slot's.
private struct FlightClip: Shape {
    let path: FlightPath
    let fromCorner: Double
    let toCorner: Double
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // The spring may pass its end a little; the corners never do
        RoundedRectangle(cornerRadius: Motion.lerp(fromCorner, toCorner, min(max(progress, 0), 1)), style: .continuous).path(in: path.frame(progress))
    }
}

/// The header's picture over the card's in the flying frame: it crosses over linearly between 30 and 70 % of the flight,
/// following the flight's own progress frame by frame, so neither end shows the other picture.
private struct FlightCrossfade: ViewModifier, Animatable {
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(min(max((progress - 0.3) / 0.4, 0), 1))
    }
}

/// A picture drawn at [base] (its size filling the slot) moved and scaled to fill the flying frame at the flight's
/// progress: one scale for both axes (``OverviewMotion/fill(aspect:base:frame:)``).
private struct FlightFill: GeometryEffect {
    let path: FlightPath
    let aspect: Double
    let base: CGSize
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let fill = OverviewMotion.fill(aspect: aspect, base: base, frame: path.frame(progress))
        return ProjectionTransform(CGAffineTransform(a: fill.scale, b: 0, c: 0, d: fill.scale, tx: fill.dx, ty: fill.dy))
    }
}

/// A cover of the dashboard's row while the overview opens or closes (`homeOut` of the prototype): the others lift away
/// one after another with the settle spring (``OverviewMotion/settle``; up by 160 px plus 30 per cover of distance, to
/// 92 %, 34 ms apart) and come back together with the closing flight's spring; the one in the overview hides while its
/// card flies and shows again at once when the flight lands; with reduced motion they only fade. The focused cover
/// follows a finger swiping it up.
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
        // Away with the settle spring, 34 ms apart; back all together with the closing flight's spring
        let motion = reduced ? OverviewMotion.reducedFade
            : descent.active ? OverviewMotion.settle.delay(Double(distance) * OverviewMotion.coverLiftStagger / 1000) : OverviewMotion.flightCloseSpring
        content
            .offset(y: lift ? stage.px(OverviewMotion.coverLift(distance: distance)) : 0)
            .scaleEffect(lift ? OverviewMotion.coverLiftScale : 1)
            .opacity(descent.active ? 0 : 1)
            .animation(motion, value: descent.active)
            .animation(nil) { $0.opacity(mine ? 0 : 1) }
            .offset(y: dragged)
            #if os(iOS)
            .gesture(CoverSwipeGesture(
                app: app, launcher: launcher, enabled: distance == 0 && !descent.active,
                minimumDistance: OverviewMotion.swipeSlop, threshold: stage.px(OverviewMotion.swipeOpen)))
            #endif
    }
}

extension OverviewMotion {
    /// The cover's flight is a spring (interruptible: Back mid-flight turns it around from where it is, at its speed):
    /// response 0.42 s, damping 0.72 out to the header (it overshoots by about 3.8 % and settles once); 0.36 s, 0.80
    /// back to the card (about 1.5 %). The overshoot only grows the cover (``flightFrame(from:to:progress:lift:)``);
    /// the corners and the crossfades are clamped.
    static let flightOpenSpring = Animation.spring(response: 0.42, dampingFraction: 0.72)
    static let flightCloseSpring = Animation.spring(response: 0.36, dampingFraction: 0.8)
    /// The page and its parts land with the same family: response 0.45 s, damping 0.78. An opacity it drives is
    /// clamped to 0…1 by the renderer, so it never overshoots.
    static let settle = Animation.spring(response: 0.45, dampingFraction: 0.78)
    /// The chips beside the ratings pop with response 0.4 s, damping 0.7.
    static let chipSpring = Animation.spring(response: 0.4, dampingFraction: 0.7)
    /// The header's parts leave with an ease-in over 180 ms.
    static let leave = Animation.timingCurve(0.5, 0, 0.75, 0, duration: 0.18)
    /// Reduced motion: no springs, 280 ms fades.
    static let reducedFade = Animation.easeOut(duration: 0.28)
}

/// The overview's horizontal rows (Screenshots and videos, Similar games) move like the dashboard's covers: each step of
/// the arrows or the D-pad glides the focused item to the row's start (its content inset, 150 px) in 200 ms
/// (`cubic-bezier(.33, 1, .68, 1)`), the row clamping at its end; the ends fade as the dashboard's row's do.
enum OverviewAnchorRow {
    @MainActor static func step(position: Binding<ScrollPosition>, x: Double, reduced: Bool) {
        if reduced { position.wrappedValue.scrollTo(x: x) }
        else { withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.2)) { position.wrappedValue.scrollTo(x: x) } }
    }
}

extension View {
    /// The row is moved by the focus alone (a hardware keyboard's arrows would also scroll it by themselves), and its
    /// ends fade where items go on behind them (``RowFade``).
    func overviewAnchorRow() -> some View {
        focusable(false)
            .scrollEdgeFade(.horizontal, FadeEdges(start: FadeEdge(solid: RowFade.start), end: FadeEdge(solid: RowFade.endSolid, clear: RowFade.endClear)),
                            growth: RowFade.switching, outset: 1000)
    }
}
