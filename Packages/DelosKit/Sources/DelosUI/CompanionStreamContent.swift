import DelosInput
import DelosMedia
import SwiftUI

/*
 * The stream's companion (`CompanionStreamContent.kt` and `CompanionTypingContent.kt` of DELOS for Android, docs/DUAL_SCREEN.md
 * §10 "Stream" and "Statistics"): the statistics and the stream menu as touch tiles, or the keyboard. Every tile runs the
 * handler of its twin on the dock (``StreamDock``), every sheet the rows and pills of ``StreamController/menuContent(_:)``.
 * Nothing scrolls: the tiles page and every sheet are one ``PageCard``, and long lists page (``CompanionPagedGrid``).
 *
 * Android reads the menu's getters again once a second; ``StreamController`` is observable, so the readout and the tiles
 * follow its state as it changes and nothing polls here.
 */

// MARK: - Pure parts

/// The four values of the statistics bar and the picture line of the heading (`StatsReadout`, CompanionLogic.kt:174-193).
/// Technical units, never translated.
struct CompanionStatsReadout: Equatable, Sendable {
    let fps: String
    let network: String
    let decode: String
    /// The bandwidth the stream takes now. Android shows the bitrate asked for here; the dock of this app has no Bitrate
    /// tile, so the bar shows what the statistics measure instead.
    let bandwidth: String
    /// "1920 × 1080 · 60 FPS · HEVC HDR"; nil before the first reading.
    let picture: String?

    static let dash = "\u{2013}"
    static let empty = CompanionStatsReadout(fps: dash, network: dash, decode: dash, bandwidth: dash, picture: nil)

    static func of(_ stats: StreamStatistics?) -> CompanionStatsReadout {
        guard let stats else { return empty }
        let fps = stats.renderingFPS ?? stats.incomingFPS
        let megabits = stats.bandwidthKiBPerSecond * 1024 * 8 / 1_000_000
        return CompanionStatsReadout(
            fps: number(fps, places: 1),
            network: stats.networkMilliseconds.map { "\(number($0, places: 0)) ms" } ?? dash,
            decode: stats.decodeMilliseconds.map { "\(number($0, places: 1)) ms" } ?? dash,
            bandwidth: "\(number(megabits, places: megabits >= 100 ? 0 : 1)) Mb/s",
            picture: "\(stats.width) \u{00D7} \(stats.height) \u{00B7} \(number(fps, places: 0)) FPS \u{00B7} \(stats.codec)\(stats.hdr ? " HDR" : "")")
    }

    private static func number(_ value: Double, places: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, value)
    }
}

/// How the tiles are laid out (`Tiles`, CompanionStreamContent.kt:142-174): three to a row in the dock's order, the last row
/// (More, Disconnect, Quit) set apart from the tiles used all the time. Every row has three cells, so the tiles keep one width.
enum CompanionTileLayout {
    static let columns = 3
    /// The gap between tiles, in stage pixels.
    static let gap = 10.0
    /// The least height of the grid: three rows of 64 px targets and their gaps (`TILES_MIN`, CompanionStreamContent.kt:118).
    static let minHeight = 3 * CompanionFit.minTarget + 2 * gap
    /// A tile shorter than this lays its icon beside its name, flat: the room of a 3:2 or 4:3 panel (`COMPACT_TILE`).
    static let flatBelow = 140.0
    /// A flat tile this tall or taller also has room for its state under the name (`COMPACT_TILE_STATE`).
    static let flatStateFrom = 84.0

    private static let lastRow: [BarItem] = [.more, .disconnect, .quit]

    static func rows(_ tiles: [BarItem]) -> [[BarItem]] {
        let main = tiles.filter { !lastRow.contains($0) }
        let last = tiles.filter { lastRow.contains($0) }
        let chunks = stride(from: 0, to: main.count, by: columns).map { Array(main[$0..<min($0 + columns, main.count)]) }
        return chunks + (last.isEmpty ? [] : [last])
    }

    static func flat(height: Double) -> Bool { height < flatBelow }
    static func showsState(height: Double) -> Bool { !flat(height: height) || height >= flatStateFrom }
}

