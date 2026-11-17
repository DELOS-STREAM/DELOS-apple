import DelosData
import DelosHost
import SwiftUI

/// What the library of a PC shows (`Library` of DELOS for Android, for one PC).
enum HomeContent: Equatable {
    /// The apps are being asked for the first time.
    case loading
    case offline
    case empty
    case apps([HostApp])

    /// [apps]: the list as last loaded (nil: never); [loadFailed]: the last attempt to load it failed.
    init(apps: [HostApp]?, loadFailed: Bool) {
        if let apps, !loadFailed {
            self = apps.isEmpty ? .empty : .apps(apps)
        } else if loadFailed {
            self = .offline
        } else {
            self = .loading
        }
    }
}

/// Where the 16:9 home's title box, info row and covers stand, stage pixels (`HomeStandard` of DELOS for Android; the
/// wide and tall stages share its numbers). The covers' row starts at ``rowTop`` (moving up with the interface scale),
/// the info row ``infoRingGap`` above the focused cover's ring, and the title box (a 180 px logo with 10 px of air)
/// is centred in the room between the status bar and the info row.
struct HomeLayout: Equatable {
    let titleTop: Double
    let titleBox: Double
    let titleGap: Double
    let infoHeight: Double
    let coverTop: Double

    /// Where the row starts on a 1080 px high stage, and so how far its covers end above the stage's bottom: the row
    /// keeps that distance from the bottom edge on every stage height (owner: the row is always at the bottom, with the
    /// same margin; room above it grows on a taller stage, and the space below is kept for what a down arrow will show).
    static let rowTop = 430.0
    static let designHeight = 1080.0
    static let rowPad = 90.0
    static let rowShift = 92.0
    static let titleBoxMax = 200.0
    static let logoPad = 10.0
    static let infoRingGap = 44.0
    /// `HomeCompact`'s numbers the standard layout uses.
    static let statusBar = 104.0, gapStatus = 16.0, infoRowHeight = 44.0, coverHeight = 450.0, focusScale = 1.055, ring = 10.0

    static func ringReach(_ height: Double) -> Double { height * (focusScale - 1) / 2 + ring * focusScale }

    /// The layout at the interface scale [scale]; [safeTop] is the display cutout.
    init(scale: Double, safeTop: Double = 0, stageHeight: Double = HomeLayout.designHeight) {
        let rowTop = Self.rowTop + (stageHeight - Self.designHeight) - (scale - 1) * Self.rowShift
        let ringTop = rowTop + Self.rowPad - Self.ringReach(Self.coverHeight)
        let infoHeight = Self.infoRowHeight * scale
        let infoTop = ringTop - Self.infoRingGap - infoHeight
        let statusBottom = safeTop + Self.statusBar * scale
        let room = infoTop - statusBottom
        // The box keeps its size unless the room is smaller than it and the two least gaps
        let box = max(min(Self.titleBoxMax, room - 2 * Self.gapStatus), 0)
        let gap = (room - box) / 2
        titleTop = statusBottom + gap
        titleBox = box
        titleGap = gap
        self.infoHeight = infoHeight
        coverTop = rowTop + Self.rowPad
    }
}

/// The library of a paired PC (`HomeScreen` of DELOS for Android): the focused game's background behind everything
/// (drawn by the backdrop), its logo or title, the info row with its streaming time and the row of covers (SteamGridDB
/// covers, the PC's box art, or placeholder art; the first one three covers wide). A starts the app, its context menu
/// resumes, quits or starts it. The PC is asked again and its apps loaded when the screen shows; with SteamGridDB on,
/// the artwork of games never looked up is downloaded in the background.
struct HomeScreen: View {
    let hostID: String
    let focus: FocusModel
    let actions: ShellActions
    @Environment(Layers.self) private var layers
    @Environment(HostStore.self) private var hosts
    @Environment(HomeArt.self) private var art
    @State private var loadFailed = false

    /// The focus the screen opens with: no item has it, so the covers, once loaded, give it to the first one.
    static let initialFocus = "first-app"

