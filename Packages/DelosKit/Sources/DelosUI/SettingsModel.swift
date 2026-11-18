import DelosCore
import DelosData
import DelosInput
import enum DelosMedia.FramePacing
import enum DelosInput.ShortcutButton
import Foundation

/// A tab of Settings (`SettingsTab` of DELOS for Android), in Android's order: Stream, Display, Audio, Controls,
/// Appearance (``AppearanceForm``), Covers (``CoversForm``: SteamGridDB), Devices (the default PC, skipping the start
/// screen, the paired PCs and pairing a new one) and About. The rows of the preference catalog are
/// ``SettingsCatalog``; the shell's own rows come from their forms.
enum SettingsTab: CaseIterable, Hashable, Sendable {
    case stream, display, audio, controls, appearance, covers, devices, about

    /// Every tab has rows on every platform (About has at least the version).
    static let availableCases: [SettingsTab] = allCases

    var label: String {
        switch self {
        case .stream: L("settings_tab_stream")
        case .display: L("settings_tab_display")
        case .audio: L("settings_tab_audio")
        case .controls: L("settings_tab_controls")
        case .appearance: L("settings_tab_appearance")
        case .covers: L("settings_tab_covers")
        case .devices: L("settings_tab_devices")
        case .about: L("settings_tab_about")
        }
    }

    var icon: String {
        switch self {
        case .stream: Symbols.cast
        case .display: Symbols.monitor
        case .audio: Symbols.graphicEq
        case .controls: Symbols.sportsEsports
        case .appearance: Symbols.appearance
        case .covers: Symbols.photoLibrary
        case .devices: Symbols.desktopWindows
        case .about: Symbols.info
        }
    }

    /// What the description panel says while no row of the tab is focused.
    var help: String {
        switch self {
        case .stream: L("settings_tab_stream_description")
        case .display: L("settings_tab_display_description")
        case .audio: L("settings_tab_audio_description")
        case .controls: L("settings_tab_controls_description")
        case .appearance: L("settings_tab_appearance_description")
        case .covers: L("settings_tab_covers_description")
        case .devices: L("settings_tab_devices_description")
        case .about: L("settings_tab_about_description")
        }
    }

    /// The tab [direction] steps away (L1 / R1), wrapping around.
    func step(_ direction: Int) -> SettingsTab {
        let all = Self.availableCases
        guard let index = all.firstIndex(of: self) else { return all[0] }
        return all[((index + direction) % all.count + all.count) % all.count]
    }
}

/// The value side of a settings row (`RowValue` of DELOS for Android).
enum SettingValue: Equatable {
    case toggle(Bool)
    /// [label] of the current value; [options] the values a tap lists; [selected] the current one among them (nil: the
    /// stored value is not offered on this device).
    case choice(label: String, options: [String], selected: Int?)
    case slider(value: Int, range: ClosedRange<Int>, step: Int, divisor: Int, unit: String)
    /// Opens something (a screen, a dialog) or runs it; [label] is shown before the chevron (the API key's "Added").
    case action(label: String?)
    /// A value typed into a dialog (`RowValue.Text`): the custom resolution, bitrate and refresh rate.
    case text(String)
    /// Shows the effective app language and opens its system Settings page, not an in-app picker.
    case appSettings(language: String)
    /// Shows a fact and does nothing (`RowValue.Info` of DELOS for Android): the app's origin.
    case info(String)
}

extension SettingValue {
    /// What a row that opens a dialog holds (`RowValue.Text`): the API key's state, a typed value.
    var heldText: String? {
        switch self {
        case .action(let label): label
        case .text(let value): value
        default: nil
        }
    }
}

/// One row of Settings: the key of the same setting in DELOS for Android, where it is, what it shows and its help.
struct SettingRow: Identifiable, Equatable {
    let id: String
    let tab: SettingsTab
    let section: String
    let icon: String
    let label: String
    let value: SettingValue
    /// The description panel's text: the chosen value and what it means, then what the setting does
    /// (`SettingsHelp.details`); the bitrate row adds the link guidance (``LinkGuidanceRows``).
    var help: String
    /// A color dot before a choice's value (`RowValue.Choice.swatch` of DELOS for Android: the palette's main hue).
    var swatch: RGBA? = nil
    /// False: the row is dimmed, its value cannot change and the panel says it is unavailable (`SettingsItem.enabled`).
    var enabled = true
    /// A line under the label (`SettingRow`'s `description`: the side menu's hidden-games count).
    var note: String? = nil
    /// What the profile has ("Profile: 225 Mbps") on a row that the app overrides (`RowOverride.profileLine` of DELOS
    /// for Android): the row then carries the CUSTOM badge and this line instead of its note.
    var customLine: String? = nil
    /// What the current value costs (GPU, latency, network): three chips on their own line above the label, which the row
    /// reserves room for (`SettingsItem.impact`).
    var impact: SettingImpact? = nil
    /// A slider's text at its minimum instead of the number (`RowValue.Slider.minText`: Gyro smoothing's "0 % (off)").
    var sliderMinText: String? = nil
}

extension Array where Element == SettingRow {
    /// The rows with each section's rows together, the sections in the order they first appear (Android groups a tab's
    /// rows by section, so a category split across tabs still has one heading per tab).
    func groupedBySection() -> [SettingRow] {
        var order: [String] = []
        var bySection: [String: [SettingRow]] = [:]
        for row in self {
            if bySection[row.section] == nil { order.append(row.section) }
            bySection[row.section, default: []].append(row)
        }
        return order.flatMap { bySection[$0] ?? [] }
    }
}

/// What this device offers Settings (`SettingsCapabilities` of DELOS for Android).
struct StreamDevice: Equatable, Sendable {
    var pixelWidth: Int
    var pixelHeight: Int
    var maxFramesPerSecond: Int
    /// The formats VideoToolbox decodes in hardware (``DecoderSupport``).
    var decodable: VideoFormats
    /// The display shows HDR (``HDRDisplay``).
    var hdrDisplay = false
    /// The safe area in pixels where it is smaller than the display (a notch or the Dynamic Island): the resolutions
    /// then have a fullscreen variant, as Android's for a display cutout.
    var safePixelWidth: Int? = nil
    var safePixelHeight: Int? = nil
    /// A touchscreen: the on-screen controls and their key layouts (Android's touchscreen-only categories).
    var touchscreen = false
    /// The device's own gyroscope and accelerometer (Core Motion): the built-in motion rows.
    var deviceMotion = false
    /// A vibration motor the app can drive (Core Haptics): the device rumble rows and the rumble feel.
    var haptics = false
    /// Picture in Picture for the stream.
    var pictureInPicture = false
    /// A GPU upscaler for the stream (Metal on every supported device).
    var upscaler = true
    /// MetalFX's spatial and temporal scalers on this GPU (``DelosMedia/MetalFXSupport``); a mode without its scaler runs
    /// as Sharpen only.
    var metalFXSpatial = true
    var metalFXTemporal = true
    /// A PyroWave decoder.
    var pyroWave = false