/// What a key of the companion keyboard does (`Cell`, CompanionTypingContent.kt:40-48).
enum CompanionKeyCell: Equatable, Sendable {
    /// A character as typed on the letters page (Shift makes a letter capital); on the symbols page the character itself.
    case char(Character, weight: Double = 1)
    case action(CompanionKeyAction, weight: Double)
    case gap(Double)

    var weight: Double {
        switch self {
        case .char(_, let weight), .action(_, let weight): weight
        case .gap(let weight): weight
        }
    }
}

enum CompanionKeyAction: Equatable, Sendable { case backspace, enter, space, left, right, shift, symbols }

/// The rows of the keyboard for a panel (`KeyRows`, CompanionTypingContent.kt:55-98): the five US QWERTY rows of ten keys
/// when the panel is wide enough for every key to be at least 64 px wide, else rows of eight, so a key never shrinks below
/// a thumb.
enum CompanionKeyRows {
    /// The gap between keys, in stage pixels.
    static let gap = 8.0
    /// The widest QWERTY row in key units (ten keys and the wide Backspace) and its gaps.
    private static let qwertyUnits = 11.6
    private static let qwertyGaps = 10.0
    private static let narrowColumns = 8

    /// The columns a keyboard [width] stage pixels wide has: 10 (the QWERTY rows) or 8.
    static func columns(width: Double) -> Int { (width - qwertyGaps * gap) / qwertyUnits >= CompanionFit.minTarget ? 10 : 8 }

    static func rows(symbols: Bool, columns: Int) -> [[CompanionKeyCell]] {
        columns >= 10 ? (symbols ? symbolRows : letterRows) : narrow(symbols: symbols)
    }

    private static func chars(_ text: String) -> [CompanionKeyCell] { text.map { .char($0) } }

    private static let bottomRow: [CompanionKeyCell] = [
        .action(.symbols, weight: 1.5), .char(","), .action(.space, weight: 5.5), .char("."), .action(.left, weight: 1), .action(.right, weight: 1),
    ]

    private static let letterRows: [[CompanionKeyCell]] = [
        chars("1234567890") + [.action(.backspace, weight: 1.6)],
        chars("qwertyuiop"),
        chars("asdfghjkl") + [.action(.enter, weight: 1.6)],
        [.action(.shift, weight: 1.5)] + chars("zxcvbnm"),
        bottomRow,
    ]

    private static let symbolRows: [[CompanionKeyCell]] = [
        chars("!@#$%^&*()") + [.action(.backspace, weight: 1.6)],
        chars("[]{}<>+=_~"),
        chars(";:'\"/\\|?-") + [.action(.enter, weight: 1.6)],
        [.gap(1.5)] + chars("`,.") + [.gap(5.5)],
        bottomRow,
    ]

    private static func narrow(symbols: Bool) -> [[CompanionKeyCell]] {
        let all = chars(symbols ? "!@#$%^&*()[]{}<>+=_~;:'\"/\\|?-`,." : "1234567890qwertyuiopasdfghjklzxcvbnm,.")
        return stride(from: 0, to: all.count, by: narrowColumns).map { Array(all[$0..<min($0 + narrowColumns, all.count)]) } + [
            [.action(.shift, weight: 1.5), .action(.symbols, weight: 1.5), .action(.space, weight: 3), .action(.backspace, weight: 2)],
            [.action(.enter, weight: 4), .action(.left, weight: 2), .action(.right, weight: 2)],
        ]
    }
}

/// What the echo box says (`EchoView`/`EchoFit`, CompanionTypingContent.kt:101-112): the hint (or its short form, or
/// nothing) while empty, set in the quiet color; what was typed when it fits one line; else how many characters were typed.
struct CompanionEcho: Equatable, Sendable {
    let text: String
    let placeholder: Bool