    var body: some View {
        let name = hosts.host(hostID)?.name ?? ""
        Group {
            switch HomeContent(apps: hosts.apps[hostID], loadFailed: loadFailed) {
            case .loading: HomeMessage(icon: Symbols.loading, title: L("home_loading"), text: nil)
            case .offline: HomeMessage(icon: Symbols.wifiOff, title: L("home_offline_title", name), text: nil)
            case .empty: HomeMessage(icon: Symbols.sportsEsports, title: L("home_empty_title", name), text: L("home_empty_note"))
            case .apps(let apps): GameLibrary(hostID: hostID, apps: actions.libraryOrder(hostID: hostID, apps: apps), focus: focus, actions: actions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: hostID) {
            art.hero = nil
            await hosts.refresh(hostID)
            do {
                try await hosts.loadApps(hostID)
                loadFailed = false
            } catch {
                loadFailed = true
                return
            }
            await actions.downloadArtwork(hostID: hostID, refresh: false, quiet: true)
        }
        .onChange(of: HomeContent(apps: hosts.apps[hostID], loadFailed: loadFailed)) { _, now in
            // Without games there is no game background
            if case .apps = now {} else { art.hero = nil }
        }
    }
}

/// What A (or a tap) on a cover does (`GameTile`'s `activate`).
enum GameActivation: Equatable {
    /// Start or resume the game.
    case start
    /// Another game runs on the PC: open the game's menu (quit that one and start this one, or resume the running one)
    /// instead of quitting the running game by a stray press.
    case offerChoices

    /// [running]: the game running on the PC, when it is one of the library's.
    static func of(app: Int, running: Int?) -> GameActivation {
        guard let running, running != app else { return .start }
        return .offerChoices
    }
}

/// Which cover has the focus when the library opens, and where the focus goes when its game disappears.
enum LibraryFocus {
    /// The index of the cover that opens focused: the one the screen's focus still holds ([focused], an app id), else the
    /// one remembered from the last time this PC's library was shown, else the first (`HomeScreen`'s
    /// `focusedIndex`). [apps]: the library's app ids in order.
    static func initial(apps: [Int], focused: Int?, remembered: Int?) -> Int {
        if let focused, let index = apps.firstIndex(of: focused) { return index }
        if let remembered, let index = apps.firstIndex(of: remembered) { return index }
        return 0
    }

    /// The index that takes the focus when the focused game disappeared from a library of [count] games (hidden,
    /// removed): its neighbour, which now stands where it stood.
    static func afterRemoval(count: Int, lastIndex: Int) -> Int {
        max(min(lastIndex, count - 1), 0)
    }
}

/// The wrap of the row: left on the first cover goes round to the last one, right on the last one back to the first.
enum LibraryWrap {
    static func moves(index: Int, ids: [AnyHashable]) -> [FocusDirection: AnyHashable] {
        guard ids.count > 1 else { return [:] }
        if index == 0 { return [.left: ids[ids.count - 1]] }
        if index == ids.count - 1 { return [.right: ids[0]] }
        return [:]
    }

    /// Whether the focus going from cover [from] to cover [to] is a wrap round the row.
    static func isWrap(from: Int?, to: Int, count: Int) -> Bool {
        guard let from, count > 2 else { return false }
        return (from == 0 && to == count - 1) || (from == count - 1 && to == 0)
    }

    /// A wrap over more than this many covers fades out, jumps this far short of the other end and fades in again, so the
    /// glide does not have to cross every cover.
    static let glideItems = 12

    /// How far the row overshoots the end it arrives at before it settles back, stage pixels, for a glide of [distance]
    /// (`rowBounce` of `HomeScreen.kt`: a spring kicked with the glide's speed, at most 4200 px/s).
    static func bounce(distance: Double) -> Double {
        min(distance * 1.75 / 0.36, 4200) * 0.035
    }
}

/// The covers of a state of the context menu: the ones beside the focused cover idle slightly muted
/// (`saturate(.86) brightness(.92)`) and dim further while a context menu is open (`.6` and `.5`), so the cover the
/// menu belongs to stands out. The focused cover keeps its colors.
enum CoverTone {
    static func of(focused: Bool, menuOpen: Bool) -> (saturation: Double, brightness: Double) {
        if focused { return (1, 1) }
        return menuOpen ? (0.6, 0.5) : (0.86, 0.92)
    }

    /// The info block's opacity: it dims behind an open context menu.
    static func info(menuOpen: Bool) -> Double { menuOpen ? 0.4 : 1 }
}

/// The row's edge fades (`fadeMask` of DELOS for Android): transparent up to [startClear] stage pixels from the left
/// edge, opaque from [startSolid], opaque until [endSolid] before the right edge and transparent from [endClear] before it.
enum RowFade {
    static func stops(width: Double, startClear: Double, startSolid: Double, endSolid: Double, endClear: Double)
        -> [(location: Double, opacity: Double)]
    {
        func at(_ px: Double) -> Double { min(max(px / width, 0), 1) }
        return [
            (0, 0), (at(startClear), 0), (at(startSolid), 1),
            (1 - at(endSolid), 1), (1 - at(endClear), 0), (1, 0),
        ]
    }

    /// The fade at the left edge, stage pixels, when covers lie beyond it.
    static let start = 120.0
    /// The fade at the right edge, and the clear strip at its end, when covers lie beyond it.
    static let endSolid = 260.0, endClear = 20.0
}

/// The row's edge fades, each of which fades out ([back], [forward] from 1 to 0) while no cover lies beyond its edge,
/// so the first cover's ring and glow are not faded at the start nor the last one's at the end.
private struct RowEdgeFade: ViewModifier, Animatable {
    var back: Double
    var forward: Double
    /// The stage's width in stage pixels.
    let width: Double
    let overdraw: Double

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(back, forward) }
        set { (back, forward) = (newValue.first, newValue.second) }
    }

