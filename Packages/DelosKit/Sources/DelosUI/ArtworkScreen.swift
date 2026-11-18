import DelosData
import DelosHost
import DelosInput
import Observation
import SwiftUI

/// What the Artwork screen knows and loads (`ArtworkScreen`'s state of DELOS for Android): the game's SteamGridDB match,
/// the image in use per kind, the filters of each tab and the images [tab]'s kind can be chosen from.
@MainActor
@Observable
final class ArtworkModel {
    let hostID: String
    let app: HostApp
    let artwork: ArtworkStore
    var tab = ArtworkTab.cover
    /// The filters of each tab, for as long as the screen is open (`filtersByTab`).
    var filtersByTab: [ArtworkTab: ArtFilters] = [:]
    var sheetOpen = false
    /// The focus inside the open filter sheet; a new one each time it opens. The screen's body never reads it or
    /// ``sheetOpen``: the sheet layer and the modal-focus modifier do, so opening the sheet does not rebuild the grid.
    var sheetFocus = FocusModel()
    private(set) var choices = ArtworkChoices.loading
    private(set) var match: SteamGridDBGame?
    private(set) var chosen = ArtworkChoice.unset
    /// The game is being looked up (the first visit of a game never looked up).
    private(set) var looking = false
    /// A filter's list is being loaded while the grid keeps the images it has.
    private(set) var refreshing = false
    @ObservationIgnored private var lists: [String: [SteamGridDBImage]] = [:]
    /// The tab and game the grid shows images of: another one starts over with the loading message.
    @ObservationIgnored private var shown: (tab: ArtworkTab, game: Int)?
    /// The list [choices] holds, by game and filters (``listKey(game:)``): the filters just chosen have no list yet while it
    /// differs from the current one.
    private(set) var shownKey: String?

    init(hostID: String, app: HostApp, artwork: ArtworkStore) {
        self.hostID = hostID
        self.app = app
        self.artwork = artwork
    }

    /// The filters of the tab, without what its kind cannot filter by.
    var filters: ArtFilters { ArtFilterRules.normalized(tab.kind, filtersByTab[tab] ?? ArtFilters()) }

    /// The app's artwork comes from SteamGridDB (`ArtworkStore.eligible`): DELOS's own entries have bundled artwork.
    var eligible: Bool { BundledArtwork.kind(app) == nil }

    /// Never looked up yet: find the game first and download its best-rated images like the automatic run, retrying a
    /// passing failure (`SgdbRetry`). A failure is reported through [onError].
    func lookup(onError: (any Error) -> Void) async {
        if artwork.enabled, eligible, await !artwork.isSearched(hostID: hostID, appID: app.id) {
            looking = true
            do {
                _ = try await SteamGridDBRetry.run { try await artwork.fetch(hostID: hostID, appID: app.id, name: app.title) }
            } catch is CancellationError {
            } catch {
                onError(error)
            }
            looking = false
        }
        await refresh()
    }

    /// The match and the image in use of the tab, read again (the store's version changed).
    func refresh() async {
        match = await artwork.matchedGame(hostID: hostID, appID: app.id)
        chosen = await artwork.choice(hostID: hostID, appID: app.id, kind: tab.kind)
    }

    func load() async {
        chosen = await artwork.choice(hostID: hostID, appID: app.id, kind: tab.kind)
        guard artwork.enabled else { return choices = .noKey }
        guard !looking else { return choices = .loading }
        guard let game = match else { return choices = .noGame }
        let kind = tab.kind
        let filters = self.filters
        let tab = self.tab
        // The sort is applied here to what was loaded, so changing it asks nothing
        let key = listKey(game: game.id)
        func total() -> Int? { lists["\(game.id)|\(ArtFilterRules.cacheKey(kind, ArtFilters()))"]?.count }
        func ready(_ list: [SteamGridDBImage]) -> ArtworkChoices {
            shown = (tab, game.id)
            shownKey = key
            return .ready(gameID: game.id, images: ArtFilterRules.sort(list, filters.sort), total: total())
        }
        if let cached = lists[key] { return choices = ready(cached) }
        // The grid keeps its images while a filter loads (the new list replaces them); another tab or game starts over
        if shown?.tab != tab || shown?.game != game.id { choices = .loading }
        refreshing = true
        defer { refreshing = false }
        do {
            var asked = filters
            asked.sort = .score
            let list = try await SteamGridDBRetry.run { try await artwork.choices(hostID: hostID, appID: app.id, kind: kind, filters: asked) }
            lists[key] = list
            choices = ready(list)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            choices = .failed(ShellActions.artworkErrorText(error, fallback: "artwork_unreachable"))
        }
    }

    /// What identifies a load: another tab, game, key or filter starts it over.
    struct LoadKey: Hashable {
        let tab: ArtworkTab
        let game: Int?
        let enabled: Bool
        let looking: Bool
        let filters: ArtFilters
    }

    var loadKey: LoadKey { LoadKey(tab: tab, game: match?.id, enabled: artwork.enabled, looking: looking, filters: filters) }

    /// What identifies the list of a game for the current tab and filters; the sort is applied to the list, not asked for.
    private func listKey(game: Int) -> String { "\(game)|\(ArtFilterRules.cacheKey(tab.kind, filters))" }

    /// Why the grid has no image, once the list of the current filters is there (not while it loads).
    var empty: ArtworkEmpty? {
        guard case .ready(_, let images, _) = choices, let game = match, shownKey == listKey(game: game.id) else { return nil }
        return ArtworkEmpty(images: images.count, filters: filters)
    }

    /// The tile that takes the focus when a list shows: the image in use, else the first choice, or Reset when the filters
    /// left nothing.
    func initialTile() -> String {
        if let empty { return empty.firstFocus }
        if case .image(let id) = chosen, case .ready(_, let images, _) = choices, images.contains(where: { $0.id == id }) {
            return ArtworkScreen.tileID(id)
        }
        return ArtworkScreen.noneID
    }

