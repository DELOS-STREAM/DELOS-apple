import SwiftUI

/// The numbers of the stream menu's dock (`StreamMenuLayout` and `StreamMenuMotion` of DELOS for Android) for [count]
/// tiles: stage pixels and milliseconds. The tiles and the labels take their progress from one clock (milliseconds since
/// the menu opened, and since it started to close), like the prototype's per-element animations with a delay.
enum StreamDockLayout {
    static let tile = 150.0
    static let tileRadius = 42.0
    static let gap = 40.0
    static let icon = 64.0
    static let focusScale = 1.12
    static let iconFocusScale = 1.04
    /// The ring around the focused tile: 186 box (the tile at 1.12 is 168, plus 9 each side).
    static let ring = 186.0
    static let ringRadius = 56.0
    static let ringWidth = 4.0
    static let labelSize = 24.0
    static let labelGap = 24.0
    static let labelFocusShift = 8.0
    /// The tiles' top lies this far above the stage's bottom edge (1080 − 628).
    static let topFromBottom = 452.0

    static let pillHeight = 34.0
    static let pillSize = 18.0
    static let pillPaddingX = 15.0
    static let pillRight = -12.0
    static let pillTop = -14.0

    // The entrance (delays from the moment the menu opens), milliseconds
    static let enter = 620.0
    static let tileDelay = 100.0
    static let staggerTile = 42.0
    static let labelExtraDelay = 140.0
    static let ringExtraDelay = 260.0
    static let labelDuration = enter * 0.8
    static let exitStagger = 8.0
    /// The gradient behind the tiles (and the blur of the stream) arrives and leaves.
    static let gradientIn = 460.0
    static let gradientOut = leave + 80
    static let leave = Motion.exit
    static let ringGlide = 560.0
    static let breathe = 2600.0
    /// The stream behind the menu is blurred by this many stage pixels.
    static let videoBlur = 50.0

    static func rowWidth(count: Int) -> Double { Double(count) * tile + Double(max(count - 1, 0)) * gap }

    static func tileLeft(_ index: Int) -> Double { Double(index) * (tile + gap) }

    static func ringLeft(_ index: Int) -> Double { tileLeft(index) + tile / 2 - ring / 2 }

    static func tileDelay(_ index: Int) -> Double { tileDelay + Double(max(index, 0)) * staggerTile }

    static func labelDelay(_ index: Int) -> Double { tileDelay(index) + labelExtraDelay }

    static func ringDelay(_ index: Int) -> Double { tileDelay(index) + ringExtraDelay }

    /// The tile's exit starts later the further left it is: the last one leaves first.
    static func exitDelay(_ index: Int, count: Int) -> Double { Double(max(count - 1 - index, 0)) * exitStagger }

    /// The time the whole entrance needs: the ring on the last tile is the last to arrive.
    static func enterTotal(count: Int) -> Double {
        max(ringDelay(count - 1) + enter, labelDelay(count - 1) + labelDuration)
    }

    /// The time the whole exit needs: the first tile starts last.
    static func exitTotal(count: Int) -> Double { exitDelay(0, count: count) + leave }

    /// The dock stays mounted this long after the menu closed: the exit, then 80 ms.
    static func closeTotal(count: Int) -> Double { exitTotal(count: count) + 80 }
}

/// The stream menu (`StreamMenuRoot` of DELOS for Android): the dock of glass tiles with the game's name and the button hints
/// above them and the help of the focused tile under them, one gold ring that glides between the tiles and breathes, on a
/// dark ramp over the blurred stream, and the popover with the pages of the tiles that have one. The tiles rise in one
/// after the other and leave the other way round. [open] false: the menu is leaving (the parent unmounts it once the exit
/// is over).
struct StreamMenu: View {
    let focus: FocusModel
    let controller: StreamController
    let open: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    @Environment(Layers.self) private var layers: Layers?
    @State private var openedAt = Date()
    @State private var closedAt: Date?
    @State private var animating = true
    /// The horizontal center of each tile in the menu's space, stage pixels: the caret of the popover points at it.
    @State private var tileCenters: [BarItem: Double] = [:]