    /// Whether the MetalFX scaler of the stored upscaler mode `value` runs here (Sharpen only needs none).
    func metalFXRuns(_ value: String) -> Bool {
        switch value {
        case "standard": metalFXSpatial
        case "temporal": metalFXTemporal
        default: true
        }
    }

    /// HDR streaming needs a hardware HEVC Main10 decoder and an HDR display, both as on Android
    /// (`SettingsCapabilities`: no HDR10 display or no Main10 hides the row).
    var supportsHDR: Bool { hdrDisplay && decodable.contains(.hevcMain10) }

    /// The display's resolution while the profile has not chosen one.
    var defaultResolution: StreamResolution { .forDisplay(pixelWidth: pixelWidth, pixelHeight: pixelHeight) }

    /// The catalog rows this device does not have (`SettingsCapabilities.hidden` plus the touchscreen-only categories).
    func hides(_ spec: CatalogSpec) -> Bool {
        if spec.phoneOnly { return true }
        if !touchscreen, ["category_onscreen_controls", "category_special_key_layout"].contains(spec.category) { return true }
        switch spec.id {
        case SettingKey.upscaler.rawValue, SettingKey.upscalerMode.rawValue, SettingKey.upscalerSharpness.rawValue,
             SettingKey.upscalerSupersampling.rawValue:
            return !upscaler && !pyroWave
        case SettingKey.gamepadMotionFallback.rawValue, SettingKey.forceDeviceMotion.rawValue: return !deviceMotion
        case SettingKey.enablePip.rawValue: return !pictureInPicture
        case "checkbox_vibrate_fallback", "seekbar_vibrate_fallback_strength", "checkbox_enable_device_rumble", "list_rumble_feel",
             SettingKey.vibrateOsc.rawValue, SettingKey.vibrateKeyboard.rawValue:
            return !haptics
        default: return false
        }
    }
}

/// The rows of the preference catalog over one profile's ``StreamSettings`` (Stream, Display, Audio, Controls and the
/// catalog's Appearance rows), the profile's own shell rows (stream menu swipe, on-screen controls opacity, statistics
/// position), and the changes the controller and touch make to them. Everything a row shows and does is here; the view
/// only draws it.
struct StreamSettingsForm: Equatable {
    var settings: StreamSettings
    let device: StreamDevice
    /// Whether the bitrate is chosen here (an app's bitrate override; nil: it is whenever the settings have one), which
    /// decides if a codec change keeps it for the codec left.
    var ownsBitrate: Bool? = nil

    init(settings: StreamSettings, device: StreamDevice) {
        // Choices the device does not offer are replaced when the screen opens, as on Android
        self.settings = Self.normalized(settings, device: device)
        self.device = device
    }

    private static func normalized(_ settings: StreamSettings, device: StreamDevice) -> StreamSettings {
        StreamChoices.normalized(
            settings, displayWidth: device.pixelWidth, displayHeight: device.pixelHeight,
            maxFramesPerSecond: device.maxFramesPerSecond, decodable: device.decodable,
            safeWidth: device.safePixelWidth, safeHeight: device.safePixelHeight, pyroWave: device.pyroWave)
    }

    static let resolution = "list_resolution"
    static let frameRate = "list_fps"
    static let bitrate = "seekbar_bitrate_kbps"
    static let codec = "video_format"
    static let hdr = "checkbox_enable_hdr"
    static let framePacing = "frame_pacing"
    static let hostAudio = "checkbox_host_audio"
    static let perfOverlay = "checkbox_enable_perf_overlay"
    static let perfOverlayLite = "checkbox_enable_perf_overlay_lite"
    static let oscOpacity = "seekbar_osc_opacity"
    static let statsPosition = SettingKey.statsPosition.rawValue
    /// The profile's shell rows (`nativeSettings`): stream menu buttons and swipe, on-screen controls opacity,
    /// statistics position.
    static let menuButtons = "ui_stream_menu_buttons"
    static let menuSwipe = "ui_stream_menu_swipe"
    /// The buttons that open the stream menu, none by default.
    var menuButtonsChosen: Set<ShortcutButton> { ShortcutButton.parse(settings.streamMenuButtons) }

    /// The buttons the recording returned.
    mutating func setMenuButtons(_ buttons: Set<ShortcutButton>) {
        settings.streamMenuButtons = ShortcutButton.stored(buttons)
    }

    /// The HDR row shows where HDR can work, and also while `hdr` is stored as on where it cannot (a profile from
    /// another device, another monitor): the row is then the way to switch it off.
    private var showsHDRRow: Bool { device.supportsHDR || settings.hdr }

    /// Every row of [tab]: the shell's own rows first, then the catalog's, as Android lists them.
    func rows(_ tab: SettingsTab) -> [SettingRow] { nativeRows(tab) + catalogRows(tab) }

    /// The catalog rows of [tab] in Android's order, without the ones this device does not have, with their cost chips.
    func catalogRows(_ tab: SettingsTab) -> [SettingRow] {
        let context = impactContext
        return SettingsCatalog.all.filter { $0.tab == tab && visible($0) }.compactMap { spec in
            guard var row = row(spec) else { return nil }
            row.impact = settingImpact(id: row.id, context: context)
            return row
        }
    }

    /// Every catalog row of every tab, by id (the App settings screen picks its rows from them).
    func catalogRow(_ id: String) -> SettingRow? {
        guard let spec = SettingsCatalog.spec(id), visible(spec), var row = row(spec) else { return nil }
        row.impact = settingImpact(id: row.id, context: impactContext)
        return row
    }