    /// Whether the first choice (the PC's artwork, the name) is the one in use.
    var noneInUse: Bool {
        if case .ready(_, let images, _) = choices {
            return chosen == .none || (chosen == .unset && images.isEmpty && !filters.active)
        }
        return chosen == .none
    }

    /// What identifies the list the focus starts on: another tab or game, not another filter.
    var readyKey: String {
        if case .ready(let game, _, _) = choices { return "ready:\(tab):\(game)" }
        switch choices {
        case .loading: return "loading"
        case .noKey: return "noKey"
        case .noGame: return "noGame"
        case .failed: return "failed"
        case .ready: return "ready"
        }
    }

    /// The images of a ready list.
    var images: [SteamGridDBImage]? {
        if case .ready(_, let images, _) = choices { images } else { nil }
    }

    var total: Int? {
        if case .ready(_, _, let total) = choices { total } else { nil }
    }

    /// The item that had the focus before the sheet opened, to return to it.
    @ObservationIgnored private var origin: AnyHashable?

    /// The filter sheet can open: there is a matched game and a key.
    var canOpenSheet: Bool { match != nil && artwork.enabled && !sheetOpen }

    /// Opens the filter sheet with a new focus of its own on its first option; the grid's focus stays where it is, and
    /// [origin] is where it returns to.
    func openSheet(returningTo origin: AnyHashable?) {
        guard canOpenSheet else { return }
        self.origin = origin
        sheetFocus = FocusModel(initial: ArtworkFilterSheet.startID(kind: tab.kind, filters: filters))
        sheetOpen = true
    }

    /// Closes the sheet and puts [focus] back where it was: a tile the filters removed (or the first choice, when they left
    /// nothing) leaves it on the first thing that is there.
    func closeSheet(restoring focus: FocusModel) {
        guard sheetOpen else { return }
        sheetOpen = false
        let fallback = AnyHashable(empty?.firstFocus ?? ArtworkScreen.noneID)
        let tileGone: Bool = {
            guard let id = origin as? String else { return false }
            if id == ArtworkScreen.noneID { return empty?.showsFirstChoice == false }
            guard id.hasPrefix("art-"), let number = Int(id.dropFirst(4)) else { return false }
            return !(images?.contains { $0.id == number } ?? false)
        }()
        focus.focus(tileGone ? fallback : origin ?? fallback)
    }
}

/// The artwork of one game (the game's menu → Artwork; `ArtworkScreen` of DELOS for Android): a tab per kind (cover, wide
/// cover, background, logo, switched with L1 and R1) over a toolbar (the matched SteamGridDB game, search for another name
/// with X, the filter sheet with Y), the active filters as removable chips, the grid of every SteamGridDB image to choose
/// from (the first choice being the PC's artwork, or the name instead of a logo) and a strip about the focused image. A or
/// a tap uses the image; the image in use has the accent border. Animated images are marked; their tiles show the first
/// frame (the animation does not play).
struct ArtworkScreen: View {
    let hostID: String
    let app: HostApp
    let focus: FocusModel
    let navigator: Navigator
    let actions: ShellActions

    static let noneID = "art-none"
    static let searchID = "art-search"
    static let filterID = "art-filter"
    static let firstFocus = noneID
    static func tileID(_ image: Int) -> String { "art-\(image)" }
    static func tabID(_ tab: ArtworkTab) -> String { "art-tab-\(tab)" }

    /// The shell builds this again whenever its own body runs, and it runs on every move of the focus (the hint bar asks the
    /// focused item whether it has a menu). The content is compared first, so the screen below is drawn again only when
    /// the game, the focus, the navigator or the actions are others.
    var body: some View {
        // DELOS's own entries have bundled artwork, which is read-only: the game menu has no Artwork entry for them, but a
        // stale navigation entry (a demo, a restored screen) may still reach this screen
        if BundledArtwork.kind(app) != nil {
            BuiltInArtworkScreen(hostID: hostID, app: app, focus: focus, navigator: navigator)
        } else {
            ArtworkContent(hostID: hostID, app: app, focus: focus, navigator: navigator, actions: actions).equatable()
        }
    }
}

/// The Artwork screen of one of DELOS's own entries (`BuiltInArtworkScreen`): its name, its bundled wide cover, a note that
/// its artwork is built in, and Back (A or B).
private struct BuiltInArtworkScreen: View {
    let hostID: String
    let app: HostApp
    let focus: FocusModel
    let navigator: Navigator
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(HomeArt.self) private var art
    @State private var picture: CGImage?

    static let backID = "art-builtin-back"

    var body: some View {
        VStack(alignment: .leading, spacing: stage.px(24)) {
            Text(app.title)
                .font(DelosFonts.unbounded(stage.tpx(46), .semibold))
                .foregroundStyle(colors.text.color)
            ZStack {
                if let picture {
                    Image(decorative: picture, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: stage.px(920))
                        .aspectRatio(920.0 / 430, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: stage.px(26)))
                } else {
                    RingSpinner(size: 48)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(L("artwork_builtin_note"))
                .font(DelosFonts.figtree(stage.tpx(24)))
                .foregroundStyle(colors.text2.color)
            FocusItem(id: Self.backID, model: focus, clickCue: .back, action: { navigator.back() }) { focused in
                PillButton(label: L("artwork_builtin_back"), icon: Symbols.arrowBack, focused: focused)
            }
        }
        .padding(.leading, stage.px(150) + stage.safe.leading)
        .padding(.trailing, stage.px(150) + stage.safe.trailing)
        .padding(.top, stage.px(92) + stage.safe.top)
        .padding(.bottom, stage.px(110))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BuiltInHintSync(focus: focus, navigator: navigator))
        .onAppear { focus.focus(Self.backID) }
        .task { picture = await art.image(hostID: hostID, app: app, kind: .wide) }
    }
}

/// Tells the hint bar that A and B both go back here.
private struct BuiltInHintSync: View {
    let focus: FocusModel
    let navigator: Navigator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { navigator.setHints(ScreenHints(artworkBuiltIn: true), from: focus) }
    }
}