    private typealias D = StreamDockLayout
    private typealias M = StreamMenuLayout

    static let resumeID = BarItem.resume.id
    private nonisolated static let space = "stream-menu"

    private var tiles: [BarItem] { controller.capabilities.tiles }
    private var popOpen: Bool { open && controller.menu.isOpen }

    // MARK: Geometry

    private var labelHeight: Double { D.labelSize * stage.textScale * M.labelLineHeight }
    /// The caption's top edge below the tiles' top edge (below the label, its gap and 8).
    private var captionTop: Double { D.tile + D.labelGap + labelHeight + M.captionGap + 8 }

    /// How far the dock rises so that its caption stays clear of the safe area (the home indicator).
    private var lift: Double {
        let bottom = stage.height - D.topFromBottom + captionTop + M.captionHeight(textScale: stage.textScale)
        return max(0, bottom - (stage.height - stage.safe.bottom - 16))
    }

    /// The tiles' top edge on the stage.
    private var top: Double { stage.height - D.topFromBottom - lift }

    private var geometry: DockGeometry { DockGeometry(count: tiles.count, width: stage.width) }

    var body: some View {
        let count = tiles.count
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(paused: !animating)) { timeline in
                let now = timeline.date
                let t = now.timeIntervalSince(openedAt) * 1000
                let exitT = closedAt.map { now.timeIntervalSince($0) * 1000 } ?? 0
                ZStack(alignment: .topLeading) {
                    backdrop(t: t, exitT: exitT)
                    dock(t: t, exitT: exitT)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .disabled(!open)
            StreamPopoverHost(
                controller: controller, anchorX: anchorX, bottom: stage.height - M.popoverBottom - M.caretHeight - lift,
                maxHeight: M.maxHeight(stageHeight: stage.height, lift: lift, top: stage.safe.top))
                .disabled(!open)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .environment(\.modalFocus, popOpen ? controller.menu.focus : nil)
        .onAppear { focus.focus(Self.resumeID) }
        .task {
            try? await Task.sleep(for: .milliseconds(Int(D.enterTotal(count: count)) + 50))
            if open { animating = false }
        }
        .onChange(of: open) { _, now in
            if now {
                closedAt = nil
            } else {
                closedAt = Date()
                animating = true
            }
        }
        // A dimmed tile that opens no page takes no focus while a popover is open: the ring stays on the tile that opened it
        .onChange(of: focus.focused) { _, now in
            guard controller.menu.isOpen, let item = BarItem(id: now), item.page == nil, let opener = controller.menu.page.barItem else { return }
            focus.focus(opener.id)
        }
        // The tile that opened a page wears the focus while the page is open (another tile's page moves it there)
        .onChange(of: controller.menu.page) { _, page in
            guard let opener = page.barItem, focus.focused != AnyHashable(opener.id) else { return }
            focus.focus(opener.id)
        }
    }

    /// The center of the tile that opened the open page: its caret's point.
    private var anchorX: Double {
        guard let item = controller.menu.shownPage.barItem else { return stage.width / 2 }
        return tileCenters[item] ?? stage.width / 2
    }

    // MARK: Backdrop

    /// `#grad`: the soft ramp under the dock, and the extra scrim while a popover is open (`#scrim`). Nothing else dims the
    /// stream; a tap beside the tiles closes the popover and never resumes.
    private func backdrop(t: Double, exitT: Double) -> some View {
        let alpha = open || closedAt == nil
            ? Motion.progress(t, delay: 0, duration: D.gradientIn, Motion.ease)
            : 1 - Motion.progress(exitT, delay: 0, duration: D.gradientOut, Motion.ease)
        let ink = RGBA(red: 4 / 255, green: 6 / 255, blue: 14 / 255)
        return ZStack {
            LinearGradient(stops: [
                .init(color: ink.opacity(0).color, location: 0),
                .init(color: ink.opacity(0).color, location: 0.34),
                .init(color: ink.opacity(0.22).color, location: 0.48),
                .init(color: ink.opacity(0.55).color, location: 0.66),
                .init(color: ink.opacity(0.80).color, location: 0.84),
                .init(color: ink.opacity(0.90).color, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            ink.opacity(M.scrimPopover).color
                .opacity(popOpen ? 1 : 0)
                .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000), value: popOpen)
        }
        .opacity(alpha)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
            guard controller.menuOpen else { return }
            layers?.feedback?.play(.back)
            controller.tapOutside()
        }
    }

    // MARK: Dock

    private func dock(t: Double, exitT: Double) -> some View {
        let geometry = geometry
        let sink = popOpen ? M.dockShift : 0
        return ZStack(alignment: .topLeading) {
            tilesRow(t: t, exitT: exitT, geometry: geometry)
            DockHead(title: controller.appName, t: t, exitT: exitT)
                .offset(x: stage.px(geometry.tilesLeft))
            DockCaption(text: caption, popOpen: popOpen, t: t, exitT: exitT)
                .frame(width: stage.px(M.captionWidth), height: stage.px(M.captionHeight(textScale: stage.textScale)), alignment: .top)
                .offset(x: stage.px((stage.width - M.captionWidth) / 2), y: stage.px(captionTop))
        }
        .frame(width: stage.px(stage.width), alignment: .topLeading)
        .offset(y: stage.px(top + sink))
        .animation(reducedMotion ? nil : Motion.out(M.dockSink), value: popOpen)
    }

    /// The help of the tile that has the focus (the one that opened the page while the popover is open).
    private var caption: String {
        StreamMenuText.caption(BarItem(id: focus.focused) ?? tiles.first ?? .resume)
    }

    private func tilesRow(t: Double, exitT: Double, geometry: DockGeometry) -> some View {
        let focusedIndex = tiles.firstIndex { focus.focused == AnyHashable($0.id) }
        let row = ZStack(alignment: .topLeading) {
            DockRing(index: focusedIndex ?? 0, t: t, exitT: exitT, count: tiles.count)
            ForEach(Array(tiles.enumerated()), id: \.element) { index, item in
                tile(item, index: index, t: t, exitT: exitT)
                    .offset(x: stage.px(D.tileLeft(index)))
            }
        }
        .frame(width: stage.px(D.rowWidth(count: tiles.count)), height: stage.px(D.tile), alignment: .topLeading)
        if geometry.scrolls {
            // The tiles keep their size and the row scrolls sideways under the focus; the ring, glow, pills and labels have room
            let room = 110.0
            return AnyView(
                FocusScroll(axis: .horizontal) {
                    row
                        .padding(.leading, stage.px(DockGeometry.scrollSide))
                        .padding(.trailing, stage.px(DockGeometry.scrollSide))
                        .padding(.top, stage.px(room))
                        .padding(.bottom, stage.px(130))
                }
                .frame(width: stage.px(stage.width), height: stage.px(room + D.tile + 130))
                .offset(y: -stage.px(room)))
        }
        return AnyView(row.offset(x: stage.px(geometry.tilesLeft)))
    }

    private func tile(_ item: BarItem, index: Int, t: Double, exitT: Double) -> some View {
        let last = tiles.count - 1
        var moves: [FocusDirection: AnyHashable] = [:]
        // The dock wraps: Right on the last tile goes to the first, Left on the first to the last
        if tiles.count > 1 {
            if index == 0 { moves[.left] = AnyHashable(tiles[last].id) }
            if index == last { moves[.right] = AnyHashable(tiles[0].id) }
        }
        let works = StreamMenuNavigation.tileWorks(opensPage: item.page != nil, popoverOpen: popOpen)
        return FocusItem(
            id: item.id, model: focus, moves: moves, clickCue: works ? cue(item) : nil, action: { activate(item) }
        ) { focused in
            DockTile(
                spec: spec(item), focused: focused, index: index, count: tiles.count, t: t, exitT: exitT,
                dimmed: popOpen && !focused, labelsHidden: popOpen && stage.compact && stage.height < 800)
        }
        .onGeometryChange(for: Double.self) { $0.frame(in: .named(Self.space)).midX } action: { x in
            tileCenters[item] = x / stage.scale
        }
    }

    private func cue(_ item: BarItem) -> Cue {
        switch item {
        case .resume: .back
        case .brightness, .more: .open
        default: .select
        }
    }

    private func activate(_ item: BarItem) {
        guard StreamMenuNavigation.tileWorks(opensPage: item.page != nil, popoverOpen: popOpen) else { return }
        switch item {
        case .resume: controller.closeMenu()
        case .keyboard: controller.toggleKeyboard()
        case .overlay: controller.toggleStatistics()
        case .brightness, .more:
            if let page = item.page { controller.openMenuPage(page) }
        case .disconnect: Task { await controller.leave(quit: false, scene: true) }
        case .quit: Task { await controller.leave(quit: true, scene: true) }
        }
    }

    private func spec(_ item: BarItem) -> DockTile.Spec {
        switch item {
        case .resume: DockTile.Spec(icon: Symbols.resume, label: L("stream_menu_tile_resume"))
        // The Delos keyboard of Android turns accent while it is up and has no On / Off pill
        case .keyboard: DockTile.Spec(icon: Symbols.keyboard, label: L("stream_menu_tile_keyboard"), on: controller.keyboardShown, showState: false)
        case .overlay: DockTile.Spec(icon: Symbols.overlay, label: L("stream_menu_tile_overlay"), on: controller.statisticsEnabled)
        case .brightness: DockTile.Spec(icon: Symbols.brightnessMedium, label: L("stream_menu_tile_brightness"))
        case .more: DockTile.Spec(icon: Symbols.moreHoriz, label: L("stream_menu_tile_more"))
        case .disconnect: DockTile.Spec(icon: Symbols.logout, label: L("stream_menu_tile_disconnect"))
        case .quit: DockTile.Spec(icon: Symbols.powerSettingsNew, label: L("stream_menu_tile_quit"))
        }
    }
}

/// An A or B button's glyph (`GlyphButton` of DELOS for Android): the letter in the background color on a disc in the text
/// color.
struct ButtonGlyph: View {
    let letter: String
    let size: Double
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        Text(letter)
            .font(DelosFonts.figtree(stage.tpx(21 * size / 38), .heavy))
            .foregroundStyle(colors.bg.color)
            .frame(width: stage.px(size), height: stage.px(size))
            .background(Circle().fill(colors.text.color))
            .accessibilityHidden(true)
    }
}

