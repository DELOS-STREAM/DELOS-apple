import DelosData
import DelosInput
import DelosMedia
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Settings (`SettingsScreen` of DELOS for Android) on a stage that is not compact: the title, the tabs between their
/// L1 and R1 badges, the rows of the selected tab and, on the right, the description panel with the focused row's help.
/// Search, the impact chips and the compact layout with the help dock under the list are not ported yet.
/// About contains only the system app-language action on iPhone and iPad. The appearance rows change the current
/// profile's ``Appearance``, which the whole interface shows at once, and store it.
///
/// Controller: up and down move between the rows (a held Up stops at the first row; a new press there goes on to the
/// top navigation), left and right change the focused row's value (a held direction speeds a slider up), A changes it
/// (the next choice, a toggle flips), L1 and R1 switch the tab, B goes back.
/// Touch (Android issue #92): a tap focuses a row, so the panel shows its help; a tap on a toggle also flips it, a tap
/// on a choice opens the list of its values to pick from, and a slider is tapped or dragged on its track. The tabs are
/// touch only, as on Android.
struct SettingsScreen: View {
    let profileID: String
    let focus: FocusModel
    let navigator: Navigator
    let feedback: Feedback?
    /// What the Covers rows do (the API key dialog, the downloads).
    let actions: ShellActions
    /// The current profile's appearance, owned by ``DelosRoot``.
    @Binding var appearance: Appearance
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.openURL) private var openURL
    @Environment(\.modalFocus) private var inheritedModal
    @State private var form: StreamSettingsForm
    @State private var tab: SettingsTab
    /// The row whose list of values is open, and the focus inside the list.
    @State private var picker: (id: String, focus: FocusModel)?
    @State private var rowFrames: [String: CGRect] = [:]
    private let store = StreamSettingsStore()
    private let appearances = AppearanceStore()

    /// The row the screen opens with.
    static let initialFocus = StreamSettingsForm.resolution

    init(profileID: String, appearance: Binding<Appearance>, focus: FocusModel, navigator: Navigator, feedback: Feedback?, actions: ShellActions,
         tab: SettingsTab? = nil) {
        self.profileID = profileID
        _appearance = appearance
        self.focus = focus
        self.navigator = navigator
        self.feedback = feedback
        self.actions = actions
        _tab = State(initialValue: SettingsSession.shared.opening(tab))
        _form = State(initialValue: StreamSettingsForm(settings: StreamSettingsStore().load(profile: profileID), device: .current))
    }

    /// The first row of [tab], which the screen opens with on that tab.
    static func firstRow(_ tab: SettingsTab) -> String {
        switch tab {
        case .stream: StreamSettingsForm.resolution
        case .audio: StreamSettingsForm.hostAudio
        case .controls: AppearanceForm.haptics
        case .appearance: AppearanceForm.theme
        case .covers: CoversForm.key
        case .about: AppLanguageSetting.supportsAppSettings ? AppLanguageSetting.id : GameDataSetting.firstID
        }
    }

    private var appearanceForm: AppearanceForm { AppearanceForm(appearance: appearance) }

    private var coversForm: CoversForm {
        CoversForm(enabled: actions.artwork.enabled, automatic: actions.artwork.automatic,
                   pcName: actions.libraryHostID.flatMap { actions.hosts.host($0)?.name })
    }

    private var rows: [SettingRow] {
        form.rows(tab) + appearanceForm.rows(tab) + coversForm.rows(tab) + AppLanguageSetting.rows(tab) + GameDataSetting.rows(tab)
    }
    private var focusedRow: SettingRow? { rows.first { focus.focused == AnyHashable($0.id) } }

    var body: some View {
        let left = 150 + stage.safe.leading, right = 150 + stage.safe.trailing
        ZStack(alignment: .topLeading) {
            Text(L("settings_screen_title"))
                .font(DelosFonts.unbounded(stage.tpx(46)))
                .foregroundStyle(colors.text.color)
                .offset(x: stage.px(left), y: stage.px(124 + stage.safe.top))
            SettingsTabs(selected: tab, focus: focus) { next in select(next, sound: .select, keepFocus: true) }
                .frame(height: stage.px(66))
                .frame(maxWidth: .infinity)
                .tvFocusSection()
                .offset(y: stage.px(206 + stage.safe.top))
            HStack(alignment: .top, spacing: stage.px(56)) {
                list
                DescriptionPanel(tab: tab, row: focusedRow)
                    .frame(width: stage.px(520))
            }
            .padding(.leading, stage.px(left))
            .padding(.trailing, stage.px(right))
            .padding(.top, stage.px(312 + stage.safe.top))
            .padding(.bottom, stage.px(96 + stage.safe.bottom))
            if let picker, let row = rows.first(where: { $0.id == picker.id }), case let .choice(_, options, selected) = row.value {
                ChoicePicker(
                    title: row.label, options: options, selected: selected, focus: picker.focus,
                    anchor: rowFrames[row.id] ?? .zero,
                    onPick: { index in pick(row.id, index) },
                    onClose: closePicker)
            }
        }
        .coordinateSpace(.named(Self.space))
        // The rows cannot take the system focus (tvOS) while the list of values is open
        .environment(\.modalFocus, picker?.focus ?? inheritedModal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: form.settings) { _, now in store.save(now, profile: profileID) }
        .onChange(of: appearance) { _, now in appearances.save(now, profile: profileID) }
        .onAppear {
            navigator.commandCapture = { command in capture(command) }
            if focusedRow == nil { focus.focus(Self.firstRow(tab)) }
            SettingsSession.shared.tab = tab
        }
        .onDisappear { navigator.commandCapture = nil }
        .onChange(of: tab) { _, next in SettingsSession.shared.tab = next }
    }

    nonisolated static let space = "settings"

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: stage.px(10)) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index == 0 || rows[index - 1].section != row.section {
                            SectionHeading(label: row.section)
                        }
                        FocusItem(
                            id: row.id, model: focus, action: { activate(row) }, tap: { tapped(row) }
                        ) { focused in
                            SettingRowView(row: row, focused: focused, hostedPlate: true) { value in
                                focus.focus(AnyHashable(row.id))
                                slide(row.id, to: value)
                            }
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
                            .id(tab)
                    }
                }
                // Room for the focused row's scale and glow, which the scroll view would cut
                .padding(.horizontal, stage.px(18))
                .padding(.top, stage.px(14))
                .padding(.bottom, stage.px(140))
            }
            .focusable(false)
            .scrollClipDisabled()
            .onChange(of: focus.focused) { _, now in
                guard let id = now as? String, rows.contains(where: { $0.id == id }) else { return }
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(id) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Input

    /// The controller's and the keyboard's commands, before the focus gets them (`Navigator.commandCapture`).
    private func capture(_ command: MenuCommand) -> Bool {
        if let picker { return capturePicker(command, picker.focus) }
        switch command {
        case .previousTab, .nextTab:
            select(tab.step(command == .nextTab ? 1 : -1), sound: .move)
            return true
        case .left, .right:
            // Left and right change the focused row's value and never leave the row
            guard let row = focusedRow else { return false }
            // A row that is unavailable keeps its value
            guard row.enabled else { return true }
            var direction = command == .right ? 1 : -1
            if case let .slider(_, range, step, _, _) = row.value {
                direction *= StreamSettingsForm.sliderAcceleration(steps: (range.upperBound - range.lowerBound) / step, repeatCount: navigator.commandRepeat)
            }
            if case .toggle = row.value { return true }
            if step(row.id, by: direction) { feedback?.play(.move) }
            return true
        case .up:
            // A held Up stops at the first row; only a new press there goes on to the top navigation
            return navigator.commandRepeat > 0 && focusedRow?.id == rows.first?.id
        case .down, .accept, .back, .menu, .options, .toastAction:
            return false
        }
    }

    /// The open list of values: up and down move, A picks, B closes it; nothing reaches the screen behind it.
    private func capturePicker(_ command: MenuCommand, _ pickerFocus: FocusModel) -> Bool {
        switch command {
        case .up, .down:
            if pickerFocus.handle(command) { feedback?.play(.move) }
        case .accept:
            if pickerFocus.handle(.accept) { feedback?.play(.select) }
        case .back:
            feedback?.play(.back)
            closePicker()
        case .left, .right, .previousTab, .nextTab, .menu, .options, .toastAction:
            break
        }
        return true
    }

    /// A on a row: a toggle flips, a choice or a slider steps forward, an action runs (`SettingRow.activate` of DELOS for
    /// Android); an unavailable row only plays the error sound.
    private func activate(_ row: SettingRow) {
        guard row.enabled else {
            feedback?.play(.error)
            return
        }
        switch row.id {
        case CoversForm.key: actions.openSteamGridDBKeyDialog()
        case CoversForm.missing: Task { await actions.downloadArtwork(hostID: actions.libraryHostID, refresh: false) }
        case CoversForm.refresh: Task { await actions.downloadArtwork(hostID: actions.libraryHostID, refresh: true) }
        case _ where GameDataSetting.website(row.id) != nil:
            if let url = GameDataSetting.website(row.id) { openURL(url) }
        default:
            if case .appSettings = row.value {
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                #endif
                return
            }
            step(row.id, by: 1)
        }
    }

    /// Steps row [id] of the stream settings, of the appearance (which changes live) or of Covers.
    @discardableResult
    private func step(_ id: String, by direction: Int) -> Bool {
        if id == CoversForm.automaticID {
            actions.artwork.automatic.toggle()
            return true
        }
        guard AppearanceForm.ids.contains(id) else { return form.step(id, by: direction) }
        var next = appearanceForm
        guard next.step(id, by: direction) else { return false }
        appearance = next.appearance
        return true
    }

    /// A slider's value set on its track by touch: the bitrate, the interface scale, the app background's blur or opacity.
    private func slide(_ id: String, to value: Int) {
        if AppearanceForm.ids.contains(id) {
            var next = appearanceForm
            next.slide(id, to: value)
            appearance = next.appearance
        } else if id == StreamSettingsForm.bitrate {
            form.setBitrate(value)
        }
    }

    /// A tap on a row (it is focused already): a toggle flips, a choice opens its list, an action runs, a slider waits
    /// for its track.
    private func tapped(_ row: SettingRow) {
        guard row.enabled else {
            feedback?.play(.error)
            return
        }
        switch row.value {
        case .toggle:
            feedback?.play(.select)
            step(row.id, by: 1)
        case .choice(_, _, let selected):
            feedback?.play(.open)
            picker = (row.id, FocusModel(initial: ChoicePicker.optionID(selected ?? 0)))
        case .appSettings, .action:
            feedback?.play(.open)
            activate(row)
        case .slider:
            break
        }
    }

    private func pick(_ id: String, _ index: Int) {
        feedback?.play(.select)
        if AppearanceForm.ids.contains(id) {
            var next = appearanceForm
            next.pick(id, option: index)
            appearance = next.appearance
        } else {
            form.pick(id, option: index)
        }
        closePicker()
    }

    private func closePicker() {
        withAnimation(.easeOut(duration: 0.2)) { picker = nil }
    }

    /// [keepFocus]: the tab was chosen on the tab itself (tvOS), so the focus stays there.
    private func select(_ next: SettingsTab, sound: Cue, keepFocus: Bool = false) {
        guard next != tab else { return }
        feedback?.play(sound)
        tab = next
        if !keepFocus, let first = rows.first { focus.focus(AnyHashable(first.id)) }
    }
}