private struct ArtworkContent: View, Equatable {
    let hostID: String
    let app: HostApp
    let focus: FocusModel
    let navigator: Navigator
    let actions: ShellActions
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @State private var model: ArtworkModel

    init(hostID: String, app: HostApp, focus: FocusModel, navigator: Navigator, actions: ShellActions) {
        self.hostID = hostID
        self.app = app
        self.focus = focus
        self.navigator = navigator
        self.actions = actions
        _model = State(initialValue: ArtworkModel(hostID: hostID, app: app, artwork: actions.artwork))
    }

    nonisolated static func == (a: ArtworkContent, b: ArtworkContent) -> Bool {
        a.hostID == b.hostID && a.app == b.app && a.focus === b.focus && a.navigator === b.navigator && a.actions === b.actions
    }

    var body: some View {
        let left = 150 + stage.safe.leading, right = 150 + stage.safe.trailing
        let top = stage.safe.top
        // The grid and the info strip share the room from the grid's top down to 110 px above the stage's foot; the strip is as
        // high as its content needs (at least 84 px) and the grid takes the rest
        let lowerHeight = stage.height - 110 - (324 + top)
        let filters = model.filters
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("artwork_header"))
                    .font(DelosFonts.figtree(stage.tpx(20), .semibold))
                    .tracking(stage.tpx(20) * 0.14)
                    .foregroundStyle(colors.accent2.color)
                Text("SteamGridDB")
                    .font(DelosFonts.unbounded(stage.tpx(40)))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
            }
            .frame(width: stage.px(560), alignment: .leading)
            .offset(x: stage.px(left), y: stage.px(104 + top))
            // The tabs end exactly at the content's right edge, on every stage width
            TabRow(
                tabs: ArtworkTab.allCases.map { TabSpec(id: $0, icon: $0.icon, label: $0.label) }, selected: model.tab, focus: focus,
                focusID: ArtworkScreen.tabID, left: left, right: stage.width - right, centred: false) { select($0, sound: .select) }
                .frame(height: stage.px(66))
                .tvFocusSection()
                .offset(y: stage.px(124 + top))
            toolbar
                .frame(height: stage.px(64))
                .padding(.horizontal, stage.px(left))
                .padding(.trailing, stage.px(right - left))
                .offset(y: stage.px(206 + top))
            if let images = model.images {
                ArtworkFilterStrip(
                    tab: model.tab, filters: filters, images: images.count, total: model.total, refreshing: model.refreshing,
                    focus: focus, onClear: { chip in model.filtersByTab[model.tab] = ArtFilterRules.clear(filters, chip) },
                    onReset: resetFilters)
                    .frame(height: stage.px(44))
                    .padding(.horizontal, stage.px(left))
                    .padding(.trailing, stage.px(right - left))
                    .offset(y: stage.px(276 + top))
            }
            VStack(spacing: stage.px(10)) {
                ArtworkGridView(
                    model: model, hostID: hostID, app: app, focus: focus, actions: actions, left: left, right: right,
                    onReset: resetFilters, onChange: openSheet)
                    .frame(maxHeight: .infinity)
                ArtworkInfoStrip(model: model, focus: focus)
                    .padding(.horizontal, stage.px(left))
                    .padding(.trailing, stage.px(right - left))
            }
            .frame(height: stage.px(lowerHeight))
            .offset(y: stage.px(324 + top))
            ArtworkSheetLayer(model: model, left: left, right: right, top: 280 + top, onReset: resetFilters, onClose: closeSheet)
            ArtworkHintSync(model: model, focus: focus, navigator: navigator)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(SheetModalFocus(model: model))
        .modifier(ArtworkArtMotion(model: model))
        .task { await model.lookup { error in report(error) } }
        .task(id: model.loadKey) { await model.load() }
        .task(id: actions.artwork.version) { await model.refresh() }
        .onChange(of: model.readyKey) { _, now in
            if now.hasPrefix("ready") { focus.focus(model.initialTile()) }
        }
        .onChange(of: model.empty) { was, now in
            // The filters emptied the grid under the focus: Reset is the first thing to reach. Reset or another filter brought
            // the tiles back: the first choice. An open sheet keeps the focus; closeSheet() places it afterwards
            guard !model.sheetOpen else { return }
            if now == .filtered {
                focus.focus(ArtworkEmpty.resetID)
            } else if was == .filtered {
                focus.focus(model.initialTile())
            }
        }
        .onChange(of: filters.active) { was, now in
            // Reset disables itself once nothing is filtered; if it had the focus, the focus goes back to the first option
            if was, !now, model.sheetOpen, model.sheetFocus.focused == AnyHashable(ArtworkFilterSheet.resetID) {
                model.sheetFocus.focus(ArtworkFilterSheet.startID(kind: model.tab.kind, filters: filters))
            }
        }
        .onAppear {
            navigator.takeInput(focus) { command in capture(command) }
        }
        .onDisappear {
            navigator.releaseInput(focus)
        }
    }

    // MARK: Parts

    /// The game chip and the two pills. The pills share one ring that glides from one to the other (so exactly one is ever
    /// shown), and are as far apart as that ring and the focused pill's growth need.
    private var toolbar: some View {
        ChipGlideHost(look: .pill) {
            toolbarRow
        }
    }

    private var toolbarRow: some View {
        HStack(spacing: stage.px(GlideLook.pillGap)) {
            ArtworkGameChip(
                match: model.match, looking: model.looking, appName: app.title, tab: model.tab,
                imageCount: model.total ?? (model.filters.active ? nil : model.images?.count))
            let enabled = actions.artwork.enabled
            FocusItem(id: ArtworkScreen.searchID, model: focus, clickCue: .open, action: { search() }) { focused in
                ToolbarPill(label: L("artwork_search_other"), icon: Symbols.searchName, focused: focused, glyph: .west)
                    .opacity(enabled ? 1 : 0.4)
            }
            .disabled(!enabled)
            let filterEnabled = enabled && model.match != nil
            FocusItem(id: ArtworkScreen.filterID, model: focus, clickCue: nil, action: { openSheet() }) { focused in
                ToolbarPill(
                    label: L("artwork_filter"), icon: Symbols.filter, focused: focused, glyph: .north, badge: model.filters.activeCount)
                    .opacity(filterEnabled ? 1 : 0.4)
            }
            .disabled(!filterEnabled)
        }
    }

    // MARK: Input

    private func select(_ next: ArtworkTab, sound: Cue) {
        guard next != model.tab else { return }
        actions.layers.feedback?.play(sound)
        if model.sheetOpen { model.sheetOpen = false }
        model.tab = next
    }

    private func search() {
        actions.openArtworkSearch(hostID: hostID, app: app, term: model.match?.name.isEmpty == false ? model.match!.name : app.title)
    }

    private func report(_ error: any Error) {
        actions.layers.feedback?.play(.error)
        actions.toasts.show(ShellActions.artworkErrorText(error, fallback: "artwork_unreachable"), icon: Symbols.error)
    }

    private func openSheet() {
        guard model.canOpenSheet else { return }
        actions.layers.feedback?.play(.open)
        navigator.armInputGate()
        withAnimation { model.openSheet(returningTo: focus.focused) }
    }

    private func closeSheet() {
        guard model.sheetOpen else { return }
        actions.layers.feedback?.play(.back)
        withAnimation { model.closeSheet(restoring: focus) }
    }

    private func resetFilters() {
        guard model.filters.active else { return }
        actions.layers.feedback?.play(.select)
        model.filtersByTab[model.tab] = ArtFilters()
        actions.toasts.show(L("filters_art_reset_toast"), icon: Symbols.reset)
    }

    /// The controller's and keyboard's commands, before the focus gets them: what each does is ``ArtworkCommand``'s.
    private func capture(_ command: MenuCommand) -> Bool {
        let feedback = actions.layers.feedback
        let action = ArtworkCommand.route(command, sheetOpen: model.sheetOpen, toastOwnsY: actions.toasts.current?.action != nil)
        switch action {
        case .tab(let step): select(model.tab.step(step), sound: .move)
        case .search: search()
        case .openSheet: openSheet()
        case .closeSheet: closeSheet()
        case .resetFilters: resetFilters()
        case .sheetAccept:
            guard !navigator.swallowsAccept() else { break }
            if let feedback { feedback.activate(model.sheetFocus.acceptCue) { model.sheetFocus.handle(.accept) } } else { model.sheetFocus.handle(.accept) }
        case .sheetMove: if model.sheetFocus.handle(command) { feedback?.play(.move) }
        case .nothing: break
        case .pass: return false
        }
        return true
    }
}