    static func view(
        _ value: String, hint: String, hintShort: String, width: Double, metrics: some CompanionTextMetrics, count: (Int) -> String
    ) -> CompanionEcho {
        if value.isEmpty {
            return CompanionEcho(text: [hint, hintShort].first { metrics.lines($0, width: width) <= 1 } ?? "", placeholder: true)
        }
        if metrics.lines(value, width: width) <= 1 { return CompanionEcho(text: value, placeholder: false) }
        return CompanionEcho(text: count(value.count), placeholder: false)
    }
}

// MARK: - The stream's companion

/// The stream's companion (`StreamContent`, CompanionStreamContent.kt:70-114): the heading with the game and the picture,
/// the statistics bar and the tiles; or, after Resume, "Back to the main screen" with a button that brings the tiles back;
/// or the keyboard. A sheet opens over the tiles for the tiles and rows that have a page.
struct CompanionStreamContent: View {
    let stream: CompanionStream
    @State private var typing = false
    @State private var menuShown = true
    @State private var sheet: MenuPage?
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        if typing {
            CompanionTyping(controller: stream.controller) {
                typing = false
                menuShown = true
            }
        } else {
            ZStack {
                PageCard { fit in
                    let readout = CompanionStatsReadout.of(stream.controller.statistics)
                    let title = CompanionFit.title(
                        stream.gameName, alias: L("companion_streaming"), width: fit.budget.innerWidth - PageHeading.chrome, metrics: fit.metrics)
                    PageHeading(icon: Symbols.playArrow, title: title, subtitle: readout.picture ?? stream.pcName)
                    if menuShown {
                        CompanionStatsBar(readout: readout)
                        CompanionTiles(controller: stream.controller, onKeyboard: { typing = true }, onResume: { menuShown = false }, onSheet: { sheet = $0 })
                            .fills(minHeight: stage.px(CompanionTileLayout.minHeight))
                    } else {
                        BodyText(L("companion_back_to_main"), weight: .semibold)
                        BodyText(L("companion_back_hint"), color: colors.text2, maxLines: 2).optional(60)
                        Filler()
                        CompanionButton(label: L("companion_open_menu"), style: .secondary, textSize: CompanionFit.minText) { menuShown = true }
                            .frame(height: stage.px(CompanionFit.minTarget))
                    }
                }
                if let sheet {
                    CompanionStreamSheet(controller: stream.controller, page: sheet, navigate: { self.sheet = $0 })
                }
            }
        }
    }
}

/// FPS, network delay, decode time and the bandwidth: four values the player glances at (`StatsBar`,
/// CompanionStreamContent.kt:121-139).
private struct CompanionStatsBar: View {
    let readout: CompanionStatsReadout
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        let cells = [
            (readout.fps, "FPS"),
            (readout.network, L("stream_stats_network")),
            (readout.decode, L("stream_stats_decoding")),
            (readout.bandwidth, L("stream_stats_bandwidth")),
        ]
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                VStack(spacing: 0) {
                    Text(verbatim: cell.0)
                        .font(DelosFonts.figtree(stage.tpx(34), .semibold).monospacedDigit())
                        .foregroundStyle(colors.accent2.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    BodyText(cell.1, maxLines: 1, alignment: .center)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The dock's tiles as touch tiles (`Tiles`, CompanionStreamContent.kt:142-174): the same tiles (``StreamMenuCapabilities/tiles``)
/// in the same order, each running its dock twin's handler (`StreamDock.activate`). Two differ on purpose, as on Android:
/// Resume also tucks the touch menu away, and Keyboard opens the companion's own keyboard instead of the system one.
private struct CompanionTiles: View {
    let controller: StreamController
    let onKeyboard: @MainActor () -> Void
    let onResume: @MainActor () -> Void
    let onSheet: @MainActor (MenuPage) -> Void
    @Environment(\.stage) private var stage

    var body: some View {
        let rows = CompanionTileLayout.rows(controller.capabilities.tiles)
        VStack(spacing: stage.px(CompanionTileLayout.gap)) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: stage.px(CompanionTileLayout.gap)) {
                    ForEach(row, id: \.self) { item in
                        CompanionTile(spec: spec(item)) { activate(item) }
                    }
                    ForEach(0..<(CompanionTileLayout.columns - row.count), id: \.self) { _ in Color.clear }
                }
            }
        }
    }