/// The game's name (Unbounded 36) and the A / B hints, their bottom edge 46 above the tiles at the row's left edge. They rise
/// 24 px from 60 ms and fade out with the exit.
private struct DockHead: View {
    let title: String
    let t: Double
    let exitT: Double
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion

    private typealias D = StreamDockLayout
    private typealias M = StreamMenuLayout

    var body: some View {
        let p = Motion.progress(t, delay: 60, duration: D.enter, Motion.easeOut)
        let leaving = Motion.progress(exitT, delay: 0, duration: D.leave, Motion.ease)
        // A low compact stage has no room for the two hints one above the other: side by side there
        let inRow = stage.compact && stage.height < 800
        let hints = Group {
            hint("A", L("stream_menu_hint_select"))
            hint("B", L("stream_menu_hint_back"))
        }
        let block = VStack(alignment: .leading, spacing: stage.px(M.headGap)) {
            Text(title)
                .font(DelosFonts.unbounded(stage.px(M.titleSize)))
                .foregroundStyle(colors.text.color)
                .shadow(color: .black.opacity(0.55), radius: stage.px(8), y: stage.px(2))
                .lineLimit(1)
                .frame(maxWidth: stage.px(min(M.titleMaxWidth, stage.width - 2 * DockGeometry.scrollSide)), alignment: .leading)
            if inRow {
                HStack(spacing: stage.px(32)) { hints }
            } else {
                VStack(alignment: .leading, spacing: stage.px(M.hintsGap)) { hints }
            }
        }
        // The block's bottom edge lies 46 above the tiles: it hangs from a point on that edge
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: .bottomLeading) { block.fixedSize().offset(y: -stage.px(M.headBottom)) }
            .opacity(min(max(p, 0), 1) * (1 - leaving))
            .offset(y: reducedMotion ? 0 : stage.px(24 * (1 - p)))
    }

    private func hint(_ letter: String, _ label: String) -> some View {
        HStack(spacing: stage.px(14)) {
            ButtonGlyph(letter: letter, size: M.hintGlyph)
            Text(label)
                .font(DelosFonts.figtree(stage.tpx(M.hintSize), .medium))
                .foregroundStyle(colors.text2.color)
                .shadow(color: .black.opacity(0.55), radius: stage.px(8), y: stage.px(2))
                .lineLimit(1)
        }
    }
}

