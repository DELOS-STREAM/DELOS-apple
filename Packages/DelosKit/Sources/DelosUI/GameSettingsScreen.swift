import DelosData
import DelosHost
import DelosInput
import SwiftUI

/// The settings of one app (the game's menu → App settings; `GameSettingsScreen` of DELOS for Android, docs/PER_APP_SETTINGS.md):
/// the eyebrow and the app's name over the game background, how many settings are custom for it and Reset all; the rows
/// of the stream settings that exist here (resolution, frame rate, bitrate, codec, frame pacing, host audio) with the
/// gliding plate; and the description panel with where the focused value comes from. A row the app overrides carries the
/// CUSTOM badge and the profile's value and resets with X (or its round button on touch). Changes are stored at once and
/// apply to the next stream. Android's Display tab has no counterpart here, so there are no tabs.
struct GameSettingsScreen: View {
    /// What the hint bar's adjust, reset and popover hints depend on.
    private struct HintKey: Equatable {
        let focus: AnyHashable?
        let custom: Int
        let popup: RowPopupKind?
    }

    let hostID: String
    let app: HostApp
    let focus: FocusModel
    let navigator: Navigator
    let actions: ShellActions
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(HostStore.self) private var hosts
    @State private var model: GameSettingsModel
    @State private var popup: RowPopupState?
    @State private var rowFrames: [String: CGRect] = [:]
    /// The row last focused, which Reset all gives the focus back to.
    @State private var lastRow: String?

    static let resetAllID = "game-reset-all"
    static let space = "game-settings"

    static func firstFocus() -> String { StreamSettingsForm.resolution }

    init(hostID: String, app: HostApp, focus: FocusModel, navigator: Navigator, actions: ShellActions, profileID: String) {
        self.hostID = hostID
        self.app = app
        self.focus = focus
        self.navigator = navigator
        self.actions = actions
        _model = State(initialValue: GameSettingsModel(
            hostID: hostID, app: app, profileID: profileID, device: .current, host: { [hosts = actions.hosts] in hosts.host($0) }))
        // The banner blurs the app's art like the app's background
        _heroBlur = State(initialValue: AppearanceStore().load(profile: profileID).heroBlur)
    }

    @State private var tab = GameSettingsTab.stream
    @State private var heroBlur: Int
    private var tabs: [GameSettingsTab] { model.tabs }
    /// The tab shown: the chosen one, as far as it has rows.
    private var current: GameSettingsTab { tabs.contains(tab) ? tab : .stream }
    private var rows: [SettingRow] { model.rows(current) }
    private var focusedRow: SettingRow? { rows.first { focus.focused == AnyHashable($0.id) } }