    private func activate(_ item: BarItem) {
        switch item {
        case .resume:
            controller.closeMenu()
            onResume()
        case .keyboard: onKeyboard()
        case .overlay: controller.cycleStatistics()
        case .brightness: onSheet(.brightness)
        case .more: onSheet(.more)
        case .disconnect: Task { await controller.leave(quit: false, scene: true) }
        case .quit: Task { await controller.leave(quit: true, scene: true) }
        }
    }

    private func spec(_ item: BarItem) -> CompanionTile.Spec {
        switch item {
        case .resume: CompanionTile.Spec(icon: Symbols.resume, label: L("stream_menu_tile_resume"), style: .primary)
        case .keyboard: CompanionTile.Spec(icon: Symbols.keyboard, label: L("stream_menu_tile_keyboard"))
        case .overlay:
            CompanionTile.Spec(
                icon: Symbols.overlay, label: L("stream_menu_tile_overlay"), pill: StreamMenuText.overlayState(controller.statisticsOverlay),
                on: controller.statisticsOverlay.isShown)
        case .brightness: CompanionTile.Spec(icon: Symbols.brightnessMedium, label: L("stream_menu_tile_brightness"))
        case .more: CompanionTile.Spec(icon: Symbols.moreHoriz, label: L("stream_menu_tile_more"))
        case .disconnect: CompanionTile.Spec(icon: Symbols.logout, label: L("stream_menu_tile_disconnect"), style: .danger)
        case .quit: CompanionTile.Spec(icon: Symbols.powerSettingsNew, label: L("stream_menu_tile_quit"), style: .danger)
        }
    }
}

/// One tile (`Tile`, CompanionStreamContent.kt:184-245): the icon at the top and the name at the bottom with the state pill
/// at the top right; on a short tile flat, the icon beside the name and the state under it when there is room.
private struct CompanionTile: View {
    struct Spec {
        let icon: String
        let label: String
        var style = CompanionButtonStyle.normal
        var pill: String?
        var on = false
    }

    let spec: Spec
    let action: @MainActor () -> Void
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        Button(action: action) {
            GeometryReader { proxy in
                let height = proxy.size.height / stage.scale
                let (fill, content, line) = look
                let iconColor = spec.style == .normal ? colors.accent2 : content
                let shape = RoundedRectangle(cornerRadius: stage.px(24), style: .continuous)
                ZStack {
                    shape.fill(fill.color)
                    shape.strokeBorder((spec.on ? colors.accent : line).color, lineWidth: stage.px(spec.on ? 3 : 1))
                    if CompanionTileLayout.flat(height: height) {
                        HStack(spacing: stage.px(10)) {
                            SymbolView(symbol: spec.icon, size: 34, color: iconColor)
                            VStack(alignment: .leading, spacing: 0) {
                                label(spec.label, size: CompanionFit.minText, color: content)
                                if let pill = spec.pill, CompanionTileLayout.showsState(height: height) {
                                    label(pill, size: CompanionFit.minText, color: spec.on ? colors.accent : colors.text2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, stage.px(14))
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top) {
                                SymbolView(symbol: spec.icon, size: 48, color: iconColor)
                                Spacer(minLength: 0)
                                if let pill = spec.pill {
                                    Text(verbatim: pill)
                                        .font(DelosFonts.figtree(stage.tpx(CompanionFit.minText), .semibold))
                                        .foregroundStyle((spec.on ? colors.onAccent : colors.text2).color)
                                        .lineLimit(1)
                                        .padding(.horizontal, stage.px(16))
                                        .padding(.vertical, stage.px(4))
                                        .background(Capsule().fill((spec.on ? colors.accent : colors.surface3).color))
                                }
                            }
                            Spacer(minLength: 0)
                            label(spec.label, size: 32, color: content)
                        }
                        .padding(.leading, stage.px(22))
                        .padding(.trailing, stage.px(18))
                        .padding(.vertical, stage.px(16))
                    }
                }
                .contentShape(shape)
            }
        }
        .buttonStyle(CompanionTilePress())
    }