    func body(content: Content) -> some View {
        let stops = RowFade.stops(
            width: width, startClear: 0, startSolid: RowFade.start * back,
            endSolid: RowFade.endSolid * forward, endClear: RowFade.endClear * forward)
        content.mask {
            LinearGradient(
                stops: stops.map { .init(color: .black.opacity($0.opacity), location: $0.location) },
                startPoint: .leading, endPoint: .trailing
            )
            // The glow and the ring of a cover reach above and below the row: the mask only cuts sideways
            .padding(.vertical, -overdraw)
        }
    }
}

/// Which ends of the row have covers beyond them.
private struct ScrollEnds: Equatable {
    var back = false
    var forward = false
}

/// The games: the focused one's title and info above the row of covers. The focused cover stays where the first one
/// starts (Android keeps it at the left edge too). The focused game is remembered, so the way back from Settings,
/// Profile, Devices or a stream returns to it with the row scrolled to it; the row wraps at its ends and fades where
/// more covers continue; the covers of the first screenful enter one after the other.
struct GameLibrary: View {
    let hostID: String
    let apps: [HostApp]
    let focus: FocusModel
    let actions: ShellActions
    @Environment(HostStore.self) private var hosts
    @Environment(HomeArt.self) private var art
    @Environment(GameMetadataModel.self) private var metadata
    @Environment(Layers.self) private var layers
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: .leading)
    @State private var lastFocusMove = Date.distantPast
    /// Where the focused game stood, for the one that takes its place when it disappears.
    @State private var lastIndex = 0
    @State private var ends = ScrollEnds()
    /// The row faded out for a moment while a long wrap jumps close to the other end.
    @State private var rowAlpha = 1.0
    /// The overshoot at the end of a wrap, stage pixels.
    @State private var rowBounce = 0.0
    @State private var wrap: Task<Void, Never>?

    static let tile = 300.0, height = 450.0, gap = 44.0
    /// The wide first cover: three covers and the two gaps between them.
    static let wide = 3 * tile + 2 * gap
    /// Room above and below the covers for the focus scale, the ring and the glow, which the scroll view would cut.
    static let rowPad = 40.0
    static let focusScale = 1.055

    /// Where cover [index] starts in the row, stage pixels from the first one.
    static func itemStart(_ index: Int) -> Double {
        index == 0 ? 0 : wide + gap + Double(index - 1) * (tile + gap)
    }

    /// The room after the last cover (`CoverGeometry.endPadding`): the focused wide first cover grows only to the left, so
    /// it ends closer to the edge than the others, which grow evenly; the last cover, focused, is as far from the right
    /// edge as the first one, focused, is from the left one (about 104 px for the first cover's 150 px).
    static func endPadding(start: Double) -> Double {
        start - wide * (focusScale - 1) + tile * (focusScale - 1) / 2
    }

    /// A or a tap on [app] opens its menu (another game runs on the PC) instead of starting it.
    private func offersChoices(_ app: HostApp) -> Bool {
        let running = hosts.host(hostID).flatMap { $0.runningAppID == 0 ? nil : $0.runningAppID }
        let known = running.flatMap { id in apps.first { $0.id == id }?.id }
        return GameActivation.of(app: app.id, running: known) == .offerChoices
    }

    private var menuOpen: Bool {
        if case .context = layers.layer { true } else { false }
    }

    var body: some View {
        let ids = apps.map(\.id)
        let focusedIndex = apps.firstIndex { focus.focused == AnyHashable(Self.id($0)) }
        // Before the library takes the focus, the game it will take it with is the one shown
        let current = focusedIndex ?? LibraryFocus.initial(apps: ids, focused: nil, remembered: actions.homeGame(hostID: hostID))
        let focused = apps[current]
        let layout = HomeLayout(scale: stage.textScale, safeTop: stage.safe.top, stageHeight: stage.height)
        let host = hosts.host(hostID)
        let running = host.flatMap { $0.runningAppID == 0 ? nil : $0.runningAppID }
        let last = actions.lastPlayed(hostID: hostID)
        let start = 150 + stage.safe.leading
        let end = Self.endPadding(start: 150 + stage.safe.trailing)
        let keys = apps.map { AnyHashable(Self.id($0)) }
        ZStack(alignment: .topLeading) {
            GameInfo(hostID: hostID, app: focused, pcName: host?.name ?? "", running: running == focused.id,
                     playtime: actions.playtime(hostID: hostID, appID: focused.id), layout: layout)
                .padding(.leading, stage.px(start))
                .padding(.top, stage.px(layout.titleTop))
                // Behind an open context menu the info block dims to 40 %
                .opacity(CoverTone.info(menuOpen: menuOpen))
                .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000), value: menuOpen)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: stage.px(Self.gap)) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        let badge: CoverBadge? = app.id == running ? .running : index == 0 && app.id == last ? .lastPlayed : nil
                        FocusItem(
                            id: Self.id(app), model: focus, moves: LibraryWrap.moves(index: index, ids: keys),
                            menu: { actions.gameMenu(hostID: hostID, app: app) },
                            // The offer menu plays its own OPEN cue, not SELECT
                            clickCue: offersChoices(app) ? nil : .select,
                            action: { actions.activate(hostID: hostID, app: app, focus: focus) }
                        ) { isFocused in
                            Cover(hostID: hostID, app: app, wide: index == 0, focused: isFocused, menuOpen: menuOpen, badge: badge)
                        }
                        .staggerEntrance()
                    }
                }
                .padding(.leading, stage.px(start))
                .padding(.trailing, stage.px(end))
                .padding(.vertical, stage.px(Self.rowPad))
            }
            .entranceScope()
            .scrollClipDisabled()
            // The row is moved by the focus alone: without this a hardware keyboard's arrow keys also scroll the
            // scroll view by themselves, on top of the focus (owner's iPad with a Magic Keyboard: a crawl, then the
            // focus ran off the screen)
            .focusable(false)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollEnds.self) { geometry in
                ScrollEnds(back: geometry.visibleRect.minX > 1, forward: geometry.visibleRect.maxX < geometry.contentSize.width - 1)
            } action: { _, now in
                ends = now
            }
            .padding(.top, stage.px(layout.coverTop - Self.rowPad))
            .modifier(RowEdgeFade(back: ends.back ? 1 : 0, forward: ends.forward ? 1 : 0, width: stage.width, overdraw: stage.px(1000)))
            .animation(.easeInOut(duration: 0.3), value: ends)
            .opacity(rowAlpha)
            .offset(x: stage.px(rowBounce))
            #if os(tvOS)
            // The system focus engine has nowhere to go past the ends: the wrap is made here
            .onMoveCommand { direction in
                guard let focusedIndex else { return }
                for (move, target) in LibraryWrap.moves(index: focusedIndex, ids: keys) where move.matches(direction) {
                    focus.focus(target)
                }
            }
            #endif
            .onChange(of: focusedIndex) { old, now in
                guard let now else { return }
                lastIndex = now
                actions.rememberHomeGame(hostID: hostID, appID: apps[now].id)
                if LibraryWrap.isWrap(from: old, to: now, count: apps.count) {
                    glide(to: now, from: old ?? now)
                    return
                }
                wrap?.cancel()
                rowAlpha = 1
                rowBounce = 0
                // A held arrow moves the focus every 50 ms: overlapping 200 ms animations lagged behind it, so a fast
                // move scrolls in one short step and a single press glides
                let fast = Date.now.timeIntervalSince(lastFocusMove) < 0.12
                lastFocusMove = .now
                scroll(to: now, animation: fast ? .linear(duration: 0.05) : .timingCurve(0.33, 1, 0.68, 1, duration: 0.2))
            }
            // The focused game disappeared (hidden, removed): its neighbour takes the focus
            .onChange(of: ids) { _, now in
                guard focusedIndex == nil, !apps.isEmpty else { return }
                focus.focus(Self.id(apps[LibraryFocus.afterRemoval(count: now.count, lastIndex: lastIndex)]))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The covers register after the screen shows, and the model would take whichever comes first: the game that had
        // the focus when the library was left (or was remembered from the last time), else the first one, takes it,
        // and the row opens scrolled to it
        .onAppear {
            let focusedID = apps.first { focus.focused == AnyHashable(Self.id($0)) }?.id
            let index = LibraryFocus.initial(apps: ids, focused: focusedID, remembered: actions.homeGame(hostID: hostID))
            lastIndex = index
            actions.rememberHomeGame(hostID: hostID, appID: apps[index].id)
            focus.focus(Self.id(apps[index]))
            scroll(to: index, animation: nil)
        }
        .onDisappear { wrap?.cancel() }
        // The focused game's information is looked up (the store decides from its cache whether it is due)
        .task(id: focused.id) { metadata.ensure(focused) }
        // The game background follows the focus with a short delay, so it does not flicker while scrolling fast
        .task(id: "\(GameArt.key(hostID, focused.id))#\(art.artwork.version)") {
            let image = await heroImage(focused)
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            art.hero = GameArt(hostID: hostID, app: focused, image: image)
        }
    }

    /// Scrolls the row so cover [index] stands at its start: animated, or at once with reduced motion or no [animation].
    private func scroll(to index: Int, animation: Animation?) {
        let x = stage.px(Self.itemStart(index))
        if let animation, !reduceMotion {
            withAnimation(animation) { position.scrollTo(x: x) }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { position.scrollTo(x: x) }
        }
    }

    /// The wrap round the row (`GameLibrary`'s key handler of Android): far away, the row fades out, jumps near the other
    /// end and fades in; then it glides there without slowing down and, arriving, overshoots the end a little and settles
    /// back. With reduced motion it jumps.
    private func glide(to target: Int, from source: Int) {
        wrap?.cancel()
        if reduceMotion {
            scroll(to: target, animation: nil)
            return
        }
        wrap = Task { @MainActor in
            if abs(target - source) > LibraryWrap.glideItems {
                withAnimation(.easeOut(duration: 0.11)) { rowAlpha = 0 }
                try? await Task.sleep(for: .milliseconds(110))
                guard !Task.isCancelled else { return }
                scroll(to: target == 0 ? LibraryWrap.glideItems : max(target - LibraryWrap.glideItems, 0), animation: nil)
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.26)) { rowAlpha = 1 }
            }
            let distance = abs(Self.itemStart(target) - Self.itemStart(min(source, apps.count - 1)))
            scroll(to: target, animation: .timingCurve(0.45, 0.05, 0.8, 0.65, duration: 0.36))
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }
            // Arriving at the last cover the content moves left, at the first one right
            let overshoot = LibraryWrap.bounce(distance: distance) * (target == 0 ? 1 : -1)
            withAnimation(.easeOut(duration: 0.09)) { rowBounce = overshoot }
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.36)) { rowBounce = 0 }
        }
    }

    /// The game background's image: the SteamGridDB hero, else the cover, else the PC's box art.
    private func heroImage(_ app: HostApp) async -> CGImage? {
        if art.artwork.enabled {
            if let hero = await art.image(hostID: hostID, appID: app.id, kind: .hero) { return hero }
            if let cover = await art.image(hostID: hostID, appID: app.id, kind: .cover) { return cover }
        }
        return await art.boxArt(hostID: hostID, appID: app.id, hosts: hosts)
    }

    static func id(_ app: HostApp) -> String { "app-\(app.id)" }
}