extension StreamDevice {
    /// This device's display and decoders.
    @MainActor static var current: StreamDevice {
        #if canImport(UIKit)
        let screen = UIScreen.main
        let size = screen.nativeBounds.size
        let fps = screen.maximumFramesPerSecond
        #elseif canImport(AppKit)
        let screen = NSScreen.main
        let size = screen.map { $0.convertRectToBacking($0.frame).size } ?? CGSize(width: 1920, height: 1080)
        let fps = screen?.maximumFramesPerSecond ?? 60
        #endif
        return StreamDevice(pixelWidth: Int(size.width), pixelHeight: Int(size.height), maxFramesPerSecond: fps, decodable: DecoderSupport.device)
    }
}

/// A section's heading over its first row: its name in capitals.
private struct SectionHeading: View {
    let label: String
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        Text(label.uppercased(with: .current))
            .font(DelosFonts.figtree(stage.tpx(16), .semibold))
            .tracking(stage.tpx(16) * 0.08)
            .foregroundStyle(colors.text3.color)
            .padding(.leading, stage.px(26))
            .padding(.top, stage.px(10))
            .padding(.bottom, stage.px(2))
    }
}

/// The tabs between the L1 and R1 badges (`TabPill` in a `TabRow` of DELOS for Android), centred on the stage. On the
/// controller they are never focused: L1 and R1 switch them; a tap selects one. On tvOS the Siri Remote has no L1 and
/// R1, so each tab is also an item of the screen's focus (up from the first row): select picks it. The selected one
/// sits on the accent pill, which glides to the next.
private struct SettingsTabs: View {
    let selected: SettingsTab
    let focus: FocusModel
    let onSelect: (SettingsTab) -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion
    @Namespace private var pill