/// Tells the hint bar what the screen's buttons do now: whether the filter sheet is open and what A does on the focused item.
/// A view of its own: it reads the focus, which the screen's body must not.
private struct ArtworkHintSync: View {
    let model: ArtworkModel
    let focus: FocusModel
    let navigator: Navigator

    var body: some View {
        let hints = ScreenHints(sheetOpen: model.sheetOpen, artworkSouth: ArtworkSouth.of(focus.focused))
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: hints, initial: true) { _, now in navigator.setHints(now, from: focus) }
    }
}

/// Whether the filter sheet is open, for the screen's items on tvOS (the system focus engine). Its own modifier, so the
/// screen's body does not read ``ArtworkModel/sheetOpen``.
private struct SheetModalFocus: ViewModifier {
    let model: ArtworkModel

    func body(content: Content) -> some View {
        content.environment(\.modalFocus, model.sheetOpen ? model.sheetFocus : nil)
    }
}

/// Whether the animated choices play (`AnimatedPlayback.shouldPlay` on the Artwork screen): nothing covers the screen (the
/// filter sheet, a layer, the side menu, the portal) and motion is not reduced; each tile adds whether it is on screen. Its
/// own modifier, so the screen's body does not read ``ArtworkModel/sheetOpen``.
private struct ArtworkArtMotion: ViewModifier {
    let model: ArtworkModel
    @Environment(Layers.self) private var layers
    @Environment(\.shellCoversArt) private var shellCoversArt
    @Environment(\.reducedMotion) private var reducedMotion
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func body(content: Content) -> some View {
        content.environment(\.artMotion, AnimatedPlayback.shouldPlay(
            visible: !model.sheetOpen && !layers.isOpen && !shellCoversArt, foreground: true, streaming: false,
            reducedMotion: reducedMotion, systemReduceMotion: systemReduceMotion))
    }
}

/// The filter sheet over its scrim (`FilterSheetLayer`): it drops down from the toolbar over a dimmed page; the grid stays
/// visible underneath. A view of its own that reads ``ArtworkModel/sheetOpen``, so opening it re-renders only itself.
private struct ArtworkSheetLayer: View {
    let model: ArtworkModel
    let left: Double
    let right: Double
    let top: Double
    let onReset: () -> Void
    let onClose: () -> Void
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion

    var body: some View {
        if model.sheetOpen {
            Rectangle()
                .fill(Color(.sRGB, red: 5 / 255, green: 10 / 255, blue: 20 / 255, opacity: 0x73 / 255))
                .frame(width: stage.px(stage.width), height: stage.px(stage.height))
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .transition(.opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.exit / 1000)))
            ArtworkFilterSheet(
                state: ArtworkFilterSheetState(
                    tab: model.tab, filters: model.filters, images: model.images?.count, total: model.total, refreshing: model.refreshing),
                focus: model.sheetFocus, onChange: { model.filtersByTab[model.tab] = $0 }, onReset: onReset, onClose: onClose)
                .frame(width: stage.px(stage.width - left - right))
                .offset(x: stage.px(left), y: stage.px(top))
                .transition(popTransition)
        }
    }

    /// `popEnter` / `popExit` from the sheet's top right: it fades in a little faster than it grows from 86 % on the
    /// overshooting spring, and shrinks back in 240 ms.
    private var popTransition: AnyTransition {
        let origin = UnitPoint(x: 0.92, y: 0)
        if reducedMotion {
            return .asymmetric(
                insertion: .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000)),
                removal: .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.exit / 1000)))
        }
        return .asymmetric(
            insertion: .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.cardFadeIn / 1000))
                .combined(with: .scale(scale: Motion.popFromScale, anchor: origin).animation(Motion.spring(Motion.popIn))),
            removal: .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.exit / 1000))
                .combined(with: .scale(scale: Motion.popFromScale, anchor: origin).animation(.timingCurve(0.5, 0, 0.75, 0, duration: Motion.exit / 1000))))
    }
}