/// The focused game's logo or title and the info row under it (`GameInfo` of DELOS for Android).
private struct GameInfo: View {
    let hostID: String
    let app: HostApp
    let pcName: String
    let running: Bool
    let playtime: Playtime
    let layout: HomeLayout
    @Environment(GameMetadataModel.self) private var metadata
    @Environment(HomeArt.self) private var art
    @Environment(\.matchGameColors) private var matchGameColors
    @Environment(\.stage) private var stage

    var body: some View {
        // Up to two genres and two themes: Steam's user tags when the game has them, else IGDB's lists; the facts first
        let data = metadata.data(for: app)
        let genres = GameTags.topGenres(data?.candidate?.genres.filter { !$0.name.isEmpty } ?? [], steamTags: data?.steamTags ?? [])
        let themes = GameTags.topThemes(data?.candidate?.themes.filter { !$0.name.isEmpty } ?? [], steamTags: data?.steamTags ?? [])
        let hdr = data?.hdrBadge
        let completion = data?.completionSeconds.map(CompletionLength.init(seconds:))
        // The colors of the animated background: the cover's, the game background's while those are unknown
        let gameColors = matchGameColors ? art.gameColors(GameArt.key(hostID, app.id)) : nil
        VStack(alignment: .leading, spacing: 0) {
            GameTitle(hostID: hostID, app: app, box: layout.titleBox)
            Spacer().frame(height: stage.px(layout.titleGap))
            InfoRow(playtime: playtime, height: layout.infoHeight,
                    hasFacts: running || hdr != nil || completion != nil,
                    hasTags: !genres.isEmpty || !themes.isEmpty) {
                if running { InfoChip(icon: Symbols.running, label: L("home_chip_running_on", pcName)) }
                switch hdr {
                case .hdr: NativeHDRChip()
                case .sdr: InfoChip(icon: Symbols.sdr, label: "SDR")
                case .unknown: InfoChip(icon: Symbols.hdrUnknown, label: L("metadata_hdr_unverified"))
                case nil: EmptyView()
                }
                if let completion {
                    InfoChip(icon: Symbols.completionTime, label: L("home_chip_hltb", TagLook.completionText(completion)))
                }
            } tags: {
                if !genres.isEmpty { GenrePill(genres: genres, gameColors: gameColors) }
                if !themes.isEmpty { ThemePill(themes: themes, gameColors: gameColors) }
            }
            .frame(maxWidth: stage.px(1620), alignment: .leading)
        }
    }
}