/// The caption under the tiles: the complete help of the focused tile, centered, in a box as tall as three lines. A new text
/// slides up 18 px out of a 6 px blur; it rises 20 px from 520 ms; while a popover is open it is gone.
private struct DockCaption: View {
    let text: String
    let popOpen: Bool
    let t: Double
    let exitT: Double
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion

    private typealias D = StreamDockLayout
    private typealias M = StreamMenuLayout

    var body: some View {
        let p = Motion.progress(t, delay: 520, duration: D.enter, Motion.easeOut)
        let leaving = Motion.progress(exitT, delay: 0, duration: D.leave, Motion.ease)
        ZStack {
            Text(text)
                .font(DelosFonts.figtree(stage.tpx(M.captionSize), .medium))
                .lineSpacing(stage.tpx(M.captionSize) * (M.captionLineHeight - 1.2))
                .multilineTextAlignment(.center)
                .foregroundStyle(colors.text.color)
                .shadow(color: .black.opacity(0.65), radius: stage.px(7), y: stage.px(2))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(text)
                .transition(.asymmetric(
                    insertion: reducedMotion ? .opacity : .modifier(active: CaptionShift(settled: 0), identity: CaptionShift(settled: 1)),
                    removal: .identity))
        }
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.42), value: text)
        .opacity(min(max(p, 0), 1) * (1 - leaving) * (popOpen ? 0 : 1))
        .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000), value: popOpen)
        .offset(y: reducedMotion ? 0 : stage.px(20 * (1 - p)))
    }
}