    static func tabID(_ tab: SettingsTab) -> String { "tab-\(tab)" }

    var body: some View {
        HStack(spacing: 0) {
            ShoulderLabel(label: "L1")
            ForEach(SettingsTab.availableCases, id: \.self) { tab in
                tabView(tab)
            }
            ShoulderLabel(label: "R1")
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: selected)
    }

    @ViewBuilder private func tabView(_ tab: SettingsTab) -> some View {
        #if os(tvOS)
        FocusItem(id: Self.tabID(tab), model: focus, action: { onSelect(tab) }) { focused in
            pillView(tab)
                .focusLook(focused, scale: 1.06, ring: 3, glowBlur: 0, glowY: 0)
        }
        .padding(.horizontal, stage.px(5))
        #else
        pillView(tab)
            .contentShape(Capsule())
            .onTapGesture { onSelect(tab) }
            .padding(.horizontal, stage.px(5))
        #endif
    }

    private func pillView(_ tab: SettingsTab) -> some View {
        let on = tab == selected
        return HStack(spacing: stage.px(12)) {
            SymbolView(symbol: tab.icon, size: 30, color: on ? colors.onAccent : colors.text2, filled: on)
            Text(tab.label)
                .font(DelosFonts.figtree(stage.tpx(22), .semibold))
                .foregroundStyle((on ? colors.onAccent : colors.text2).color)
        }
        .padding(.horizontal, stage.px(22))
        .frame(height: stage.px(66))
        .background {
            if on { Capsule().fill(colors.accent.color).matchedGeometryEffect(id: "pill", in: pill) }
        }
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// The L1 / R1 hint beside the tabs.
private struct ShoulderLabel: View {
    let label: String
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        Text(label)
            .font(DelosFonts.figtree(stage.tpx(18), .bold))
            .foregroundStyle(colors.text3.color)
            .padding(.horizontal, stage.px(12))
            .padding(.vertical, stage.px(6))
            .overlay(RoundedRectangle(cornerRadius: stage.px(10)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
            .padding(.horizontal, stage.px(10))
    }
}

/// A settings row (`SettingRow` of DELOS for Android): the icon, the name and the value. The focused row lies on a
/// glass plate with a 3 px ring in the main color and a glow, slightly larger.
struct SettingRowView: View {
    let row: SettingRow
    let focused: Bool
    var compact = false
    var hostedPlate = false
    /// A value set on the slider's track by touch (on release).
    var onSlide: (Int) -> Void = { _ in }
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: stage.px(22)) {
            SymbolView(symbol: row.icon, size: 34, color: focused ? colors.accent2 : colors.accent2.opacity(0.62), filled: focused)
                .frame(width: stage.px(compact ? 44 : 52), alignment: .leading)
            VStack(alignment: .leading, spacing: stage.px(4)) {
                MarqueeLabel(text: row.label, active: focused)
                    .font(DelosFonts.figtree(stage.tpx(26), .semibold))
                    .foregroundStyle(colors.text.color)
                if let note = row.note {
                    Text(note)
                        .font(DelosFonts.figtree(stage.tpx(19)))
                        .foregroundStyle(colors.text3.color)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            value
        }
        // An unavailable row is dimmed (Android's 45 %); the focus plate keeps its look
        .opacity(row.enabled ? 1 : 0.45)
        .padding(.horizontal, stage.px(26))
        .padding(.vertical, stage.px(14))
        .frame(minHeight: stage.px(compact ? 80 : 92))
        .background {
            if !hostedPlate {
                RoundedRectangle(cornerRadius: stage.px(24))
                    .fill(colors.surface2.color)
                    .overlay(RoundedRectangle(cornerRadius: stage.px(24)).strokeBorder(colors.accent.color, lineWidth: stage.px(3)))
                    .shadow(color: colors.glow.color, radius: stage.px(25), y: stage.px(20))
                    .opacity(focused ? 1 : 0)
            }
        }
        .scaleEffect(focused ? 1.02 : 1)
        .zIndex(focused ? 1 : 0)
        .animation(reduceMotion ? nil : .timingCurve(0.3, 1.22, 0.42, 1, duration: SettingsPlateGeometry.duration), value: focused)
    }

    @ViewBuilder private var value: some View {
        let arrows = focused ? colors.accent2 : colors.text3
        switch row.value {
        case .toggle(let on):
            SettingSwitch(on: on)
        case .choice(let label, let options, let selected):
            ChoiceValue(index: selected ?? 0, count: options.count, arrows: arrows) {
                // The dot stays beside the value, as on Android
                HStack(spacing: stage.px(12)) {
                    if let swatch = row.swatch {
                        Circle().fill(swatch.color).frame(width: stage.px(26), height: stage.px(26))
                    }
                    MarqueeLabel(text: label, active: focused)
                        .font(DelosFonts.figtree(stage.tpx(23)))
                        .foregroundStyle(colors.text2.color)
                }
                .frame(maxWidth: stage.px(row.swatch == nil ? 360 : 398), alignment: .trailing)
            }
        case let .slider(value, range, step, divisor, unit):
            SettingSlider(value: value, range: range, step: step, divisor: divisor, unit: unit, focused: focused, onChange: onSlide)
        case .action(let label):
            labelled(label, arrows: arrows)
        case .appSettings(let language):
            labelled(language, arrows: arrows)
        }
    }

    /// A value before the chevron of a row that opens something.
    private func labelled(_ label: String?, arrows: RGBA) -> some View {
        HStack(spacing: stage.px(12)) {
            if let label {
                MarqueeLabel(text: label, active: focused)
                    .font(DelosFonts.figtree(stage.tpx(23)))
                    .foregroundStyle(colors.text2.color)
                    .frame(maxWidth: stage.px(360), alignment: .trailing)
            }
            SymbolView(symbol: Symbols.chevronRight, size: 30, color: arrows)
                .offset(x: stage.px(label == nil ? 0 : 9))
        }
    }
}

/// The on/off switch (`MotionSwitch` of the settings): 74 × 42, a veil when off, the main color into the secondary when
/// on, the knob sliding across.
private struct SettingSwitch: View {
    let on: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion

    var body: some View {
        let width = 74.0, height = 42.0, knob = height - 12
        ZStack(alignment: .leading) {
            Capsule().fill(colors.surface3.color).opacity(on ? 0 : 1)
            Capsule().fill(LinearGradient(colors: [colors.accent.color, colors.accent2.color], startPoint: .leading, endPoint: .trailing))
                .opacity(on ? 1 : 0)
            Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1))
            Circle()
                .fill((on ? colors.onAccent : colors.text2).color)
                .frame(width: stage.px(knob), height: stage.px(knob))
                .offset(x: stage.px(6 + (on ? width - height : 0)))
        }
        .frame(width: stage.px(width), height: stage.px(height))
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.7), value: on)
    }
}

