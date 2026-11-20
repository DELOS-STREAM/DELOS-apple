import DelosCore
import DelosData
import DelosHost
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
/// On a compact stage the title goes, the tabs keep only the selected label and the help is a dock under the list.
/// Y or the Search button opens the search, and the stream rows that cost something carry the three impact chips.
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
    @Environment(Layers.self) private var layers: Layers?
    @State private var form: StreamSettingsForm
    @State private var tab: SettingsTab
    /// The popover that is open on a row (its options, or its slider), and the focus inside the options.
    @State private var popup: RowPopupState?
    @State private var rowFrames: [String: CGRect] = [:]
    /// A row of the search to bring into view once its tab is laid out.
    @State private var reveal: String?
    /// The focus of the search while it is open, and what it looks for.
    @State private var searchFocus: FocusModel?
    @State private var query = ""
    /// The row that was focused when the search opened: B returns to it (`shell.settingsFocus`).
    @State private var focusBeforeSearch: AnyHashable?
    /// The file picker of Import Custom Keys is open.
    @State private var importingSpecialKeys = false
    /// "Keep diagnostic logs" (device-wide, ``DiagLog``).
    @State private var diagnosticLogs = DiagLog.isEnabled
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

    /// The first row of [tab], which the screen opens with on that tab (the shell's own rows come first, as on Android).
    static func firstRow(_ tab: SettingsTab) -> String {
        switch tab {
        case .stream: StreamSettingsForm.resolution
        case .display: StreamSettingsForm.statsPosition
        case .audio: AppearanceForm.sounds
        case .controls: AppearanceForm.haptics
        case .appearance: AppearanceForm.theme
        case .covers: CoversForm.key
        case .devices: StartupSetting.defaultPCID
        case .about: AboutSetting.firstID
        }
    }

    private var appearanceForm: AppearanceForm {
        AppearanceForm(appearance: appearance, offersMaterialYou: SystemAccent.supported, systemHue: SystemAccent.hue)
    }

    private var coversForm: CoversForm {
        CoversForm(enabled: actions.artwork.enabled, automatic: actions.artwork.automatic,
                   pcName: actions.libraryHostID.flatMap { actions.hosts.host($0)?.name })
    }

    private var startupSetting: StartupSetting {
        StartupSetting(startup: actions.profiles.startup, pcs: actions.hosts.paired.map { ($0.id, $0.name) })
    }

    private var rows: [SettingRow] { rows(for: tab) }

    /// The rows of [tab] in Android's order (`nativeSettings` + the catalog), each section's rows together; the link
    /// guidance's rows follow the bitrate row.
    private func rows(for tab: SettingsTab) -> [SettingRow] {
        (appearanceForm.rows(tab) + shellRows(for: tab) + catalogRows(for: tab)).groupedBySection()
    }

    /// The shell's own rows of [tab] besides the appearance (the rest of `nativeSettings`).
    private func shellRows(for tab: SettingsTab) -> [SettingRow] {
        form.nativeRows(tab) + startupSetting.rows(tab) + DevicesSetting.rows(tab) + coversForm.rows(tab)
            + AboutSetting.rows(tab, diagnosticLogs: diagnosticLogs) + GameDataSetting.rows(tab)
    }

    /// The stream settings' rows of [tab] (the catalog), with the link guidance's rows after the bitrate row.
    private func catalogRows(for tab: SettingsTab) -> [SettingRow] {
        LinkGuidanceRows.apply(
            form.catalogRows(tab), guidance: linkGuidance, host: linkHost, form: form,
            nowMs: Int64((Date().timeIntervalSince1970 * 1000).rounded()), transport: .current)
            + AppLanguageSetting.rows(tab) + DebugInfoSetting.rows(tab)
    }

    /// The PC the link guidance talks about, and the guidance for it and the profile's stream.
    private var linkHost: HostRecord? { LinkGuidanceRows.settingsHost(libraryHostID: actions.libraryHostID, hosts: actions.hosts) }
    private var linkGuidance: LinkGuidance? { LinkGuidance.forSettings(host: linkHost, form: form) }

    /// Test link: the portal of the test, or a toast when the PC is offline or cannot test.
    private func testLink() {
        guard let host = linkHost, let guidance = linkGuidance else { return }
        switch LinkGuidanceRows.testPress(host: host, guidance: guidance) {
        case .offline(let text): actions.toasts.show(text, icon: Symbols.wifiOff)
        case .unavailable(let text): actions.toasts.show(text, icon: Symbols.info)
        case .run: actions.connection.testLink(host.id, startKbps: form.effectiveBitrate)
        }
    }

    /// Use recommended bitrate: the user's own press is the only thing that sets the recommendation.
    private func useRecommendedBitrate() {
        guard let kbps = linkGuidance?.recommendation.kbps else { return }
        form.setBitrate(kbps)
        actions.toasts.show(L("link_use_done_toast", linkMbps(kbps)), icon: Symbols.checkCircle)
    }

    /// The rows of every tab, which the search looks through, in the order of Android's list (`nativeSettings` + the catalog,
    /// not sorted by tab): the appearance rows first, then the shell's other rows, then the stream settings.
    private var searchableRows: [SettingRow] {
        SettingsSearch.appearanceOrder.flatMap { appearanceForm.rows($0) }
            + SettingsSearch.shellOrder.flatMap { shellRows(for: $0) }
            + SettingsTab.availableCases.flatMap { catalogRows(for: $0) }
    }
    private var focusedRow: SettingRow? { rows.first { focus.focused == AnyHashable($0.id) } }

    static let searchID = "settings-search"

    var body: some View {
        Group {
            if let searchFocus {
                SettingsSearchView(rows: searchableRows, focus: searchFocus, navigator: navigator, query: $query, onOpen: openResult)
            } else {
                content
            }
        }
        .coordinateSpace(.named(Self.space))
        // The rows cannot take the system focus (tvOS) while the list of values or the search is open
        .screenModal(searchFocus ?? popup?.focus)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: form.settings) { _, now in store.save(now, profile: profileID) }
        .onChange(of: appearance) { _, now in appearances.save(now, profile: profileID) }
        .onAppear {
            navigator.takeInput(focus) { command in capture(command) }
            if focusedRow == nil { focus.focus(Self.firstRow(tab)) }
            SettingsSession.shared.tab = tab
        }
        .onDisappear { navigator.releaseInput(focus) }
        #if !os(tvOS)
        .fileImporter(isPresented: $importingSpecialKeys, allowedContentTypes: [.json, .plainText]) { result in
            importSpecialKeys(result)
        }
        #endif
        .onChange(of: tab) { _, next in SettingsSession.shared.tab = next }
        .onChange(of: focus.focused, initial: true) { sendHints() }
        .onChange(of: searchFocus == nil) { sendHints() }
        .onChange(of: popup?.kind) { sendHints() }
    }

    /// The hint bar: the search's own set while it is open (`Screen.SettingsSearch`), a row popover's while one is open, else
    /// the focused row's.
    private func sendHints() {
        let searching = searchFocus != nil
        navigator.setHints(
            ScreenHints(
                adjustable: !searching && ShellHints.adjustable(focusedRow), rowOptions: !searching && RowOptions.of(focusedRow).opens,
                settingsSearch: searching, rowPopup: popup?.kind),
            from: focus)
    }

    private var content: some View {
        let compact = stage.compact
        let left = compact ? SettingsLayout.margin(stage) : SettingsLayout.margin(stage) + stage.safe.leading
        let right = compact ? SettingsLayout.margin(stage) : SettingsLayout.margin(stage) + stage.safe.trailing
        let bottom = SettingsLayout.bottom(scale: stage.textScale) + stage.safe.bottom
        let searchSize = SettingsLayout.searchSize(stage)
        return ZStack(alignment: .topLeading) {
            // A compact stage drops the title: the status bar and the selected tab say where this is
            if !compact {
                Text(L("settings_screen_title"))
                    .font(DelosFonts.unbounded(stage.tpx(46)))
                    .foregroundStyle(colors.text.color)
                    .offset(x: stage.px(left), y: stage.px(124 + stage.safe.top))
                // Kept the same distance from the right edge as at 1920 (x 1530), so a wider or narrower stage moves it with the edge
                FocusItem(id: Self.searchID, model: focus, clickCue: nil, action: openSearch) { focused in
                    PillButton(label: L("settings_screen_search"), icon: Symbols.search, focused: focused)
                }
                .offset(x: stage.px(stage.width - 390 - stage.safe.trailing), y: stage.px(122 + stage.safe.top))
            }
            SettingsTabs(
                selected: tab, focus: focus, collapse: compact || stage.width < SettingsLayout.fullTabsMinWidth,
                left: compact ? left : SettingsLayout.titleX,
                right: compact ? stage.width - right - searchSize - SettingsLayout.searchGap : stage.width - SettingsLayout.titleX
            ) { next in
                select(next, sound: .select, keepFocus: true)
            }
                .frame(height: stage.targetPx(66))
                .frame(maxWidth: .infinity)
                .tvFocusSection()
                .offset(y: stage.px((compact ? SettingsLayout.compactTabsY : SettingsLayout.tabsY) + stage.safe.top))
            if compact {
                // The search is a glass circle flush with the content's right edge, level with the tabs
                FocusItem(id: Self.searchID, model: focus, clickCue: nil, action: openSearch) { focused in
                    CircleIconButton(icon: Symbols.search, focused: focused, size: searchSize)
                }
                .accessibilityLabel(L("settings_screen_search"))
                .offset(
                    x: stage.px(stage.width - right - searchSize),
                    y: stage.px(SettingsLayout.compactTabsY + (SettingsLayout.tabsHeight - searchSize) / 2 + stage.safe.top))
                // The list takes the full width; the help is a dock under it, so the focused row and its help are on screen together
                VStack(spacing: stage.px(HelpDockLayout.listGap)) {
                    list
                    CompactHelpDock(tab: tab, row: focusedRow, appearance: appearance)
                        .frame(height: stage.px(HelpDockLayout.height(
                            stageHeight: stage.height, rowsTop: SettingsLayout.compactListTop + stage.safe.top + 14 + SettingsLayout.sectionHeading,
                            bottom: bottom, rowHeight: SettingsLayout.tallRow(stage))))
                }
                .padding(.leading, stage.px(left))
                .padding(.trailing, stage.px(right))
                .padding(.top, stage.px(SettingsLayout.compactListTop + stage.safe.top))
                .padding(.bottom, stage.px(bottom))
            } else {
                HStack(alignment: .top, spacing: stage.px(56)) {
                    list
                    DescriptionPanel(tab: tab, row: focusedRow, appearance: appearance)
                        .frame(width: stage.px(520))
                }
                .padding(.leading, stage.px(left))
                .padding(.trailing, stage.px(right))
                .padding(.top, stage.px(SettingsLayout.listTop + stage.safe.top))
                .padding(.bottom, stage.px(bottom))
            }
            if let popup, let row = rows.first(where: { $0.id == popup.id }) {
                RowPopover(
                    row: row, kind: popup.kind, focus: popup.focus, anchor: rowFrames[row.id] ?? .zero, slider: popup.slider,
                    onPick: { index in pick(row.id, index) }, onClose: closePopup)
            }
        }
    }

    nonisolated static let space = "settings"


    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: stage.px(10)) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index == 0 || rows[index - 1].section != row.section {
                        SectionHeading(label: row.section)
                    }
                    FocusItem(
                        id: row.id, model: focus, action: { activate(row) }, tap: { wasFocused in tapped(row, wasFocused: wasFocused) }
                    ) { focused in
                        SettingRowView(
                            row: row, focused: focused, hostedPlate: true, entrance: min(index, Motion.staggerCap),
                            onSlide: { value in
                                focus.focus(AnyHashable(row.id))
                                slide(row.id, to: value)
                            }, onStep: { direction in steppedByTouch(row, direction) })
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
                        .id(tab)
                }
            }
            // Room for the focused row's scale and glow, which the scroll view would cut
            .padding(.horizontal, stage.px(18))
            .padding(.top, stage.px(14))
            .padding(.bottom, stage.px(140))
            .focusDrivenScroll()
            .coordinateSpace(.named(SettingsListScroll.contentSpace))
            // A tab that is switched starts a new entrance (`rememberEntranceStagger(tab)`)
            .entranceScope()
            .id(tab)
        }
        .settingsListScroll(
            focus: focus, contains: { id in rows.contains { $0.id == id } }, resetKey: AnyHashable(tab),
            fadeTop: stage.compact ? SettingsLayout.compactFadeTop : SettingsLayout.fadeTop,
            fadeBottom: stage.compact ? SettingsLayout.compactFadeBottom : SettingsLayout.fadeBottom,
            compact: stage.compact, reveal: $reveal)
        .frame(maxWidth: .infinity)
    }

    // MARK: Input

    /// The controller's and the keyboard's commands, before the focus gets them (`Navigator.commandCapture`).
    private func capture(_ command: MenuCommand) -> Bool {
        if let searchFocus { return captureSearch(command, searchFocus) }
        if let popup { popup.capture(command, navigator: navigator, feedback: feedback, close: closePopup); return true }
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
        case .toastAction:
            // Y opens the search, unless the toast that is shown has its own action
            guard actions.toasts.current?.action == nil else { return false }
            openSearch()
            return true
        case .options:
            // Options opens the focused row's list of values or its slider, the popover a second tap opens
            guard let row = focusedRow else { return false }
            switch RowOptions.of(row) {
            case .popup:
                feedback?.play(.open)
                popup = RowPopupState.open(row) { value in slide(row.id, to: value) }
            case .refuse:
                feedback?.play(.error)
            case .menu, .none:
                return false
            }
            return true
        case .down, .accept, .back, .menu:
            return false
        }
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
        case DevicesSetting.manageID: navigator.openFromNavigation(.devices)
        case DevicesSetting.pairID: navigator.push(.pair)
        case AboutSetting.welcomeID: actions.replayWelcome()
        case DebugInfoSetting.id: go { navigator.push(.debugInfo) }
        case AboutSetting.basedID, AboutSetting.versionID, CoversForm.choose: return
        case StreamSettingsForm.oscPreview: navigator.push(.oscPreview)
        case LinkGuidanceRows.testID: testLink()
        case LinkGuidanceRows.useID: useRecommendedBitrate()
        case "option_reset_osc_preference":
            // Every on-screen control of the profile back to its default size and place (`SettingsActions`)
            OnScreenControlsStore().reset(profile: profileID)
            actions.toasts.show(L("settings_actions_osc_reset"), icon: Symbols.reset, kind: .success)
        case _ where GameDataSetting.website(row.id) != nil:
            if let url = GameDataSetting.website(row.id) { openURL(url) }
        case "import_special_button_file":
            #if os(tvOS)
            // Apple TV has no file picker (`settings_actions_no_file_picker`)
            actions.toasts.show(L("settings_actions_no_file_picker"), icon: Symbols.error)
            #else
            importingSpecialKeys = true
            #endif
        default:
            if case .appSettings = row.value {
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                #endif
                return
            }
            if case .text = row.value {
                openTextDialog(row)
                return
            }
            if let spec = SettingsCatalog.spec(row.id), case .action(let url?) = spec.kind {
                // A web page (`WebLauncherPreference`); no app for it says so
                openURL(url) { accepted in
                    if !accepted { actions.toasts.show(L("settings_actions_no_app_for_link"), icon: Symbols.error) }
                }
                return
            }
            step(row.id, by: 1)
        }
    }

    /// A TEXT row's dialog (`settingsActions`' text dialog of DELOS for Android): the row's name, its help, one field with
    /// the value, Save. A value that does not fit says why in a toast and keeps the dialog open.
    private func openTextDialog(_ row: SettingRow) {
        guard case .text(let value) = row.value else { return }
        let spec = SettingsCatalog.spec(row.id)
        actions.layers.openDialog(DialogSpec(
            title: row.label, note: spec?.help ?? "",
            fields: [DialogField(icon: row.icon, initial: value, maxLength: 32)],
            confirm: L("settings_actions_save")
        ) { [self] values in
            if let error = form.setText(row.id, values.first ?? "") {
                feedback?.play(.error)
                actions.toasts.show(error, icon: Symbols.error)
                return false
            }
            return true
        })
    }

    #if !os(tvOS)
    /// The custom keys file picked for Import Custom Keys, with Android's toasts.
    private func importSpecialKeys(_ result: Result<URL, any Error>) {
        let message: String
        var failed = true
        switch result {
        case .failure:
            message = L("settings_actions_file_open_failed")
        case .success(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                do {
                    try CustomSpecialKeys().importFile(data, profile: profileID)
                    message = L("settings_actions_imported")
                    failed = false
                } catch .tooLarge {
                    message = L("settings_actions_file_too_large")
                } catch .noShortcutData {
                    message = L("settings_actions_no_shortcut_data")
                } catch {
                    message = L("settings_actions_import_failed")
                }
            } else {
                message = L("settings_actions_file_open_failed")
            }
        }
        if failed { feedback?.play(.error) }
        actions.toasts.show(message, icon: failed ? Symbols.error : Symbols.checkCircle)
    }
    #endif

    /// Steps row [id] of the stream settings, of the appearance (which changes live), of Covers or of the startup.
    @discardableResult
    private func step(_ id: String, by direction: Int) -> Bool {
        switch id {
        case CoversForm.automaticID:
            actions.artwork.automatic.toggle()
            return true
        case StartupSetting.defaultPCID:
            let next = startupSetting.steppedDefault(by: direction)
            guard next != actions.profiles.startup.defaultPC else { return false }
            setDefaultPC(next)
            return true
        case StartupSetting.skipStartID:
            actions.profiles.setSkipStart(!actions.profiles.startup.skipStart)
            return true
        case AboutSetting.diagLogsID:
            diagnosticLogs.toggle()
            DiagLog.setEnabled(diagnosticLogs)
            return true
        default:
            break
        }
        if id == StreamSettingsForm.menuButtons {
            recordMenuButtons()
            return false
        }
        guard AppearanceForm.ids.contains(id) else { return form.step(id, by: direction) }
        var next = appearanceForm
        guard next.step(id, by: direction) else { return false }
        appearance = next.appearance
        return true
    }

    /// A new default PC keeps "Skip the start screen" only while it is a PC.
    private func setDefaultPC(_ hostID: String?) {
        let skip = actions.profiles.startup.skipStart
        actions.profiles.setDefaultPC(hostID)
        if hostID != nil, skip { actions.profiles.setSkipStart(true) }
    }

    /// A slider's value set on its track by touch.
    private func slide(_ id: String, to value: Int) {
        if AppearanceForm.ids.contains(id) {
            var next = appearanceForm
            next.slide(id, to: value)
            appearance = next.appearance
        } else {
            form.slide(id, to: value)
        }
    }

    /// A tap on a row (rules in ``RowTouch/of(_:wasFocused:enabled:canPopup:)``): the first tap focuses it and shows its help, a
    /// tap on the focused row flips it, or opens its options / its slider popover; a row that opens something does so at once.
    private func tapped(_ row: SettingRow, wasFocused: Bool) {
        switch RowTouch.of(row.value, wasFocused: wasFocused, enabled: row.enabled, canPopup: RowPopupKind.of(row) != nil) {
        case .focusOnly:
            feedback?.play(.move)
        case .activate:
            if case .toggle = row.value { feedback?.play(.select) } else { feedback?.play(.open) }
            activate(row)
        case .pick, .adjust:
            feedback?.play(.open)
            popup = RowPopupState.open(row) { value in slide(row.id, to: value) }
        case .error:
            feedback?.play(.error)
        case .none:
            break
        }
    }

    /// A touch on a choice's arrow or on a switch: the row is focused for its help and changes at once.
    private func steppedByTouch(_ row: SettingRow, _ direction: Int) {
        focus.focus(AnyHashable(row.id))
        guard row.enabled else {
            feedback?.play(.error)
            return
        }
        if step(row.id, by: direction) { feedback?.play(.move) }
    }

    private func pick(_ id: String, _ index: Int) {
        feedback?.play(.select)
        if AppearanceForm.ids.contains(id) {
            var next = appearanceForm
            next.pick(id, option: index)
            appearance = next.appearance
        } else if id == StreamSettingsForm.menuButtons, index == 1 {
            closePopup()
            recordMenuButtons()
            return
        } else if id == StartupSetting.defaultPCID {
            let choices = startupSetting.choices
            if choices.indices.contains(index) { setDefaultPC(choices[index].id) }
        } else {
            form.pick(id, option: index)
        }
        closePopup()
    }

    /// "Record buttons": the recording layer takes every controller button until the buttons held together are let go.
    private func recordMenuButtons() {
        layers?.openButtonCapture { buttons in form.setMenuButtons(buttons) }
    }

    private func closePopup() {
        withAnimation(.easeOut(duration: 0.2)) { popup = nil }
    }

    /// [keepFocus]: the tab was chosen on the tab itself (tvOS), so the focus stays there.
    private func select(_ next: SettingsTab, sound: Cue, keepFocus: Bool = false) {
        guard next != tab else { return }
        feedback?.play(sound)
        tab = next
        if !keepFocus, let first = rows.first { focus.focus(AnyHashable(first.id)) }
    }

    // MARK: Search

    /// Y, or the search button: the field, the letter picker and the results of every tab (`Screen.SettingsSearch`); the
    /// focus starts where Android's does (``SettingsSearchView/initialFocus``), and the row focused now is kept for the way back.
    private func openSearch() {
        feedback?.play(.open)
        query = ""
        focusBeforeSearch = focus.focused
        searchFocus = FocusModel(initial: AnyHashable(SettingsSearchView.initialFocus))
    }

    /// The commands while the search is open: B goes back to the settings, the focus has the rest; typing in the field takes the keys.
    private func captureSearch(_ command: MenuCommand, _ searchFocus: FocusModel) -> Bool {
        if navigator.isEditingText {
            if command == .back { navigator.isEditingText = false }
            return true
        }
        switch command {
        case .back:
            feedback?.play(.back)
            self.searchFocus = nil
            if let row = focusBeforeSearch { focus.focus(row) }
        case .accept:
            guard !navigator.swallowsAccept() else { break }
            if let feedback { feedback.activate(searchFocus.acceptCue) { searchFocus.handle(.accept) } } else { searchFocus.handle(.accept) }
        case .up, .down, .left, .right:
            if searchFocus.handle(command) { feedback?.play(.move) }
        case .previousTab, .nextTab, .menu, .options, .toastAction:
            break
        }
        return true
    }

    /// A result: its tab opens with the focus on that row (`shell.settingsTab` and `settingsFocus` of DELOS for Android).
    private func openResult(_ row: SettingRow) {
        tab = row.tab
        searchFocus = nil
        focus.focus(AnyHashable(row.id))
        // The rows of the tab are laid out a moment later: the list scrolls to the row then
        reveal = row.id
    }
}