/// The SteamGridDB logo in the title box (fitted, at the start), else the name in a gradient from the text color into
/// the game background's main color; the space is kept while the logo is being looked for. Both enter by sliding in
/// from 32 px to the left over 800 ms.
private struct GameTitle: View {
    let hostID: String
    let app: HostApp
    let box: Double
    @Environment(HomeArt.self) private var art
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion
    @State private var logo: CGImage?
    @State private var resolved = false

    var body: some View {
        let key = GameArt.key(hostID, app.id)
        ZStack(alignment: .leading) {
            if let logo {
                Image(decorative: logo, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: stage.px(900), maxHeight: stage.px(box - 2 * HomeLayout.logoPad), alignment: .leading)
                    .accessibilityLabel(app.title)
                    .modifier(TitleEntrance(key: key + "/logo", reduced: reduceMotion))
            } else if resolved {
                let size = app.title.count > 22 ? 56.0 : app.title.count > 13 ? 68 : 84
                let placeholder = GameArt(hostID: hostID, app: app)
                Text(app.title)
                    .font(DelosFonts.unbounded(stage.tpx(size), .bold))
                    .tracking(-0.01 * stage.tpx(size))
                    .lineLimit(1)
                    .foregroundStyle(LinearGradient(
                        stops: [.init(color: colors.text.color, location: 0.25),
                                .init(color: hsl(art.heroHue(key) ?? placeholder.hue2, 70, 58).color, location: 1)],
                        startPoint: .top, endPoint: .bottom))
                    .padding(.trailing, stage.px(150))
                    .modifier(TitleEntrance(key: key, reduced: reduceMotion))
            }
        }
        .frame(height: stage.px(box), alignment: .leading)
        .task(id: "\(key)#\(art.artwork.version)") {
            let cached = art.cachedImage(hostID: hostID, appID: app.id, kind: .logo)
            logo = cached
            resolved = cached != nil || !art.artwork.enabled
            guard cached == nil, art.artwork.enabled else { return }
            logo = await art.image(hostID: hostID, appID: app.id, kind: .logo)
            resolved = true
        }
    }
}