/// A new caption slides up 18 px out of a 6 px blur.
private struct CaptionShift: ViewModifier {
    let settled: Double
    @Environment(\.stage) private var stage

    func body(content: Content) -> some View {
        content
            .opacity(settled)
            .offset(y: stage.px(18 * (1 - settled)))
            .blur(radius: stage.px(6 * (1 - settled)))
    }
}

/// One tile with its label: 150 px of glass, the icon, and for a toggle the On / Off pill. The focus lifts it to 1.12 with
/// the spring, lights its glass, fills its icon and turns the label gold and 8 px lower; a toggle that is on has accent
/// glass and an accent icon. While a popover is open the tiles but the one that opened it dim.
private struct DockTile: View {
    struct Spec {
        let icon: String
        let label: String
        /// A toggle's state; nil: not a toggle.
        var on: Bool?
        /// Whether a toggle shows its On / Off pill (the keyboard only turns accent).
        var showState = true
    }

    let spec: Spec
    let focused: Bool
    let index: Int
    let count: Int
    let t: Double
    let exitT: Double
    /// A popover is open and this is not its tile.
    let dimmed: Bool
    /// A low compact stage's sunk dock has no room for the labels: they fade out while a popover is open.
    let labelsHidden: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    @Environment(\.pressed) private var pressed

    private typealias D = StreamDockLayout
    private typealias M = StreamMenuLayout