    private func visible(_ spec: CatalogSpec) -> Bool {
        guard !device.hides(spec) else { return false }
        return spec.id != Self.hdr || showsHDRRow
    }

    // MARK: The shell's own rows of the profile

    /// The stream menu's rows of Settings → Controls (`ui_stream_menu_buttons`, `ui_stream_menu_swipe`).
    func streamMenuRows(_ tab: SettingsTab) -> [SettingRow] {
        tab == .controls ? [menuButtonsRow, menuSwipeRow] : []
    }

    func nativeRows(_ tab: SettingsTab) -> [SettingRow] {
        switch tab {
        case .controls:
            // The other on-screen controls settings are phone-only; the opacity and the preview show wherever there is a
            // touchscreen
            streamMenuRows(tab) + (device.touchscreen ? [oscOpacityRow, oscPreviewRow] : [])
        case .display: [statsPositionRow]
        default: []
        }
    }

    /// The on-screen controls' opacity (`OscOpacity`): 0 to 100 % in steps of 5, the stream menu's More slider too.
    static let oscOpacityStep = 5

    private var oscOpacityRow: SettingRow {
        SettingRow(
            id: Self.oscOpacity, tab: .controls, section: L("category_on_screen_controls_settings"), icon: Symbols.opacity,
            label: L("settings_native_osc_opacity_title"),
            value: .slider(value: settings.int(.oscOpacity), range: 0...100, step: Self.oscOpacityStep, divisor: 1, unit: " %"),
            help: L("summary_osc_opacity"))
    }

    /// "Preview on-screen controls" (Android's Debug info → On-screen controls → `osc_preview`; DELOS for Apple has no Debug
    /// screen, so it sits with the on-screen controls' opacity): the controls without a stream (``OnScreenControlsPreview``).
    static let oscPreview = "osc_preview"

    private var oscPreviewRow: SettingRow {
        SettingRow(
            id: Self.oscPreview, tab: .controls, section: L("category_on_screen_controls_settings"), icon: Symbols.joystick,
            label: L("debug_osc_label"), value: .action(label: nil), help: L("debug_osc_description"))
    }

    static func statsLabel(_ position: StatsPosition) -> String {
        switch position {
        case .topLeft: L("settings_native_stats_top_left")
        case .topRight: L("settings_native_stats_top_right")
        case .bottomLeft: L("settings_native_stats_bottom_left")
        case .bottomRight: L("settings_native_stats_bottom_right")
        }
    }

    private static func statsHelp(_ position: StatsPosition) -> String {
        switch position {
        case .topLeft: L("settings_native_help_stats_top_left")
        case .topRight: L("settings_native_help_stats_top_right")
        case .bottomLeft: L("settings_native_help_stats_bottom_left")
        case .bottomRight: L("settings_native_help_stats_bottom_right")
        }
    }

    private var statsPositionRow: SettingRow {
        let position = settings.statsPosition
        let label = Self.statsLabel(position)
        return SettingRow(
            id: Self.statsPosition, tab: .display, section: L("settings_native_section_statistics"), icon: Symbols.statsPosition,
            label: L("settings_native_stats_position_title"),
            value: .choice(label: label, options: StatsPosition.allCases.map(Self.statsLabel), selected: StatsPosition.allCases.firstIndex(of: position)),
            help: AppearanceForm.details(value: label, explanation: Self.statsHelp(position), about: L("settings_native_stats_position_description")))
    }

    // MARK: The values of the typed rows

    /// The resolutions: the display's own (nil: Android has no such row; it is the default here), the presets, the native
    /// ones and the custom one.
    var resolutionOptions: [(value: StreamResolution?, label: String)] {
        [(nil, L("settings_screen_dot_join", L("videoformat_auto"), device.defaultResolution.text))]
            + StreamChoices.resolutions(
                displayWidth: device.pixelWidth, displayHeight: device.pixelHeight, safeWidth: device.safePixelWidth,
                safeHeight: device.safePixelHeight, custom: StreamChoices.customResolution(settings)
            ).map { choice in
                switch choice {
                case .preset(let r): (r, Self.presetLabel(r) ?? r.text)
                case .native(let r, let portrait, let fullscreen): (r, Self.nativeLabel(r, portrait: portrait, fullscreen: fullscreen))
                case .custom(let r): (r, L("settings_resolution_custom", r.text))
                }
            }
    }

    private static func nativeLabel(_ r: StreamResolution, portrait: Bool, fullscreen: Bool) -> String {
        switch (fullscreen, portrait) {
        case (true, true): L("settings_resolution_native_fullscreen_portrait", r.text)
        case (true, false): L("settings_resolution_native_fullscreen", r.text)
        case (false, true): L("settings_resolution_native_portrait", r.text)
        case (false, false): L("settings_resolution_native", r.text)
        }
    }

    var frameRateOptions: [(value: Int, label: String)] {
        StreamChoices.frameRates(
            maxFramesPerSecond: device.maxFramesPerSecond, unlocked: settings.bool(.unlockFps),
            custom: StreamChoices.customFrameRate(settings)
        ).map { choice in
            switch choice {
            case .preset(let fps): (fps, Self.presetLabel(fps: fps))
            case .native(let fps): (fps, L("settings_fps_native", fps))
            case .custom(let fps, let text): (fps, L("settings_fps_custom", text))
            }
        }
    }

    var codecOptions: [(value: VideoCodec, label: String)] {
        VideoCodec.choices(decodable: device.decodable, pyroWave: device.pyroWave).map { ($0, Self.codecLabel($0)) }
    }

    private static func presetLabel(_ r: StreamResolution) -> String? {
        switch StreamResolution.presets.firstIndex(of: r) {
        case 0: L("resolution_360p")
        case 1: L("resolution_480p")
        case 2: L("resolution_720p")
        case 3: L("resolution_1080p")
        case 4: L("resolution_1440p")
        case 5: L("resolution_4k")
        default: nil
        }
    }

    private static func presetLabel(fps: Int) -> String {
        switch fps {
        case 30: L("fps_30")
        case 90: L("fps_90")
        case 120: L("fps_120")
        default: L("fps_60")
        }
    }