/// A slider's track and value (`RowValue.Slider` of DELOS for Android): a 220 px track filled with the main into the
/// secondary color, the knob that grows on the focused row, the number with its unit. Touch: a tap or a drag on the
/// track sets the value, which is kept when the finger lifts.
private struct SettingSlider: View {
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let divisor: Int
    let unit: String
    let focused: Bool
    let onChange: (Int) -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion
    @State private var dragging: Int?

    var body: some View {
        let number = dragging ?? value
        let span = Double(max(range.upperBound - range.lowerBound, 1))
        let fraction = min(max(Double(number - range.lowerBound) / span, 0), 1)
        let track = 220.0
        HStack(spacing: stage.px(12)) {
            touchable(ZStack(alignment: .leading) {
                Capsule().fill(colors.surface3.color).frame(height: stage.px(10))
                Capsule()
                    .fill(LinearGradient(colors: [colors.accent.color, colors.accent2.color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: stage.px(track * fraction), height: stage.px(10))
                let radius = 14.0 * (focused ? 1.2 : 1)
                ZStack {
                    if focused { Circle().fill(colors.accent3.opacity(0.4).color).frame(width: stage.px(2 * (radius + 6)), height: stage.px(2 * (radius + 6))) }
                    Circle().fill(colors.text.color).frame(width: stage.px(2 * radius), height: stage.px(2 * radius))
                        .shadow(color: .black.opacity(0.3), radius: 0, y: stage.px(3))
                }
                .offset(x: stage.px(track * fraction) - stage.px(radius + (focused ? 6 : 0)))
            }
            .frame(width: stage.px(track), height: stage.px(48))
            .contentShape(Rectangle()), width: stage.px(track))
            .animation(dragging == nil && !reduceMotion ? .easeOut(duration: 0.2) : nil, value: number)
            Text(label(number))
                .font(DelosFonts.figtree(stage.tpx(23)))
                .foregroundStyle(colors.text2.color)
                .lineLimit(1)
                .frame(width: stage.px(160), alignment: .trailing)
        }
    }

    /// A tap or a drag on the track (there is no touch on tvOS).
    @ViewBuilder private func touchable(_ track: some View, width: CGFloat) -> some View {
        #if os(tvOS)
        track
        #else
        track.gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            dragging = snapped(drag.location.x / width)
        }.onEnded { drag in
            onChange(snapped(drag.location.x / width))
            dragging = nil
        })
        #endif
    }

