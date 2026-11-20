import DelosData
import DelosHost
import DelosInput
import SwiftUI

/// What the library of a PC shows (`Library` of DELOS for Android, for one PC).
enum HomeContent: Equatable {
    /// The PC is not (or no longer) paired: there is no library to show (`Library.NoPc`).
    case noPC
    /// The apps are being asked for the first time.
    case loading
    case offline
    case empty
    case apps([HostApp])

    /// [paired]: the PC is a paired PC DELOS knows; [apps]: the list as last loaded (nil: never); [loadFailed]: the last
    /// attempt to load it failed.
    init(paired: Bool = true, apps: [HostApp]?, loadFailed: Bool) {
        if !paired {
            self = .noPC
        } else if let apps, !loadFailed {
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
    @Environment(GameMetadataModel.self) private var metadata
    @Environment(Navigator.self) private var navigator
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.shellCoversArt) private var shellCoversArt
    @State private var loadFailed = false
    /// The library filter's sheet (Y, or a tap on the hint bar's Filter): its focus is new each time it opens.
    @State private var sheetOpen = false
    @State private var sheetFocus = FocusModel()
    /// The item that had the focus before the sheet opened, to return to it.
    @State private var origin: AnyHashable?
    /// The library has games and information about them to filter by: Y and the button are there.
    @State private var offered = false

    /// The focus the screen opens with: no item has it, so the covers, once loaded, give it to the first one.
    static let initialFocus = "first-app"

    private var content: HomeContent {
        HomeContent(paired: hosts.host(hostID)?.pin != nil, apps: hosts.apps[hostID], loadFailed: loadFailed)
    }

    /// The games the library lists before the filter: the PC's, without the hidden ones, in the library's order.
    private var listed: [HostApp] {
        if case .apps(let apps) = content { actions.libraryOrder(hostID: hostID, apps: apps) } else { [] }
    }

    /// This PC's filter; without a metadata service there is nothing to filter by.
    private var filters: MetadataFilters {
        metadata.enabled ? actions.libraryFilters.filters(hostID: hostID) : MetadataFilters()
    }

    var body: some View {
        let name = hosts.host(hostID)?.name ?? ""
        let listed = self.listed
        let filters = self.filters
        let visible = LibraryFilter.apply(filters, to: listed) { metadata.data(for: $0) }
        let offeredNow = metadata.enabled && !listed.isEmpty
        ZStack {
            Group {
                switch content {
                case .noPC: HomeMessage(icon: Symbols.devices, title: L("home_no_pc_title"), text: L("home_no_pc_devices_note"))
                case .loading: HomeMessage(icon: Symbols.loading, title: L("home_loading"), text: nil)
                case .offline: HomeMessage(icon: Symbols.wifiOff, title: L("home_offline_title", name), text: L("home_offline_devices_note"))
                case .empty: HomeMessage(icon: Symbols.sportsEsports, title: L("home_empty_title", name), text: L("home_empty_note"))
                case .apps:
                    // Every game hidden: the library has nothing to show until the side menu's switch is on
                    if listed.isEmpty {
                        HomeMessage(icon: Symbols.sportsEsports, title: L("home_empty_title", name), text: L("home_empty_note"))
                    } else if visible.isEmpty {
                        FilteredLibraryEmpty(focus: focus, onReset: resetFilters)
                    } else {
                        // Animated artwork (covers, the wide cover, the logo) plays only while nothing covers or stops it
                        // (`rememberArtworkMotion`); each cover adds whether it is on screen
                        GameLibrary(hostID: hostID, apps: visible, focus: focus, actions: actions)
                            .environment(\.artMotion, AnimatedPlayback.shouldPlay(
                                visible: !shellCoversArt && !AnimatedPlayback.layerStopsLibraryArt(layers.layer) && !sheetOpen,
                                foreground: true, streaming: false, reducedMotion: reducedMotion, systemReduceMotion: systemReduceMotion))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The screen under the sheet blurs like under every layer
            .modifier(LayerBackdropBlur(active: sheetOpen))
            sheet(filters: filters, listed: listed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenModal(sheetOpen ? sheetFocus : nil)
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
        // The whole library's information, so the filter and its genre list are complete (the focused game is asked for by the row)
        .task(id: "\(hostID)#\(metadata.enabled)#\(listed.map(\.id))") {
            guard metadata.enabled else { return }
            await metadata.ensureLibrary(listed)
        }
        .onChange(of: content) { _, now in
            // Without games there is no game background
            if case .apps = now {} else { art.hero = nil }
        }
        // Without covers (loading, offline, no games, all hidden) the first focus the screen was opened with is nothing: the
        // navigation has it until a cover appears and takes it
        .onChange(of: listed.isEmpty, initial: true) { _, none in
            if none { focus.focusFirstItem() }
        }
        .onChange(of: offeredNow, initial: true) { _, now in
            offered = now
            if !now, sheetOpen { closeSheet(silently: true) }
        }
        .onChange(of: filters.active) { was, now in
            // Reset disables itself once nothing is filtered; if it had the focus, the focus goes back to the first option
            if was, !now, sheetOpen, sheetFocus.focused == AnyHashable(LibraryFilterIDs.reset) {
                sheetFocus.focus(LibraryFilterIDs.start(filters, genres: LibraryFilter.genres(listed.map { metadata.data(for: $0) })))
            }
        }
        .onChange(of: ScreenFilter(label: offeredNow ? LibraryFilter.hintLabel(filters) : nil, open: sheetOpen), initial: true) { _, now in
            navigator.setHints(ScreenHints(sheetOpen: now.open, filterLabel: now.label), from: focus)
        }
        .onAppear { navigator.takeInput(focus) { command in capture(command) } }
        .onDisappear { navigator.releaseInput(focus) }
    }

    /// What the hint bar needs of the filter: Y's label (nil: no filter here) and whether the sheet is open.
    private struct ScreenFilter: Equatable {
        let label: String?
        let open: Bool
    }

    // MARK: Filter sheet

    @ViewBuilder private func sheet(filters: MetadataFilters, listed: [HostApp]) -> some View {
        if sheetOpen {
            let games = listed.map { metadata.data(for: $0) }
            let matching = games.indices.count { filters.matches(games[$0], builtIn: BundledArtwork.kind(listed[$0]) != nil) }
            LayerScrim(onTap: { closeSheet() })
            LibraryFilterSheet(
                state: LibraryFilterState(filters: filters, games: games, matching: matching), focus: sheetFocus,
                onChange: { actions.libraryFilters.set($0, hostID: hostID) }, onReset: resetFilters, onClose: { closeSheet() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(popTransition)
        }
    }

    /// The sheet settles in from a slight scale and leaves the same way (`dialogEnter` / `dialogExit`).
    private var popTransition: AnyTransition {
        if reducedMotion {
            return .asymmetric(
                insertion: .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000)),
                removal: .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.exit / 1000)))
        }
        return .asymmetric(
            insertion: .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000))
                .combined(with: .scale(scale: Motion.dialogFromScale).animation(Motion.out(Motion.popIn)))
                .combined(with: SlideByHeight(fraction: 1 / 25).animation(Motion.out(Motion.popIn))),
            removal: .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.exit / 1000))
                .combined(with: .scale(scale: Motion.dialogFromScale).animation(LayerHost.easeIn(Motion.exit)))
                .combined(with: SlideByHeight(fraction: 1 / 25).animation(LayerHost.easeIn(Motion.exit))))
    }