    /// What the chosen codec means (`help_video_format_<value>`).
    private static func codecHelp(_ codec: VideoCodec) -> String {
        switch codec {
        case .automatic: L("help_video_format_auto")
        case .av1: L("help_video_format_forceav1")
        case .hevc: L("help_video_format_forceh265")
        case .h264: L("help_video_format_neverh265")
        case .pyroWave: L("help_video_format_pyrowave")
        }
    }

    static func codecLabel(_ codec: VideoCodec) -> String {
        switch codec {
        case .automatic: L("videoformat_auto")
        case .av1: L("videoformat_av1always")
        case .hevc: L("videoformat_hevcalways")
        case .h264: L("videoformat_h264always")
        case .pyroWave: L("videoformat_pyrowave")
        }
    }

    /// The resolution the next stream asks for.
    var effectiveResolution: StreamResolution { settings.resolution ?? device.defaultResolution }

    /// The bitrate the slider shows: the chosen one, else the default for the resolution and frame rate.
    var effectiveBitrate: Int { settings.bitrate(at: effectiveResolution) }

    /// The frame pacing modes in Android's order; Fast V-Sync not with PyroWave (`SettingsCapabilities.choices`).
    var framePacingOptions: [(value: FramePacing, label: String)] {
        let order: [FramePacing] = [.warp2, .warp, .latency, .balanced, .capFPS, .smoothness, .fastVSync]
        return order.filter { $0 != .fastVSync || settings.codec != .pyroWave }.map { ($0, Self.pacingLabel($0)) }
    }

    private static func pacingLabel(_ mode: FramePacing) -> String {
        switch mode {
        case .latency: L("pacing_latency")
        case .balanced: L("pacing_balanced")
        case .capFPS: L("pacing_balanced_alt")
        case .smoothness: L("pacing_smoothness")
        case .warp: L("pacing_warp")
        case .warp2: L("pacing_warp2")
        case .fastVSync: L("pacing_fast_vsync")
        }
    }

    private static func pacingHelp(_ mode: FramePacing) -> String {
        switch mode {
        case .latency: L("help_frame_pacing_latency")
        case .balanced: L("help_frame_pacing_balanced")
        case .capFPS: L("help_frame_pacing_cap_fps")
        case .smoothness: L("help_frame_pacing_smoothness")
        case .warp: L("help_frame_pacing_warp")
        case .warp2: L("help_frame_pacing_warp2")
        case .fastVSync: L("help_frame_pacing_fast_vsync")
        }
    }

    // MARK: Rows

    /// The row of [spec], nil for a row another part of the app builds (the language row, the rumble rows of
    /// ``typedRow(_:)``).
    private func row(_ spec: CatalogSpec) -> SettingRow? {
        let enabled = isEnabled(spec)
        let row: SettingRow?
        switch spec.kind {
        case .typed:
            row = typedRow(spec)
        case .toggle:
            row = SettingRow(
                id: spec.id, tab: spec.tab, section: spec.section, icon: spec.icon, label: spec.label,
                value: .toggle(spec.key.map(settings.bool) ?? false), help: details(spec, value: nil, explanation: nil))
        case .choice:
            let options = choices(spec)
            let current = spec.key.map(settings.text) ?? ""
            let selected = options.firstIndex { $0.value == current }
            let known = selected.map { options[$0] } ?? allChoices(spec).first { $0.value == current }
            let label = selected.map { options[$0].label } ?? L("settings_choice_unavailable", known?.label ?? current)
            row = SettingRow(
                id: spec.id, tab: spec.tab, section: spec.section, icon: spec.icon, label: spec.label,
                value: .choice(label: label, options: options.map(\.label), selected: selected),
                help: details(spec, value: known?.label, explanation: known?.help ?? Self.dynamicHelp(spec.id), unavailable: selected == nil))
        case let .slider(range, step, divisor, unit):
            row = SettingRow(
                id: spec.id, tab: spec.tab, section: spec.section, icon: spec.icon, label: spec.label,
                value: .slider(value: spec.key.map(settings.int) ?? range.lowerBound, range: range, step: step, divisor: divisor, unit: unit),
                help: details(spec, value: nil, explanation: nil),
                sliderMinText: spec.id == SettingKey.gyroSmoothing.rawValue ? L("settings_screen_gyro_off", 0) : nil)
        case .text:
            row = SettingRow(
                id: spec.id, tab: spec.tab, section: spec.section, icon: spec.icon, label: spec.label,
                value: .text(spec.key.map(settings.text) ?? ""), help: details(spec, value: nil, explanation: nil))
        case .action:
            row = SettingRow(
                id: spec.id, tab: spec.tab, section: spec.section, icon: spec.icon, label: spec.label,
                value: .action(label: nil), help: details(spec, value: nil, explanation: nil))
        }
        guard var row else { return nil }
        row.enabled = row.enabled && enabled
        return row
    }

    /// An explanation of the chosen value that no `help_<key>_<value>` text has (`SettingsHelp.choice`).
    private static func dynamicHelp(_ id: String) -> String? {
        id == "keyboard_axi_list" ? L("help_dynamic_keyboard_layout") : nil
    }

    /// The rows with a field of their own in ``StreamSettings``. The five rumble rows (`checkbox_enable_rumble`,
    /// `list_rumble_feel`, `checkbox_vibrate_fallback`, `checkbox_enable_device_rumble`, `seekbar_vibrate_fallback_strength`)
    /// belong to the rumble settings (`StreamSettings.rumble`), which build them in this slot; the language row is
    /// ``AppLanguageSetting``'s.
    private func typedRow(_ spec: CatalogSpec) -> SettingRow? {
        switch spec.id {
        case Self.resolution: resolutionRow(spec)
        case Self.frameRate: frameRateRow(spec)
        case Self.bitrate: bitrateRow(spec)
        case Self.codec: codecRow(spec)
        case Self.framePacing: framePacingRow(spec)
        case Self.hdr: toggleRow(spec, settings.hdr)
        case Self.hostAudio: toggleRow(spec, settings.playAudioOnHost)
        case Self.perfOverlay: toggleRow(spec, settings.statisticsOverlay.isShown)
        case Self.perfOverlayLite: toggleRow(spec, settings.statisticsOverlay == .compact)
        case Self.rumbleEnabled, Self.rumbleFeel, Self.rumbleFallback, Self.rumbleDevice, Self.rumbleStrength:
            rumbleRows.first { $0.id == spec.id }
        default: nil
        }
    }

