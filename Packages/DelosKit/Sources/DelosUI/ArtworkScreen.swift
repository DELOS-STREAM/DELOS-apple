import DelosData
import DelosHost
import DelosInput
import Observation
import SwiftUI

/// What the Artwork screen knows and loads (`ArtworkScreen`'s state of DELOS for Android): the game's SteamGridDB match,
/// the image in use per kind and the images [tab]'s kind can be chosen from.
@MainActor
@Observable
final class ArtworkModel {
    let hostID: String
    let app: HostApp
    let artwork: ArtworkStore
    var tab = ArtworkTab.cover
    private(set) var choices = ArtworkChoices.loading
    private(set) var match: SteamGridDBGame?
    private(set) var chosen = ArtworkChoice.unset
    /// The game is being looked up (the first visit of a game never looked up).
    private(set) var looking = false
    @ObservationIgnored private var lists: [String: [SteamGridDBImage]] = [:]

    init(hostID: String, app: HostApp, artwork: ArtworkStore) {
        self.hostID = hostID
        self.app = app
        self.artwork = artwork
    }

    /// Never looked up yet: find the game first and download its best-rated images like the automatic run. A failure is
    /// reported through [onError].
    func lookup(onError: (any Error) -> Void) async {
        if artwork.enabled, await !artwork.isSearched(hostID: hostID, appID: app.id) {
            looking = true
            do {
                try await artwork.fetch(hostID: hostID, appID: app.id, name: app.title)
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
        let key = "\(game.id)|\(tab.kind.rawValue)"
        if let cached = lists[key] { return choices = .ready(gameID: game.id, images: cached) }
        choices = .loading
        do {
            let list = try await artwork.choices(hostID: hostID, appID: app.id, kind: tab.kind)
            lists[key] = list
            choices = .ready(gameID: game.id, images: list)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            choices = .failed(ShellActions.artworkErrorText(error, fallback: "artwork_unreachable"))
        }
    }

    /// What identifies a load: another tab, game or key starts it over.
    struct LoadKey: Hashable {
        let tab: ArtworkTab
        let game: Int?
        let enabled: Bool
        let looking: Bool
    }

    var loadKey: LoadKey { LoadKey(tab: tab, game: match?.id, enabled: artwork.enabled, looking: looking) }

    /// The tile that takes the focus when a list shows: the image in use, else the first choice.
    func initialTile() -> String {
        if case .image(let id) = chosen, case .ready(_, let images) = choices, images.contains(where: { $0.id == id }) {
            return ArtworkScreen.tileID(id)
        }
        return ArtworkScreen.noneID
    }

    /// Whether the first choice (the PC's artwork, the name) is the one in use.
    var noneInUse: Bool {
        if case .ready(_, let images) = choices {
            return chosen == .none || (chosen == .unset && images.isEmpty)
        }
        return chosen == .none
    }
}

/// The artwork of one game (the game's menu → Artwork; `ArtworkScreen` of DELOS for Android): a tab per kind (cover, wide
/// cover, background, logo, switched with L1 and R1) over a toolbar (the matched SteamGridDB game, search for another name
/// with X), the grid of every still SteamGridDB image to choose from (the first choice being the PC's artwork, or the name
/// instead of a logo) and a strip about the focused image. A or a tap uses the image; the image in use has the accent
/// border. The filters and animated images of Android are not ported: the store downloads and shows still images.
struct ArtworkScreen: View {
    let hostID: String
    let app: HostApp
    let focus: FocusModel
    let navigator: Navigator
    let actions: ShellActions
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(HomeArt.self) private var art
    @State private var model: ArtworkModel

    static let noneID = "art-none"
    static let searchID = "art-search"
    static let firstFocus = noneID
    static func tileID(_ image: Int) -> String { "art-\(image)" }
    static func tabID(_ tab: ArtworkTab) -> String { "art-tab-\(tab)" }

    init(hostID: String, app: HostApp, focus: FocusModel, navigator: Navigator, actions: ShellActions) {
        self.hostID = hostID
        self.app = app
        self.focus = focus
        self.navigator = navigator
        self.actions = actions
        _model = State(initialValue: ArtworkModel(hostID: hostID, app: app, artwork: actions.artwork))
    }

    var body: some View {
        let left = 150 + stage.safe.leading, right = 150 + stage.safe.trailing
        let top = stage.safe.top
        let infoTop = stage.height - 194
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
            ArtworkTabs(selected: model.tab, focus: focus) { select($0, sound: .select) }
                .frame(height: stage.px(66))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, stage.px(right))
                .tvFocusSection()
                .offset(y: stage.px(124 + top))
            toolbar
                .frame(height: stage.px(64))
                .padding(.horizontal, stage.px(left))
                .padding(.trailing, stage.px(right - left))
                .offset(y: stage.px(206 + top))
            grid(left: left, right: right)
                .frame(height: stage.px(infoTop - 10 - (324 + top)))
                .offset(y: stage.px(324 + top))
            ArtworkInfoStrip(tab: model.tab, described: described, inUse: described.isInUse(model.chosen))
                .frame(height: stage.px(84))
                .padding(.horizontal, stage.px(left))
                .padding(.trailing, stage.px(right - left))
                .offset(y: stage.px(infoTop))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.lookup { error in report(error) } }
        .task(id: model.loadKey) { await model.load() }
        .task(id: actions.artwork.version) { await model.refresh() }
        .onChange(of: model.choices) { _, now in
            if case .ready = now { focus.focus(model.initialTile()) }
        }
        .onAppear {
            navigator.commandCapture = { command in capture(command) }
        }
        .onDisappear { navigator.commandCapture = nil }
    }