    private func openSheet() {
        guard offered, !sheetOpen else { return }
        let games = listed.map { metadata.data(for: $0) }
        actions.layers.feedback?.play(.open)
        origin = focus.focused
        sheetFocus = FocusModel(initial: LibraryFilterIDs.start(filters, genres: LibraryFilter.genres(games)))
        navigator.armInputGate()
        withAnimation { sheetOpen = true }
    }

    private func closeSheet(silently: Bool = false) {
        guard sheetOpen else { return }
        if !silently { actions.layers.feedback?.play(.back) }
        withAnimation { sheetOpen = false }
        // The focus goes back to where it was; a cover the filter removed leaves it on the game that took its place
        var stillThere = true
        if let id = origin as? String, id.hasPrefix("app-") {
            stillThere = LibraryFilter.apply(filters, to: listed) { metadata.data(for: $0) }.contains { GameLibrary.id($0) == id }
        }
        if stillThere, let origin { focus.focus(origin) }
    }

    private func resetFilters() {
        guard filters.active else { return }
        actions.layers.feedback?.play(.select)
        actions.libraryFilters.set(MetadataFilters(), hostID: hostID)
    }

    /// Y opens the filter; with the sheet open it has every command: X resets, Y and B close it. A toast that has its own
    /// action keeps Y.
    private func capture(_ command: MenuCommand) -> Bool {
        if sheetOpen { return captureSheet(command) }
        guard command == .toastAction, offered, actions.toasts.current?.action == nil else { return false }
        openSheet()
        return true
    }