    private func toggleRow(_ spec: CatalogSpec, _ on: Bool) -> SettingRow {
        SettingRow(
            id: spec.id, tab: spec.tab, section: spec.section, icon: spec.icon, label: spec.label, value: .toggle(on),
            help: details(spec, value: nil, explanation: nil))
    }

    private func resolutionRow(_ spec: CatalogSpec) -> SettingRow {
        let options = resolutionOptions
        let selected = options.firstIndex { $0.value == settings.resolution }
        let label = selected.map { options[$0].label } ?? L("settings_choice_unavailable", effectiveResolution.text)
        let explanation = L("help_dynamic_resolution", "\(effectiveResolution.width) × \(effectiveResolution.height)")
        return SettingRow(
            id: spec.id, tab: spec.tab, section: spec.section, icon: spec.icon, label: spec.label,
            value: .choice(label: label, options: options.map(\.label), selected: selected),
            help: details(spec, value: label, explanation: explanation, unavailable: selected == nil))
    }

    private func frameRateRow(_ spec: CatalogSpec) -> SettingRow {
        let options = frameRateOptions
        let selected = options.firstIndex { $0.value == settings.fps }
        let label = selected.map { options[$0].label } ?? L("settings_choice_unavailable", "\(settings.fps)")
        return SettingRow(
            id: spec.id, tab: spec.tab, section: spec.section, icon: spec.icon, label: spec.label,
            value: .choice(label: label, options: options.map(\.label), selected: selected),
            help: details(spec, value: label, explanation: L("help_dynamic_fps", "\(settings.fps)"), unavailable: selected == nil))
    }

    private func bitrateRow(_ spec: CatalogSpec) -> SettingRow {
        SettingRow(
            id: spec.id, tab: spec.tab, section: spec.section, icon: spec.icon, label: spec.label,
            value: .slider(
                value: effectiveBitrate, range: StreamSettings.bitrateRange, step: StreamSettings.bitrateStep, divisor: 1000,
                unit: CatalogSpec.unit(L("suffix_seekbar_bitrate_mbps"))),
            help: details(spec, value: nil, explanation: nil))
    }

    private func codecRow(_ spec: CatalogSpec) -> SettingRow {
        let options = codecOptions
        let selected = options.firstIndex { $0.value == settings.codec }
        let label = selected.map { options[$0].label } ?? L("settings_choice_unavailable", Self.codecLabel(settings.codec))
        return SettingRow(
            id: spec.id, tab: spec.tab, section: spec.section, icon: spec.icon, label: spec.label,
            value: .choice(label: label, options: options.map(\.label), selected: selected),
            help: details(spec, value: label, explanation: Self.codecHelp(settings.codec), unavailable: selected == nil))
    }

    /// "Not set" or the recorded buttons; the list clears them or records new ones, and a step records (the row's own
    /// value is never a choice of its list once buttons are set).
    private var menuButtonsRow: SettingRow {
        let buttons = menuButtonsChosen
        let label = buttons.isEmpty ? L("row_not_set") : StreamMenuButtonsText.label(buttons)
        return SettingRow(
            id: Self.menuButtons, tab: .controls, section: L("settings_native_section_stream_menu"), icon: Symbols.streamMenuButtons,
            label: L("settings_native_menu_buttons_title"),
            value: .choice(label: label, options: [L("row_not_set"), L("settings_native_menu_buttons_record")], selected: buttons.isEmpty ? 0 : nil),
            help: AppearanceForm.details(value: label, explanation: nil, about: L("settings_native_menu_buttons_description")))
    }

    private var menuSwipeRow: SettingRow {
        SettingRow(
            id: Self.menuSwipe, tab: .controls, section: L("settings_native_section_stream_menu"), icon: Symbols.swipeUp,
            label: L("settings_native_menu_swipe_title"), value: .toggle(settings.streamMenuSwipe),
            help: L("settings_native_menu_swipe_description"))
    }

    private func framePacingRow(_ spec: CatalogSpec) -> SettingRow {
        let options = framePacingOptions
        let selected = options.firstIndex { $0.value == settings.framePacing }
        let label = Self.pacingLabel(settings.framePacing)
        return SettingRow(
            id: spec.id, tab: spec.tab, section: spec.section, icon: spec.icon, label: spec.label,
            value: .choice(label: selected == nil ? L("settings_choice_unavailable", label) : label, options: options.map(\.label), selected: selected),
            help: details(spec, value: label, explanation: Self.pacingHelp(settings.framePacing), unavailable: selected == nil))
    }

    // MARK: Choices, availability and help

    /// Every value of a list row with its label, as the catalog has them.
    private func allChoices(_ spec: CatalogSpec) -> [CatalogChoice] {
        guard case .choice(let choices) = spec.kind else { return [] }
        // The classic array repeats one label for the five layouts: number them (`settings_layout_number`)
        if spec.id == SettingKey.keyLayout.rawValue {
            return choices.enumerated().map { CatalogChoice(value: $1.value, label: L("settings_layout_number", $0 + 1), help: $1.help) }
        }
        return choices
    }

    /// The values of a list row this device offers (`SettingsCapabilities.choices`).
    func choices(_ spec: CatalogSpec) -> [CatalogChoice] { allChoices(spec) }

    /// Whether the row can change (`StreamSettingsStore.enabled`): the rules between settings, then the dependency chain
    /// (`android:dependency`: the row it depends on is on, and so is that one's).
    func isEnabled(_ spec: CatalogSpec) -> Bool {
        let pyro = settings.codec == .pyroWave
        switch spec.id {
        // PyroWave has its own decoder; the hardware decoder's options do not apply
        case SettingKey.asyncDecode.rawValue, SettingKey.ultraLowLatency.rawValue: if pyro { return false }
        case SettingKey.lowLatencyFrameBalance.rawValue: if pyro || settings.framePacing == .fastVSync { return false }
        // 4:4:4 is PyroWave-only and never offered with HDR (the HDR path is 4:2:0)
        case SettingKey.pyrowaveChroma.rawValue: if !pyro || settings.hdr { return false }
        case SettingKey.upscaler.rawValue, SettingKey.upscalerMode.rawValue, SettingKey.upscalerSharpness.rawValue:
            if !device.upscaler && !pyro { return false }
        case SettingKey.upscalerSupersampling.rawValue:
            if !device.upscaler && !pyro { return false }
            // Sharpen only never scales, so there is no supersampling quality to choose
            if settings.text(.upscalerMode) == "sharpen" { return false }
        case SettingKey.gyroSmoothing.rawValue: if !gyroSourceOn { return false }
        default: break
        }
        var seen: Set<String> = []
        var parent = spec.dependency
        while let id = parent {
            guard seen.insert(id).inserted else { return false }
            guard let parentSpec = SettingsCatalog.spec(id) else { return true }
            guard dependencyValue(parentSpec) else { return false }
            parent = parentSpec.dependency
        }
        return true
    }