/// The grid of choices, or why there is none (`ArtworkGrid` of DELOS for Android). A view of its own that reads only the
/// model's choices and the image in use: what the screen reads (the filter sheet, the focused tile) does not rebuild its
/// tiles, and a tile whose picture, border and state did not change is not drawn again when the focus moves.
private struct ArtworkGridView: View {
    let model: ArtworkModel
    let hostID: String
    let app: HostApp
    let focus: FocusModel
    let actions: ShellActions
    let left: Double
    let right: Double
    let onReset: () -> Void
    let onChange: () -> Void
    @Environment(\.stage) private var stage

    var body: some View {
        switch model.choices {
        case .loading:
            ArtworkMessage(icon: Symbols.loading, title: L("artwork_loading"), text: nil)
        case .noKey:
            ArtworkMessage(icon: Symbols.key, title: L("artwork_no_key_title"), text: L("artwork_no_key_note"))
        case .noGame:
            let text = ArtworkNoGame.text(app)
            ArtworkMessage(icon: Symbols.search, title: text.title, text: text.note)
        case .failed(let text):
            ArtworkMessage(icon: Symbols.error, title: L("artwork_unreachable"), text: text)
        case .ready(_, let images, let total):
            let empty = model.empty
            let layout = ArtworkGrid(
                width: stage.width - left - right, ratio: model.tab.ratio, columns: model.tab.columns(forStageWidth: stage.width))
            // Takedown placeholders found while the thumbnails load disappear (the chosen image always stays)
            let shown = TakedownPlaceholder.shown(images, chosen: model.chosen, removed: actions.artwork.removedThumbnails)
            let all: [ArtworkTile] = [.none] + shown.map(ArtworkTile.image)
            let tiles = Array(all.enumerated())
            let rows = stride(from: 0, to: tiles.count, by: layout.columns).map { tiles[$0..<min($0 + layout.columns, tiles.count)] }
            ZStack(alignment: .top) {
                // Filters that leave nothing take the first choice's tile away with the rest: the message and its two buttons
                // are all there is
                if empty?.showsFirstChoice ?? true {
                    // The top and bottom edges fade where tiles go on behind them
                    FocusScroll(axis: .vertical, fades: FadeEdges(start: FadeEdge(solid: 30), end: FadeEdge(solid: 70))) {
                        VStack(alignment: .leading, spacing: stage.px(layout.gapY)) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                HStack(spacing: stage.px(layout.gapX)) {
                                    ForEach(row, id: \.element.id) { place, tile in tileView(tile, place: place, layout: layout) }
                                }
                            }
                        }
                        // A short list (the first choice alone, a single row) starts at the left like the full ones
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, stage.px(left))
                        .padding(.trailing, stage.px(right))
                        .padding(.top, stage.px(46))
                        .padding(.bottom, stage.px(96))
                    }
                    .focusable(false)
                    .scrollClipDisabled()
                }
                if let empty {
                    NoImages(
                        kind: empty, tab: model.tab, filters: model.filters, total: total,
                        gameName: model.match?.name.isEmpty == false ? model.match!.name : app.title, focus: focus,
                        left: left, right: right, tile: CGSize(width: layout.tileWidth, height: layout.tileHeight),
                        onReset: onReset, onChange: onChange)
                }
            }
        }
    }

    private func tileView(_ tile: ArtworkTile, place: Int, layout: ArtworkGrid) -> some View {
        let image = tile.image
        let id = image.map { ArtworkScreen.tileID($0.id) } ?? ArtworkScreen.noneID
        let kind = model.tab.kind
        let applying = actions.artwork.applying(hostID: hostID, appID: app.id, kind: kind)
        // The first eight tiles rise and fade in one after the other; later ones (a scroll, a filter) just appear
        return FocusItem(id: id, model: focus, action: { actions.applyArtwork(hostID: hostID, app: app, tab: model.tab, image: image) }) { focused in
            ArtworkTileView(
                tab: model.tab, width: layout.tileWidth, height: layout.tileHeight, focused: focused,
                inUse: image.map { model.chosen == .image($0.id) } ?? model.noneInUse,
                loading: applying == (image?.id ?? ArtworkStore.noImage), image: image, hostID: hostID, app: app)
                .equatable()
        }
        .staggerEntrance(index: place < Motion.staggerCap ? place : nil)
    }
}

/// A choice in the grid: the first one (the PC's artwork, the name) or one of SteamGridDB's images.
enum ArtworkTile: Hashable {
    case none
    case image(SteamGridDBImage)

    var image: SteamGridDBImage? {
        if case .image(let image) = self { image } else { nil }
    }

    var id: Int { image?.id ?? -1 }
}

/// Which choice the info strip describes.
enum ArtworkDescribed: Equatable {
    case firstChoice
    case image(SteamGridDBImage)

    func isInUse(_ chosen: ArtworkChoice) -> Bool {
        switch self {
        case .firstChoice: chosen == .none
        case .image(let image): chosen == .image(image.id)
        }
    }
}

// MARK: Toolbar

/// A toolbar pill (`PillButton` with `compact = true`): 64 px high, 28 px of padding on each side, the 30 px icon and the label
/// 12 px apart, then the accent [badge] (the count of active filters) and the [glyph] of the button that does the same.
struct ToolbarPill: View {
    let label: String
    let icon: String
    let focused: Bool
    var glyph: GlyphRole?
    var badge = 0
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    /// Inside a ``ChipGlideHost`` the host draws the ring and the pill only grows; alone it draws its own focus look.
    @Environment(\.glideLook) private var glide