    var body: some View {
        let on = spec.on == true
        let p = Motion.progress(t, delay: D.tileDelay(index), duration: D.enter, Motion.easeSpring)
        let q = Motion.progress(exitT, delay: D.exitDelay(index, count: count), duration: D.leave, Motion.easeIn)
        let label = Motion.progress(t, delay: D.labelDelay(index), duration: D.labelDuration, Motion.ease)
        let entrance = reducedMotion ? 1 : Motion.lerp(Motion.lerp(0.8, 1, p), 0.92, q)
        let rise = reducedMotion ? 0 : 90 * (1 - p) + 46 * q
        let alpha = min(max(p, 0), 1) * (1 - q) * (dimmed ? M.tileDimmed : 1)
        let shape = RoundedRectangle(cornerRadius: stage.px(D.tileRadius), style: .continuous)
        ZStack {
            tile(shape: shape, on: on)
                .frame(width: stage.px(D.tile), height: stage.px(D.tile))
                .overlay {
                    ZStack(alignment: .topTrailing) {
                        SymbolView(symbol: spec.icon, size: D.icon, color: on ? colors.accent : colors.text, filled: focused)
                            .scaleEffect(focused ? D.iconFocusScale : 1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let on = spec.on, spec.showState {
                            pill(on: on)
                                .offset(x: -stage.px(D.pillRight), y: stage.px(D.pillTop))
                                .fixedSize()
                        }
                    }
                }
                .scaleEffect(focusScale(focused: focused, pressed: pressed, focus: D.focusScale))
                .animation(.focusScale(pressed: pressed, reduced: reducedMotion), value: TilePress(focused: focused, pressed: pressed))
                .animation(Motion.spring(Motion.focus), value: focused)
                .scaleEffect(entrance)
                .offset(y: stage.px(rise))
                .opacity(alpha)
                .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000), value: dimmed)
            Text(spec.label)
                .font(DelosFonts.figtree(stage.tpx(D.labelSize), .semibold))
                .foregroundStyle((focused ? colors.accent : colors.text2).color)
                .shadow(color: .black.opacity(0.6), radius: stage.px(6), y: stage.px(2))
                .lineLimit(1)
                .fixedSize()
                .offset(y: stage.px(D.tile / 2 + D.labelGap + 18 + (focused ? D.labelFocusShift : 0)))
                .animation(reducedMotion ? nil : Motion.spring(Motion.focus), value: focused)
                .animation(.easeOut(duration: Motion.fade / 1000), value: focused)
                .opacity(label * (1 - Motion.progress(exitT, delay: 0, duration: D.leave, Motion.ease)) * (labelsHidden ? 0 : dimmed ? M.labelDimmed : 1))
                .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000), value: dimmed)
        }
        .frame(width: stage.px(D.tile), height: stage.px(D.tile))
    }

    private func tile(shape: RoundedRectangle, on: Bool) -> some View {
        ZStack {
            shape.fill(RGBA(red: 5 / 255, green: 7 / 255, blue: 15 / 255).opacity(0.28).color)
            GlassShape(shape, tint: colors.surface2)
            // `--tile-fill-focus`, and the accent glass of a tile that is on
            shape.fill(LinearGradient(
                stops: [.init(color: .white.opacity(0.40), location: 0), .init(color: .white.opacity(0.16), location: 0.6),
                        .init(color: .white.opacity(0.22), location: 1)],
                startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1)))
                .opacity(focused ? 1 : 0)
            shape.fill(LinearGradient(
                stops: [.init(color: colors.accent.opacity(0.30).color, location: 0), .init(color: colors.accent.opacity(0.10).color, location: 0.6),
                        .init(color: .white.opacity(0.12), location: 1)],
                startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1)))
                .opacity(on ? 1 : 0)
        }
        .animation(.easeOut(duration: Motion.fade / 1000), value: focused)
        .animation(.easeOut(duration: Motion.fade / 1000), value: on)
        // 0 18 40 −14 black at rest; focused 0 26 56 −14 and the accent glow
        .shadow(color: .black.opacity(focused ? 0.6 : 0.55), radius: stage.px(focused ? 28 : 20), y: stage.px(focused ? 26 : 18))
        .shadow(color: focused ? colors.accent.opacity(0.22).color : .clear, radius: stage.px(30))
        .animation(Motion.out(Motion.focus), value: focused)
    }

    private func pill(on: Bool) -> some View {
        Text(on ? L("common_on") : L("common_off"))
            .font(DelosFonts.figtree(stage.tpx(D.pillSize), .bold))
            .tracking(stage.tpx(D.pillSize) * 0.02)
            .foregroundStyle((on ? colors.onAccent : colors.text2).color)
            .lineLimit(1)
            .padding(.horizontal, stage.px(D.pillPaddingX))
            .frame(height: stage.px(D.pillHeight))
            .background {
                Capsule()
                    .fill(on ? colors.accent.color : RGBA(red: 22 / 255, green: 28 / 255, blue: 48 / 255, alpha: 0.78).color)
                    .shadow(color: on ? colors.glow.color : .black.opacity(0.55), radius: stage.px(10), y: stage.px(8))
            }
            // A new text pops in from 0.6
            .id(on)
            .transition(reducedMotion ? .identity : .scale(scale: Motion.popFromPill))
            .animation(reducedMotion ? nil : Motion.spring(Motion.pillPop), value: on)
    }
}