    /// Whether a gyroscope source is on, which Gyro smoothing acts on (`gyroSourceEnabled`): the gamepad's sensors
    /// (GameController reads them on every supported system) or the device's own.
    var gyroSourceOn: Bool { settings.bool(.gamepadMotionSensors) || settings.bool(.gamepadMotionFallback) }

    /// A row's value as a dependency sees it: on, or not empty.
    private func dependencyValue(_ spec: CatalogSpec) -> Bool {
        if spec.id == Self.perfOverlay { return settings.statisticsOverlay.isShown }
        guard let key = spec.key else { return true }
        switch settings.value(key) {
        case .bool(let on): return on
        case .text(let text): return !text.isEmpty
        case .int: return true
        }
    }

    /// The note that the other settings add to a row's help (`SettingsHelp.context`).
    private func contextNote(_ id: String) -> String? {
        let pyro = settings.codec == .pyroWave
        switch id {
        case Self.bitrate:
            return settings.pyroWaveRecommendedKbps(displayResolution: device.defaultResolution)
                .map { L("help_note_pyrowave_recommends", $0 / 1000) }
        case Self.framePacing where settings.framePacing == .fastVSync: return L("help_note_fast_vsync_lfr")
        case Self.framePacing where settings.bool(.lowLatencyFrameBalance): return L("help_note_lfr_balanced")
        case SettingKey.asyncDecode.rawValue, SettingKey.ultraLowLatency.rawValue, SettingKey.lowLatencyFrameBalance.rawValue:
            return pyro ? L("help_note_not_with_pyrowave") : nil
        case SettingKey.pyrowaveChroma.rawValue where !pyro: return L("help_note_needs_pyrowave")
        case SettingKey.pyrowaveChroma.rawValue where settings.hdr: return L("help_note_hdr_420")
        case SettingKey.upscalerMode.rawValue where !device.metalFXRuns(settings.text(.upscalerMode)):
            return L("help_note_metalfx_unavailable")
        case SettingKey.upscalerSupersampling.rawValue where settings.text(.upscalerMode) == "sharpen": return L("help_note_sharpen_only")
        default: return nil
        }
    }

    private func details(_ spec: CatalogSpec, value: String?, explanation: String?, unavailable: Bool = false) -> String {
        Self.details(value: value, explanation: explanation, unavailable: unavailable, note: contextNote(spec.id), about: spec.help)
    }