    var body: some View {
        let left = 150 + stage.safe.leading, right = 150 + stage.safe.trailing
        let bottom = SettingsLayout.bottom(scale: stage.textScale) + stage.safe.bottom
        let rows = rows
        let count = model.overrides.count
        let streamCount = model.customCount(.stream), displayCount = model.customCount(.display)
        ZStack(alignment: .topLeading) {
            GameBanner(hostID: hostID, app: app, blur: heroBlur)
            header(count: count)
                .frame(height: stage.px(GameSettingsLayout.headHeight))
                .padding(.leading, stage.px(left))
                .padding(.trailing, stage.px(right))
                .padding(.top, stage.px(GameSettingsLayout.headTop + stage.safe.top))
            // Centred on the stage, like the global settings' tabs (Display shows only where it has a row)
            if tabs.count > 1 {
                TabRow(
                    tabs: tabs.map { TabSpec(id: $0, icon: $0.icon, label: $0.label, badge: model.customCount($0)) }, selected: current,
                    focus: focus, focusID: { "game-tab-\($0)" }, collapse: stage.compact, left: SettingsLayout.titleX,
                    right: stage.width - SettingsLayout.titleX
                ) { next in
                    select(next, sound: .select, keepFocus: true)
                }
                .frame(height: stage.targetPx(SettingsLayout.tabsHeight))
                .frame(maxWidth: .infinity)
                .tvFocusSection()
                .offset(y: stage.px(SettingsLayout.tabsY + stage.safe.top))
            }
            // The list spans from 132 to 38 short of the panel, which starts where the global settings' panel does
            list(rows)
                .frame(width: stage.px(stage.width - GameSettingsLayout.listWidthLess - stage.safe.leading - stage.safe.trailing))
                .padding(.leading, stage.px(GameSettingsLayout.listX + stage.safe.leading))
                .padding(.top, stage.px(GameSettingsLayout.listTop + stage.safe.top))
                .padding(.bottom, stage.px(bottom))
            GameSettingsPanel(
                app: app.title, row: focusedRow.map { row in
                    (row, model.isCustom(row.id), model.profileLabel(row.id), model.currentLabel(row.id))
                }, streamCount: streamCount, displayCount: displayCount)
                .frame(width: stage.px(520))
                .padding(.trailing, stage.px(right))
                .padding(.top, stage.px(SettingsLayout.listTop + stage.safe.top))
                .padding(.bottom, stage.px(bottom))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            if let popup, let row = rows.first(where: { $0.id == popup.id }) {
                RowPopover(
                    row: row, kind: popup.kind, focus: popup.focus, anchor: rowFrames[row.id] ?? .zero, slider: popup.slider,
                    onPick: { index in pick(row.id, index) },
                    onReset: model.isCustom(row.id) ? { resetFromPopup(row.id) } : nil, onClose: closePopup)
            }
        }
        .coordinateSpace(.named(Self.space))
        .screenModal(popup?.focus)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            navigator.takeInput(focus) { command in capture(command) }
            if focusedRow == nil { focus.focus(Self.firstFocus()) }
        }
        .onDisappear { navigator.releaseInput(focus) }
        .onChange(of: HintKey(focus: focus.focused, custom: model.overrides.count, popup: popup?.kind), initial: true) {
            navigator.setHints(ScreenHints(
                adjustable: ShellHints.adjustable(focusedRow),
                rowOptions: RowOptions.of(focusedRow, custom: focusedRow.map { model.isCustom($0.id) } ?? false).opens,
                rowPopup: popup?.kind), from: focus)
        }
        .onChange(of: focus.focused) { _, now in
            if let id = now as? String, rows.contains(where: { $0.id == id }) { lastRow = id }
        }
    }

    /// Another tab: the focus goes to its first row, unless the tab was chosen on the tab itself (tvOS).
    private func select(_ next: GameSettingsTab, sound: Cue, keepFocus: Bool = false) {
        guard next != current else { return }
        actions.feedback?.play(sound)
        tab = next
        if !keepFocus, let first = model.rows(next).first { focus.focus(AnyHashable(first.id)) }
    }

    // MARK: Header

    private func header(count: Int) -> some View {
        HStack(spacing: stage.px(16)) {
            title
                .frame(maxWidth: .infinity, alignment: .leading)
            CustomChip(count: count)
            if count > 0 {
                FocusItem(id: Self.resetAllID, model: focus, action: { resetAll() }) { focused in
                    ToolbarPill(label: L("settings_game_reset_all"), icon: Symbols.reset, focused: focused)
                }
            } else {
                // Nothing to reset: dimmed and out of the focus
                ToolbarPill(label: L("settings_game_reset_all"), icon: Symbols.reset, focused: false).opacity(0.4)
            }
        }
    }

    /// The eyebrow ("App settings · the PC") over the app's name (`GameTitle`), with the prototype's text shadows, which keep
    /// the text legible on a bright game background.
    private var title: some View {
        let shadow = colors.dark ? Color.black.opacity(0.5) : .clear
        return VStack(alignment: .leading, spacing: stage.px(4)) {
            Text(L("settings_game_eyebrow", hosts.host(hostID)?.name ?? "").uppercased(with: .current))
                .font(DelosFonts.figtree(stage.tpx(16), .bold))
                .tracking(stage.tpx(16) * 0.14)
                .foregroundStyle(colors.accent2.color)
                .lineLimit(1)
                .shadow(color: shadow, radius: stage.px(12), y: stage.px(3))
            MarqueeLabel(text: app.title, active: true)
                .font(DelosFonts.unbounded(stage.tpx(46)))
                .foregroundStyle(colors.text.color)
                .shadow(color: shadow, radius: stage.px(12), y: stage.px(3))
        }
    }

    // MARK: List

    private func list(_ rows: [SettingRow]) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: stage.px(SettingsLayout.rowGap)) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    FocusItem(
                        id: row.id, model: focus,
                        menu: { model.isCustom(row.id) ? resetMenu(row) : nil },
                        action: { activate(row) }, tap: { wasFocused in tapped(row, wasFocused: wasFocused) }
                    ) { focused in
                        SettingRowView(row: row, focused: focused, hostedPlate: true, entrance: min(index, Motion.staggerCap), onSlide: { value in
                            focus.focus(AnyHashable(row.id))
                            model.slide(row.id, to: value)
                        }, onStep: { direction in steppedByTouch(row, direction) }, onReset: { resetRow(row.id) })
                    }
                    .accessibilityStepper(row.adjustable) { direction in steppedByTouch(row, direction) }
                    .id(row.id)
                    .anchorPreference(key: SettingsRowAnchors.self, value: .bounds) { [row.id: $0] }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { rowFrames[row.id] = $0 }
                    .reportsRowFrame(row.id)
                }
            }
            .backgroundPreferenceValue(SettingsRowAnchors.self) { anchors in
                GeometryReader { proxy in
                    let anchor = (focus.focused as? String).flatMap { anchors[$0] }
                    SettingsFocusPlate(target: anchor.map { SettingsPlateGeometry.target(proxy[$0]) })
                        .id(current)
                }
            }
            .padding(.horizontal, stage.px(18))
            .padding(.top, stage.px(GameSettingsLayout.listInnerTop))
            .padding(.bottom, stage.px(140))
            .focusDrivenScroll()
            .coordinateSpace(.named(SettingsListScroll.contentSpace))
            // A tab that is switched starts a new entrance
            .entranceScope()
            .id(current)
        }
        .settingsListScroll(
            focus: focus, contains: { id in rows.contains { $0.id == id } }, resetKey: AnyHashable(current),
            fadeTop: stage.compact ? SettingsLayout.compactFadeTop : 14, fadeBottom: stage.compact ? SettingsLayout.compactFadeBottom : 70,
            compact: stage.compact)
        .frame(maxWidth: .infinity)
    }

    /// The right-menu / long-press menu of a custom row (`ContextMenu` with "Reset to profile value"); a slider's also opens its
    /// popover, which Options opens on a row that is not custom.
    private func resetMenu(_ row: SettingRow) -> ContextMenu {
        let adjust = RowPopupKind.of(row) == .slider && row.enabled
            ? [MenuItem(icon: Symbols.tune, label: L("shell_hint_adjust")) { openPopup(row) }] : []
        return ContextMenu(title: row.label, items: adjust + [
            MenuItem(icon: Symbols.reset, label: L("settings_game_reset_menu")) { resetRow(row.id) },
        ])
    }

    // MARK: Input

    /// The controller's and the keyboard's commands, before the focus gets them.
    private func capture(_ command: MenuCommand) -> Bool {
        if let popup { popup.capture(command, navigator: navigator, feedback: actions.feedback, close: closePopup); return true }
        switch command {
        case .previousTab, .nextTab:
            guard tabs.count > 1 else { return false }
            select(current.step(command == .nextTab ? 1 : -1, among: tabs), sound: .move)
            return true
        case .left, .right:
            guard let row = focusedRow else { return false }
            var direction = command == .right ? 1 : -1
            if case let .slider(_, range, step, _, _) = row.value {
                direction *= StreamSettingsForm.sliderAcceleration(steps: (range.upperBound - range.lowerBound) / step, repeatCount: navigator.commandRepeat)
            }
            if case .toggle = row.value { return true }
            if model.step(row.id, by: direction) { actions.feedback?.play(.move) }
            return true
        case .up:
            // A held Up stops at the first row; only a new press there goes on to Reset all
            return navigator.commandRepeat > 0 && focusedRow?.id == rows.first?.id
        case .options:
            // Options opens the popover a second tap opens (a custom choice's list ends with its reset); a custom slider or
            // a custom row without a popover leaves it to the router, which opens the row's menu
            guard let row = focusedRow else { return false }
            switch RowOptions.of(row, custom: model.isCustom(row.id)) {
            case .popup:
                actions.feedback?.play(.open)
                openPopup(row)
            case .refuse:
                actions.feedback?.play(.error)
            case .menu, .none:
                return false
            }
            return true
        case .down, .accept, .back, .menu, .toastAction, .mute:
            return false
        }
    }

    private func activate(_ row: SettingRow) {
        guard row.enabled else {
            actions.feedback?.play(.error)
            return
        }
        model.step(row.id, by: 1)
    }

    /// A tap on a row (rules in ``RowTouch/of(_:wasFocused:enabled:canPopup:)``): the first tap focuses it and shows its help, a
    /// tap on the focused row flips it, or opens its options / its slider popover.
    private func tapped(_ row: SettingRow, wasFocused: Bool) {
        switch RowTouch.of(row.value, wasFocused: wasFocused, enabled: row.enabled, canPopup: RowPopupKind.of(row) != nil) {
        case .focusOnly:
            actions.feedback?.play(.move)
        case .activate:
            if case .toggle = row.value { actions.feedback?.play(.select) } else { actions.feedback?.play(.open) }
            activate(row)
        case .pick, .adjust:
            actions.feedback?.play(.open)
            popup = RowPopupState.open(row) { value in model.slide(row.id, to: value) }
        case .error:
            actions.feedback?.play(.error)
        case .none:
            break
        }
    }

    /// A touch on a choice's arrow or on a switch: the row is focused for its help and changes at once.
    private func steppedByTouch(_ row: SettingRow, _ direction: Int) {
        focus.focus(AnyHashable(row.id))
        guard row.enabled else {
            actions.feedback?.play(.error)
            return
        }
        if model.step(row.id, by: direction) { actions.feedback?.play(.move) }
    }

    private func pick(_ id: String, _ index: Int) {
        actions.feedback?.play(.select)
        model.pick(id, option: index)
        closePopup()
    }

    private func openPopup(_ row: SettingRow) {
        popup = RowPopupState.open(row) { value in model.slide(row.id, to: value) }
    }

    /// "Reset to profile value", the last item of a custom row's list.
    private func resetFromPopup(_ id: String) {
        actions.feedback?.play(.select)
        closePopup()
        resetRow(id)
    }

    private func closePopup() {
        withAnimation(.easeOut(duration: 0.2)) { popup = nil }
    }

    // MARK: Resets

    /// A reset never asks: it acts, says so, and the toast's Undo writes back what it removed.
    private func resetRow(_ id: String) {
        let backup = model.reset(id)
        actions.toasts.show(
            L("settings_game_reset_row_toast"), icon: Symbols.reset,
            action: ToastAction(label: L("settings_game_undo")) { model.restore(backup) })
    }

    private func resetAll() {
        guard !model.overrides.isEmpty else { return }
        let backup = model.resetAll()
        actions.toasts.show(
            L("settings_game_reset_all_toast"), icon: Symbols.reset,
            action: ToastAction(label: L("settings_game_undo")) { model.restore(backup) })
        // The pill dims now that nothing is custom: the focus goes back to the list, where it was
        focus.focus(AnyHashable(lastRow ?? Self.firstFocus()))
    }
}

