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
    let onApp: @MainActor (HostApp) -> Void
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
            case .apps(let apps): GameLibrary(hostID: hostID, apps: actions.libraryOrder(hostID: hostID, apps: apps), focus: focus, actions: actions, onApp: onApp)
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

/// The games: the focused one's title and info above the row of covers. The focused cover stays where the first one
/// starts (Android keeps it at the left edge too).
private struct GameLibrary: View {
    let hostID: String
    let apps: [HostApp]
    let focus: FocusModel
    let actions: ShellActions
    let onApp: @MainActor (HostApp) -> Void
    @Environment(HostStore.self) private var hosts
    @Environment(HomeArt.self) private var art
    @Environment(\.stage) private var stage
    @State private var position = ScrollPosition(edge: .leading)
    @State private var lastFocusMove = Date.distantPast

    static let tile = 300.0, height = 450.0, gap = 44.0
    /// The wide first cover: three covers and the two gaps between them.
    static let wide = 3 * tile + 2 * gap
    /// Room above and below the covers for the focus scale, the ring and the glow, which the scroll view would cut.
    static let rowPad = 40.0

    /// Where cover [index] starts in the row, stage pixels from the first one.
    static func itemStart(_ index: Int) -> Double {
        index == 0 ? 0 : wide + gap + Double(index - 1) * (tile + gap)
    }

    var body: some View {
        let focusedIndex = apps.firstIndex { focus.focused == AnyHashable(Self.id($0)) }
        let focused = apps[focusedIndex ?? 0]
        let layout = HomeLayout(scale: stage.textScale, safeTop: stage.safe.top, stageHeight: stage.height)
        let host = hosts.host(hostID)
        let running = host.flatMap { $0.runningAppID == 0 ? nil : $0.runningAppID }
        let last = actions.lastPlayed(hostID: hostID)
        let start = 150 + stage.safe.leading
        ZStack(alignment: .topLeading) {
            GameInfo(hostID: hostID, app: focused, pcName: host?.name ?? "", running: running == focused.id,
                     playtime: actions.playtime(hostID: hostID, appID: focused.id), layout: layout)
                .padding(.leading, stage.px(start))
                .padding(.top, stage.px(layout.titleTop))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: stage.px(Self.gap)) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        let badge: CoverBadge? = app.id == running ? .running : index == 0 && app.id == last ? .lastPlayed : nil
                        FocusItem(id: Self.id(app), model: focus, menu: { actions.gameMenu(hostID: hostID, app: app) }, action: { onApp(app) }) { isFocused in
                            Cover(hostID: hostID, app: app, wide: index == 0, focused: isFocused, badge: badge)
                        }
                    }
                }
                .padding(.horizontal, stage.px(start))
                .padding(.vertical, stage.px(Self.rowPad))
            }
            .scrollClipDisabled()
            // The row is moved by the focus alone: without this a hardware keyboard's arrow keys also scroll the
            // scroll view by themselves, on top of the focus (owner's iPad with a Magic Keyboard: a crawl, then the
            // focus ran off the screen)
            .focusable(false)
            .scrollPosition($position)
            .padding(.top, stage.px(layout.coverTop - Self.rowPad))
            .onChange(of: focusedIndex) { _, now in
                guard let now else { return }
                // A held arrow moves the focus every 50 ms: overlapping 200 ms animations lagged behind it, so a fast
                // move scrolls in one short step and a single press glides
                let fast = Date.now.timeIntervalSince(lastFocusMove) < 0.12
                lastFocusMove = .now
                withAnimation(fast ? .linear(duration: 0.05) : .easeOut(duration: 0.2)) {
                    position.scrollTo(x: stage.px(Self.itemStart(now)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The first cover takes the focus, before the covers register (the model would take whichever comes first)
        .onAppear { if focusedIndex == nil { focus.focus(Self.id(apps[0])) } }
        // The game background follows the focus with a short delay, so it does not flicker while scrolling fast
        .task(id: "\(GameArt.key(hostID, focused.id))#\(art.artwork.version)") {
            let image = await heroImage(focused)
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            art.hero = GameArt(hostID: hostID, app: focused, image: image)
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
    @Environment(\.stage) private var stage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GameTitle(hostID: hostID, app: app, box: layout.titleBox)
            Spacer().frame(height: stage.px(layout.titleGap))
            InfoRow(playtime: playtime, height: layout.infoHeight) {
                if running { InfoChip(icon: Symbols.running, label: L("home_chip_running_on", pcName)) }
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
        let shape = RoundedRectangle(cornerRadius: stage.px(26))
        let placeholder = GameArt(hostID: hostID, app: app)
        ZStack(alignment: .topLeading) {
            shape.fill(colors.surface2.color)
            ZStack {
                if let shown {
                    Image(decorative: shown, scale: 1).resizable().scaledToFill()
                        .frame(width: stage.px(width), height: stage.px(GameLibrary.height))
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
private struct InfoChip: View {
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
    }
}