    /// `SettingsHelp.details`: the chosen [value] with its [explanation], the note that it is unavailable and the [note] the
    /// other settings add, a blank line, then what the setting does ([about]).
    static func details(value: String?, explanation: String?, unavailable: Bool, note: String? = nil, about: String?) -> String {
        let state = [
            value.flatMap { value in explanation.map { "\(value)\n\($0)" } },
            unavailable ? L("help_note_unavailable") : nil,
            note,
        ].compactMap { $0 }.joined(separator: "\n")
        return [state, about ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: Changes

    /// Left / right (A: +1) on row [id]: the next choice, wrapping around (`nextSettingChoice`), or [direction] steps of
    /// a slider landing on its grid; a toggle flips. False when nothing changed.
    @discardableResult
    mutating func step(_ id: String, by direction: Int) -> Bool {
        let before = settings
        switch id {
        case Self.resolution: settings.resolution = Self.next(settings.resolution, in: resolutionOptions.map(\.value), direction)
        case Self.frameRate: settings.fps = Self.next(settings.fps, in: frameRateOptions.map(\.value), direction)
        case Self.codec: setCodec(Self.next(settings.codec, in: codecOptions.map(\.value), direction))
        case Self.framePacing: settings.framePacing = Self.next(settings.framePacing, in: framePacingOptions.map(\.value), direction)
        case Self.bitrate: setBitrate(effectiveBitrate + direction * StreamSettings.bitrateStep)
        case Self.hdr where showsHDRRow: settings.hdr.toggle()
        case Self.hostAudio: settings.playAudioOnHost.toggle()
        case Self.perfOverlay: settings.statisticsOverlay = settings.statisticsOverlay.isShown ? .off : .full
        case Self.perfOverlayLite where settings.statisticsOverlay.isShown:
            settings.statisticsOverlay = settings.statisticsOverlay == .compact ? .full : .compact
        case Self.menuSwipe: settings.streamMenuSwipe.toggle()
        case Self.oscOpacity: setSlider(.oscOpacity, settings.int(.oscOpacity) + direction * Self.oscOpacityStep, step: Self.oscOpacityStep)
        case Self.statsPosition:
            settings.set(.statsPosition, .text(Self.next(settings.statsPosition, in: StatsPosition.allCases, direction).rawValue))
        default:
            guard let spec = SettingsCatalog.spec(id), let key = spec.key else { stepRumble(id, by: direction); break }
            switch spec.kind {
            case .toggle: settings.set(key, .bool(!settings.bool(key)))
            case .choice:
                let values = choices(spec).map(\.value)
                settings.set(key, .text(Self.next(settings.text(key), in: values, direction)))
            case let .slider(_, step, _, _): setSlider(key, settings.int(key) + direction * step, step: step)
            case .typed, .text, .action: break
            }
        }
        settled(after: before)
        return settings != before
    }

    /// A value picked from a choice row's list.
    mutating func pick(_ id: String, option index: Int) {
        let before = settings
        switch id {
        case Self.resolution: if resolutionOptions.indices.contains(index) { settings.resolution = resolutionOptions[index].value }
        case Self.frameRate: if frameRateOptions.indices.contains(index) { settings.fps = frameRateOptions[index].value }
        case Self.codec: if codecOptions.indices.contains(index) { setCodec(codecOptions[index].value) }
        case Self.framePacing: if framePacingOptions.indices.contains(index) { settings.framePacing = framePacingOptions[index].value }
        case Self.statsPosition: if StatsPosition.allCases.indices.contains(index) { settings.set(.statsPosition, .text(StatsPosition.allCases[index].rawValue)) }
        case Self.rumbleFeel where settings.rumble.enabled:
            if RumblePreset.allCases.indices.contains(index) { settings.rumble.applyPreset(RumblePreset.allCases[index]) }
        // "Not set"; "Record buttons" is the screen's (it opens the recording)
        case Self.menuButtons: if index == 0 { settings.streamMenuButtons = [] }
        default:
            guard let spec = SettingsCatalog.spec(id), let key = spec.key else { break }
            let options = choices(spec)
            if options.indices.contains(index) { settings.set(key, .text(options[index].value)) }
        }
        settled(after: before)
    }

    /// A slider's value set on its track by touch.
    mutating func slide(_ id: String, to value: Int) {
        switch id {
        case Self.bitrate: setBitrate(value)
        case Self.oscOpacity: setSlider(.oscOpacity, value, step: Self.oscOpacityStep)
        case Self.rumbleStrength: settings.rumble.deviceStrength = value
        default:
            guard let spec = SettingsCatalog.spec(id), let key = spec.key,
                  case let .slider(_, step, _, _) = spec.kind else { return }
            setSlider(key, value, step: step)
        }
    }

    /// What follows a change, as Android's store writes it: PyroWave's bitrate follows the resolution, frame rate, HDR
    /// and chroma, and the choices are normalized again when "Unlock all FPS" changes.
    private mutating func settled(after before: StreamSettings) {
        if settings.codec == .pyroWave, settings.codec == before.codec,
           settings.resolution != before.resolution || settings.fps != before.fps || settings.hdr != before.hdr
            || settings.text(.pyrowaveChroma) != before.text(.pyrowaveChroma) {
            settings.followPyroWave(displayResolution: device.defaultResolution)
        }
        if settings.bool(.unlockFps) != before.bool(.unlockFps) { settings = Self.normalized(settings, device: device) }
    }

    /// The codec, with each codec's own bitrate (``StreamSettings/changeCodec(to:displayResolution:ownsBitrate:)``).
    mutating func setCodec(_ codec: VideoCodec) {
        settings.changeCodec(to: codec, displayResolution: device.defaultResolution, ownsBitrate: ownsBitrate)
    }

    /// The bitrate from the slider, snapped to whole Mbps within the range. Once moved it stays: it no longer follows
    /// the resolution and the frame rate.
    mutating func setBitrate(_ kbps: Int) {
        let range = StreamSettings.bitrateRange, step = StreamSettings.bitrateStep
        let snapped = range.lowerBound + Int((Double(kbps - range.lowerBound) / Double(step)).rounded()) * step
        settings.bitrateKbps = min(max(snapped, range.lowerBound), range.upperBound)
    }

    /// A catalog slider's value snapped to its grid (from its minimum) within its range.
    private mutating func setSlider(_ key: SettingKey, _ value: Int, step: Int) {
        guard let range = key.range else { return }
        let snapped = range.lowerBound + Int((Double(value - range.lowerBound) / Double(step)).rounded()) * step
        settings.set(key, .int(min(max(snapped, range.lowerBound), range.upperBound)))
    }

    /// Text typed into a TEXT row's dialog (`StreamSettingsStore.writeText`): the custom resolution `<width>x<height>`, the
    /// custom refresh rate (above 0, up to 1000) or the bitrate in Mbps (above 0, up to 9999, which also sets the bitrate).
    /// Returns the error to show, or nil once the value is stored.
    mutating func setText(_ id: String, _ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespaces).lowercased()
        switch id {
        case SettingKey.customResolution.rawValue:
            let parts = value.split(separator: "x", omittingEmptySubsequences: false).map { Int($0) }
            guard parts.count == 2, let w = parts[0], let h = parts[1], (1...32768).contains(w), (1...32768).contains(h) else {
                return L("settings_error_resolution_format")
            }
            settings.set(.customResolution, .text("\(w)x\(h)"))
        case SettingKey.customRefreshRate.rawValue:
            guard let fps = Double(value), fps.isFinite, fps > 0, fps <= 1000 else { return L("settings_error_fps_range") }
            var text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), fps)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            settings.set(.customRefreshRate, .text(text))
        case SettingKey.customBitrate.rawValue:
            guard let mbps = Double(value), mbps.isFinite, mbps > 0, mbps <= 9999 else { return L("settings_error_bitrate_range") }
            settings.set(.customBitrate, .text(value))
            settings.bitrateKbps = Int((mbps * 1000).rounded())
        default:
            guard let key = SettingKey(rawValue: id) else { return nil }
            settings.set(key, .text(input.trimmingCharacters(in: .whitespaces)))
        }
        return nil
    }

    private static func next<T: Equatable>(_ value: T, in list: [T], _ direction: Int) -> T {
        guard !list.isEmpty else { return value }
        guard let index = list.firstIndex(of: value) else { return direction >= 0 ? list[0] : list[list.count - 1] }
        return list[((index + direction) % list.count + list.count) % list.count]
    }

    /// How many steps one repeat of a held direction moves a slider (`sliderAcceleration` of DELOS for Android): one
    /// at first, more the longer it is held, at most a fortieth of the range, so the bitrate's 999 steps cross in about
    /// a second while a short slider never jumps.
    static func sliderAcceleration(steps: Int, repeatCount: Int) -> Int {
        let wanted = switch repeatCount {
        case ..<8: 1
        case ..<20: 5
        case ..<35: 10
        default: 50
        }
        return min(wanted, max(1, steps / 40))
    }
}

/// Settings → Devices → Startup (`ui_default_pc`, `ui_skip_start`): the default PC among the paired ones (None first,
/// then by name) and connecting to it straight away when DELOS starts. Without paired PCs the default cannot be chosen;
/// without a default PC there is nothing to skip to.
struct StartupSetting: Equatable {
    var startup: Startup
    /// The paired PCs: id and name.
    var pcs: [(id: String, name: String)]

    static let defaultPCID = "ui_default_pc"
    static let skipStartID = "ui_skip_start"