    private func captureSheet(_ command: MenuCommand) -> Bool {
        let feedback = actions.layers.feedback
        switch command {
        case .back, .toastAction:
            closeSheet()
        case .options:
            resetFilters()
        case .accept:
            guard !navigator.swallowsAccept() else { break }
            if let feedback { feedback.activate(sheetFocus.acceptCue) { sheetFocus.handle(.accept) } } else { sheetFocus.handle(.accept) }
        case .up, .down, .left, .right:
            if sheetFocus.handle(command) { feedback?.play(.move) }
        case .previousTab, .nextTab, .menu:
            break
        }
        return true
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
    static func moves(index: Int, ids: [AnyHashable], up: AnyHashable? = nil) -> [FocusDirection: AnyHashable] {
        var moves: [FocusDirection: AnyHashable] = [:]
        if let up { moves[.up] = up }
        guard ids.count > 1 else { return moves }
        if index == 0 { moves[.left] = ids[ids.count - 1] }
        if index == ids.count - 1 { moves[.right] = ids[0] }
        return moves
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

/// What the row does when the focus goes from one cover to another: the one scroll target of that focus step, and the
/// motion of the row.
enum LibraryScroll {
    enum Step: Equatable {
        /// Round the row from the first cover to the last or back (``LibraryWrap``).
        case wrap
        /// The row brings cover [to] to its start.
        case follow(to: Int)
    }

    static func step(from old: Int?, to new: Int, count: Int) -> Step {
        LibraryWrap.isWrap(from: old, to: new, count: count) ? .wrap : .follow(to: new)
    }

    /// The row's glide (``ScrollGlide``): a critically damped spring that settles within 2 % in 250 ms. Android's row
    /// restarts a 200 ms ease-out (`FastScroll`) at every step, which starts at full speed; this one is retargeted by every
    /// step and keeps the row's speed, so a single press eases in and out over about the same time (90 % after 167 ms,
    /// Android's after 107 ms) and the steps of a held arrow join into one glide at a steady pace instead of a hop per step.
    static let pace = GlideSpring.Pace.fixed(settle: 0.25)
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

/// The row's edge fades (`fadeMask` of DELOS for Android), stage pixels: the fade at the left edge, and at the right edge the
/// fade with the clear strip at its end, each whole while covers go on behind that edge and gone when none do, switching
/// over ``switching`` (`animateFloatAsState(…, tween(300))` on `canScrollBackward` / `canScrollForward`).
enum RowFade {
    static let start = 120.0
    static let endSolid = 260.0, endClear = 20.0
    static let switching = FadeGrowth.whileHidden(Motion.fastOutSlowIn(300))
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
    /// The glide of the focus steps (the wrap is an animation of its own).
    @State private var follow = ScrollGlide(pace: LibraryScroll.pace)
    /// Where the focused game stood, for the one that takes its place when it disappears.
    @State private var lastIndex = 0
    /// The row faded out for a moment while a long wrap jumps close to the other end.
    @State private var rowAlpha = 1.0
    /// The overshoot at the end of a wrap, stage pixels.
    @State private var rowBounce = 0.0
    @State private var wrap: Task<Void, Never>?

    static let focusScale = CoverGeometry.focusScale

    private var menuOpen: Bool {
        if case .context = layers.layer { true } else { false }
    }

    var body: some View {
        let ids = apps.map(\.id)
        let focusedIndex = apps.firstIndex { focus.focused == AnyHashable(Self.id($0)) }
        // Before the library takes the focus, the game it will take it with is the one shown
        let current = focusedIndex ?? LibraryFocus.initial(apps: ids, focused: nil, remembered: actions.homeGame(hostID: hostID))
        let focused = apps[current]
        let metrics = HomeMetrics(stage: stage)
        let covers = metrics.covers
        let host = hosts.host(hostID)
        let running = host.flatMap { $0.runningAppID == 0 ? nil : $0.runningAppID }
        let last = actions.lastPlayed(hostID: hostID)
        let start = metrics.rowStart(safeLeading: stage.safe.leading)
        let end = metrics.rowEnd
        ZStack(alignment: .topLeading) {
            GameInfo(hostID: hostID, app: focused, pcName: host?.name ?? "", running: running == focused.id,
                     virtualDisplay: VirtualDisplayChip.shows(app: focused, support: host?.virtualDisplay),
                     playtime: actions.playtime(hostID: hostID, appID: focused.id), metrics: metrics)
                .padding(.leading, stage.px(metrics.infoStart))
                .padding(.top, stage.px(metrics.titleTop))
                // Behind an open context menu the info block dims to 40 %
                .opacity(CoverTone.info(menuOpen: menuOpen))
                .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000), value: menuOpen)
            ScrollView(.horizontal, showsIndicators: false) {
                LibraryCovers(
                    hostID: hostID, apps: apps, focus: focus, actions: actions, running: running, last: last, menuOpen: menuOpen,
                    covers: covers, start: stage.px(start), end: stage.px(end), pad: stage.px(metrics.rowPad))
                    .equatable()
                    .focusDrivenScroll()
            }
            .entranceScope()
            .scrollClipDisabled()
            // The row is moved by the focus alone: without this a hardware keyboard's arrow keys also scroll the
            // scroll view by themselves, on top of the focus (owner's iPad with a Magic Keyboard: a crawl, then the
            // focus ran off the screen); the content switches the scroll view's own keyboard scrolling off
            .focusable(false)
            .scrollGlide(follow, axis: .horizontal, position: $position)
            // The ends fade where covers go on behind them, so the first and the last cover's ring and glow stay whole; the
            // mask reaches far above and below the row for the focused cover's glow and ring
            .scrollEdgeFade(.horizontal, FadeEdges(
                start: FadeEdge(solid: RowFade.start), end: FadeEdge(solid: metrics.fadeSolid, clear: metrics.fadeClear)),
                growth: RowFade.switching, outset: 1000)
            .padding(.top, stage.px(metrics.coverTop - metrics.rowPad))
            .opacity(rowAlpha)
            .offset(x: stage.px(rowBounce))
            #if os(tvOS)
            // The system focus engine has nowhere to go past the ends: the wrap is made here
            .onMoveCommand { direction in
                guard let focusedIndex else { return }
                for (move, target) in LibraryWrap.moves(index: focusedIndex, ids: apps.map { AnyHashable(Self.id($0)) })
                    where move.matches(direction) {
                    focus.focus(target)
                }
            }
            #endif
            .onChange(of: focusedIndex) { old, now in
                guard let now else { return }
                lastIndex = now
                actions.rememberHomeGame(hostID: hostID, appID: apps[now].id)
                // One focus step, one scroll target: this is the only thing that scrolls the row
                switch LibraryScroll.step(from: old, to: now, count: apps.count) {
                case .wrap:
                    glide(to: now, from: old ?? now)
                case .follow(let index):
                    wrap?.cancel()
                    rowAlpha = 1
                    rowBounce = 0
                    if reduceMotion {
                        scroll(to: index, animation: nil)
                    } else {
                        follow.glide(to: stage.px(HomeMetrics(stage: stage).covers.itemStart(index)), unit: stage.scale)
                    }
                }
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
            let (image, animation) = await heroImage(focused)
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            art.hero = GameArt(hostID: hostID, app: focused, image: image, animation: animation)
        }
    }

    /// Scrolls the row so cover [index] stands at its start on [animation] (the wrap's), or at once with reduced motion or no
    /// [animation]; a glide of the focus steps stops.
    private func scroll(to index: Int, animation: Animation?) {
        follow.stop()
        let x = stage.px(HomeMetrics(stage: stage).covers.itemStart(index))
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
            let covers = HomeMetrics(stage: stage).covers
            let distance = abs(covers.itemStart(target) - covers.itemStart(min(source, apps.count - 1)))
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

    /// The game background's image: the SteamGridDB hero, else the cover, else the PC's box art; and the hero's animation
    /// when it is one (it plays as the game background, the image being its first frame).
    private func heroImage(_ app: HostApp) async -> (CGImage?, AnimatedSource?) {
        // DELOS's own entries have bundled artwork; a game has SteamGridDB's, else the PC's box art
        if BundledArtwork.kind(app) != nil { return (await art.image(hostID: hostID, app: app, kind: .hero), nil) }
        if art.artwork.enabled {
            if let hero = await art.image(hostID: hostID, appID: app.id, kind: .hero) {
                return (hero, await art.animation(hostID: hostID, app: app, kind: .hero))
            }
            if let cover = await art.image(hostID: hostID, appID: app.id, kind: .cover) { return (cover, nil) }
        }
        return (await art.boxArt(hostID: hostID, appID: app.id, hosts: hosts), nil)
    }

    static func id(_ app: HostApp) -> String { "app-\(app.id)" }
}

/// The covers of the row. Equatable: the library around them is redrawn at every step of the focus and while its scroll
/// position moves, the covers only when what they show changes; each cover's focus look follows its own item's focus
/// (``FocusModel/isFocused(_:)``), so a step redraws the cover that loses the focus and the one that gains it.
private struct LibraryCovers: View, Equatable {
    let hostID: String
    let apps: [HostApp]
    let focus: FocusModel
    let actions: ShellActions
    /// The running game and the last one played.
    let running: Int?
    let last: Int?
    let menuOpen: Bool
    let covers: CoverGeometry
    /// The room before the first cover, after the last one and above and below them, points.
    let start: CGFloat
    let end: CGFloat
    let pad: CGFloat
    @Environment(HostStore.self) private var hosts
    @Environment(\.stage) private var stage

    nonisolated static func == (a: LibraryCovers, b: LibraryCovers) -> Bool {
        a.hostID == b.hostID && a.apps == b.apps && a.focus === b.focus && a.actions === b.actions && a.running == b.running
            && a.last == b.last && a.menuOpen == b.menuOpen && a.covers == b.covers && a.start == b.start && a.end == b.end
            && a.pad == b.pad
    }

    /// A or a tap on [app] opens its menu (another game runs on the PC) instead of starting it.
    private func offersChoices(_ app: HostApp) -> Bool {
        let running = hosts.host(hostID).flatMap { $0.runningAppID == 0 ? nil : $0.runningAppID }
        let known = running.flatMap { id in apps.first { $0.id == id }?.id }
        return GameActivation.of(app: app.id, running: known) == .offerChoices
    }

    var body: some View {
        let keys = apps.map { AnyHashable(GameLibrary.id($0)) }
        HStack(spacing: stage.px(covers.gap)) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                let badge: CoverBadge? = app.id == running ? .running : index == 0 && app.id == last ? .lastPlayed : nil
                FocusItem(
                    id: GameLibrary.id(app), model: focus, moves: LibraryWrap.moves(index: index, ids: keys),
                    menu: { actions.gameMenu(hostID: hostID, app: app) },
                    // The offer menu plays its own OPEN cue, not SELECT
                    clickCue: offersChoices(app) ? nil : .select,
                    action: { actions.activate(hostID: hostID, app: app, focus: focus) }
                ) { isFocused in
                    Cover(hostID: hostID, app: app, wide: index == 0, focused: isFocused, menuOpen: menuOpen, badge: badge,
                          marks: actions.marks(hostID: hostID, appID: app.id), geometry: covers)
                }
                // Left to right, as Android's lazy row composes them
                .staggerEntrance(index: min(index, Motion.staggerCap))
            }
        }
        .padding(.leading, start)
        .padding(.trailing, end)
        .padding(.vertical, pad)
        // The row gives the focus back to the cover it had last when the focus comes from outside (Down from the top
        // navigation), as a focus group of Android's lazy row does
        .onChange(of: keys, initial: true) { _, now in focus.restoreFocus(in: Self.group, items: now) }
    }

    /// The restoring focus group of the covers (``FocusModel/restoreFocus(in:items:)``).
    static let group = "library-covers"
}

/// The focused game's logo or title and the info row under it (`GameInfo` of DELOS for Android).
private struct GameInfo: View {
    let hostID: String
    let app: HostApp
    let pcName: String
    let running: Bool
    /// The Virtual display chip (``VirtualDisplayChip``).
    let virtualDisplay: Bool
    let playtime: Playtime
    let metrics: HomeMetrics
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
            GameTitle(hostID: hostID, app: app, metrics: metrics, width: metrics.infoWidth)
            Spacer().frame(height: stage.px(metrics.titleGap))
            InfoRow(playtime: playtime, height: metrics.infoHeight,
                    hasFacts: running || hdr != nil || completion != nil || virtualDisplay,
                    hasTags: !genres.isEmpty || !themes.isEmpty, above: metrics.blockAbove) {
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
                if virtualDisplay { InfoChip(icon: Symbols.screenShare, label: L("home_chip_virtual_display")) }
            } tags: {
                if !genres.isEmpty { GenrePill(genres: genres, gameColors: gameColors) }
                if !themes.isEmpty { ThemePill(themes: themes, gameColors: gameColors) }
            }
            .frame(maxWidth: stage.px(metrics.infoWidth), alignment: .leading)
        }
    }
}