    private func label(_ text: String, size: Double, color: RGBA) -> some View {
        Text(verbatim: text)
            .font(DelosFonts.figtree(stage.tpx(size), .semibold))
            .foregroundStyle(color.color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var look: (RGBA, RGBA, RGBA) {
        switch spec.style {
        case .primary: (colors.accent, colors.onAccent, colors.accent)
        case .danger: (ImpactRed.value.opacity(0.13), ImpactRed.value, ImpactRed.value.opacity(0.5))
        case .secondary, .normal: (colors.surface2, colors.text, colors.line)
        }
    }
}

/// The press of a tile: it sinks 2 stage pixels.
private struct CompanionTilePress: ButtonStyle {
    @Environment(\.stage) private var stage

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.offset(y: configuration.isPressed ? stage.px(2) : 0)
    }
}

// MARK: - Sheets

/// A page over the tiles (`SheetFrame` and `SheetHost`, CompanionStreamContent.kt:250-281): the same card as every page on the
/// page color, its title and Close in one row; a tap beside the card closes it too. Send keys and Commands go back to More,
/// as the popover's pages do. Android's Bitrate, Upscaler and Mouse sheets are not here: the dock of this app has no
/// Bitrate or Upscaler tile and its More page no mouse mode row.
private struct CompanionStreamSheet: View {
    let controller: StreamController
    let page: MenuPage
    let navigate: @MainActor (MenuPage?) -> Void
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        let close: @MainActor () -> Void = { navigate(page.parent == .more ? .more : nil) }
        ZStack {
            colors.bg.color
                .contentShape(Rectangle())
                .onTapGesture { close() }
            PageCard { _ in
                HStack(spacing: stage.px(12)) {
                    PageHeading(icon: icon, title: title)
                    CompanionButton(label: L("companion_close"), icon: Symbols.close, textSize: CompanionFit.minText, action: close)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(height: stage.px(CompanionFit.minTarget))
                }
                content
            }
        }
    }

    private var title: String {
        switch page {
        case .brightness: L("stream_menu_title_brightness")
        case .keys: L("stream_menu_title_keys")
        case .commands: L("stream_menu_title_commands")
        case .more, .main: L("stream_menu_title_more")
        }
    }

    private var icon: String {
        switch page {
        case .brightness: Symbols.brightnessMedium
        case .keys: Symbols.keyboardCommandKey
        case .commands: Symbols.terminal
        case .more, .main: Symbols.moreHoriz
        }
    }

    /// The page's rows and pills (``StreamController/menuContent(_:)``): the actions and toggles as a paged grid of buttons,
    /// the sliders as touch sliders with − and +, the pills as a paged grid. A row that opens a page opens its sheet; a
    /// one-shot action and a server command close the sheet once they ran (`MorePage`, `SheetHost`).
    @ViewBuilder private var content: some View {
        switch controller.menuContent(page) {
        case .rows(let rows):
            let buttons = rows.filter { if case .slider = $0.value { false } else { true } }
            if !buttons.isEmpty {
                CompanionPagedGrid(entries: buttons.map(entry), maxColumns: 2)
                    .fills(minHeight: stage.px(CompanionGridPaging.minHeight))
            }
            ForEach(rows.filter { if case .slider = $0.value { true } else { false } }) { row in
                CompanionSliderRow(row: row)
            }
            if buttons.isEmpty { Filler() }
        case .pills(let pills, let empty):
            if pills.isEmpty {
                BodyText(empty ?? "", color: colors.text2, maxLines: 4)
                Filler()
            } else {
                CompanionPagedGrid(entries: pills.map { pill in
                    CompanionGridEntry(label: pill.label) {
                        pill.run()
                        if page == .commands { navigate(nil) }
                    }
                })
                .fills(minHeight: stage.px(CompanionGridPaging.minHeight))
            }
        }
    }