    var body: some View {
        HStack(spacing: stage.px(12)) {
            SymbolView(symbol: icon, size: 30, color: colors.text, filled: focused)
            Text(label)
                .font(DelosFonts.figtree(stage.tpx(24), .semibold))
                .foregroundStyle(colors.text.color)
                .lineLimit(1)
            if badge > 0 { ArtCountBadge(count: badge) }
            if let glyph { GlyphButton(glyph, size: 32) }
        }
        .padding(.horizontal, stage.px(28))
        .frame(height: stage.px(64))
        .background {
            GlassShape(Capsule(), tint: colors.surface)
                .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
        .modifier(PillFocusLook(focused: focused, hosted: glide != nil))
    }
}

/// The focus look of a ``ToolbarPill``: in a ``ChipGlideHost`` it reports its frame to the host's one ring and only grows,
/// alone it has its own ring and glow (the game's settings screen).
private struct PillFocusLook: ViewModifier {
    let focused: Bool
    let hosted: Bool

    func body(content: Content) -> some View {
        if hosted {
            content.modifier(ChipFocus(focused: focused))
        } else {
            content.focusLook(focused, scale: GlideLook.pill.scale, ring: GlideLook.pill.ring, glowBlur: 50, glowY: 18)
        }
    }
}

/// The matched SteamGridDB game in the toolbar (`GameChip`): its name, year, id and how many images the tab has.
private struct ArtworkGameChip: View {
    let match: SteamGridDBGame?
    let looking: Bool
    let appName: String
    let tab: ArtworkTab
    let imageCount: Int?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        let name = looking ? L("artwork_chip_looking", appName)
            : match.map { $0.name.isEmpty ? L("artwork_chip_game_id", $0.id) : $0.name } ?? L("artwork_chip_not_found")
        let shape = RoundedRectangle(cornerRadius: stage.px(22))
        HStack(spacing: stage.px(16)) {
            SymbolView(symbol: Symbols.sportsEsports, size: 24, color: colors.accent2, filled: true)
                .frame(width: stage.px(40), height: stage.px(40))
                .background(Circle().fill(colors.accent2.opacity(0.2).color))
            MarqueeLabel(text: name, active: false)
                .font(DelosFonts.unbounded(stage.tpx(22)))
                .foregroundStyle(colors.text.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let match {
                if let year = match.year { chip(String(year)) }
                chip("#\(match.id)")
                if let imageCount { chip(tab.count(imageCount)) }
            }
        }
        .padding(.leading, stage.px(14))
        .padding(.trailing, stage.px(22))
        .frame(height: stage.px(64))
        .frame(maxWidth: .infinity)
        .background {
            GlassShape(shape, tint: colors.surface).overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(DelosFonts.figtree(stage.tpx(16), .semibold))
            .foregroundStyle(colors.text2.color)
            .lineLimit(1)
            .padding(.horizontal, stage.px(14))
            .padding(.vertical, stage.px(4))
            .background(Capsule().fill(colors.surface2.color))
    }
}

// MARK: Grid

/// No image in the grid (`NoImages`): what the filters left, as a message with Reset filters and Change filters and nothing
/// else, or that SteamGridDB has none, in a note beside the first choice that stays.
private struct NoImages: View {
    let kind: ArtworkEmpty
    let tab: ArtworkTab
    let filters: ArtFilters
    let total: Int?
    let gameName: String
    let focus: FocusModel
    /// The grid's side margins and the first choice's tile (stage px).
    let left: Double
    let right: Double
    let tile: CGSize
    let onReset: () -> Void
    let onChange: () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        switch kind {
        case .filtered: filtered
        case .bare: bare
        }
    }