extension StreamDevice {
    /// This device's display, decoders and hardware.
    @MainActor static var current: StreamDevice {
        #if canImport(UIKit)
        let screen = UIScreen.main
        let size = screen.nativeBounds.size
        let fps = screen.maximumFramesPerSecond
        // The safe area of the window in pixels: smaller than the panel around a notch or the Dynamic Island. Only an
        // iPhone has one; an iPad's and a TV's insets are the status bar, the home indicator and overscan, which a stream
        // covers, so their native resolution is the whole panel (Android counts a display cutout only)
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let safe = UIDevice.current.userInterfaceIdiom != .phone ? nil : window.map { $0.bounds.inset(by: $0.safeAreaInsets).size }
            .map { CGSize(width: $0.width * screen.nativeScale, height: $0.height * screen.nativeScale) }
        #elseif canImport(AppKit)
        let screen = NSScreen.main
        let size = screen.map { $0.convertRectToBacking($0.frame).size } ?? CGSize(width: 1920, height: 1080)
        let fps = screen?.maximumFramesPerSecond ?? 60
        let safe: CGSize? = nil
        #endif
        var device = StreamDevice(
            pixelWidth: Int(size.width), pixelHeight: Int(size.height), maxFramesPerSecond: fps, decodable: DecoderSupport.device,
            hdrDisplay: HDRDisplay.isSupported)
        if let safe {
            device.safePixelWidth = Int(safe.width.rounded())
            device.safePixelHeight = Int(safe.height.rounded())
        }
        device.touchscreen = DeviceHardware.touchscreen
        device.deviceMotion = DeviceHardware.motion
        device.haptics = DeviceHardware.haptics
        device.pictureInPicture = DeviceHardware.pictureInPicture
        device.metalFX = MetalFXSupport.system
        return device
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

/// The tabs of Settings (``TabRow``): the stream, audio, controls, appearance, covers, devices and about tabs that exist here.
private struct SettingsTabs: View {
    let selected: SettingsTab
    let focus: FocusModel
    var collapse = false
    var left = SettingsLayout.titleX
    var right = Stage.designWidth - SettingsLayout.titleX
    let onSelect: (SettingsTab) -> Void

    static func tabID(_ tab: SettingsTab) -> String { "tab-\(tab)" }

    var body: some View {
        TabRow(
            tabs: SettingsTab.availableCases.map { TabSpec(id: $0, icon: $0.icon, label: $0.label) }, selected: selected, focus: focus,
            focusID: Self.tabID, collapse: collapse, left: left, right: right, onSelect: onSelect)
    }
}

/// A settings row (`SettingRow` of DELOS for Android): the icon, the name and the value. The focused row lies on a
/// glass plate with a 3 px ring in the main color and a glow, slightly larger. Sizes that are not text scale with the
/// compact stage (`cpx`). [entrance]: the row's place in the tab's staggered entrance, nil for none.
struct SettingRowView: View {
    let row: SettingRow
    let focused: Bool
    var compact = false
    var hostedPlate = false
    var entrance: Int?
    /// A value set on the slider's track by touch (on release).
    var onSlide: (Int) -> Void = { _ in }
    /// A touch on a switch or on a choice's arrow (-1, +1) changes the row by itself, without the focus-first tap.
    var onStep: ((Int) -> Void)? = nil
    /// Resets the row to the profile's value (a row that is custom only).
    var onReset: (() -> Void)? = nil
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: stage.cpx(22)) {
            SymbolView(symbol: row.icon, size: 34, color: focused ? colors.accent2 : colors.accent2.opacity(0.62), filled: focused)
                .frame(width: stage.cpx(compact ? 44 : 52), alignment: .leading)
                .entering(entrance)
            VStack(alignment: .leading, spacing: stage.px(4)) {
                // Cost-bearing rows: the chips on their own line above the title, on the same left edge
                if let impact = row.impact { ImpactChips(impact: impact, focused: focused).padding(.bottom, stage.px(2)) }
                MarqueeLabel(text: row.label, active: focused)
                    .font(DelosFonts.figtree(stage.tpx(26), .semibold))
                    .foregroundStyle(colors.text.color)
                if let line = row.customLine {
                    HStack(spacing: stage.px(10)) {
                        CustomBadge()
                        Text(line)
                            .font(DelosFonts.figtree(stage.tpx(19)))
                            .lineSpacing(stage.tpx(19 * 0.35))
                            .foregroundStyle(colors.text3.color)
                            .lineLimit(1)
                    }
                } else if let note = row.note {
                    Text(note)
                        .font(DelosFonts.figtree(stage.tpx(19)))
                        .lineSpacing(stage.tpx(19 * 0.35))
                        .foregroundStyle(colors.text3.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .entering(entrance)
            if row.customLine != nil, let onReset {
                RowResetButton(focused: focused && row.enabled, onReset: onReset)
            }
            value.entering(entrance)
        }
        // The icon and the arrows change color as the plate glides (Motion.ROW_FOCUS, CSS ease)
        .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: (reduceMotion ? Motion.fade : Motion.rowFocus) / 1000), value: focused)
        // An unavailable row is dimmed (Android's 45 %); the focus plate keeps its look
        .opacity(row.enabled ? 1 : 0.45)
        .padding(.horizontal, stage.cpx(26))
        .padding(.vertical, stage.cpx(14))
        .frame(minHeight: stage.targetPx(compact ? 80 : row.impact != nil ? 120 : 92))
        .background {
            if !hostedPlate {
                RoundedRectangle(cornerRadius: stage.px(24))
                    .fill(colors.surface2.color)
                    .overlay(RoundedRectangle(cornerRadius: stage.px(24)).strokeBorder(colors.accent.color, lineWidth: stage.px(3)))
                    .background { GeometryReader { PlateGlow(size: $0.size) } }
                    .opacity(focused ? 1 : 0)
            }
        }
        .focusLift(focused, scale: 1.02)
        .zIndex(focused ? 1 : 0)
        // The scale of a focused row: the prototype's spring over Motion.ROW_FOCUS
        .animation(reduceMotion ? nil : Motion.spring(Motion.rowFocus), value: focused)
        // VoiceOver reads the row as its name and its value, a switch as a switch; the reset button is an action
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityHint(row.enabled ? row.impact.map(ImpactAxes.description) ?? "" : L("settings_screen_unavailable"))
        .accessibilityAddTraits(row.value.isToggle ? .isToggle : [])
        .modifier(RowResetAction(onReset: row.customLine == nil ? nil : onReset))
    }

    @ViewBuilder private var value: some View {
        let arrows = focused ? colors.accent2 : colors.text3
        switch row.value {
        case .toggle(let on):
            SettingSwitch(on: on)
                .touchStep(onStep)
        case .choice(let label, let options, let selected):
            ChoiceValue(index: selected ?? 0, count: options.count, arrows: arrows, onStep: onStep) {
                // The dot stays beside the value, as on Android
                HStack(spacing: stage.px(12)) {
                    if let swatch = row.swatch {
                        Circle().fill(swatch.color).frame(width: stage.px(26), height: stage.px(26))
                    }
                    MarqueeLabel(text: label, active: focused)
                        .font(DelosFonts.figtree(stage.tpx(23)))
                        .foregroundStyle(colors.text2.color)
                }
                .frame(maxWidth: stage.px(stage.compact ? 260 + (row.swatch == nil ? 0 : 38) : row.swatch == nil ? 360 : 398), alignment: .trailing)
            }
        case let .slider(value, range, step, divisor, unit):
            SettingSlider(value: value, range: range, step: step, divisor: divisor, unit: unit, minText: row.sliderMinText, focused: focused, onChange: onSlide)
        case .action(let label):
            labelled(label, arrows: arrows)
        case .text(let value):
            labelled(value, arrows: arrows)
        case .appSettings(let language):
            labelled(language, arrows: arrows)
        case .info(let text):
            MarqueeLabel(text: text, active: focused)
                .font(DelosFonts.figtree(stage.tpx(23)))
                .foregroundStyle(colors.text2.color)
                .frame(maxWidth: stage.px(360), alignment: .trailing)
        }
    }

    /// A value before the chevron of a row that opens something (`RowValue.Text`: 220 px at most, 180 on a compact stage).
    private func labelled(_ label: String?, arrows: RGBA) -> some View {
        HStack(spacing: stage.px(12)) {
            if let label {
                MarqueeLabel(text: label, active: focused)
                    .font(DelosFonts.figtree(stage.tpx(23)))
                    .foregroundStyle(colors.text2.color)
                    .frame(maxWidth: stage.px(stage.compact ? 180 : 220), alignment: .trailing)
            }
            SymbolView(symbol: Symbols.chevronRight, size: 30, color: arrows)
        }
    }
}

extension SettingValue {
    var isToggle: Bool {
        if case .toggle = self { true } else { false }
    }
}

extension SettingRow {
    /// What VoiceOver reads as the row's name: the label, then the line under it (a custom row's badge and the profile's
    /// value).
    var accessibilityLabel: String {
        [label, customLine.map { _ in L("row_badge_custom") }, customLine ?? note].compactMap { $0 }.joined(separator: ", ")
    }