    private func entry(_ row: StreamMenuRow) -> CompanionGridEntry {
        switch row.value {
        case .toggle(let on):
            return CompanionGridEntry(label: row.label, icon: row.icon, selected: on, enabled: row.enabled, run: row.activate)
        case .action, .slider:
            return CompanionGridEntry(label: row.label, icon: row.icon, enabled: row.enabled) {
                switch MenuRowID(rawValue: row.id) {
                case .keys: navigate(.keys)
                case .commands: navigate(.commands)
                default:
                    row.activate()
                    navigate(nil)
                }
            }
        }
    }
}

/// A slider row of a sheet (`BrightnessPage`, CompanionStreamContent.kt:298-312): its name and value on one line, the slider
/// between − and + under it. Each change goes through the row's own setter at once.
private struct CompanionSliderRow: View {
    let row: StreamMenuRow
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        if case let .slider(value, range, step, unit) = row.value {
            let set: @MainActor (Int) -> Void = { next in if next != value { row.set?(next) } }
            VStack(spacing: stage.px(8)) {
                HStack {
                    Text(verbatim: row.label)
                        .font(DelosFonts.figtree(stage.tpx(34)))
                        .foregroundStyle(colors.text.color)
                    Spacer(minLength: stage.px(12))
                    Text(verbatim: "\(value)\(unit)")
                        .font(DelosFonts.figtree(stage.tpx(34), .semibold).monospacedDigit())
                        .foregroundStyle(colors.accent2.color)
                }
                .lineLimit(1)
                CompanionStepper(
                    onMinus: { if let next = row.stepped(-1) { set(next) } }, onPlus: { if let next = row.stepped(1) { set(next) } }
                ) {
                    TouchSlider(value: value, range: range, step: step, enabled: row.enabled, onChange: set, onCommit: set)
                }
                .disabled(!row.enabled)
            }
        }
    }
}

// MARK: - Typing

/// The companion's keyboard (`TypingContent`, CompanionTypingContent.kt:114-170): a one-line echo of what was typed with
/// Clear and Stream menu beside it, and the US rows under it sharing the height. The keys go into the stream through the
/// on-screen keyboard's own text path (``StreamController/typed(_:)``: Return as "\n", which the input sends as Enter;
/// ``StreamController/typedBackspace()``); the arrows go as key combinations (``StreamController/send(_:)``). Android sends
/// key codes down and up; this app's keyboard path sends text, so a character goes when the finger lands. Shift holds for one
/// character. There is no text field: the PC has the text.
private struct CompanionTyping: View {
    let controller: StreamController
    let onMenu: @MainActor () -> Void
    @State private var echo = TypedEcho()
    @State private var shifted = false
    @State private var symbols = false
    @Environment(\.stage) private var stage

    /// VK_RIGHT: ``VirtualKey`` names only the keys of the menu's combinations.
    private static let rightArrow: UInt8 = 0x27