private struct TilePress: Equatable {
    let focused: Bool
    let pressed: Bool
}


/// The dock's one ring: a gold 186 box that glides to the focused tile (560 ms, overshooting) and breathes (2.6 s),
/// behind the tiles. It arrives after the first tile, from a 0.7 scale; reduced motion: it jumps and does not breathe.
private struct DockRing: View {
    let index: Int
    let t: Double
    let exitT: Double
    let count: Int
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion

    private typealias D = StreamDockLayout
    private static let breathing = CubicBezier(0.42, 0, 0.58, 1)

    var body: some View {
        let p = Motion.progress(t, delay: D.ringDelay(0), duration: D.enter, Motion.easeSpring)
        let leaving = Motion.progress(exitT, delay: 0, duration: D.leave, Motion.ease)
        TimelineView(.animation(paused: reducedMotion)) { timeline in
            let phase = (timeline.date.timeIntervalSinceReferenceDate * 1000).truncatingRemainder(dividingBy: D.breathe) / D.breathe
            let b = reducedMotion ? 0 : Self.breathing(phase < 0.5 ? phase * 2 : 2 - phase * 2)
            ring(breath: b)
        }
        .scaleEffect(reducedMotion ? 1 : Motion.lerp(0.7, 1, p))
        .opacity(min(max(p, 0), 1) * (1 - leaving))
        .frame(width: stage.px(D.ring), height: stage.px(D.ring))
        .offset(x: stage.px(D.ringLeft(index)), y: stage.px((D.tile - D.ring) / 2))
        .animation(reducedMotion ? nil : .timingCurve(0.3, 1.22, 0.42, 1, duration: D.ringGlide / 1000), value: index)
        .allowsHitTesting(false)
    }

    private func ring(breath b: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(D.ringRadius), style: .continuous)
        return shape.strokeBorder(colors.accent.color, lineWidth: stage.px(D.ringWidth))
            .overlay {
                // inset 0 0 30px −4px, breathing to 36px −2px
                shape.inset(by: stage.px(D.ringWidth)).stroke(colors.accent.opacity(0.22).color, lineWidth: stage.px(Motion.lerp(14, 18, b)))
                    .blur(radius: stage.px(Motion.lerp(12, 15, b)))
                    .clipShape(shape.inset(by: stage.px(D.ringWidth)))
            }
            // 0 0 44px 4px glow, breathing to 62px 8px
            .background {
                shape.fill(colors.glow.opacity(Motion.lerp(1.0, 1.0, b)).color)
                    .blur(radius: stage.px(Motion.lerp(22, 31, b)))
                    .opacity(Motion.lerp(0.55, 0.7, b))
            }
    }
}
