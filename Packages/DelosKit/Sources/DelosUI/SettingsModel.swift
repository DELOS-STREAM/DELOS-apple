import DelosCore
import DelosData
import enum DelosMedia.FramePacing
import Foundation

/// A tab of Settings (`SettingsTab` of DELOS for Android), as far as its rows are ported, in Android's order: Stream
/// (resolution, frame rate, bitrate, codec), Audio (playing audio on the PC, interface sounds), Controls (interface
/// haptics) and Appearance (``AppearanceForm``).
enum SettingsTab: CaseIterable, Hashable, Sendable {
    case stream, audio, controls, appearance

    var label: String {
        switch self {
        case .stream: L("settings_tab_stream")
        case .audio: L("settings_tab_audio")
        case .controls: L("settings_tab_controls")
        case .appearance: L("settings_tab_appearance")
        }
    }

    var icon: String {
        switch self {
        case .stream: Symbols.cast
        case .audio: Symbols.graphicEq
        case .controls: Symbols.sportsEsports
        case .appearance: Symbols.appearance
        }
    }

    /// What the description panel says while no row of the tab is focused.
    var help: String {
        switch self {
        case .stream: L("settings_tab_stream_description")
        case .audio: L("settings_tab_audio_description")
        case .controls: L("settings_tab_controls_description")
        case .appearance: L("settings_tab_appearance_description")
        }
    }

    /// The tab [direction] steps away (L1 / R1), wrapping around.
    func step(_ direction: Int) -> SettingsTab {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
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
    /// Opens something (a screen).
    case action
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
    /// (`SettingsHelp.details`).
    let help: String
    /// A color dot before a choice's value (`RowValue.Choice.swatch` of DELOS for Android: the palette's main hue).
    var swatch: RGBA? = nil
}

/// What this device offers Settings → Stream (`SettingsCapabilities` of DELOS for Android).
struct StreamDevice: Equatable, Sendable {
    var pixelWidth: Int
    var pixelHeight: Int
    var maxFramesPerSecond: Int
    /// The formats VideoToolbox decodes in hardware (``DecoderSupport``).
    var decodable: VideoFormats

    /// The display's resolution while the profile has not chosen one.
    var defaultResolution: StreamResolution { .forDisplay(pixelWidth: pixelWidth, pixelHeight: pixelHeight) }
}

/// The rows of Settings → Stream and → Audio over one profile's ``StreamSettings``, and the changes the controller and
/// touch make to them. Everything a row shows and does is here; the view only draws it.
struct StreamSettingsForm: Equatable {
    var settings: StreamSettings
    let device: StreamDevice

    init(settings: StreamSettings, device: StreamDevice) {
        // Choices the device does not offer are replaced when the screen opens, as on Android
        self.settings = StreamChoices.normalized(
            settings, displayWidth: device.pixelWidth, displayHeight: device.pixelHeight,
            maxFramesPerSecond: device.maxFramesPerSecond, decodable: device.decodable)
        self.device = device
    }

    static let resolution = "list_resolution"
    static let frameRate = "list_fps"
    static let bitrate = "seekbar_bitrate_kbps"
    static let codec = "video_format"
    static let framePacing = "frame_pacing"
    static let hostAudio = "checkbox_host_audio"

    /// The rows of [tab] in their order.
    func rows(_ tab: SettingsTab) -> [SettingRow] {
        switch tab {
        case .stream: [resolutionRow, frameRateRow, bitrateRow, codecRow, framePacingRow]
        case .audio: [hostAudioRow]
        case .controls, .appearance: []
        }
    }

    // MARK: The values of each row

    /// The resolutions: the display's own (nil: Android has no such row; it is the default here), the presets, the native.
    var resolutionOptions: [(value: StreamResolution?, label: String)] {
        [(nil, L("settings_screen_dot_join", L("videoformat_auto"), device.defaultResolution.text))]
            + StreamChoices.resolutions(displayWidth: device.pixelWidth, displayHeight: device.pixelHeight).map { choice in
                switch choice {
                case .preset(let r): (r, Self.presetLabel(r) ?? r.text)
                case .native(let r, let portrait):
                    (r, portrait ? L("settings_resolution_native_portrait", r.text) : L("settings_resolution_native", r.text))
                }
            }
    }

    var frameRateOptions: [(value: Int, label: String)] {
        StreamChoices.frameRates(maxFramesPerSecond: device.maxFramesPerSecond).map { choice in
            switch choice {
            case .preset(let fps): (fps, Self.presetLabel(fps: fps))
            case .native(let fps): (fps, L("settings_fps_native", fps))
            }
        }
    }

    var codecOptions: [(value: VideoCodec, label: String)] {
        VideoCodec.choices(decodable: device.decodable).map { ($0, Self.codecLabel($0)) }
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
        }
    }

    private static func codecLabel(_ codec: VideoCodec) -> String {
        switch codec {
        case .automatic: L("videoformat_auto")
        case .av1: L("videoformat_av1always")
        case .hevc: L("videoformat_hevcalways")
        case .h264: L("videoformat_h264always")
        }
    }

    /// The resolution the next stream asks for.
    var effectiveResolution: StreamResolution { settings.resolution ?? device.defaultResolution }

    /// The bitrate the slider shows: the chosen one, else the default for the resolution and frame rate.
    var effectiveBitrate: Int { settings.bitrate(at: effectiveResolution) }

    // MARK: Rows

    private var section: String { L("category_video_settings") }