    /// What VoiceOver reads as the row's value: what the row shows beside its name, a switch as On or Off.
    var accessibilityValue: String {
        switch value {
        case .toggle(let on): L(on ? "common_on" : "common_off")
        case .choice(let label, _, _): label
        case let .slider(number, range, step, divisor, unit):
            SliderSpec(value: number, min: range.lowerBound, max: range.upperBound, step: step, divisor: divisor, unit: unit, minText: sliderMinText)
                .label(number)
        case .action(let label): label ?? ""
        case .text(let text): text
        case .appSettings(let language): language
        case .info(let text): text
        }
    }

    /// VoiceOver's swipe up and down steps the row as the arrows and a controller's left and right do
    /// (``View/accessibilityStepper(_:step:)``): a choice or a slider.
    var adjustable: Bool {
        switch value {
        case .choice, .slider: enabled
        default: false
        }
    }
}

/// A custom row's reset button, which the row's single accessibility element hides, as a named action.
private struct RowResetAction: ViewModifier {
    let onReset: (() -> Void)?

    func body(content: Content) -> some View {
        if let onReset {
            content.accessibilityAction(named: L("row_reset_to_profile")) { onReset() }
        } else {
            content
        }
    }
}

extension View {
    /// VoiceOver's swipe up and down on an [adjustable] row (a choice or a slider) steps it by +1 or -1 through [step].
    @ViewBuilder func accessibilityStepper(_ adjustable: Bool, step: @escaping (Int) -> Void) -> some View {
        if adjustable {
            accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(1)
                case .decrement: step(-1)
                @unknown default: break
                }
            }
        } else {
            self
        }
    }
}