    var body: some View {
        let rows = CompanionKeyRows.rows(symbols: symbols, columns: CompanionKeyRows.columns(width: stage.width - 2 * CompanionFit.margin))
        VStack(spacing: stage.px(10)) {
            HStack(spacing: stage.px(10)) {
                CompanionEchoBox(value: echo.value)
                CompanionButton(label: L("companion_typing_clear"), textSize: CompanionFit.minText) { echo = echo.cleared() }
                    .fixedSize(horizontal: true, vertical: false)
                CompanionButton(label: L("companion_typing_menu"), style: .secondary, icon: Symbols.moreHoriz, textSize: CompanionFit.minText, action: onMenu)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: stage.px(CompanionFit.minTarget))
            VStack(spacing: stage.px(CompanionKeyRows.gap)) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    CompanionKeyRow(cells: row) { cell in key(cell) }
                }
            }
        }
        .padding(.horizontal, stage.px(CompanionFit.margin))
        .padding(.top, stage.px(20))
        .padding(.bottom, stage.px(CompanionFit.margin + CompanionFit.footer))
    }

    @ViewBuilder private func key(_ cell: CompanionKeyCell) -> some View {
        switch cell {
        case .gap: Color.clear
        case .char(let c, _):
            let shown = shifted && !symbols && c.isLetter ? Character(c.uppercased()) : c
            PressKey(onDown: {
                controller.typed(String(shown))
                echo = echo.typed(shown)
                shifted = false
            }, onUp: {}) { _ in
                CompanionKeyLabel(text: String(shown), size: 36)
            }
        case .action(let action, _):
            PressKey(
                selected: (action == .shift && shifted) || (action == .symbols && symbols), accent: action == .enter,
                onDown: { press(action) }, onUp: {}
            ) { _ in actionLabel(action) }
        }
    }

    private func press(_ action: CompanionKeyAction) {
        switch action {
        case .shift: shifted.toggle()
        case .symbols: symbols.toggle()
        case .backspace:
            controller.typedBackspace()
            echo = echo.backspace()
        case .enter:
            controller.typed("\n")
            echo = echo.enter()
        case .space:
            controller.typed(" ")
            echo = echo.typed(" ")
        case .left: controller.send(KeyCombo([VirtualKey.left]))
        case .right: controller.send(KeyCombo([Self.rightArrow]))
        }
    }

    @ViewBuilder private func actionLabel(_ action: CompanionKeyAction) -> some View {
        switch action {
        case .backspace: CompanionKeySymbol(symbol: Symbols.backspace)
        case .left: CompanionKeySymbol(symbol: Symbols.chevronLeft)
        case .right: CompanionKeySymbol(symbol: Symbols.chevronRight)
        case .shift: CompanionKeyLabel(text: "\u{21E7}", size: 36)
        case .enter: CompanionKeyLabel(text: String(TypedEcho.returnMark), size: 36)
        case .symbols: CompanionKeyLabel(text: symbols ? "ABC" : "#+=", size: CompanionFit.minText)
        case .space: CompanionSpaceBar()
        }
    }
}

/// One row of keys, each as wide as its weight says (the gaps kept).
private struct CompanionKeyRow<Key: View>: View {
    let cells: [CompanionKeyCell]
    @ViewBuilder let key: (CompanionKeyCell) -> Key
    @Environment(\.stage) private var stage

    var body: some View {
        GeometryReader { proxy in
            let gap = stage.px(CompanionKeyRows.gap)
            let total = cells.reduce(0) { $0 + $1.weight }
            let unit = (proxy.size.width - gap * CGFloat(max(cells.count - 1, 0))) / CGFloat(max(total, 1))
            HStack(spacing: gap) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    key(cell).frame(width: unit * cell.weight)
                }
            }
        }
    }
}

private struct CompanionKeyLabel: View {
    let text: String
    let size: Double
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        Text(verbatim: text)
            .font(DelosFonts.figtree(stage.tpx(size), .medium))
            .foregroundStyle(colors.text.color)
            .lineLimit(1)
    }
}

private struct CompanionKeySymbol: View {
    let symbol: String
    @Environment(\.delosColors) private var colors

    var body: some View { SymbolView(symbol: symbol, size: 40, color: colors.text) }
}

private struct CompanionSpaceBar: View {
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(colors.text3.color)
                .frame(width: proxy.size.width / 2, height: stage.px(6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The echo (`Echo`, CompanionTypingContent.kt:173-193): what was typed in one line, the count when it does not fit, the
/// hint while empty.
private struct CompanionEchoBox: View {
    let value: String
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(18), style: .continuous)
        GeometryReader { proxy in
            let width = (proxy.size.width - 2 * stage.px(20)) / stage.scale / stage.textScale
            let view = CompanionEcho.view(
                value, hint: L("companion_typing_hint"), hintShort: L("companion_typing_hint_short"), width: width, metrics: CoreTextMetrics()
            ) { LPlural("companion_typing_count", $0) }
            Text(verbatim: view.text)
                .font(DelosFonts.figtree(stage.tpx(CompanionFit.minText)))
                .foregroundStyle((view.placeholder ? colors.text3 : colors.text).color)
                .lineLimit(1)
                .padding(.horizontal, stage.px(20))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .background(shape.fill(colors.surface2.color))
        .overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
    }
}