/// The selection entrance of a game's title (`gameTitleEntrance`): it appears before the movement ends, so its slow
/// settling stays visible.
private struct TitleEntrance: ViewModifier {
    let key: String
    let reduced: Bool
    @State private var progress = 0.0
    @Environment(\.stage) private var stage

    func body(content: Content) -> some View {
        content
            .modifier(TitleEntranceEffect(progress: progress, distance: stage.px(32)))
            .onAppear(perform: run)
            .onChange(of: key) { _, _ in run() }
    }

    private func run() {
        guard !reduced else {
            progress = 1
            return
        }
        progress = 0
        withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.8)) { progress = 1 }
    }
}

private struct TitleEntranceEffect: ViewModifier, Animatable {
    var progress: Double
    let distance: CGFloat

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(min(max(progress * 1.5, 0), 1))
            .offset(x: (1 - progress) * distance)
    }
}

/// The badge on a cover's top-left corner (`TileBadge`).
enum CoverBadge {
    case running, lastPlayed

    var icon: String { self == .running ? Symbols.running : Symbols.history }
    var label: String { self == .running ? L("home_badge_running") : L("home_badge_last_played") }
}

/// A cover: the SteamGridDB cover (the wide cover for the first one), else, while a SteamGridDB lookup is still
/// expected, the placeholder art (so the PC's box art is not shown only to be replaced), else the PC's box art, else
/// the placeholder art with the title (`GameTile`, `tileArtSource`).
private struct Cover: View {
    let hostID: String
    let app: HostApp
    let wide: Bool
    let focused: Bool
    /// A context menu is open: the covers beside the focused one dim.
    let menuOpen: Bool
    let badge: CoverBadge?
    @Environment(HostStore.self) private var hosts
    @Environment(HomeArt.self) private var art
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @State private var shown: CGImage?