    private var filtered: some View {
        VStack(spacing: stage.px(18)) {
            SymbolView(symbol: Symbols.search, size: 90, color: colors.accent, filled: true)
            Text(tab.none)
                .font(DelosFonts.unbounded(stage.tpx(34)))
                .foregroundStyle(colors.text.color)
            Text(total.map { tab.has(game: gameName, total: $0) } ?? tab.unknown)
                .font(DelosFonts.figtree(stage.tpx(22)))
                .foregroundStyle(colors.text2.color)
                .frame(maxWidth: stage.px(min(820, stage.width - 160)))
            Text(L("artwork_filtered_active", ArtFilterRules.chips(filters).map(\.label).joined(separator: " · ")))
                .font(DelosFonts.figtree(stage.tpx(20), .semibold))
                .foregroundStyle(colors.text3.color)
                .frame(maxWidth: stage.px(min(820, stage.width - 160)))
            ChipGlideHost(look: .pill) {
                HStack(spacing: stage.px(GlideLook.pillGap)) {
                    FocusItem(id: ArtworkEmpty.resetID, model: focus, clickCue: nil, action: onReset) { focused in
                        ToolbarPill(label: L("filters_art_reset"), icon: Symbols.reset, focused: focused, glyph: ArtworkEmpty.resetGlyph)
                    }
                    FocusItem(id: ArtworkEmpty.changeID, model: focus, clickCue: nil, action: onChange) { focused in
                        ToolbarPill(label: L("filters_art_change"), icon: Symbols.filter, focused: focused, glyph: ArtworkEmpty.changeGlyph)
                    }
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, stage.px(40))
        .padding(.leading, stage.px(left))
        .padding(.trailing, stage.px(right))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The note stands beside the first choice's tile, centred on its height.
    private var bare: some View {
        Text(tab.empty)
            .font(DelosFonts.figtree(stage.tpx(22)))
            .foregroundStyle(colors.text3.color)
            .frame(height: stage.px(tile.height))
            .padding(.leading, stage.px(left + tile.width + 48))
            .padding(.trailing, stage.px(right))
            .padding(.top, stage.px(46))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Why there is no grid (`GridMessage`).
private struct ArtworkMessage: View {
    let icon: String
    let title: String
    let text: String?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        VStack(spacing: stage.px(18)) {
            SymbolView(symbol: icon, size: 90, color: colors.accent, filled: true)
            Text(title)
                .font(DelosFonts.unbounded(stage.tpx(34)))
                .foregroundStyle(colors.text.color)
            if let text {
                Text(text)
                    .font(DelosFonts.figtree(stage.tpx(22)))
                    .foregroundStyle(colors.text2.color)
                    .frame(maxWidth: stage.px(min(820, stage.width - 160)))
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, stage.px(80))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A choice in the grid (`Tile`): the image in the tab's shape, the accent border and "In use" badge of the image in use,
/// a spinner while it downloads. The thumbnail loads when the tile scrolls into view.
struct ArtworkTileView: View, Equatable {
    let tab: ArtworkTab
    let width: Double
    let height: Double
    let focused: Bool
    let inUse: Bool
    let loading: Bool
    let image: SteamGridDBImage?
    let hostID: String
    let app: HostApp

    /// What a tile draws: everything but the environment, which SwiftUI tracks itself. A tile equal to what it was is not
    /// drawn again when the focus moves to another one.
    nonisolated static func == (a: ArtworkTileView, b: ArtworkTileView) -> Bool {
        a.tab == b.tab && a.width == b.width && a.height == b.height && a.focused == b.focused && a.inUse == b.inUse
            && a.loading == b.loading && a.image == b.image && a.hostID == b.hostID && a.app == b.app
    }

    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(HomeArt.self) private var art
    @Environment(HostStore.self) private var hosts
    @Environment(\.artMotion) private var artMotion
    @State private var picture: CGImage?
    @State private var visible = false
    /// The animation has faded in over the thumbnail: the still under it is hidden.
    @State private var animating = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(20))
        ZStack(alignment: .topLeading) {
            shape.fill(colors.surface2.color)
            content
                .opacity(animating ? 0 : 1)
            if let image, image.animated {
                ArtworkTileAnimation(image: image, logo: tab == .logo, playing: artMotion && visible, covering: $animating)
                    .frame(width: stage.px(width), height: stage.px(height))
            }
            if image == nil {
                Text(tab == .logo ? L("artwork_first_name_only") : L("artwork_first_from_pc"))
                    .font(DelosFonts.figtree(stage.tpx(18), .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, stage.px(8))
                    .background(Color(.sRGB, red: 5 / 255, green: 10 / 255, blue: 20 / 255, opacity: 0.65))
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            if loading {
                RingSpinner(size: 48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.sRGB, red: 5 / 255, green: 10 / 255, blue: 20 / 255, opacity: 0.6))
            }
            if image?.animated == true {
                // The icon alone on the covers, where "In use" takes the room (`Tile`)
                HStack(spacing: stage.px(6)) {
                    SymbolView(symbol: Symbols.animated, size: 20, color: colors.accent2, filled: true)
                    if tab != .cover {
                        Text(L("artwork_animated"))
                            .font(DelosFonts.figtree(stage.tpx(16), .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                .fixedSize()
                .padding(.horizontal, stage.px(tab == .cover ? 6 : 12))
                .padding(.vertical, stage.px(4))
                .background(Capsule().fill(Color(.sRGB, red: 5 / 255, green: 10 / 255, blue: 20 / 255, opacity: 0xB3 / 255)))
                .padding(stage.px(12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if inUse {
                HStack(spacing: stage.px(6)) {
                    SymbolView(symbol: Symbols.check, size: 20, color: colors.onAccent)
                    Text(L("artwork_in_use"))
                        .font(DelosFonts.figtree(stage.tpx(16), .bold))
                        .foregroundStyle(colors.onAccent.color)
                        .lineLimit(1)
                }
                .fixedSize()
                .padding(.horizontal, stage.px(12))
                .padding(.vertical, stage.px(4))
                .background(Capsule().fill(colors.accent.color))
                .padding(stage.px(12))
            }
        }
        .frame(width: stage.px(width), height: stage.px(height))
        .clipShape(shape)
        .overlay(shape.strokeBorder(inUse ? colors.accent.color : colors.line.color, lineWidth: stage.px(inUse ? 3 : 1)))
        .focusLook(focused, scale: ArtworkGrid.focusScale, ring: 4, glowBlur: 50, glowY: 18, corner: 20)
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .task(id: "\(visible)#\(art.artwork.version)") { await load() }
        // The picture says nothing to VoiceOver: the tile reads as the info strip's title and its badges
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isImage)
    }

    private var accessibilityText: String {
        let title = image.map { ArtworkFact.title($0, fallback: tab.label) } ?? L(tab == .logo ? "artwork_first_name_only" : "artwork_first_from_pc")
        return [title, image?.animated == true ? L("artwork_animated") : nil, inUse ? L("artwork_in_use") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    @ViewBuilder private var content: some View {
        if let picture {
            if tab == .logo, image != nil {
                // A logo is shown whole, with air round it
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(stage.px(18))
                    .frame(width: stage.px(width), height: stage.px(height))
            } else {
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: stage.px(width), height: stage.px(height))
                    .clipped()
            }
        } else if image != nil {
            RingSpinner(size: 36, color: colors.text3).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tab == .logo {
            Text(app.title)
                .font(DelosFonts.unbounded(stage.tpx(26), .bold))
                .foregroundStyle(colors.text.color)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(stage.px(18))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let placeholder = GameArt(hostID: hostID, app: app)
            PlaceholderArt(hue: placeholder.hue, hue2: placeholder.hue2, icon: placeholder.icon, glyphSize: 120)
        }
    }

    private func load() async {
        guard visible, picture == nil else { return }
        if let image {
            picture = await art.thumbnail(image)
            if let picture, TakedownPlaceholder.looksRemoved(picture) { art.artwork.markRemoved(image.previewURL) }
        } else if tab != .logo {
            picture = await art.boxArt(hostID: hostID, appID: app.id, hosts: hosts)
        }
    }
}

/// The playing animation of an animated choice over its first frame (`AnimatedTileLayer`): its animated thumbnail (else the
/// full file) is fetched the first time the tile may play, kept in the cache, decoded at tile size while [playing] and
/// released when it stops; a bar shows how far the download is meanwhile. A logo plays whole, with the still's air round it.
private struct ArtworkTileAnimation: View {
    let image: SteamGridDBImage
    let logo: Bool
    let playing: Bool
    @Binding var covering: Bool
    @Environment(HomeArt.self) private var art
    @Environment(\.stage) private var stage
    @State private var source: AnimatedSource?

    var body: some View {
        let store = art.artwork
        ZStack {
            AnimatedArtLayer(source: source, playing: playing, width: AnimatedPlayback.tileWidth, fit: logo, covering: $covering)
                .padding(logo ? stage.px(18) : 0)
            // The animation is a whole file: how far it is shows while it downloads
            if source == nil, playing, !store.hasNoAnimation(image) {
                TileDownloadBar(progress: store.animationProgress[image.previewURL])
            }
        }
        .task(id: playing) {
            guard source == nil, playing, !store.hasNoAnimation(image) else { return }
            if let data = await store.animation(of: image) { source = AnimatedSource(key: "choice/\(image.id)", data: data) }
        }
    }
}

/// A slim bar at the foot of a tile: [progress] of its download, a small spinner while the size is not known yet.
private struct TileDownloadBar: View {
    let progress: Double?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        if let progress {
            GeometryReader { proxy in
                Capsule()
                    .fill(colors.accent.color)
                    .frame(width: proxy.size.width * max(progress, 0.04))
                    .animation(Motion.fadeIn, value: progress)
            }
            .frame(height: stage.px(8))
            .background(Capsule().fill(Color(.sRGB, red: 5 / 255, green: 10 / 255, blue: 20 / 255, opacity: 0x99 / 255)))
            .clipShape(Capsule())
            .padding(.horizontal, stage.px(16))
            .padding(.vertical, stage.px(14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        } else {
            RingSpinner(size: 26)
                .padding(stage.px(12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }
}

// MARK: Info strip

/// The strip under the grid about the focused choice (`InfoStrip`): its title and badges, then its facts.
private struct ArtworkInfoStrip: View {
    let model: ArtworkModel
    let focus: FocusModel
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    /// What the strip describes: the focused tile, read here so the screen's body does not depend on the focus.
    private var described: ArtworkDescribed {
        if let images = model.images,
           let image = images.first(where: { AnyHashable(ArtworkScreen.tileID($0.id)) == focus.focused }) {
            return .image(image)
        }
        return .firstChoice
    }

    var body: some View {
        let tab = model.tab
        let described = described
        let inUse = described.isInUse(model.chosen)
        let shape = RoundedRectangle(cornerRadius: stage.px(26))
        let title: String
        let facts: [(label: String, value: String)]
        switch described {
        case .firstChoice:
            title = L(tab == .logo ? "artwork_first_name_only" : "artwork_first_from_pc")
            facts = tab == .logo
                ? [(L("artwork_fact_source"), L("artwork_fact_name_source")), (L("artwork_fact_shows"), L("artwork_fact_name_shows"))]
                : [(L("artwork_fact_source"), L("artwork_fact_pc_source")), (L("artwork_fact_shows"), L("artwork_fact_pc_shows"))]
        case .image(let image):
            title = ArtworkFact.title(image, fallback: tab.label)
            facts = ArtworkFact.of(image).map(\.text)
        }
        return HStack(spacing: stage.px(ArtworkInfoLayout.gap)) {
            VStack(alignment: .leading, spacing: stage.px(4)) {
                Text(title)
                    .font(DelosFonts.unbounded(stage.tpx(24)))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
                // The badges' row keeps its height with none shown, so the strip does not change height from one tile to the next
                ZStack(alignment: .leading) {
                    badge(L("artwork_in_use"), icon: Symbols.check, accent: true).hidden()
                    HStack(spacing: stage.px(8)) {
                        if case .image(let image) = described {
                            badge(L(image.animated ? "artwork_animated" : "artwork_static"), icon: image.animated ? Symbols.animated : nil, accent: false)
                        }
                        if inUse { badge(L("artwork_in_use"), icon: Symbols.check, accent: true) }
                    }
                }
            }
            .layoutPriority(1)
            // The facts that the title leaves room for; the last ones are left out rather than squeezed (compact stages, big text)
            ViewThatFits(in: .horizontal) {
                factRow(facts, count: 4)
                factRow(facts, count: 3)
                factRow(facts, count: 2)
                factRow(facts, count: 1)
                factRow(facts, count: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // As high as the content needs plus air, never under the design's 84 px; the plate is the whole frame, not the content
        .padding(.horizontal, stage.px(30))
        .padding(.vertical, stage.px(ArtworkInfoLayout.padding))
        .frame(maxWidth: .infinity, minHeight: stage.px(ArtworkInfoLayout.minHeight), alignment: .leading)
        .background {
            GlassShape(shape, tint: colors.surface).overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
    }

    private func factRow(_ facts: [(label: String, value: String)], count: Int) -> some View {
        HStack(spacing: stage.px(ArtworkInfoLayout.gap)) {
            ForEach(Array(facts.prefix(count).enumerated()), id: \.offset) { _, fact in
                VStack(alignment: .leading, spacing: 0) {
                    Text(fact.label)
                        .font(DelosFonts.figtree(stage.tpx(13), .semibold))
                        .tracking(stage.tpx(13) * 0.12)
                        .foregroundStyle(colors.text3.color)
                    Text(fact.value)
                        .font(DelosFonts.figtree(stage.tpx(22), .semibold))
                        .foregroundStyle(colors.text.color)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func badge(_ text: String, icon: String?, accent: Bool) -> some View {
        let content = accent ? colors.onAccent : colors.text2
        return HStack(spacing: stage.px(6)) {
            if let icon { SymbolView(symbol: icon, size: 16, color: content, filled: true) }
            Text(text)
                .font(DelosFonts.figtree(stage.tpx(14), .bold))
                .foregroundStyle(content.color)
        }
        .padding(.horizontal, stage.px(12))
        .padding(.vertical, stage.px(3))
        .background(Capsule().fill((accent ? colors.accent : colors.surface2).color))
    }
}