/// The Virtual display chip of the info row (`virtualDisplay` in `GameInfo` of DELOS for Android): on Desktop, when the PC
/// can stream to a virtual display of its own.
enum VirtualDisplayChip {
    static func shows(app: HostApp, support: VirtualDisplaySupport?) -> Bool {
        BundledArtwork.kind(app) == .desktop && support?.capable == true
    }
}

/// The SteamGridDB logo in the title box (fitted, at the start), else the name in a gradient from the text color into
/// the game background's main color; the space is kept while the logo is being looked for. Both enter by sliding in
/// from 32 px to the left over 800 ms. DELOS's own entries have no logo: they show their name.
private struct GameTitle: View {
    let hostID: String
    let app: HostApp
    let metrics: HomeMetrics
    let width: Double
    @Environment(HomeArt.self) private var art
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion
    @Environment(\.artMotion) private var artMotion
    @Environment(\.displayScale) private var displayScale
    @State private var logo: CGImage?
    @State private var resolved = false
    /// The logo's animation when it is one.
    @State private var animation: AnimatedSource?
    /// The animation has faded in over the logo: the still under it is hidden.
    @State private var animating = false

    var body: some View {
        let key = GameArt.key(hostID, app.id)
        ZStack(alignment: .leading) {
            if let logo {
                let box = CGSize(width: stage.px(min(metrics.logoWidth(stageWidth: stage.width), width)),
                                 height: stage.px(metrics.titleBox - 2 * metrics.logoPad))
                Image(decorative: logo, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .opacity(animating ? 0 : 1)
                    .frame(maxWidth: box.width, maxHeight: box.height, alignment: .leading)
                    // The chosen animated logo plays over its first frame, fitted into the same box (start-aligned like the still)
                    // while anything may play: the focused game's logo is always on screen
                    .overlay {
                        AnimatedArtLayer(source: animation, playing: artMotion, width: Int(box.width * displayScale),
                                         height: Int(box.height * displayScale), fit: true, alignment: .leading, covering: $animating)
                    }
                    .accessibilityElement()
                    .accessibilityLabel(app.title)
                    .modifier(TitleEntrance(key: key + "/logo", reduced: reduceMotion))
            } else if resolved {
                let size = metrics.titleSize(length: app.title.count)
                let placeholder = GameArt(hostID: hostID, app: app)
                Text(app.title)
                    .font(DelosFonts.unbounded(stage.tpx(size), .bold))
                    .tracking(-0.01 * stage.tpx(size))
                    .lineLimit(1)
                    .foregroundStyle(LinearGradient(
                        stops: [.init(color: colors.text.color, location: 0.25),
                                .init(color: hsl(art.heroHue(key) ?? placeholder.hue2, 70, 58).color, location: 1)],
                        startPoint: .top, endPoint: .bottom))
                    .padding(.trailing, stage.px(metrics.compact ? HomeCompact.side : 150))
                    .frame(maxWidth: stage.px(width), alignment: .leading)
                    .modifier(TitleEntrance(key: key, reduced: reduceMotion))
            }
        }
        .frame(height: stage.px(metrics.titleBox), alignment: .leading)
        .task(id: "\(key)#\(art.artwork.version)") {
            animation = nil
            // Bundled entries keep their name as the logo
            if BundledArtwork.kind(app) != nil {
                logo = nil
                resolved = true
                return
            }
            let cached = art.cachedImage(hostID: hostID, appID: app.id, kind: .logo)
            logo = cached
            resolved = cached != nil || !art.artwork.enabled
            guard art.artwork.enabled else { return }
            if cached == nil {
                logo = await art.image(hostID: hostID, appID: app.id, kind: .logo)
                resolved = true
            }
            if logo != nil { animation = await art.animation(hostID: hostID, app: app, kind: .logo) }
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
    /// The icon-only pills of the top-right corner (hidden, custom settings).
    var marks: [CoverMark] = []
    /// The covers' size: the prototype's, or a compact stage's.
    var geometry = CoverGeometry.standard
    @Environment(HostStore.self) private var hosts
    @Environment(HomeArt.self) private var art
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.artMotion) private var artMotion
    @Environment(\.displayScale) private var displayScale
    @State private var shown: CGImage?
    /// The animation of the SteamGridDB cover shown, when it is one.
    @State private var animation: AnimatedSource?
    /// The animation has faded in over the cover: the still under it is hidden.
    @State private var animating = false
    /// Some of the cover is on screen.
    @State private var visible = false

    /// A lookup that never finishes (offline, failed) stops being waited for after this long.
    static let lookupGiveUp = Duration.seconds(20)

    var body: some View {
        let width = wide ? geometry.wide : geometry.tile
        let tone = CoverTone.of(focused: focused, menuOpen: menuOpen)
        let shape = RoundedRectangle(cornerRadius: stage.px(geometry.corner))
        let placeholder = GameArt(hostID: hostID, app: app)
        ZStack(alignment: .topLeading) {
            shape.fill(colors.surface2.color)
            ZStack {
                if let shown {
                    Image(decorative: shown, scale: 1).resizable().scaledToFill()
                        .opacity(animating ? 0 : 1)
                        .frame(width: stage.px(width), height: stage.px(geometry.height))
                        // The chosen animated cover plays over its still first frame, cropped and muted exactly like it, only while
                        // the cover is on screen; decoded no bigger than the cover (its focused size) needs
                        .overlay {
                            let pixels = displayScale * CoverGeometry.focusScale
                            AnimatedArtLayer(source: animation, playing: artMotion && visible,
                                             width: Int((stage.px(width) * pixels).rounded()), height: Int((stage.px(geometry.height) * pixels).rounded()),
                                             covering: $animating)
                        }
                        // The idle and menu filters (`IdleCoverFilter`, `menuDimCoverFilter`); the placeholder art has none
                        .saturation(tone.saturation)
                        .colorMultiply(Color(white: tone.brightness))
                        .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000), value: menuOpen)
                        .transition(.opacity)
                } else {
                    // A compact stage's small covers set the placeholder's title smaller (the wide one at most 40 %, the others at most
                    // 20 %, then fitted to their longest word), with the cover's own inset
                    let s = geometry.scale
                    PlaceholderArt(
                        hue: placeholder.hue, hue2: placeholder.hue2, icon: placeholder.icon,
                        glyphSize: (wide ? 420 : 320) * s, glyphRight: (wide ? 40 : -36) * s, glyphTop: wide ? 0.04 : 0.24,
                        title: app.title, titleSize: (wide ? 72 : 34) * min(max(s, wide ? 0.6 : 0.8), 1),
                        titleInset: (wide ? 44 : 26) * s, titleBottom: (wide ? 40 : 26) * s, titleFit: s < 1)
                }
            }
            .animation(Motion.fastOutSlowIn(400), value: shown.map(ObjectIdentifier.init))
            if art.artwork.isBusy(hostID: hostID, appID: app.id) {
                RingSpinner(size: 32)
                    .frame(width: stage.px(56), height: stage.px(56))
                    .background(Circle().fill(Color(.sRGB, red: 5 / 255, green: 10 / 255, blue: 20 / 255, opacity: 0.55)))
                    .padding(stage.px(16))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else if !marks.isEmpty {
                // Android's CornerPill: an icon-only dark glass pill; the busy spinner takes this corner while it shows
                HStack(spacing: stage.px(8)) {
                    ForEach(marks, id: \.self) { mark in
                        SymbolView(symbol: mark.icon, size: 22, color: RGBA(red: 1, green: 1, blue: 1, alpha: mark.opacity), filled: true)
                            .padding(.horizontal, stage.px(14))
                            .padding(.vertical, stage.px(6))
                            .background(Capsule().fill(Color(.sRGB, red: 5 / 255, green: 10 / 255, blue: 20 / 255, opacity: 0.55)))
                            .accessibilityElement()
                            .accessibilityLabel(mark.label)
                    }
                }
                .padding(stage.px(18))
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
        .frame(width: stage.px(width), height: stage.px(geometry.height))
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .clipShape(shape)
        // The online pulse of the start screen, around the selected game (`focusPulse`), inside the scaled layer
        .background { if focused { FocusPulse(corner: geometry.corner) } }
        // Android's TILE_FOCUS_SCALE; the wide first cover grows only to the left, so it never covers its neighbour. The
        // ring is `FocusRing(5, 5)` with the gap in the background color, the glow `FocusGlow(30, 80, -18)`
        .focusLook(focused, scale: 1.055, ring: 5, glowBlur: 80, glowY: 30, corner: geometry.corner, anchor: wide ? .trailing : .center, sweep: true,
                   glowSpread: -18, gap: 5)
        .task(id: "\(app.id)#\(art.artwork.version)") { await load() }
        // The picture says nothing to VoiceOver: the cover reads as the game's name, its badge and its corner marks
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([app.title, badge?.label].compactMap { $0 } + marks.map(\.label)).joined(separator: ", "))
    }

    private func load() async {
        let key = GameArt.key(hostID, app.id)
        let artwork = art.artwork
        // DELOS's own entries have bundled artwork and nothing to look up: the placeholder stays while it decodes
        if BundledArtwork.kind(app) != nil {
            animation = nil
            let cover = await art.image(hostID: hostID, app: app, kind: .cover)
            guard let tile = wide ? await art.image(hostID: hostID, app: app, kind: .wide) : cover else { return }
            shown = tile
            art.analyzeCover(key, cover ?? tile)
            return
        }
        var cover: CGImage?
        if artwork.enabled {
            cover = await art.image(hostID: hostID, appID: app.id, kind: .cover)
            let tile = wide ? await art.image(hostID: hostID, appID: app.id, kind: .wide) : cover
            if let tile {
                shown = tile
                // The game's colors come from its cover, worked out as soon as it is decoded
                art.analyzeCover(key, cover ?? tile)
                animation = await art.animation(hostID: hostID, app: app, kind: wide ? .wide : .cover)
                return
            }
            if artwork.lookupExpected, !(await artwork.lookupSettled(hostID: hostID, appID: app.id)) {
                // The cover is on its way (the version changes when it is stored); the box art if it never comes
                try? await Task.sleep(for: Self.lookupGiveUp)
                guard !Task.isCancelled else { return }
            }
        }
        guard let box = await art.boxArt(hostID: hostID, appID: app.id, hosts: hosts) else { return }
        animation = nil
        shown = box
        art.analyzeCover(key, cover ?? box)
    }
}

/// The online pulse (`focusPulse`, `.online-ring`) of a rounded element: a 2 px outline in the third accent starts just
/// outside the focus ring, grows outwards by 26 stage pixels and fades, every 2.4 s.
private struct FocusPulse: View {
    let corner: Double
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            let wave = Motion.easeOut(t)
            // From just outside the focus ring (5 px gap + 5 px ring) outwards
            let offset = 10 + 26 * wave
            RoundedRectangle(cornerRadius: stage.px(corner + offset + 1))
                .strokeBorder(colors.accent2.opacity(0.7 * (1 - wave)).color, lineWidth: stage.px(2))
                .padding(-stage.px(offset + 2))
        }
        .allowsHitTesting(false)
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
        // A compact stage keeps the message off the edges and sets its icon and headline smaller
        VStack(spacing: stage.px(22)) {
            SymbolView(symbol: icon, size: stage.compact ? 84 : 110, color: colors.accent, filled: true)
            Text(title)
                .font(DelosFonts.unbounded(stage.tpx(stage.compact ? 42 : 52)))
                .foregroundStyle(colors.text.color)
            if let text {
                Text(text)
                    .font(DelosFonts.figtree(stage.tpx(26)))
                    .lineSpacing(stage.tpx(26) * 0.45)
                    .foregroundStyle(colors.text2.color)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, stage.compact ? stage.px(48) : 0)
        .staggerEntrance(index: 0, base: Motion.menuDelay)
    }
}

/// The library when the filter lets no game through (`FilteredLibraryEmpty` of DELOS for Android): what happened, how to
/// change the filter, and a button that resets it. It has the focus; the game background is gone.
private struct FilteredLibraryEmpty: View {
    let focus: FocusModel
    let onReset: () -> Void
    @Environment(HomeArt.self) private var art
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        VStack(spacing: stage.px(22)) {
            Text(L("metadata_filtered_title"))
                .font(DelosFonts.figtree(stage.tpx(38)))
                .foregroundStyle(colors.text.color)
            Text(L("metadata_filtered_note", "Y"))
                .font(DelosFonts.figtree(stage.tpx(24)))
                .foregroundStyle(colors.text2.color)
            FocusItem(id: LibraryFilterIDs.emptyReset, model: focus, action: onReset) { focused in
                PillButton(label: L("metadata_filtered_reset"), icon: Symbols.reset, focused: focused)
            }
            .padding(.top, stage.px(8))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: stage.px(900))
        .padding(.horizontal, stage.compact ? stage.px(48) : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            art.hero = nil
            focus.focus(LibraryFilterIDs.emptyReset)
        }
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