extension View {
    /// The row's content enters at place [index] of the tab's staggered entrance (`staggerEntrance` of the content, not of
    /// the row: the plate stays put); no entrance for nil.
    @ViewBuilder func entering(_ index: Int?) -> some View {
        if let index { staggerEntrance(index: index) } else { self }
    }
}

/// The on/off switch (`MotionSwitch` of the settings): 74 × 42, a veil when off, the main color into the secondary when
/// on, the knob springing across (420 ms, the prototype's spring) while the track and the knob's color fade (280 ms).
private struct SettingSwitch: View {
    let on: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion

    var body: some View {
        let width = 74.0, height = 42.0, knob = height - 12
        let fade = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000)
        ZStack(alignment: .leading) {
            Capsule().fill(colors.surface3.color).opacity(on ? 0 : 1).animation(fade, value: on)
            Capsule().fill(LinearGradient(colors: [colors.accent.color, colors.accent2.color], startPoint: .leading, endPoint: .trailing))
                .opacity(on ? 1 : 0)
                .animation(fade, value: on)
            Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1))
            Circle()
                .fill((on ? colors.onAccent : colors.text2).color)
                .animation(fade, value: on)
                .frame(width: stage.px(knob), height: stage.px(knob))
                .offset(x: stage.px(6 + (on ? width - height : 0)))
                .animation(reduceMotion ? nil : Motion.spring(Motion.focus), value: on)
        }
        .frame(width: stage.px(width), height: stage.px(height))
    }
}