    // MARK: Parts

    private var toolbar: some View {
        HStack(spacing: stage.px(34)) {
            ArtworkGameChip(
                match: model.match, looking: model.looking, appName: app.title, tab: model.tab,
                imageCount: { if case .ready(_, let images) = model.choices { images.count } else { nil } }())
            let enabled = actions.artwork.enabled
            FocusItem(id: Self.searchID, model: focus, clickCue: .open, action: { search() }) { focused in
                ToolbarPill(label: L("artwork_search_other"), icon: Symbols.searchName, focused: focused)
                    .opacity(enabled ? 1 : 0.4)
            }
            .disabled(!enabled)
        }
    }

    @ViewBuilder private func grid(left: Double, right: Double) -> some View {
        switch model.choices {
        case .loading:
            ArtworkMessage(icon: Symbols.loading, title: L("artwork_loading"), text: nil)
        case .noKey:
            ArtworkMessage(icon: Symbols.key, title: L("artwork_no_key_title"), text: L("artwork_no_key_note"))
        case .noGame:
            ArtworkMessage(icon: Symbols.search, title: L("artwork_no_game_title", app.title), text: L("artwork_no_game_note"))
        case .failed(let text):
            ArtworkMessage(icon: Symbols.error, title: L("artwork_unreachable"), text: text)
        case .ready(_, let images):
            let layout = ArtworkGrid(
                width: stage.width - left - right, ratio: model.tab.ratio, columns: model.tab.columns(forStageWidth: stage.width))
            let tiles: [ArtworkTile] = [.none] + images.map(ArtworkTile.image)
            let rows = stride(from: 0, to: tiles.count, by: layout.columns).map { Array(tiles[$0..<min($0 + layout.columns, tiles.count)]) }
            FocusScroll(axis: .vertical) {
                VStack(alignment: .leading, spacing: stage.px(layout.gapY)) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: stage.px(layout.gapX)) {
                            ForEach(row, id: \.id) { tile in tileView(tile, layout: layout) }
                        }
                    }
                    if images.isEmpty {
                        Text(model.tab.empty)
                            .font(DelosFonts.figtree(stage.tpx(22)))
                            .foregroundStyle(colors.text2.color)
                            .padding(.top, stage.px(12))
                    }
                }
                .padding(.leading, stage.px(left))
                .padding(.trailing, stage.px(right))
                .padding(.top, stage.px(46))
                .padding(.bottom, stage.px(96))
            }
            .focusable(false)
            .scrollClipDisabled()
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: stage.px(30))
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: stage.px(70))
                }
            }
        }
    }

    private func tileView(_ tile: ArtworkTile, layout: ArtworkGrid) -> some View {
        let image = tile.image
        let id = image.map { Self.tileID($0.id) } ?? Self.noneID
        let kind = model.tab.kind
        let applying = actions.artwork.applying(hostID: hostID, appID: app.id, kind: kind)
        return FocusItem(id: id, model: focus, action: { actions.applyArtwork(hostID: hostID, app: app, tab: model.tab, image: image) }) { focused in
            ArtworkTileView(
                tab: model.tab, width: layout.tileWidth, height: layout.tileHeight, focused: focused,
                inUse: image.map { model.chosen == .image($0.id) } ?? model.noneInUse,
                loading: applying == (image?.id ?? ArtworkStore.noImage), image: image, hostID: hostID, app: app)
        }
    }

    /// What the strip describes: the focused tile.
    private var described: ArtworkDescribed {
        if case .ready(_, let images) = model.choices,
           let image = images.first(where: { AnyHashable(Self.tileID($0.id)) == focus.focused }) {
            return .image(image)
        }
        return .firstChoice
    }

    // MARK: Input

    private func select(_ next: ArtworkTab, sound: Cue) {
        guard next != model.tab else { return }
        actions.layers.feedback?.play(sound)
        model.tab = next
    }

    private func search() {
        actions.openArtworkSearch(hostID: hostID, app: app, term: model.match?.name.isEmpty == false ? model.match!.name : app.title)
    }

    private func report(_ error: any Error) {
        actions.layers.feedback?.play(.error)
        actions.toasts.show(ShellActions.artworkErrorText(error, fallback: "artwork_unreachable"), icon: Symbols.error)
    }

    /// L1 and R1 switch the tab; X searches for another name.
    private func capture(_ command: MenuCommand) -> Bool {
        switch command {
        case .previousTab, .nextTab:
            select(model.tab.step(command == .nextTab ? 1 : -1), sound: .move)
            return true
        case .options:
            search()
            return true
        case .up, .down, .left, .right, .accept, .back, .menu, .toastAction:
            return false
        }
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

// MARK: Tabs

/// The tabs between the L1 and R1 badges; on tvOS each is also an item of the focus, since the remote has no shoulders.
private struct ArtworkTabs: View {
    let selected: ArtworkTab
    let focus: FocusModel
    let onSelect: (ArtworkTab) -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ShoulderBadge(role: .leftShoulder)
            ForEach(ArtworkTab.allCases, id: \.self) { tab in tabView(tab) }
            ShoulderBadge(role: .rightShoulder)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: selected)
    }

    @ViewBuilder private func tabView(_ tab: ArtworkTab) -> some View {
        #if os(tvOS)
        FocusItem(id: ArtworkScreen.tabID(tab), model: focus, action: { onSelect(tab) }) { focused in
            pillView(tab).focusLook(focused, scale: 1.06, ring: 3, glowBlur: 0, glowY: 0)
        }
        .padding(.horizontal, stage.px(4))
        #else
        pillView(tab)
            .contentShape(Capsule())
            .onTapGesture { onSelect(tab) }
            .padding(.horizontal, stage.px(4))
        #endif
    }

    private func pillView(_ tab: ArtworkTab) -> some View {
        let on = tab == selected
        return HStack(spacing: stage.px(12)) {
            SymbolView(symbol: tab.icon, size: 30, color: on ? colors.onAccent : colors.text2, filled: on)
            Text(tab.label)
                .font(DelosFonts.figtree(stage.tpx(22), .semibold))
                .foregroundStyle((on ? colors.onAccent : colors.text2).color)
                .lineLimit(1)
        }
        .padding(.horizontal, stage.px(22))
        .frame(height: stage.px(66))
        .background {
            if on { Capsule().fill(colors.accent.color).matchedGeometryEffect(id: "pill", in: pill) }
        }
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// The previous / next tab hint beside the tabs (L1 / R1 on a PlayStation or generic pad, LB / RB, L / R): the connected controller's.
private struct ShoulderBadge: View {
    let role: GlyphRole
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        Text(ControllerGlyphs.shared.mark(role).text ?? "")
            .font(DelosFonts.figtree(stage.tpx(18), .bold))
            .foregroundStyle(colors.text3.color)
            .padding(.horizontal, stage.px(12))
            .padding(.vertical, stage.px(6))
            .overlay(RoundedRectangle(cornerRadius: stage.px(10)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
            .padding(.horizontal, stage.px(10))
    }
}

// MARK: Toolbar

/// A toolbar pill (`PillButton` with `compact = true`): 64 px high.
struct ToolbarPill: View {
    let label: String
    let icon: String
    let focused: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(12)) {
            SymbolView(symbol: icon, size: 30, color: colors.text, filled: focused)
            Text(label)
                .font(DelosFonts.figtree(stage.tpx(24), .semibold))
                .foregroundStyle(colors.text.color)
                .lineLimit(1)
        }
        .padding(.horizontal, stage.px(28))
        .frame(height: stage.px(64))
        .background {
            GlassShape(Capsule(), tint: colors.surface)
                .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
        .focusLook(focused, scale: 1.08, ring: 4, glowBlur: 50, glowY: 18)
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
private struct ArtworkTileView: View {
    let tab: ArtworkTab
    let width: Double
    let height: Double
    let focused: Bool
    let inUse: Bool
    let loading: Bool
    let image: SteamGridDBImage?
    let hostID: String
    let app: HostApp
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(HomeArt.self) private var art
    @Environment(HostStore.self) private var hosts
    @State private var picture: CGImage?
    @State private var visible = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(20))
        ZStack(alignment: .topLeading) {
            shape.fill(colors.surface2.color)
            content
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
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.sRGB, red: 5 / 255, green: 10 / 255, blue: 20 / 255, opacity: 0.6))
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
            ProgressView().tint(colors.text3.color).frame(maxWidth: .infinity, maxHeight: .infinity)
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
        } else if tab != .logo {
            picture = await art.boxArt(hostID: hostID, appID: app.id, hosts: hosts)
        }
    }
}

// MARK: Info strip

/// The strip under the grid about the focused choice (`InfoStrip`): its title and badges, then its facts.
private struct ArtworkInfoStrip: View {
    let tab: ArtworkTab
    let described: ArtworkDescribed
    let inUse: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
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
        return HStack(spacing: stage.px(44)) {
            VStack(alignment: .leading, spacing: stage.px(4)) {
                Text(title)
                    .font(DelosFonts.unbounded(stage.tpx(24)))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
                HStack(spacing: stage.px(8)) {
                    if case .image = described { badge(L("artwork_static"), icon: nil, accent: false) }
                    if inUse { badge(L("artwork_in_use"), icon: Symbols.check, accent: true) }
                }
            }
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, stage.px(30))
        .frame(maxWidth: .infinity)
        .background {
            GlassShape(shape, tint: colors.surface).overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
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