    private var resolutionRow: SettingRow {
        let options = resolutionOptions
        let selected = options.firstIndex { $0.value == settings.resolution }
        let label = selected.map { options[$0].label } ?? L("settings_choice_unavailable", effectiveResolution.text)
        let explanation = L("help_dynamic_resolution", "\(effectiveResolution.width) × \(effectiveResolution.height)")
        return SettingRow(
            id: Self.resolution, tab: .stream, section: section, icon: Symbols.resolution, label: L("title_resolution_list"),
            value: .choice(label: label, options: options.map(\.label), selected: selected),
            help: Self.details(value: label, explanation: explanation, unavailable: selected == nil, about: L("help_list_resolution")))
    }

    private var frameRateRow: SettingRow {
        let options = frameRateOptions
        let selected = options.firstIndex { $0.value == settings.fps }
        let label = selected.map { options[$0].label } ?? L("settings_choice_unavailable", "\(settings.fps)")
        // Android's line for the chosen rate names its Warp modes, which do not exist here: the help says what the row does
        return SettingRow(
            id: Self.frameRate, tab: .stream, section: section, icon: Symbols.frameRate, label: L("title_fps_list"),
            value: .choice(label: label, options: options.map(\.label), selected: selected),
            help: Self.details(value: label, explanation: nil, unavailable: selected == nil, about: L("help_list_fps")))
    }

    private var bitrateRow: SettingRow {
        SettingRow(
            id: Self.bitrate, tab: .stream, section: section, icon: Symbols.networkCheck, label: L("title_seekbar_bitrate"),
            value: .slider(
                value: effectiveBitrate, range: StreamSettings.bitrateRange, step: StreamSettings.bitrateStep, divisor: 1000,
                unit: " " + L("suffix_seekbar_bitrate_mbps")),
            // Android's own help points to the stream menu's bitrate, which is not ported: its summary is the help here
            help: L("summary_seekbar_bitrate"))
    }

    private var codecRow: SettingRow {
        let options = codecOptions
        let selected = options.firstIndex { $0.value == settings.codec }
        let label = selected.map { options[$0].label } ?? L("settings_choice_unavailable", Self.codecLabel(settings.codec))
        return SettingRow(
            id: Self.codec, tab: .stream, section: section, icon: Symbols.codec, label: L("title_video_format"),
            value: .choice(label: label, options: options.map(\.label), selected: selected),
            help: Self.details(value: label, explanation: Self.codecHelp(settings.codec), unavailable: selected == nil, about: L("help_video_format")))
    }

    /// Android's modes that the display layer can do; the Warp modes, the FPS limit and Fast V-Sync are not offered.
    var framePacingOptions: [(value: FramePacing, label: String)] {
        FramePacing.allCases.map { mode in
            switch mode {
            case .latency: (mode, L("pacing_latency"))
            case .balanced: (mode, L("pacing_balanced"))
            case .smoothness: (mode, L("pacing_smoothness"))
            }
        }
    }

    private var framePacingRow: SettingRow {
        let options = framePacingOptions
        let selected = options.firstIndex { $0.value == settings.framePacing }
        let label = selected.map { options[$0].label } ?? options[1].label
        let explanation = switch settings.framePacing {
        case .latency: L("help_frame_pacing_latency")
        case .balanced: L("help_frame_pacing_balanced")
        case .smoothness: L("help_frame_pacing_smoothness")
        }
        // Android's general help is about its Warp modes, which do not exist here: the chosen mode's line is the help
        return SettingRow(
            id: Self.framePacing, tab: .stream, section: section, icon: Symbols.smoothing, label: L("title_frame_pacing"),
            value: .choice(label: label, options: options.map(\.label), selected: selected),
            help: "\(label)\n\(explanation)")
    }

    private var hostAudioRow: SettingRow {
        SettingRow(
            id: Self.hostAudio, tab: .audio, section: L("category_host_settings"), icon: Symbols.speaker,
            label: L("title_checkbox_host_audio"), value: .toggle(settings.playAudioOnHost), help: L("help_checkbox_host_audio"))
    }

    /// `SettingsHelp.details`: the chosen value with its explanation and the note that it is unavailable, a blank line,
    /// then what the setting does.
    static func details(value: String, explanation: String?, unavailable: Bool, about: String) -> String {
        let state = [
            explanation.map { "\(value)\n\($0)" },
            unavailable ? L("help_note_unavailable") : nil,
        ].compactMap { $0 }.joined(separator: "\n")
        return [state, about].filter { !$0.isEmpty }.joined(separator: "\n\n")
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
        case Self.codec: settings.codec = Self.next(settings.codec, in: codecOptions.map(\.value), direction)
        case Self.framePacing: settings.framePacing = Self.next(settings.framePacing, in: framePacingOptions.map(\.value), direction)
        case Self.bitrate: setBitrate(effectiveBitrate + direction * StreamSettings.bitrateStep)
        case Self.hostAudio: settings.playAudioOnHost.toggle()
        default: break
        }
        return settings != before
    }

    /// A value picked from a choice row's list.
    mutating func pick(_ id: String, option index: Int) {
        switch id {
        case Self.resolution: if resolutionOptions.indices.contains(index) { settings.resolution = resolutionOptions[index].value }
        case Self.frameRate: if frameRateOptions.indices.contains(index) { settings.fps = frameRateOptions[index].value }
        case Self.codec: if codecOptions.indices.contains(index) { settings.codec = codecOptions[index].value }
        case Self.framePacing: if framePacingOptions.indices.contains(index) { settings.framePacing = framePacingOptions[index].value }
        default: break
        }
    }

    /// The bitrate from the slider, snapped to whole Mbps within the range. Once moved it stays: it no longer follows
    /// the resolution and the frame rate.
    mutating func setBitrate(_ kbps: Int) {
        let range = StreamSettings.bitrateRange, step = StreamSettings.bitrateStep
        let snapped = range.lowerBound + Int((Double(kbps - range.lowerBound) / Double(step)).rounded()) * step
        settings.bitrateKbps = min(max(snapped, range.lowerBound), range.upperBound)
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