    static func == (a: StartupSetting, b: StartupSetting) -> Bool {
        a.startup == b.startup && a.pcs.map(\.id) == b.pcs.map(\.id) && a.pcs.map(\.name) == b.pcs.map(\.name)
    }

    /// None, then the paired PCs alphabetically.
    var choices: [(id: String?, name: String)] {
        [(nil, L("settings_native_default_pc_none"))]
            + pcs.sorted { $0.name.lowercased() < $1.name.lowercased() }.map { (Optional($0.id), $0.name) }
    }

    func rows(_ tab: SettingsTab) -> [SettingRow] {
        guard tab == .devices else { return [] }
        let section = L("settings_native_section_startup")
        let choices = choices
        let index = choices.firstIndex { $0.id == startup.defaultPC } ?? 0
        let label = choices[index].name
        return [
            SettingRow(
                id: Self.defaultPCID, tab: .devices, section: section, icon: Symbols.star, label: L("settings_native_default_pc_title"),
                value: .choice(label: label, options: choices.map(\.name), selected: index),
                help: AppearanceForm.details(
                    value: label,
                    explanation: L(choices[index].id == nil ? "settings_native_help_default_pc_none" : "settings_native_help_default_pc_set"),
                    about: L("settings_native_default_pc_description")),
                enabled: choices.count > 1),
            SettingRow(
                id: Self.skipStartID, tab: .devices, section: section, icon: Symbols.fastForward, label: L("settings_native_skip_start_title"),
                value: .toggle(startup.skipStart), help: L("settings_native_skip_start_description"), enabled: startup.defaultPC != nil),
        ]
    }

    /// The default PC after a step of [direction] (wrapping around); a new default keeps skipping only while it is a PC.
    func steppedDefault(by direction: Int) -> String? {
        let choices = choices
        let index = choices.firstIndex { $0.id == startup.defaultPC } ?? 0
        return choices[((index + direction) % choices.count + choices.count) % choices.count].id
    }
}

/// Android's Devices tab rows for the paired PCs (`devices_manage`, `devices_pair`): the Devices screen and pairing a new PC.
enum DevicesSetting {
    static let manageID = "devices_manage"
    static let pairID = "devices_pair"

    static func rows(_ tab: SettingsTab) -> [SettingRow] {
        guard tab == .devices else { return [] }
        let section = L("settings_native_section_paired_pcs")
        return [
            SettingRow(
                id: manageID, tab: .devices, section: section, icon: Symbols.devices, label: L("settings_native_manage_devices_title"),
                value: .action(label: nil), help: L("settings_native_manage_devices_description")),
            SettingRow(
                id: pairID, tab: .devices, section: section, icon: Symbols.addLink, label: L("settings_native_pair_title"),
                value: .action(label: nil), help: L("settings_native_pair_description")),
        ]
    }
}

/// Android's About → Delos rows: the version, what DELOS is based on, and replaying the welcome (the boot screen again;
/// profiles and paired PCs are kept), then About → Diagnostics: Keep diagnostic logs (device-wide, docs/DIAGNOSTICS.md).
/// Android's update rows are left out: an App Store app does not update itself (App Review guideline 2.5.2).
enum AboutSetting {
    static let versionID = "about_version"
    static let basedID = "about_based"
    static let welcomeID = "about_welcome"
    static let diagLogsID = "about_diag_logs"

    static var firstID: String { versionID }

    /// The app's version as the App Store shows it (`CFBundleShortVersionString`).
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    static func rows(_ tab: SettingsTab, version: String = version, diagnosticLogs: Bool = DiagLog.isEnabled) -> [SettingRow] {
        guard tab == .about else { return [] }
        // A product name: Android does not translate the section either
        let section = "Delos"
        // Android's description of the row names its own platform: the panel shows the product and its version
        return [
            SettingRow(
                id: versionID, tab: .about, section: section, icon: Symbols.version, label: L("settings_native_version_title"),
                value: .info(version), help: "DELOS \(version)"),
            SettingRow(
                id: basedID, tab: .about, section: section, icon: Symbols.accountTree, label: L("settings_native_based_title"),
                value: .info("Artemis · Moonlight"), help: L("settings_native_based_description")),
            SettingRow(
                id: welcomeID, tab: .about, section: section, icon: Symbols.replay, label: L("settings_native_welcome_title"),
                value: .action(label: nil), help: L("settings_native_welcome_description")),
            SettingRow(
                id: diagLogsID, tab: .about, section: L("settings_native_section_diagnostics"), icon: Symbols.diagnosticLogs,
                label: L("settings_native_diag_logs_title"), value: .toggle(diagnosticLogs),
                help: L("settings_native_diag_logs_description") + "\n\n" + L("help_about_diag_logs")),
        ]
    }
}

/// Android's About → MISC → Debug info (`pref_debug_info`, the last row of its preference catalog): it opens ``DebugInfoScreen``.
enum DebugInfoSetting {
    static let id = "pref_debug_info"

    static func rows(_ tab: SettingsTab) -> [SettingRow] {
        guard tab == .about else { return [] }
        return [SettingRow(
            id: id, tab: .about, section: L("title_settings_misc"), icon: Symbols.debug, label: L("title_debug_info"),
            value: .action(label: nil), help: L("help_pref_debug_info"))]
    }
}

/// Android's About → MISC language row; the OS owns the app language, never a profile preference.
enum AppLanguageSetting {
    static let id = "list_languages"

    static var supportsAppSettings: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    static func rows(
        _ tab: SettingsTab, supported: Bool = supportsAppSettings,
        preferredLocalization: String = Bundle.module.preferredLocalizations.first
            ?? Bundle.module.developmentLocalization ?? "en",
        displayLocale: Locale = .current
    ) -> [SettingRow] {
        guard supported, tab == .about else { return [] }
        // The catalog's preferred localization is the actual app language; Locale.current can describe
        // the user's regional formats instead. Preserve regional/script distinctions such as pt-BR/zh-Hans.
        let language = displayLocale.localizedString(forIdentifier: preferredLocalization)
            ?? displayLocale.localizedString(forLanguageCode: preferredLocalization) ?? preferredLocalization
        return [SettingRow(
            id: id, tab: .about, section: L("title_settings_misc"), icon: Symbols.language,
            label: L("title_language_list"), value: .appSettings(language: language),
            help: L("help_list_languages"))]
    }
}