    private func snapped(_ fraction: Double) -> Int {
        let raw = Double(range.lowerBound) + Double(range.upperBound - range.lowerBound) * min(max(fraction, 0), 1)
        let steps = ((raw - Double(range.lowerBound)) / Double(step)).rounded()
        return min(max(range.lowerBound + Int(steps) * step, range.lowerBound), range.upperBound)
    }

    private func label(_ number: Int) -> String {
        let text = number % divisor == 0 ? "\(number / divisor)" : String(format: "%.1f", locale: .current, Double(number) / Double(divisor))
        return text + unit
    }
}

/// The glass panel on the right: the focused row's icon on an accent disc, its name and its help (the tab's own when no
/// row is focused). Long help scrolls by touch.
private struct DescriptionPanel: View {
    let tab: SettingsTab
    let row: SettingRow?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        VStack(alignment: .leading, spacing: stage.px(18)) {
            ZStack {
                Circle().fill(colors.accent.color)
                SymbolView(symbol: row?.icon ?? tab.icon, size: 64, color: colors.onAccent, filled: true)
            }
            .frame(width: stage.px(120), height: stage.px(120))
            Text(row?.label ?? tab.label)
                .font(DelosFonts.unbounded(stage.tpx(30)))
                .foregroundStyle(colors.text.color)
                .padding(.top, stage.px(8))
            AutoScrollingHelp(identity: "\(row?.id ?? String(describing: tab)):\(row?.help ?? tab.help)") {
                VStack(alignment: .leading, spacing: stage.px(18)) {
                    Text(row?.help ?? tab.help)
                        .font(DelosFonts.figtree(stage.tpx(22)))
                        .lineSpacing(stage.tpx(22 * 0.45))
                        .foregroundStyle(colors.text2.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if row?.enabled == false {
                        Text(L("settings_screen_unavailable"))
                            .font(DelosFonts.figtree(stage.tpx(18)))
                            .foregroundStyle(colors.text3.color)
                    }
                    if row?.id == AppearanceForm.palette { swatches }
                }
            }
        }
        .padding(stage.px(44))
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: stage.px(34)).fill(colors.surface.color)
                .overlay(RoundedRectangle(cornerRadius: stage.px(34)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
    }

    /// The palette's three colors, only for the palette row: main, secondary and accent.
    private var swatches: some View {
        HStack(spacing: stage.px(16)) {
            ForEach([(colors.accent, L("settings_screen_palette_main")), (colors.accent2, L("settings_screen_palette_secondary")),
                     (colors.accent3, L("settings_screen_palette_accent"))], id: \.1) { color, name in
                VStack(spacing: stage.px(8)) {
                    RoundedRectangle(cornerRadius: stage.px(18)).fill(color.color)
                        .overlay(RoundedRectangle(cornerRadius: stage.px(18)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                        .frame(width: stage.px(120), height: stage.px(72))
                    Text(name)
                        .font(DelosFonts.figtree(stage.tpx(18)))
                        .foregroundStyle(colors.text2.color)
                }
            }
        }
    }
}

/// The values of a choice row to pick from (touch; Android issue #92): a card that opens at the row's value with the
/// current value (checked and focused) over the row, kept under the status bar and above the bottom edge; a long list
/// scrolls. A tap picks a value, a tap beside the card closes it. With a controller: up and down, A picks, B closes.
private struct ChoicePicker: View {
    let title: String
    let options: [String]
    let selected: Int?
    let focus: FocusModel
    /// The row's frame in the screen.
    let anchor: CGRect
    let onPick: (Int) -> Void
    let onClose: () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    static func optionID(_ index: Int) -> String { "option-\(index)" }

    /// The card's parts in stage pixels: its padding, the title line with its gap, an option and the gap between two.
    private static let pad = 20.0, titleLine = 36.0, option = 64.0, gap = 4.0

    var body: some View {
        GeometryReader { proxy in
            let top = stage.px(104 + stage.safe.top), bottom = proxy.size.height - stage.px(24 + stage.safe.bottom)
            let chrome = stage.px(2 * Self.pad + Self.titleLine + 2 * Self.gap)
            let list = min(stage.px(Double(options.count) * (Self.option + Self.gap)), max(bottom - top - chrome, stage.px(Self.option)))
            let height = chrome + list
            // The current value lies over the row
            let current = stage.px(Self.pad + Self.titleLine + 2 * Self.gap + Double(selected ?? 0) * (Self.option + Self.gap) + Self.option / 2)
            let y = min(max(anchor.midY - current, top), max(bottom - height, top))
            let width = stage.px(560)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                card(listHeight: list)
                    .frame(width: width, height: height, alignment: .top)
                    .offset(x: max(stage.px(24), anchor.maxX - width), y: y)
            }
        }
        .transition(.opacity)
    }

    private func card(listHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: stage.px(Self.gap)) {
            Text(title)
                .font(DelosFonts.figtree(stage.tpx(20), .semibold))
                .foregroundStyle(colors.text3.color)
                .lineLimit(1)
                .padding(.horizontal, stage.px(24))
                .frame(height: stage.px(Self.titleLine), alignment: .top)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: stage.px(Self.gap)) {
                        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                            FocusItem(id: Self.optionID(index), model: focus, action: { onPick(index) }) { focused in
                                optionView(option, current: index == selected, focused: focused)
                            }
                            .id(Self.optionID(index))
                        }
                    }
                }
            .focusable(false)
                .frame(height: listHeight)
                .onAppear { proxy.scrollTo(Self.optionID(selected ?? 0)) }
                .onChange(of: focus.focused) { _, now in if let now { proxy.scrollTo(now) } }
            }
        }
        .padding(.vertical, stage.px(Self.pad))
        .padding(.horizontal, stage.px(12))
        .background {
            // Opaque under the glass: the rows behind must not show through the values
            RoundedRectangle(cornerRadius: stage.px(34)).fill(colors.bg2.color)
                .overlay(RoundedRectangle(cornerRadius: stage.px(34)).fill(colors.surface3.color))
                .overlay(RoundedRectangle(cornerRadius: stage.px(34)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                .shadow(color: .black.opacity(0.35), radius: stage.px(30), y: stage.px(20))
        }
    }

    /// An option (`.menu-item` of the prototype): the focused one on a tint of the main color with a 3 px ring, the
    /// current one with a check.
    private func optionView(_ label: String, current: Bool, focused: Bool) -> some View {
        HStack(spacing: stage.px(18)) {
            Text(label)
                .font(DelosFonts.figtree(stage.tpx(23), .semibold))
                .foregroundStyle(colors.text.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if current {
                SymbolView(symbol: Symbols.check, size: 30, color: focused ? colors.accent : colors.text2)
            }
        }
        .padding(.leading, stage.px(24))
        .padding(.trailing, stage.px(22))
        .frame(height: stage.px(Self.option))
        .background {
            RoundedRectangle(cornerRadius: stage.px(28))
                .fill(colors.accent.opacity(0.17).color)
                .overlay(RoundedRectangle(cornerRadius: stage.px(28)).strokeBorder(colors.accent.color, lineWidth: stage.px(3)))
                .opacity(focused ? 1 : 0)
        }
    }
}
