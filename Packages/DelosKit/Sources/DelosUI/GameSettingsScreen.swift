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
    let hostID: String
    let app: HostApp
    let focus: FocusModel
    let navigator: Navigator
    let actions: ShellActions
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(HostStore.self) private var hosts
    @State private var model: GameSettingsModel
    @State private var picker: (id: String, focus: FocusModel)?
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var pace = ScrollPace()
    /// The row last focused, which Reset all gives the focus back to.
    @State private var lastRow: String?
    @Environment(\.modalFocus) private var inheritedModal

    static let resetAllID = "game-reset-all"
    static let space = "game-settings"

    static func firstFocus() -> String { StreamSettingsForm.resolution }

    init(hostID: String, app: HostApp, focus: FocusModel, navigator: Navigator, actions: ShellActions, profileID: String) {
        self.hostID = hostID
        self.app = app
        self.focus = focus
        self.navigator = navigator
        self.actions = actions
        _model = State(initialValue: GameSettingsModel(hostID: hostID, app: app, profileID: profileID, device: .current))
    }

    private var rows: [SettingRow] { model.rows }
    private var focusedRow: SettingRow? { rows.first { focus.focused == AnyHashable($0.id) } }

    var body: some View {
        let left = 150 + stage.safe.leading, right = 150 + stage.safe.trailing
        let rows = rows
        let count = model.overrides.count
        ZStack(alignment: .topLeading) {
            header(count: count)
                .frame(height: stage.px(92))
                .padding(.leading, stage.px(left))
                .padding(.trailing, stage.px(right))
                .padding(.top, stage.px(106 + stage.safe.top))
            HStack(alignment: .top, spacing: stage.px(56)) {
                list(rows)
                GameSettingsPanel(
                    app: app.title, row: focusedRow.map { row in
                        (row, model.isCustom(row.id), model.profileLabel(row.id), model.currentLabel(row.id))
                    }, count: count)
                    .frame(width: stage.px(520))
            }
            .padding(.leading, stage.px(left))
            .padding(.trailing, stage.px(right))
            .padding(.top, stage.px(296 + stage.safe.top))
            .padding(.bottom, stage.px(96 + stage.safe.bottom))
            if let picker, let row = rows.first(where: { $0.id == picker.id }), case let .choice(_, options, selected) = row.value {
                ChoicePicker(
                    title: row.label, options: options, selected: selected, focus: picker.focus,
                    anchor: rowFrames[row.id] ?? .zero, onPick: { index in pick(row.id, index) }, onClose: closePicker)
            }
        }
        .coordinateSpace(.named(Self.space))
        .environment(\.modalFocus, picker?.focus ?? inheritedModal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            navigator.commandCapture = { command in capture(command) }
            if focusedRow == nil { focus.focus(Self.firstFocus()) }
        }
        .onDisappear { navigator.commandCapture = nil }
        .onChange(of: focus.focused) { _, now in
            if let id = now as? String, rows.contains(where: { $0.id == id }) { lastRow = id }
        }
    }

    // MARK: Header

    private func header(count: Int) -> some View {
        HStack(spacing: stage.px(16)) {
            VStack(alignment: .leading, spacing: stage.px(4)) {
                Text(L("settings_game_eyebrow", hosts.host(hostID)?.name ?? "").uppercased(with: .current))
                    .font(DelosFonts.figtree(stage.tpx(16), .bold))
                    .tracking(stage.tpx(16) * 0.14)
                    .foregroundStyle(colors.accent2.color)
                    .lineLimit(1)
                MarqueeLabel(text: app.title, active: false)
                    .font(DelosFonts.unbounded(stage.tpx(46)))
                    .foregroundStyle(colors.text.color)
            }
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

    // MARK: List

    private func list(_ rows: [SettingRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: stage.px(10)) {
                    ForEach(rows) { row in
                        FocusItem(
                            id: row.id, model: focus,
                            menu: { model.isCustom(row.id) ? resetMenu(row) : nil },
                            action: { activate(row) }, tap: { tapped(row) }
                        ) { focused in
                            SettingRowView(row: row, focused: focused, hostedPlate: true, onSlide: { value in
                                focus.focus(AnyHashable(row.id))
                                model.slide(to: value)
                            }, onReset: { resetRow(row.id) })
                        }
                        .id(row.id)
                        .anchorPreference(key: SettingsRowAnchors.self, value: .bounds) { [row.id: $0] }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { rowFrames[row.id] = $0 }
                    }
                }
                .backgroundPreferenceValue(SettingsRowAnchors.self) { anchors in
                    GeometryReader { proxy in
                        let anchor = (focus.focused as? String).flatMap { anchors[$0] }
                        SettingsFocusPlate(target: anchor.map { SettingsPlateGeometry.target(proxy[$0]) })
                    }
                }
                .padding(.horizontal, stage.px(18))
                .padding(.top, stage.px(14))
                .padding(.bottom, stage.px(140))
                .focusDrivenScroll()
            }
            .focusable(false)
            .scrollClipDisabled()
            .onChange(of: focus.focused) { _, now in
                guard let id = now as? String, rows.contains(where: { $0.id == id }) else { return }
                withAnimation(pace.animation(.easeOut(duration: 0.3))) { proxy.scrollTo(id) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The right-menu / long-press menu of a custom row (`ContextMenu` with "Reset to profile value").
    private func resetMenu(_ row: SettingRow) -> ContextMenu {
        ContextMenu(title: row.label, items: [
            MenuItem(icon: Symbols.reset, label: L("settings_game_reset_menu")) { resetRow(row.id) },
        ])
    }

    // MARK: Input

    /// The controller's and the keyboard's commands, before the focus gets them.
    private func capture(_ command: MenuCommand) -> Bool {
        if let picker { return capturePicker(command, picker.focus) }
        switch command {
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
            // X resets the focused custom row
            guard let row = focusedRow, model.isCustom(row.id) else { return false }
            actions.feedback?.play(.select)
            resetRow(row.id)
            return true
        case .previousTab, .nextTab, .down, .accept, .back, .menu, .toastAction:
            return false
        }
    }

    private func capturePicker(_ command: MenuCommand, _ pickerFocus: FocusModel) -> Bool {
        switch command {
        case .up, .down:
            if pickerFocus.handle(command) { actions.feedback?.play(.move) }
        case .accept:
            if pickerFocus.handle(.accept) { actions.feedback?.play(.select) }
        case .back:
            actions.feedback?.play(.back)
            closePicker()
        case .left, .right, .previousTab, .nextTab, .menu, .options, .toastAction:
            break
        }
        return true
    }

    private func activate(_ row: SettingRow) {
        guard row.enabled else {
            actions.feedback?.play(.error)
            return
        }
        model.step(row.id, by: 1)
    }

    private func tapped(_ row: SettingRow) {
        switch row.value {
        case .toggle:
            actions.feedback?.play(.select)
            model.step(row.id, by: 1)
        case .choice(_, _, let selected):
            actions.feedback?.play(.open)
            picker = (row.id, FocusModel(initial: ChoicePicker.optionID(selected ?? 0)))
        case .slider, .action, .appSettings, .info:
            break
        }
    }

    private func pick(_ id: String, _ index: Int) {
        actions.feedback?.play(.select)
        model.pick(id, option: index)
        closePicker()
    }

    private func closePicker() {
        withAnimation(.easeOut(duration: 0.2)) { picker = nil }
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
        let tint = count == 0 ? nil : colors.accent3
        HStack(spacing: stage.px(8)) {
            SymbolView(symbol: count == 0 ? Symbols.checkCircle : Symbols.tune, size: 22, color: tint ?? colors.text2, filled: true)
            Text(GameSettingsText.customLabel(count))
                .font(DelosFonts.figtree(stage.tpx(19), .semibold))
                .foregroundStyle((tint ?? colors.text2).color)
                .lineLimit(1)
        }
        .padding(.horizontal, stage.px(16))
        .padding(.vertical, stage.px(6))
        .background {
            GlassShape(Capsule(), tint: colors.surface)
                .overlay(Capsule().strokeBorder((tint ?? colors.line).color, lineWidth: stage.px(1)))
        }
    }
}

/// The glass panel on the right (`GameSettingsPanel`): the focused row's icon on an accent disc, its name, where its value
/// comes from (custom for this app with the profile's value, or the profile's), its help and the autosave note. With
/// nothing focused it sums up how many settings the app customises.
private struct GameSettingsPanel: View {
    let app: String
    let row: (row: SettingRow, custom: Bool, profile: String, current: String)?
    let count: Int
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
            HStack(spacing: stage.px(8)) {
                SymbolView(symbol: Symbols.checkCircle, size: 20, color: colors.text3)
                Text(L("settings_game_saved_note"))
                    .font(DelosFonts.figtree(stage.tpx(17)))
                    .foregroundStyle(colors.text3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(stage.px(44))
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: stage.px(34)).fill(colors.surface.color)
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
                L("settings_game_profile_value_button", source.profile, "X")
                #endif
            } else {
                L("settings_game_currently", source.current)
            }
        } ?? GameSettingsText.summary(count, app: app)
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

/// The CUSTOM badge of a row the app overrides (`CustomBadge`).
struct CustomBadge: View {
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(6)) {
            SymbolView(symbol: Symbols.tune, size: 17, color: colors.onAccent3, filled: true)
            Text("CUSTOM") // l10n-ignore
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
            .buttonStyle(.plain)
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