/// A slider's track and value (`RowValue.Slider` of DELOS for Android): a 220 px track (scaled on a compact stage) filled with
/// the main into the secondary color over 160 ms, the knob that grows by 18 % on the focused row inside a soft halo, the number
/// with its unit. Touch: a tap or a drag on the track sets the value, which is kept when the finger lifts.
private struct SettingSlider: View {
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let divisor: Int
    let unit: String
    /// The text at the minimum instead of the number ("0 % (off)").
    var minText: String? = nil
    let focused: Bool
    let onChange: (Int) -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion
    @State private var dragging: Int?

    /// `Motion.KNOB_FOCUS_SCALE`.
    private static let knobFocusScale = 1.18

    var body: some View {
        let number = dragging ?? value
        let span = Double(max(range.upperBound - range.lowerBound, 1))
        let fraction = min(max(Double(number - range.lowerBound) / span, 0), 1)
        let track = 220.0 * stage.compactScale
        HStack(spacing: stage.px(12)) {
            touchable(ZStack(alignment: .leading) {
                Capsule().fill(colors.surface3.color).frame(height: stage.px(10))
                Capsule()
                    .fill(LinearGradient(colors: [colors.accent.color, colors.accent2.color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: stage.px(track * fraction), height: stage.px(10))
                // The knob (radius 14) inside a halo of 6 more, which exists only while the row is focused; both grow together
                let scale = focused ? Self.knobFocusScale : 1
                ZStack {
                    if focused { Circle().fill(colors.accent3.opacity(0.4).color).frame(width: stage.px(40), height: stage.px(40)) }
                    Circle().fill(.black.opacity(0.3)).frame(width: stage.px(28), height: stage.px(28)).offset(y: stage.px(3 / scale))
                    Circle().fill(colors.text.color).frame(width: stage.px(28), height: stage.px(28))
                }
                .frame(width: stage.px(40), height: stage.px(40))
                .scaleEffect(scale)
                .animation(reduceMotion ? nil : Motion.spring(Motion.focus), value: focused)
                .offset(x: stage.px(track * fraction - 20))
            }
            .frame(width: stage.px(track), height: stage.px(48))
            .contentShape(Rectangle()), width: stage.px(track))
            .animation(dragging == nil && !reduceMotion ? Motion.out(160) : nil, value: number)
            Text(label(number))
                .font(DelosFonts.figtree(stage.tpx(23)))
                .foregroundStyle(colors.text2.color)
                .lineLimit(1)
                .frame(width: stage.px(stage.compact ? 130 : 160), alignment: .trailing)
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
        if number == range.lowerBound, let minText { return minText }
        return SliderSpec(value: number, min: range.lowerBound, max: range.upperBound, step: step, divisor: divisor, unit: unit).label(number)
    }
}

/// What the settings screen places, in stage pixels (`SettingsLayout` of DELOS for Android).
enum SettingsLayout {
    static let titleX = 150.0, tabsY = 206.0, listTop = 312.0
    /// Under this stage width the labelled tabs do not fit: only the selected tab keeps its label.
    static let fullTabsMinWidth = 1760.0
    /// A compact stage: the side margin floor, the tab row 24 px under the status bar and the list under it.
    static let compactMargin = 48.0, compactTabsY = 128.0, compactListTop = 202.0
    /// What a section's heading takes above its first row.
    static let sectionHeading = 44.0
    /// A compact row's height.
    static let compactRow = 80.0
    /// The tab row's height, the room between its R1 badge and the compact search circle (the circle's focus growth, its ring and
    /// 12 px), and what the compact search keeps at the right of its field for the count of the results.
    static let tabsHeight = 66.0, searchGap = 26.0, searchCountRoom = 300.0

    /// The compact search circle: the tab row's height scaled, a 64 px target at least.
    static func searchSize(_ stage: Stage) -> Double { max(tabsHeight * stage.compactScale, 64) }
    /// The list's edge fades; the compact list's are shorter, so the focused plate's glow ends above them.
    static let fadeTop = 14.0, fadeBottom = 90.0, compactFadeTop = 24.0, compactFadeBottom = 40.0

    /// The side margin of the screen: ``titleX`` on every shape but the compact one, where it is the 48 px floor plus the display
    /// cutout, the same at both sides (`SettingsLayout.margin`).
    static func margin(_ stage: Stage) -> Double { stage.compact ? compactMargin + max(stage.safe.leading, stage.safe.trailing) : titleX }

    /// The height of a list's tallest row on this stage: its least height (120 for a row with impact chips), or its two lines plus
    /// its scaled padding when that is more. The dock under the list leaves room for three of them (`SettingsLayout.tallRow`).
    static func tallRow(_ stage: Stage) -> Double { max(120 * stage.compactScale, 64.2 * stage.textScale + 28 * stage.compactScale) }

    /// The room kept free at the bottom for the hint bar, which grows with the interface scale ([scale]: 1 = 100 %).
    static func bottom(scale: Double) -> Double { 96 + (scale - 1) * 92 }
}

/// The help dock under a compact settings list (`HelpDockLayout` of DELOS for Android).
enum HelpDockLayout {
    static let minHeight = 210.0, maxHeight = 270.0
    /// A stage shorter than this trades dock height for list rows, down to ``shortMinHeight``.
    static let shortStage = 800.0, shortMinHeight = 168.0, rowPeek = 30.0
    static let listGap = 16.0, bodyGap = 14.0, rowGap = 10.0
    static let padX = 24.0, padY = 14.0, disc = 48.0, titleGap = 14.0, legendGap = 24.0, fade = 36.0

    /// About a quarter of the stage's height.
    static func height(stageHeight: Double) -> Double { min(max(stageHeight * 0.25, minHeight), maxHeight) }

    /// The dock under a list whose first row may start at [rowsTop], over the hint bar's [bottom]: the quarter of the
    /// stage less what three whole rows [rowHeight] high need above it, never under ``minHeight`` (a short stage: two
    /// rows and a peek of the third, down to ``shortMinHeight``).
    static func height(stageHeight: Double, rowsTop: Double, bottom: Double, rowHeight: Double) -> Double {
        if stageHeight < shortStage {
            let twoRowsAndPeek = 2 * rowHeight + 2 * rowGap + rowPeek
            return max(min(height(stageHeight: stageHeight), stageHeight - rowsTop - bottom - listGap - twoRowsAndPeek), shortMinHeight)
        }
        let threeRows = 3 * rowHeight + 2 * rowGap
        return max(min(height(stageHeight: stageHeight), stageHeight - rowsTop - bottom - listGap - threeRows), minHeight)
    }
}

/// The help under a compact list: the focused row's icon on an accent disc and its name, over the help, which scrolls
/// by itself when it is long.
private struct CompactHelpDock: View {
    let tab: SettingsTab
    let row: SettingRow?
    let appearance: Appearance
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @State private var titleWidth = 0.0
    @State private var legendWidth = 0.0
    @State private var innerWidth = 0.0

    /// Whether the legend sits at the right of the name (`legendInHeader`); otherwise it goes into the body.
    private var legendInHeader: Bool {
        row?.impact != nil && stage.px(HelpDockLayout.disc + HelpDockLayout.titleGap + HelpDockLayout.legendGap) + titleWidth + legendWidth <= innerWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: stage.px(HelpDockLayout.bodyGap)) {
            HStack(spacing: 0) {
                ZStack {
                    Circle().fill(colors.accent.color)
                    SymbolView(symbol: row?.icon ?? tab.icon, size: 28, color: colors.onAccent, filled: true)
                }
                .frame(width: stage.px(HelpDockLayout.disc), height: stage.px(HelpDockLayout.disc))
                Text(row?.label ?? tab.label)
                    .font(DelosFonts.unbounded(stage.tpx(22)))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, stage.px(HelpDockLayout.titleGap))
                    .background {
                        Text(row?.label ?? tab.label).font(DelosFonts.unbounded(stage.tpx(22))).fixedSize().hidden()
                            .onGeometryChange(for: Double.self) { $0.size.width } action: { titleWidth = $0 }
                    }
                if legendInHeader { ImpactLegend(sentence: false).padding(.leading, stage.px(HelpDockLayout.legendGap)) }
            }
            .frame(height: stage.px(HelpDockLayout.disc))
            .background {
                ImpactLegend(sentence: false).fixedSize().hidden()
                    .onGeometryChange(for: Double.self) { $0.size.width } action: { legendWidth = $0 }
                    .frame(width: 0, height: 0)
            }
            AutoScrollingHelp(identity: "\(row?.id ?? String(describing: tab)):\(row?.help ?? tab.help)", edgeFade: HelpDockLayout.fade) {
                VStack(alignment: .leading, spacing: stage.px(HelpDockLayout.rowGap)) {
                    Text(row?.help ?? tab.help)
                        .font(DelosFonts.figtree(stage.tpx(21)))
                        .lineSpacing(stage.tpx(21 * 0.45))
                        .foregroundStyle(colors.text2.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if row?.enabled == false {
                        Text(L("settings_screen_unavailable"))
                            .font(DelosFonts.figtree(stage.tpx(18)))
                            .foregroundStyle(colors.text3.color)
                    }
                    if let text = row?.value.heldText {
                        Text(text)
                            .font(DelosFonts.figtree(stage.tpx(22)))
                            .lineSpacing(stage.tpx(22 * 0.3))
                            .foregroundStyle(colors.accent.color)
                    }
                    HelpExtras(row: row, appearance: appearance)
                    // The legend goes into the body when the header has no room for it
                    if row?.impact != nil {
                        if !legendInHeader { ImpactLegend(sentence: false) }
                        ImpactLegendSentence()
                    }
                }
            }
        }
        .onGeometryChange(for: Double.self) { $0.size.width } action: { innerWidth = $0 }
        .padding(.horizontal, stage.px(HelpDockLayout.padX))
        .padding(.vertical, stage.px(HelpDockLayout.padY))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            GlassShape(RoundedRectangle(cornerRadius: stage.px(28)), tint: colors.surface, role: .panel)
                .overlay(RoundedRectangle(cornerRadius: stage.px(28)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
    }
}

/// The glass panel on the right: the focused row's icon on an accent disc, its name and its help (the tab's own when no
/// row is focused). Long help scrolls by touch.
private struct DescriptionPanel: View {
    let tab: SettingsTab
    let row: SettingRow?
    let appearance: Appearance
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
                    // A row that opens a dialog shows what it holds (`RowValue.Text`) in the accent color
                    if let text = row?.value.heldText {
                        Text(text)
                            .font(DelosFonts.figtree(stage.tpx(22)))
                            .lineSpacing(stage.tpx(22 * 0.3))
                            .foregroundStyle(colors.accent.color)
                    }
                    HelpExtras(row: row, appearance: appearance)
                }
            }
            // What the three chips of the focused row mean
            if row?.impact != nil { ImpactLegend() }
        }
        .padding(stage.px(44))
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            // The same gentle frosted glass as Android's `backdropBlur(haze, 8, surface)`: a panel
            GlassShape(RoundedRectangle(cornerRadius: stage.px(34)), tint: colors.surface, role: .panel)
                .overlay(RoundedRectangle(cornerRadius: stage.px(34)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
    }
}

/// What the help of a few rows shows besides its text: the palette's three colors (main, secondary, accent), and for the rows
/// that change the app background a preview of it, as it looks with the current blur and opacity (`GAME_BACKGROUND_ROWS`).
private struct HelpExtras: View {
    let row: SettingRow?
    let appearance: Appearance
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        if row?.id == AppearanceForm.palette { swatches }
        if let id = row?.id, [AppearanceForm.heroBackground, AppearanceForm.heroBlur, AppearanceForm.heroOpacity].contains(id) {
            BackgroundPreview(appearance: appearance)
        }
    }

    private var swatches: some View {
        HStack(spacing: stage.px(16)) {
            ForEach([(colors.accent, L("settings_screen_palette_main")), (colors.accent2, L("settings_screen_palette_secondary")),
                     (colors.accent3, L("settings_screen_palette_accent"))], id: \.1) { color, name in
                VStack(spacing: stage.px(8)) {
                    RoundedRectangle(cornerRadius: stage.px(18)).fill(color.color)
                        .overlay(RoundedRectangle(cornerRadius: stage.px(18)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                        .frame(width: stage.cpx(120), height: stage.cpx(72))
                    Text(name)
                        .font(DelosFonts.figtree(stage.tpx(18)))
                        .foregroundStyle(colors.text2.color)
                }
            }
        }
    }
}

/// The app background as the rows that change it show it (the lens of the hero, rendered off the main thread): 150 px high, the
/// game background at its opacity over the panel color, with the row's title across it.
private struct BackgroundPreview: View {
    let appearance: Appearance
    @Environment(HomeArt.self) private var homeArt
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @State private var rendered: CGImage?

    var body: some View {
        let area = HeroArea.of(stageWidth: stage.width, stageHeight: stage.height)
        let hero = homeArt.hero
        ZStack {
            colors.bg2.color
            if appearance.heroBackground, let hero {
                Group {
                    if hero.image != nil {
                        if let rendered { Image(decorative: rendered, scale: 1).resizable().scaledToFill() }
                    } else {
                        PlaceholderArt(hue: hero.hue, hue2: hero.hue2, icon: hero.icon, glyphSize: 100)
                    }
                }
                .opacity(Double(appearance.heroOpacity) / 100)
            }
            Text(L("settings_native_hero_background_title"))
                .font(DelosFonts.figtree(stage.tpx(20), .semibold))
                .foregroundStyle(colors.text.color)
        }
        .frame(maxWidth: .infinity)
        .frame(height: stage.cpx(150))
        .clipShape(RoundedRectangle(cornerRadius: stage.px(20)))
        .task(id: "\(hero?.id ?? "")/\(appearance.heroBlur)/\(area.width)x\(area.height)") {
            rendered = nil
            if let hero { rendered = await homeArt.background(hero, blur: appearance.heroBlur, area: area) }
        }
    }
}

extension View {
    /// A tap on this part of a row's value changes the row by itself (+1: a switch flips); the hit area is about 44 points. No
    /// effect when [onStep] is nil, and on tvOS, which has no touch.
    @ViewBuilder func touchStep(_ onStep: ((Int) -> Void)?) -> some View {
        #if os(tvOS)
        self
        #else
        if let onStep {
            modifier(TouchStepArea(onStep: onStep))
        } else {
            self
        }
        #endif
    }
}

private struct TouchStepArea: ViewModifier {
    let onStep: (Int) -> Void
    @Environment(\.stage) private var stage

    func body(content: Content) -> some View {
        content
            .padding(stage.px(24))
            .contentShape(Rectangle())
            .pressTap { onStep(1) }
            .padding(-stage.px(24))
    }
}