    /// A lookup that never finishes (offline, failed) stops being waited for after this long.
    static let lookupGiveUp = Duration.seconds(20)

    var body: some View {
        let width = wide ? GameLibrary.wide : GameLibrary.tile
        let tone = CoverTone.of(focused: focused, menuOpen: menuOpen)
        let shape = RoundedRectangle(cornerRadius: stage.px(26))
        let placeholder = GameArt(hostID: hostID, app: app)
        ZStack(alignment: .topLeading) {
            shape.fill(colors.surface2.color)
            ZStack {
                if let shown {
                    Image(decorative: shown, scale: 1).resizable().scaledToFill()
                        .frame(width: stage.px(width), height: stage.px(GameLibrary.height))
                        // The idle and menu filters (`IdleCoverFilter`, `menuDimCoverFilter`); the placeholder art has none
                        .saturation(tone.saturation)
                        .colorMultiply(Color(white: tone.brightness))
                        .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000), value: menuOpen)
                        .transition(.opacity)
                } else {
                    PlaceholderArt(
                        hue: placeholder.hue, hue2: placeholder.hue2, icon: placeholder.icon,
                        glyphSize: wide ? 420 : 320, glyphRight: wide ? 40 : -36, glyphTop: wide ? 0.04 : 0.24,
                        title: app.title, titleSize: wide ? 72 : 34, titleInset: wide ? 44 : 26, titleBottom: wide ? 40 : 26)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: shown.map(ObjectIdentifier.init))
            if art.artwork.isBusy(hostID: hostID, appID: app.id) {
                ProgressView()
                    .tint(.white)
                    .frame(width: stage.px(56), height: stage.px(56))
                    .background(Circle().fill(Color(.sRGB, red: 5 / 255, green: 10 / 255, blue: 20 / 255, opacity: 0.55)))
                    .padding(stage.px(16))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let badge {
                HStack(spacing: stage.px(8)) {
                    SymbolView(symbol: badge.icon, size: 22, color: RGBA(red: 1, green: 1, blue: 1), filled: true)
                    Text(badge.label)
                        .font(DelosFonts.figtree(stage.tpx(18), .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, stage.px(14))
                .padding(.vertical, stage.px(6))
                .background(Capsule().fill(Color(.sRGB, red: 5 / 255, green: 10 / 255, blue: 20 / 255, opacity: 0.55)))
                .padding(stage.px(18))
            }
        }
        .frame(width: stage.px(width), height: stage.px(GameLibrary.height))
        .clipShape(shape)
        .overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        // Android's TILE_FOCUS_SCALE; the wide first cover grows only to the left, so it never covers its neighbour
        .focusLook(focused, scale: 1.055, ring: 5, glowBlur: 50, glowY: 18, corner: 26, anchor: wide ? .trailing : .center, sweep: true)
        .task(id: "\(app.id)#\(art.artwork.version)") { await load() }
    }

    private func load() async {
        let key = GameArt.key(hostID, app.id)
        let artwork = art.artwork
        var cover: CGImage?
        if artwork.enabled {
            cover = await art.image(hostID: hostID, appID: app.id, kind: .cover)
            let tile = wide ? await art.image(hostID: hostID, appID: app.id, kind: .wide) : cover
            if let tile {
                shown = tile
                // The game's colors come from its cover, worked out as soon as it is decoded
                art.analyzeCover(key, cover ?? tile)
                return
            }
            if artwork.lookupExpected, !(await artwork.lookupSettled(hostID: hostID, appID: app.id)) {
                // The cover is on its way (the version changes when it is stored); the box art if it never comes
                try? await Task.sleep(for: Self.lookupGiveUp)
                guard !Task.isCancelled else { return }
            }
        }
        guard let box = await art.boxArt(hostID: hostID, appID: app.id, hosts: hosts) else { return }
        shown = box
        art.analyzeCover(key, cover ?? box)
    }
}

/// An info pill (icon and label) in the glass style (`Chip` of DELOS for Android).
struct InfoChip: View {
    let icon: String
    let label: String
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(8)) {
            SymbolView(symbol: icon, size: 22, color: colors.text2)
            Text(label)
                .font(DelosFonts.figtree(stage.tpx(19)))
                .foregroundStyle(colors.text2.color)
                .lineLimit(1)
        }
        .padding(.horizontal, stage.px(16))
        .padding(.vertical, stage.px(6))
        .background {
            GlassShape(Capsule(), tint: colors.surface)
                .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
    }
}

/// A centered message for the loading, offline and empty states.
private struct HomeMessage: View {
    let icon: String
    let title: String
    let text: String?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        VStack(spacing: stage.px(22)) {
            SymbolView(symbol: icon, size: 110, color: colors.accent, filled: true)
            Text(title)
                .font(DelosFonts.unbounded(stage.tpx(52)))
                .foregroundStyle(colors.text.color)
            if let text {
                Text(text)
                    .font(DelosFonts.figtree(stage.tpx(26)))
                    .foregroundStyle(colors.text2.color)
            }
        }
        .multilineTextAlignment(.center)
        .staggerEntrance(index: 0, base: Motion.menuDelay)
    }
}

#if os(tvOS)
extension FocusDirection {
    /// Whether this is the direction of the remote's move command.
    func matches(_ command: MoveCommandDirection) -> Bool {
        switch (self, command) {
        case (.left, .left), (.right, .right), (.up, .up), (.down, .down): true
        default: false
        }
    }
}
#endif