/// How many settings are custom for the app (`Chip` on the banner): the accent3 chip, or a check when it follows the profile.
private struct CustomChip: View {
    let count: Int
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        // `Chip`: an info pill in the glass style; only its icon takes the violet of a custom app
        HStack(spacing: stage.px(8)) {
            SymbolView(symbol: count == 0 ? Symbols.checkCircle : Symbols.tune, size: 22, color: count == 0 ? colors.text2 : colors.accent3)
            Text(GameSettingsText.customLabel(count))
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

/// The glass panel on the right (`GameSettingsPanel`): the focused row's icon on an accent disc, its name, where its value
/// comes from (custom for this app with the profile's value, or the profile's), its help and the autosave note. With
/// nothing focused it sums up how many settings the app customises.
private struct GameSettingsPanel: View {
    let app: String
    let row: (row: SettingRow, custom: Bool, profile: String, current: String)?
    let streamCount: Int
    let displayCount: Int
    private var count: Int { streamCount + displayCount }
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        VStack(alignment: .leading, spacing: stage.px(18)) {
            ZStack {
                Circle().fill(colors.accent.color)
                SymbolView(symbol: row?.row.icon ?? Symbols.tune, size: 64, color: colors.onAccent, filled: true)
            }
            .frame(width: stage.px(120), height: stage.px(120))
            Text(row?.row.label ?? L("settings_game_panel_title"))
                .font(DelosFonts.unbounded(stage.tpx(30)))
                .foregroundStyle(colors.text.color)
                .padding(.top, stage.px(8))
            sourceBox
            AutoScrollingHelp(identity: "\(row?.row.id ?? "game"):\(row?.row.help ?? "")") {
                Text(helpText)
                    .font(DelosFonts.figtree(stage.tpx(22)))
                    .lineSpacing(stage.tpx(22 * 0.45))
                    .foregroundStyle(colors.text2.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // What the three chips of the focused row mean
            if row?.row.impact != nil { ImpactLegend() }
            HStack(spacing: stage.px(8)) {
                SymbolView(symbol: Symbols.checkCircle, size: 20, color: colors.text3)
                Text(L("settings_game_saved_note"))
                    .font(DelosFonts.figtree(stage.tpx(17)))
                    .foregroundStyle(colors.text3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, stage.px(10))
        }
        .padding(stage.px(44))
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            // The same gentle frosted glass as the global settings' panel (`SettingsPanelFrame`)
            GlassShape(RoundedRectangle(cornerRadius: stage.px(34)), tint: colors.surface, role: .panel)
                .overlay(RoundedRectangle(cornerRadius: stage.px(34)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
    }

    private var helpText: String {
        let help = row?.row.help ?? ""
        return help.isEmpty ? L("settings_game_only_this_game", app) : help
    }

    /// The panel's source box (`.src`): a quiet frame, violet while the value is custom.
    private var sourceBox: some View {
        let custom = row?.custom ?? (count > 0)
        let tint = colors.accent3
        let icon = row == nil ? (count > 0 ? Symbols.tune : Symbols.checkCircle) : custom ? Symbols.tune : Symbols.accountCircle
        let title = row == nil ? GameSettingsText.customLabel(count)
            : custom ? L("settings_game_custom_title") : L("settings_game_from_profile")
        let body = row.map { source in
            if source.custom {
                #if os(iOS)
                L("settings_game_profile_value_touch", source.profile)
                #else
                L("settings_game_profile_value_button", source.profile, ControllerGlyphs.shared.mark(.west).text ?? "X")
                #endif
            } else {
                L("settings_game_currently", source.current)
            }
        } ?? GameSettingsText.summary(stream: streamCount, display: displayCount)
        let shape = RoundedRectangle(cornerRadius: stage.px(20))
        return VStack(alignment: .leading, spacing: stage.px(8)) {
            HStack(spacing: stage.px(10)) {
                SymbolView(symbol: icon, size: 24, color: custom ? tint : colors.text2, filled: true)
                Text(title)
                    .font(DelosFonts.figtree(stage.tpx(20), .bold))
                    .foregroundStyle((custom ? tint : colors.text2).color)
            }
            Text(body)
                .font(DelosFonts.figtree(stage.tpx(20)))
                .foregroundStyle(colors.text2.color)
        }
        .padding(.horizontal, stage.px(20))
        .padding(.vertical, stage.px(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(custom ? tint.opacity(0.22).color : colors.text.opacity(0.06).color))
        .overlay(shape.strokeBorder(custom ? tint.opacity(0.5).color : colors.line.color, lineWidth: stage.px(1)))
    }
}

// MARK: Custom marks of a row

/// The CUSTOM badge of a row the app overrides (`CustomBadge`), in capitals in every language.
struct CustomBadge: View {
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(6)) {
            SymbolView(symbol: Symbols.tune, size: 17, color: colors.onAccent3, filled: true)
            Text(L("row_badge_custom").uppercased(with: .current))
                .font(DelosFonts.figtree(stage.tpx(14), .heavy))
                .tracking(stage.tpx(14) * 0.06)
                .foregroundStyle(colors.onAccent3.color)
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.leading, stage.px(7))
        .padding(.trailing, stage.px(10))
        .frame(height: stage.px(26))
        .background(Capsule().fill(colors.accent3.color))
    }
}

/// The reset of a custom row (`RowResetButton`): a round button on touch, always there; otherwise a pill that shows on the
/// focused row (the controller's X resets it too).
struct RowResetButton: View {
    let focused: Bool
    let onReset: () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        let tint = colors.accent3
        #if os(iOS)
        let visible = true
        #else
        let visible = focused
        #endif
        if visible {
            Button(action: onReset) {
                HStack(spacing: stage.px(10)) {
                    SymbolView(symbol: Symbols.reset, size: touch ? 28 : 24, color: tint)
                    if !touch {
                        Text(L("row_reset"))
                            .font(DelosFonts.figtree(stage.tpx(19), .bold))
                            .foregroundStyle(colors.text.color)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, stage.px(touch ? 0 : 16))
                .frame(minWidth: stage.px(touch ? 52 : 0), minHeight: stage.px(touch ? 52 : 46))
                .background(Capsule().fill(tint.opacity(0.22).color))
                .overlay(Capsule().strokeBorder(tint.opacity(0.5).color, lineWidth: stage.px(1)))
            }
            .pressButton()
            .fixedSize()
            .accessibilityLabel(L("row_reset_to_profile"))
        }
    }

    private var touch: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
}

/// Where the App settings screen puts its banner, title block, list and panel (`GameSettingsLayout` of DELOS for Android), stage
/// pixels. The status bar owns y 0 to 104, so nothing starts above ``headTop``; the tabs sit where the global settings' tabs sit
/// and the first row where its first row sits.
enum GameSettingsLayout {
    static let bannerHeight = 290.0, compactBannerHeight = 220.0
    static let headTop = 106.0, headHeight = 92.0
    /// The list's top edge (its top fade is 14 px) and the padding inside it: the first row starts at 326, like the global list's.
    static let listTop = 296.0, listInnerTop = 30.0, listX = 132.0
    /// The list spans from ``listX`` to the panel's left edge (38 px short of it): the stage width less this, 1080 at 1920.
    static let listWidthLess = 840.0
}

/// The banner (`GameBanner`): the app's artwork blurred like the app's background (the hero, else the cover, else the PC's box
/// art), the top of the hero's area; the placeholder art while there is no image. A scrim keeps the title legible on bright art,
/// and the strip fades into the page towards its bottom.
///
/// The hero's area is the one of a stage no taller than 16:9 (``bannerStageHeight``), so a 4:3 stage shows the same crop, band
/// and diagonal fade of the art as DELOS for Android's 16:9 stage: the art stays as dark and as blurred, relative to the
/// banner, instead of the taller area's larger band and weaker fade bringing it forward.
private struct GameBanner: View {
    let hostID: String
    let app: HostApp
    let blur: Int
    @Environment(HomeArt.self) private var art
    @Environment(HostStore.self) private var hosts
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @State private var lens: CGImage?

    var body: some View {
        let placeholder = GameArt(hostID: hostID, app: app)
        let height = stage.compact ? GameSettingsLayout.compactBannerHeight : GameSettingsLayout.bannerHeight
        let heroStageHeight = Self.bannerStageHeight(stageWidth: stage.width, stageHeight: stage.height)
        let area = HeroArea.of(stageWidth: stage.width, stageHeight: heroStageHeight)
        ZStack(alignment: .top) {
            PlaceholderArt(hue: placeholder.hue, hue2: placeholder.hue2, icon: placeholder.icon, glyphSize: 420, glyphRight: 84, glyphTop: -0.14, glyphAlpha: 0.14)
            // The stage-wide top of the hero's overscanned area (2100 x 1260 at 16:9), as the dashboard shows it at 16:9. An
            // overlay, so the wider picture overflows the banner evenly on both sides (Android's `requiredSize`) instead of
            // widening it, and the whole screen with it, the moment the art arrives
            Color.clear.overlay(alignment: .top) {
                // The dashboard's render of the same art (same area: a stage of 16:9 or wider) is usually in memory already: it
                // shows from the first frame, without a fade (Android's `HeroBitmaps.cached`), so the banner never starts on the
                // placeholder and swaps in the art later
                if let lens = lens ?? cachedLens(area: area) {
                    Image(decorative: lens, scale: 1)
                        .resizable()
                        .interpolation(.low)
                        .frame(width: stage.px(area.width), height: stage.px(area.height))
                        .offset(y: stage.px(-(area.height - heroStageHeight) / 2))
                        .transition(.opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000)))
                }
            }
            LinearGradient(stops: [
                .init(color: colors.bg.opacity(0.7).color, location: 0), .init(color: colors.bg.opacity(0.2).color, location: 0.5),
                .init(color: colors.bg.opacity(0).color, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [colors.bg.opacity(0.15).color, colors.bg.opacity(0.55).color], startPoint: .top, endPoint: .bottom)
        }
        .frame(maxWidth: .infinity)
        .frame(height: stage.px(height), alignment: .top)
        .clipped()
        // The strip fades into the page over its lower 65 %. Opaque from its very top: Android's mask starts clear for one
        // stage pixel, a hairline on the Odin but a seam of the animated background on a denser screen
        .mask {
            LinearGradient(stops: [
                .init(color: .black, location: 0), .init(color: .black, location: 0.35), .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .task(id: "\(GameArt.key(hostID, app.id))#\(art.artwork.version)/\(blur)/\(area.width)x\(area.height)") {
            let image = await bannerImage()
            guard !Task.isCancelled, let image else { return }
            let result = await art.background(GameArt(hostID: hostID, app: app, image: image), blur: blur, area: area)
            guard !Task.isCancelled else { return }
            if result === lens || result === cachedLens(area: area) { lens = result; return }
            withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000)) { lens = result }
        }
    }

    /// The stage height the banner's hero area is worked out for: the stage's own, at most 16:9 of its width (DELOS for
    /// Android's 1920 × 1080 stage), so a taller stage keeps the wide stage's crop.
    static func bannerStageHeight(stageWidth: Double, stageHeight: Double) -> Double {
        min(stageHeight, stageWidth * 1080 / 1920)
    }

    /// The banner's render if it is in memory already, from the same picks as ``bannerImage()`` in the same order.
    private func cachedLens(area: HeroArea) -> CGImage? {
        var sources: [CGImage?] = []
        if art.artwork.enabled {
            sources.append(art.cachedImage(hostID: hostID, appID: app.id, kind: .hero))
            sources.append(art.cachedImage(hostID: hostID, appID: app.id, kind: .cover))
        }
        sources.append(art.cachedBoxArt(hostID: hostID, appID: app.id))
        guard let image = sources.lazy.compactMap({ $0 }).first else { return nil }
        return art.cachedBackground(GameArt(hostID: hostID, app: app, image: image), blur: blur, area: area)
    }

    /// The hero as the dashboard picks it (the SteamGridDB hero, else its cover, else the PC's artwork).
    private func bannerImage() async -> CGImage? {
        if art.artwork.enabled {
            if let hero = await art.image(hostID: hostID, appID: app.id, kind: .hero) { return hero }
            if let cover = await art.image(hostID: hostID, appID: app.id, kind: .cover) { return cover }
        }
        return await art.boxArt(hostID: hostID, appID: app.id, hosts: hosts)
    }
}
